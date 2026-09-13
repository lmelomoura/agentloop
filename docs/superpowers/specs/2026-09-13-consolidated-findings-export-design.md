# A exportação consolidada de findings: desenho

## O problema, medido no código

O botão **Export** do separador *Findings* faz uma coisa só
(`ui/security/findings-screen.js`):

```js
exportBtn.title = "Open this project's Reports tab";
exportBtn.onclick = () => secSwitchProjectTab("reports");
```

Navega. E o sítio para onde navega oferece relatórios **por análise** —
`/api/security/report?analysis=<id>&format=<fmt>`, que corre
`agentloop security render --analysis N` e devolve um ficheiro com o
`Content-Disposition` de uma análise só.

Isso não é um defeito do botão: é a funcionalidade errada debaixo dele. Quem
está no separador *Findings* está a olhar para **79 findings de várias
análises e várias branches** e quer levá-los todos; o que existe do outro lado
é um documento por corrida.

O caso de uso é explícito e não é humano: **um agente vai pegar no documento e
trabalhar a lista toda**. Isso impõe duas coisas que os relatórios por análise
não têm — que o documento atravesse branches, e que **diga a branch de cada
finding**, porque sem isso o agente não sabe onde aplicar a correcção.

## O que já existe e não se reinventa

| peça | onde | o que faz |
|---|---|---|
| as linhas que o ecrã desenha | `queries.finding_rows` | um projecto inteiro, com filtros de severidade, estado, categoria, branch, caminho e texto |
| o bundle do ecrã | `cli.py` `findings-page` | as linhas + os filtros guardados, numa chamada |
| os renderizadores | `report.py` `as_json` / `as_markdown` / `as_html` | **por análise**: recebem `(analysis, findings, coverage_note)` |
| a rota de download | `/api/security/report` | valida o formato e o id, corre `security render`, devolve o ficheiro |
| o registo do download | `security event --kind report_exported` | fica no histórico do projecto |

A exportação nova é **uma quarta forma de reunir findings**, não um quarto
renderizador nem uma segunda maneira de descarregar.

## Decisões

### O documento leva tudo o que está registado, não o que o filtro mostra

O ecrã já diz, por baixo da fila de números:

> *24 findings below low are hidden by this project's severity floor —
> recorded, not shown. **Downloads always contain every recorded finding,
> whatever the severity floor shows.***

Esse contrato já existe e já foi ensinado ao utilizador. A exportação
consolidada segue-o: **tudo o que está registado**, independentemente do piso
de severidade e dos filtros que estejam postos no ecrã. É também o que o caso
de uso pede — *"uma lista consolidada de todos os findings encontrados, assim
um outro agente consegue trabalhar em tudo"*.

O documento **diz isto na primeira secção**, com os números aos lados: quantos
findings leva, quantos o ecrã estava a mostrar quando o botão foi carregado, e
que os filtros não foram aplicados. Um agente que receba 79 findings depois de
alguém ter filtrado por *Critical* tem de perceber porquê sem perguntar.

> **Decisão do autor, revertível:** se preferires que o botão exporte **o que
> está filtrado**, é uma linha no pedido e um parágrafo no documento. Escolhi
> "tudo" por ser o contrato que a página já anuncia e o que a frase do pedido
> descreve. Diz e muda-se.

### Uma linha por finding, agrupada por branch

O agente precisa de saber **onde** corrigir antes de saber **o quê**. O
documento agrupa por `branch`, e dentro de cada branch por severidade
decrescente. Cada finding leva, no mínimo:

`fingerprint` · `severity` · `category` · `rule` · `title` · `branch` ·
`commit_sha` da análise que o viu · ficheiro:linha de cada ocorrência ·
`state` · `rationale` · `remediation` · a análise de origem (`#11 (Deep)`) ·
`first_seen`.

O `fingerprint` vai **primeiro** e não por estética: é a única identidade
estável de um finding entre análises e entre branches, e é por ele que o
agente reporta de volta o que corrigiu.

### O `commit_sha` de cada análise entra no documento

`analysis.commit_sha` já existe na tabela. Sem ele, um agente que receba um
finding em `develop` não sabe se o código que está a ler é o código que foi
analisado. Com ele, sabe — e é também a chave da entrega irmã
([`2026-09-13-cross-branch-finding-state-design.md`](2026-09-13-cross-branch-finding-state-design.md)),
que usa esse mesmo `commit_sha` para responder à pergunta "isto já foi
corrigido noutro lado".

### Dois formatos, os mesmos que já existem

**Markdown** (a omissão: é o que um agente lê melhor e o que uma pessoa
consegue rever) e **JSON** (para quem quiser processar). Nada de HTML nem de
SBOM: são formatos de auditoria por análise e não é isso que isto é.

### A rota é nova, não é o `report` com um modo a mais

`/api/security/findings-export`, ao lado de `/api/security/findings`.

A rota `/api/security/report` tem uma guarda construída à volta de **um id
inteiro e um formato de uma lista fechada**, e o comentário dela diz
explicitamente que nenhuma string do chamador chega ao cabeçalho. Enfiar-lhe
um segundo modo, com um projecto (texto livre) e filtros, obriga a alargar
essa guarda — que é precisamente a guarda que não se deve alargar. Uma rota
nova valida o que precisa e deixa a antiga em paz.

O download regista um evento, como o outro: `kind: findings_exported`.

## Fora desta versão

- Exportar o que está filtrado (ver a decisão acima).
- HTML e SBOM.
- Exportar vários projectos numa só chamada. O ecrã é de um projecto; o
  documento é de um projecto.
- Um formato pensado para *ingestão* automática por outra ferramenta (SARIF).
  Se aparecer, é um renderizador novo em `report.py`, não uma mudança aqui.

## Testes

- **`report.py`**: o Markdown e o JSON consolidados sobre um conjunto com três
  branches, incluindo uma branch com zero findings (tem de aparecer, dizendo
  que está limpa: um agente que não veja a branch não sabe se ela está boa ou
  se foi esquecida).
- **A ordem**: por branch, e dentro dela por severidade decrescente; dois
  findings da mesma severidade saem por ordem estável (o `fingerprint`), para
  o documento não mudar entre duas exportações do mesmo estado.
- **O cabeçalho diz a verdade**: quantos findings leva, quantos o ecrã
  mostrava, e que os filtros não foram aplicados.
- **A rota**: formato fora da lista → 400; projecto inexistente → 404, não uma
  lista vazia (um agente que receba um documento vazio de um projecto mal
  escrito começa a trabalhar em nada);
  `Content-Disposition` com um nome derivado do projecto **saneado**, nunca a
  string do chamador.
- **O evento**: um download deixa um `findings_exported` no histórico.
- **Contrato da página**: o botão existe, chama a rota nova e **não** navega
  para o separador de relatórios.

## Como isto se relaciona com a outra entrega

Este documento é útil sozinho — a lista consolidada com a branch de cada
finding já resolve o problema descrito. Mas vale **muito** mais depois da
entrega irmã: sem o estado entre branches, um agente que receba 79 findings
vai trabalhar em findings que já foram corrigidos noutra branch e ainda não
foram re-analisados nesta. A ordem recomendada é **primeiro o estado, depois
a exportação** — e, se for ao contrário, o documento ganha uma coluna quando
a outra entrega chegar.
