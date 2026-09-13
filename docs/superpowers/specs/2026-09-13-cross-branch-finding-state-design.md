# O estado de um finding entre branches: desenho

## O que acontece hoje, e porque não é um defeito

Um finding aparece em `develop`. Corrige-se em `main`. A plataforma continua a
mostrá-lo aberto em `develop`. A causa está em duas linhas de
`queries.checklist`:

```python
prev = ledger.latest_analysis(conn, analysis["project"], analysis["repo"],
                              analysis["branch"], before=analysis_id)
```

e, para o histórico:

```sql
WHERE a.project=? AND a.repo=? AND a.branch=? AND a.id < ?
```

A linha de base e o histórico são **estritamente da mesma branch**. Um finding
de `develop` só é comparado com análises de `develop`.

**E isso está certo.** Enquanto o `develop` não tiver o commit que corrigiu, o
buraco está lá. Marcá-lo resolvido porque foi resolvido noutro sítio seria
mentir sobre código que continua vulnerável — exactamente o erro que o resto
deste módulo se dá ao trabalho de não cometer (ver `diff._proven`: *absence is
only evidence when the looking finished*).

O mecanismo até se corrige sozinho: quando o `develop` receber o merge e for
re-analisado, o finding desaparece e é marcado `fixed`.

## Então qual é o problema

**A janela.** Entre corrigir e re-analisar, o operador — e agora, com a
exportação consolidada, **um agente** — recebe uma lista onde não consegue
distinguir três situações muito diferentes:

1. um buraco que continua aberto em todo o lado;
2. um buraco já corrigido noutra branch, cujo commit **ainda não está** nesta;
3. um buraco já corrigido noutra branch, cujo commit **já está** nesta, e que
   só continua a aparecer porque ninguém voltou a analisar.

O caso 3 é trabalho desperdiçado: o agente vai corrigir o que já está
corrigido. O caso 2 é informação valiosa que hoje não existe em lado nenhum —
saber que a correcção existe e onde ir buscá-la vale mais do que a descoberta.

## O que torna isto respondível

Duas colunas que já existem:

- **`analysis.commit_sha`** — cada análise regista o commit exacto que leu.
- **`finding.fingerprint`** — identidade estável do mesmo problema entre
  análises **e entre branches**.

Com as duas, e com o repositório em disco (o motor já resolve o SHA de uma
branch a partir do `cwd` do projecto quando abre uma análise), o git responde
à pergunta que falta: *o commit onde isto foi dado como ausente já está dentro
desta branch?*

```
git merge-base --is-ancestor <commit da análise que o deu por ausente> <cabeça desta branch>
```

## A decisão que sustenta tudo o resto

**A ancestralidade é um sinal forte, não é prova, e o desenho tem de o dizer.**

Se o fingerprint F foi provado ausente no commit C da `main`, e C é
antepassado da cabeça do `develop`, então o `develop` contém o código que
fechou aquilo. **Mas não se segue que F esteja ausente do `develop`**: o
`develop` pode ter reintroduzido o mesmo padrão nos seus próprios commits, que
nunca passaram pela `main`.

A única prova continua a ser re-analisar. Portanto:

- **Nada nesta entrega marca um finding como `fixed`.** A máquina de estados de
  `diff.classify` fica **intacta**, e a palavra `fixed` continua a significar o
  que significa hoje: um produtor voltou a olhar e não o encontrou.
- O que entra é uma **anotação ao lado do estado**, não um estado novo. Um
  estado novo obrigaria todos os leitores — ecrãs, relatórios, contadores,
  filtros — a aprendê-lo, e um que não aprendesse mostraria o finding em
  silêncio na categoria errada.

## O que se acrescenta

A cada finding aberto, quando existir, um campo:

```json
"fixed_elsewhere": {
  "branch": "main",
  "commit": "a1b2c3d",
  "analysis_id": 14,
  "at": 1789300000,
  "in_this_branch": true
}
```

- **`in_this_branch: true`** — o commit é antepassado da cabeça desta branch.
  Leitura: *"a correcção já cá está; isto está muito provavelmente resolvido e
  só falta re-analisar."* A acção certa é uma re-análise, e é isso que a
  interface deve oferecer — não um botão para marcar resolvido à mão.
- **`in_this_branch: false`** — corrigido lá, ainda não aqui. Leitura:
  *"o buraco é real nesta branch, e a correcção existe naquela."* Para um
  agente, isso é meio caminho andado: vai ver o que foi feito em vez de
  desenhar de novo.
- **campo ausente** — ninguém em lado nenhum deu isto por corrigido.

### Quando não há git a quem perguntar

O repositório pode não estar em disco, a branch pode ter desaparecido, o
projecto pode ter mudado de sítio. Nesse caso o campo sai **sem**
`in_this_branch` (e não com `false`, que é uma afirmação e seria falsa), mais
um `unknown_reason`. Um leitor que não consiga decidir tem de o dizer, não
escolher a resposta mais cómoda.

### O custo, e como se paga

Uma consulta por projecto — *que fingerprints estão `fixed` na análise mais
recente de cada outra branch* — e depois **uma** chamada ao git por branch de
origem candidata, não uma por finding. As cabeças das branches e o resultado
das ancestralidades vivem numa cache por pedido, ao lado da cache que
`queries.checklist` já usa.

O `--is-ancestor` do git é barato, mas nunca corre sem limite de tempo e nunca
bloqueia uma resposta da página: um repositório lento devolve o campo sem
`in_this_branch`, como acima.

## Fora desta versão

- **Marcar `fixed` por ancestralidade.** É a coisa que este desenho recusa
  fazer, e a razão está acima.
- **Re-analisar automaticamente** uma branch onde a correcção já entrou.
  Oferecer a acção, sim; decidir gastar dinheiro do operador sozinho, não.
- Comparar entre **repositórios** diferentes. O fingerprint atravessa branches
  do mesmo repositório; noutro repositório é outra coisa com o mesmo nome.
- Propagar **decisões** (`accepted`, `false_positive`) entre branches. É a
  mesma família de problema e uma decisão de produto diferente — um risco
  aceite numa branch não é automaticamente aceite noutra.

## Testes

- **A regra, sem git:** dois fingerprints iguais em duas branches, um `fixed`
  na outra → o campo aparece; sem correspondência → não aparece.
- **A ancestralidade, com um repositório de rascunho** (o e2e já sabe criar
  um): o commit da correcção dentro da branch → `in_this_branch: true`; fora
  dela → `false`; branch inexistente → o campo **sem** `in_this_branch` e com
  a razão.
- **A máquina de estados não mexeu:** os testes de `diff.classify` que já
  existem passam sem alteração, e nenhum finding muda de `state` por causa
  desta entrega. Se algum mudar, a entrega está errada.
- **O caso que engana:** F corrigido na `main`, `main` fundida no `develop`,
  e o `develop` a **reintroduzir** o mesmo padrão num commit próprio. O campo
  diz `in_this_branch: true` e o finding continua `open` — e o teste existe
  para fixar que dizemos "provavelmente resolvido, re-analisa" e nunca
  "resolvido".
- **Degradação:** repositório em falta, git lento (limite de tempo atingido),
  `commit_sha` que já não existe no repositório → campo sem
  `in_this_branch`, nunca uma excepção, nunca uma página em branco.
- **Custo:** com N findings abertos e M branches, o número de chamadas ao git
  é O(M) e não O(N). Uma asserção que conte as chamadas, porque isto degrada
  em silêncio e só se nota num projecto grande.

## Relação com a exportação consolidada

Esta entrega é a que dá **valor real** à irmã
([`2026-09-13-consolidated-findings-export-design.md`](2026-09-13-consolidated-findings-export-design.md)):
um documento com 79 findings onde 20 já estão corrigidos noutra branch manda
um agente fazer trabalho que já está feito. Com o campo, o documento pode
ordená-los por *o que é mesmo preciso fazer* e dizer, em cada um, se a
correcção já existe algures.

**Recomendo esta primeiro.** A exportação sem ela funciona; com ela, vale o
dobro.
