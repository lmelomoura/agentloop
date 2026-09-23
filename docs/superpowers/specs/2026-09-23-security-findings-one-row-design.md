# Uma linha por finding, e SAST decididos que não voltam: desenho

## O que o operador viu

No separador *Findings* do Minerva, com o filtro de estado em *False
positive*, o mesmo finding aparece duas vezes:

| título | local | análise | branch | estado |
|---|---|---|---|---|
| aws access token committed to the repository | `tests/knowledge_api/test_redaction.py:39` | #16 (Deep) | develop | FALSE POSITIVE |
| aws access token committed to the repository | `tests/knowledge_api/test_redaction.py:39` | #17 (Deep) | main | FALSE POSITIVE |

A queixa: *"findings marcados como false positive, e outros, reaparecem
quando faço um novo run"*.

## O que acontece de facto

Medido sobre uma cópia do ledger real (`data/security.db`, análises 3 a 18),
correndo o `queries.checklist` desta árvore:

- **As decisões não se perdem.** O finding da tabela tem o fingerprint
  `26c4bd41d73b…` em todas as análises, da #13 à #18, e a decisão
  `false_positive` tomada a 2026-09-13 aplica-se em todas. As análises #16
  (develop), #17 (main) e #18 (main) dão, cada uma, 35 `false_positive` e 19
  `accepted`.
- **O que reaparece é a linha.** `queries.finding_rows` une um checklist por
  branch (o último run terminado de cada uma), e um finding presente nas duas
  dá duas linhas. Os 46 secrets do `develop` estão todos também no `main`, por
  isso tudo o que foi triado aparece duas vezes, e cada run noutra branch
  "traz de volta" o que já tinha sido decidido.

A tabela `decision` foi desenhada por projecto precisamente para isto não
acontecer (o comentário do schema: *dismissing a false positive on develop
and watching it resurrect on main would make the feature unusable*). O ledger
cumpre; a lista não.

### Uma segunda causa, nos SAST do agente

O fingerprint de um `sast` cunhado pelo agente é
`fingerprint("sast", rule, path, snippet)`, com a regra, o caminho e o snippet
escolhidos por ele. A skill manda reutilizar o fingerprint de uma linha que o
`checklist` já liste, e dentro de uma branch isso funciona. Mas o `checklist`
só compara com o baseline **da mesma branch**. Um SAST decidido no `develop`
nunca é mostrado ao agente que analisa o `main`, que o cunha de novo, com
outro fingerprint e sem decisão.

Aconteceu com a decisão de produto RP-217: o mesmo problema
(`ReviewQueueController.php:54`) ficou `ece2e8e433c9…` no `main` (#10, #12) e
`60288a312941…` no `develop` (#9, #11, #14), e teve de ser aceite duas vezes
(2026-09-11 e 2026-09-14). Hoje há 12 SAST decididos no Minerva: os 8 do
pré-passe do Semgrep têm identidade determinística e estão estáveis; os 4 do
agente (`ece2e8e433c9`, `0e0587a64535`, `60288a312941`, `9e141cbdc85b`) já não
estão no checklist do `main`, e são exactamente os que podem voltar como `new`.

## Decisões tomadas com o operador

1. **O ecrã mostra uma linha por finding** (por fingerprint), não uma por
   branch.
2. **Quando as branches discordam, vence o que pede atenção.** Aberto em
   qualquer branch vence uma decisão, uma decisão vence `fixed`, e `fixed` só
   aparece quando o finding está fixed em todas. É a regra que o donut já
   segue (`_open_findings_by_fingerprint`: aberto numa branch continua a ser
   exposição).
3. **A segunda causa trata-se nesta entrega.** O `checklist` do agente passa a
   mostrar os SAST **decididos** que não lista, e só esses.
4. **Abordagens:** agrupar dentro de `finding_rows` com um interruptor
   `group`; o `export-findings` continua por branch; `decided_sast` entra na
   saída do verbo `checklist`, não em `queries.checklist()`.

## Parte 1 — `finding_rows(group=True)`

`group=True` passa a ser o default: é o que o ecrã (`findings-page`) e o
diálogo da Activity pedem. `group=False` é o comportamento de hoje, byte a
byte, e é o que o `export-findings` passa a pedir explicitamente — o documento
consolidado é organizado por branch de propósito (*"apply a fix on that
branch"*, ver a spec de 2026-09-13).

Pela ordem:

1. **Linhas por branch**, como hoje: o checklist do último run terminado de
   cada branch, com `branch`, `analysis_id`, `repo` e `first_seen`.
2. **A anotação `fixed_elsewhere`**, como hoje, mas antes de agrupar. O custo
   continua O(branches) chamadas ao git, memoizadas por pedido.
3. **Filtros de âmbito sobre os membros:** `branch` e `analysis` escolhem de
   que branches se lê. *Branch: main* mostra o finding tal como o `main` o vê
   (uma branch tem no máximo uma linha por fingerprint, portanto aqui o
   agrupamento não muda nada).
4. **Agrupar por fingerprint.** Os membros de um grupo são as linhas por
   branch com esse fingerprint.
   - **`state`**: o primeiro que aparecer em
     `regressed › new › open › partial › pending › accepted › false_positive › fixed`.
     Uma decisão é por projecto, portanto um grupo nunca mistura estados
     decididos com estados abertos; os casos reais são "aberto contra
     `fixed`" e "decidido contra `fixed`", e a ordem resolve os dois.
   - **O representante**: entre os membros com esse `state`, o da análise
     mais recente (`started`, e o `id` a desempatar). A linha herda dele
     título, rationale, remediation, ocorrências, `candidate`, `confidence`,
     classificação, `analysis_id`, `branch`, `repo` e `fixed_elsewhere`.
   - **`severity`**: a mais grave entre os membros abertos; se nenhum estiver
     aberto, a mais grave entre todos. É a regra do donut, e é o que impede
     a faixa de KPIs e o donut de se contradizerem.
   - **`branches`** (campo novo): `[{branch, analysis_id, state, severity}]`
     de cada membro, por nome de branch.
   - **`first_seen`**: já é por fingerprint; não muda.
5. **Os restantes filtros aplicam-se ao grupo.** `show_resolved` desligado
   esconde o grupo só quando o `state` do grupo é resolvido — ou seja, quando
   está resolvido em todas as branches — e, como hoje, um estado pedido pelo
   nome no filtro `state` passa esse gate. `state`, `severity`, `category`,
   `confidence` e `fingerprint` leem os valores do grupo. `path` e `q`
   apanham o grupo quando **qualquer** membro corresponde (as ocorrências e o
   texto podem diferir entre branches).
6. **Contagens, ordenação e páginas sobre os grupos.** `by_severity` e
   `fixed_by_severity` contam grupos. `unique` fica no payload, igual a
   `total`, para não partir quem o lê. Ordenar por `branch` usa a branch do
   representante.

`branches`/`analyses` (as opções dos seletores) e `capped_branches` não
mudam.

## Parte 1 — a UI (`ui/security/findings-screen.js`)

A linha do exemplo, depois:

```
Critical | aws access token committed…  | tests/…/test_redaction.py:39 | Secrets | #17 (Deep) +1 | develop, main   | FALSE POSITIVE
High     | improper input validation…    | services/…/auth.py:275        | SAST    | #18 (Deep) +1 | develop · Fixed | OPEN
                                                                                                    main · Open
```

- **Branch**: uma linha por branch do grupo. Com todos os membros no mesmo
  estado, só os nomes; quando divergem, cada branch leva o seu estado
  (`SEC_STATE_LABEL`). O tooltip da célula lista `branch — #run — estado`.
- **Analysis run**: o run do representante, com o aspecto de hoje; com mais
  do que um membro, um `+N` discreto cujo tooltip lista os outros runs.
- **Status**: o pill do grupo e o badge `fixed_elsewhere` do representante.
  O tooltip do badge passa a nomear a branch a que se refere — numa linha
  com várias branches, "this branch" deixava de dizer qual.
- **Faixa de KPIs**: sai o cartão *Unique issues* (seria sempre igual a
  *Total findings*). O tooltip do total passa a dizer que um finding presente
  em várias branches conta uma vez. Os comentários do ficheiro que explicam
  `total` contra `unique` são reescritos.
- **Não muda**: o olho abre o run do representante; *Accept risk* e *False
  positive* decidem pelo fingerprint, para o projecto todo, como sempre; os
  filtros.
- O bundle (`bin/static/security.js`) é reconstruído no mesmo commit.

## Parte 2 — `decided_sast` no `checklist` do agente

**`queries.decided_sast(conn, analysis_id)`** devolve, para o projecto e o
repositório da análise:

- todo o fingerprint com decisão (`accepted` ou `false_positive`) cujo
  registo mais recente — o da análise `done` ou `capped` desse projecto e
  repositório, de qualquer branch, com o `id` mais alto — é
  `category = 'sast'` e `producer = 'agent'`;
- **excepto** os que o checklist desta análise já lista (a análise e o seu
  baseline): esses o agente já os vê, com o estado da decisão.

O Semgrep fica de fora porque a identidade dele é determinística e não
deriva. Outro repositório fica de fora porque, como na spec de 2026-09-13, o
fingerprint atravessa branches do mesmo repositório, e noutro repositório é
outra coisa com o mesmo nome.

Cada entrada, ordenada por `(rule, fingerprint)`:

```json
{"fingerprint": "…", "rule": "broken-access-control", "title": "…",
 "severity": "info",
 "occurrences": [{"file": "martis-app/…/ReviewQueueController.php", "line": 54}],
 "last_seen": {"branch": "develop", "analysis_id": 14},
 "decision": {"state": "accepted", "reason": "By design - product decision RP-217 …"}}
```

Sem `rationale` nem `candidate`, para a lista ficar curta: o que o agente
precisa é de reconhecer o problema, e a decisão com o motivo é o que o
distingue.

**`agentloop security checklist`** passa a imprimir
`{"analysis", "findings", "decided_sast"}`. O `queries.checklist()` não muda,
portanto os ecrãs, os relatórios e o export não mudam. O Codex e o OpenCode
leem o mesmo verbo.

**A skill** (`skills/security-analysis/SKILL.md`, Job 3, a regra de fundir
antes de cunhar) ganha um parágrafo: se a fraqueza que o agente vai reportar
é uma das entradas de `decided_sast` — a mesma falha, no mesmo sítio —
re-reporta-a com esse fingerprint, copiado exactamente, com o seu rationale,
as suas ocorrências e o seu `candidate`, e a decisão do operador aplica-se.
Fica escrito que a lista é para fundir, não é trabalho herdado: nunca
re-reportar uma entrada que o agente não tenha encontrado ele próprio neste
run.

**Nos gates:** uma linha re-reportada assim sai com o estado da decisão
(`diff.classify` dá precedência à decisão). Não conta no `_untriaged` (o
agente não é um scanner), e não entraria na fila de verificação do 4.2, que
só aceita findings abertos.

**O risco, dito:** um agente que funda por engano um problema diferente numa
entrada decidida esconde-o atrás da decisão. É o mesmo risco que a regra de
fundir já tem hoje dentro de uma branch, com a mesma mitigação — "só a mesma
falha no mesmo sítio" — e o motivo da decisão na entrada para comparar.

## Relação com o que já foi decidido

- **O âmbito das decisões não muda.** A spec de 2026-09-13 deixou de fora
  "propagar decisões entre branches". Mas o ledger já aplica uma decisão ao
  projecto inteiro para o mesmo fingerprint (`decision` é
  `PRIMARY KEY (project, fingerprint)`), e isso é anterior a essa spec. Esta
  entrega não propaga nada: torna estável entre branches a identidade de um
  SAST do agente, que é o que o fingerprint sempre prometeu ser ("identidade
  estável do mesmo problema entre análises e entre branches").
- **`fixed` continua a significar o mesmo.** O agrupamento não marca nada
  `fixed`: um grupo só é `fixed` quando todos os membros o são, cada um pela
  regra de `diff._proven`. A máquina de estados de `diff.classify` fica
  intacta.
- **O export consolidado não muda** (`group=False`): continua uma linha por
  finding por branch.

## Convivência com o 4.2 (`feat/security-verdicts`)

Esta branch parte do `main`; quem entrar em segundo resolve os conflitos
(`queries.py`, `findings-screen.js`, `SKILL.md`, testes). Se o 4.2 entrar
primeiro, o agrupamento adopta o predicado `counted()` dele:

- o `show_resolved` do grupo passa de `is_open(state)` para "algum membro
  `counted`";
- o conjunto de membros abertos, de que sai a severidade, passa a ser o dos
  membros `counted` (um verdict `rejected` não é exposição);
- o filtro `verdict` lê o verdict do representante.

## Fora desta versão

- **Mostrar ao agente os SAST abertos de outras branches** (só os
  decididos entram). Evitaria duas linhas para o mesmo problema aberto em
  duas branches, mas a lista cresce e convida a re-reportar um achado de
  outra branch sem ler o código.
- **Reagrupar o que já está no ledger.** Os pares antigos com dois
  fingerprints para o mesmo problema (o RP-217) continuam como estão; a
  entrega evita os próximos.
- **Um estado "misto".** A divergência entre branches é mostrada na coluna
  Branch, não com um estado novo que todos os leitores teriam de aprender.
- **Mudar o export** para uma linha por finding.

## Testes

- **Agrupamento** (`tests/security/test_queries.py`): o mesmo fingerprint em
  duas branches dá uma linha com as duas em `branches`; a ordem de estados
  nos três casos (aberto contra `fixed`, decidido contra `fixed`, `fixed` em
  todas); o representante é o membro mais recente com o estado do grupo; a
  severidade agregada é a do donut; o filtro `branch` restringe os membros;
  `state`/`show_resolved` aplicam-se ao grupo; `path`/`q` apanham o grupo por
  qualquer membro; contagens e páginas sobre grupos; `unique == total`.
- **Regressão:** `group=False` e o `export-findings` continuam por branch; o
  teste que hoje fixa `total == 2, unique == 1` passa a fixar os dois modos.
- **`decided_sast`:** exclui o que o checklist lista, o Semgrep, os não-SAST,
  os sem decisão, outro projecto e outro repositório; usa o registo mais
  recente; análises `failed` e `running` não contam.
- **`security checklist`:** a saída traz `decided_sast`.
- **A skill:** um teste fixa o parágrafo novo, como os outros testes da
  skill.
- **Contrato da página** (`tests/test_page_contract.py`): a célula Branch
  com e sem divergência; o `+N` no Analysis run; a faixa sem o cartão
  Unique; o badge a nomear a branch.

## Aceitação

Sem gastar dinheiro, e nunca sobre o ledger real:

- sobre uma cópia do ledger, `security findings-page --project Minerva
  --show-resolved --state false_positive` desta árvore mostra o aws token
  numa linha só, com `develop` e `main` em `branches`;
- sobre a mesma cópia, `security checklist --analysis 18` traz em
  `decided_sast` os 4 SAST do agente, com o RP-217 entre eles;
- o separador *Findings* servido desta worktree sobre a cópia, visto no
  browser.

Nenhum run real do agente: a reutilização do fingerprint fica provada pelos
testes, e confirma-se no próximo run real do operador.
