# O estado de um finding entre branches: plano

Desenho: [`../specs/2026-09-13-cross-branch-finding-state-design.md`](../specs/2026-09-13-cross-branch-finding-state-design.md).

Quatro tarefas, um PR. A ordem é de dentro para fora: primeiro a pergunta ao
git isolada e testável, depois quem a usa, depois quem a mostra.

## Global Constraints

- **A máquina de estados não muda.** Nenhum finding pode mudar de `state` por
  causa desta entrega. `diff.classify` não é tocada. Se um teste existente de
  `classify` mudar de resultado, a entrega está errada — não é o teste que se
  corrige.
- **`bin/agentloop-server` e o módulo `security` são python 3, só stdlib.**
- **Editar `ui/` obriga a `bash build/build-ui.sh` no mesmo commit**;
  `build/ui-digest.sh` carimba **todos** os ficheiros debaixo de `ui/`.
- **O CHANGELOG move-se com cada commit de código.**
- **Nunca `git add -A`.** Adicionar por caminho.
- **Nenhum home real** (`/Users/<nome>`) em ficheiro versionado.
- **Nada de rede, nada do repositório vivo nos testes:** um repositório de
  rascunho em `$TMPDIR`, criado pelo teste, com `git init` e commits próprios.
- **As quatro suites no fim de cada tarefa**, o e2e nunca ao mesmo tempo que o
  selftest. Linha de base a fixar no arranque, não daqui (o merge do OpenCode
  mexeu nos números): correr as quatro **antes** de tocar em nada e escrever
  os quatro valores no topo do ledger de progresso.
- **Pré-requisito:** o merge do OpenCode. Esta entrega toca em
  `bin/agentloop-server` e em `ui/security/`, e as bundles conflituam sempre.

---

## Tarefa 1: perguntar ao git, isolado

**Cria:** uma função em `bin/security/` — proponho `branchgit.py`, novo, para
não engordar `queries.py` com a única parte que sai do processo.

```
def contains(repo_path, commit, branch_head, timeout=2.0) -> bool | None
```

`True`/`False` pela resposta do `git merge-base --is-ancestor`, e **`None`**
para tudo o resto: repositório inexistente, commit desconhecido, git ausente,
tempo esgotado. `None` é a resposta honesta e não pode ser confundida com
`False` — a spec explica porquê.

E a irmã:

```
def head_of(repo_path, branch, timeout=2.0) -> str | None
```

`refs/remotes/origin/<branch>` primeiro, depois `refs/heads/<branch>` — a
mesma ordem que `bin/agentloop` já usa quando abre uma análise (âncora: o
comentário *"no such branch in"*). Sem essa ordem, uma branch local
desactualizada responde por uma remota mais recente.

**Testes** (`tests/security/test_branchgit.py`), com um repositório criado
pelo teste: um commit dentro da branch → `True`; um commit noutra linha →
`False`; repositório inexistente → `None`; commit inventado → `None`; git com
tempo esgotado → `None` (um `timeout=0.001` chega).

**Não usar `subprocess.run(..., shell=True)`** e passar sempre lista. E
`-C <repo>`, nunca `chdir`: o servidor é um processo só e não pode mudar de
directório debaixo dos pés de outro pedido.

---

## Tarefa 2: a consulta que encontra o mesmo fingerprint noutra branch

**Muda:** `bin/security/queries.py`.

Uma função nova, ao lado de `checklist`:

```
def fixed_elsewhere(conn, project, repo, branch, fingerprints) -> dict
```

Para cada branch do mesmo `(project, repo)` **que não seja** `branch`, a
análise mais recente em estado `done`/`capped`; dessa análise, os
fingerprints que o `checklist` dá como `fixed`; e para cada um, a linha
`{branch, commit, analysis_id, at}`.

**Reutilizar `checklist`, não reimplementar o diff.** O `fixed` de uma análise
já é calculado ali, com o `_proven` e as decisões todas. Uma segunda
implementação da mesma pergunta é a maneira garantida de as duas divergirem —
e este repositório já foi mordido por conhecimento duplicado em dois sítios
três vezes só na entrega do OpenCode.

**Uma análise por branch, não todas.** Um projecto com dez branches e cem
análises não pode pagar cem passagens de `classify` por cada leitura da
página. O cache por pedido que `checklist` já aceita é passado para aqui.

**Testes** (`tests/security/`): duas branches, um fingerprint `fixed` na
outra → aparece; `fixed` numa análise `failed` → **não** aparece (a mesma
regra que o `history` já aplica); a mesma branch → nunca aparece; um
fingerprint que nunca ninguém deu por corrigido → ausente.

---

## Tarefa 3: juntar as duas, e onde isso entra

**Muda:** `bin/security/queries.py` (`finding_rows`, que é o que o ecrã lê) e
`bin/security/cli.py` (o verbo que o serve).

Para as linhas de um projecto, depois de as ter: uma chamada a
`fixed_elsewhere`, depois **uma** chamada a `head_of` por branch candidata, e
**uma** a `contains` por par (branch candidata, branch da linha) — nunca por
finding. O resultado enche o campo `fixed_elsewhere` descrito na spec, com
`in_this_branch` ausente quando o git respondeu `None`.

**O caminho do repositório** vem da configuração do projecto (`projects.json`,
o `cwd`), não do ledger — o ledger guarda o **nome** do repo, não onde ele
está. Se o projecto não estiver configurado, ou o `cwd` não existir, o campo
sai sem `in_this_branch`.

**Testes:** o custo — com N findings e M branches, contar as chamadas e exigir
O(M); o campo presente e ausente nos casos da spec; e o caso que engana (a
correcção dentro da branch, o finding na mesma aberto) a devolver
`in_this_branch: true` **com `state` ainda `open`**.

---

## Tarefa 4: mostrá-lo, sem inventar um estado

**Muda:** `ui/security/findings-screen.js`, `ui/css/components.css`,
`tests/test_page_contract.py`, e as bundles no mesmo commit.

Na linha de um finding com o campo:

- `in_this_branch: true` → um distintivo que diga que a correcção já está
  nesta branch e que falta re-analisar, com a branch e o commit curto no
  `title`. **A acção que se oferece é re-analisar**, não marcar resolvido.
- `in_this_branch: false` → um distintivo mais discreto: corrigido em
  `<branch>`, ainda não aqui.
- sem `in_this_branch` → nada. Não se desenha uma dúvida.

**O filtro `Status` não ganha valores novos** — o estado não mudou. Se quiseres
filtrar por isto, é uma caixa à parte ("corrigidos noutra branch"), e é uma
decisão de produto que o Luiz deve ver antes de ser escrita.

**Contrato da página:** o distintivo aparece nos dois casos e não aparece no
terceiro; o `state` continua `open` nos três; e nenhum contador da fila de
números muda por causa do campo (é uma anotação, não uma reclassificação).

---

## Auto-revisão do plano

- **O risco real não é técnico, é de leitura.** Um distintivo que diga
  "corrigido" sobre um finding que continua aberto ensina o operador a ignorar
  o estado. O texto tem de dizer *onde* e *o que falta*, sempre.
- **A Tarefa 3 é onde isto degrada em silêncio.** Se o número de chamadas ao
  git crescer com os findings em vez das branches, ninguém dá por isso num
  projecto pequeno e a página fica lenta num grande. Daí a asserção de custo.
- **Se alguma tarefa for abandonada**, que seja a 4: as 1 a 3 põem o campo na
  API e a exportação consolidada já o pode usar sem UI nenhuma.
