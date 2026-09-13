# A exportação consolidada de findings: plano

Desenho: [`../specs/2026-09-13-consolidated-findings-export-design.md`](../specs/2026-09-13-consolidated-findings-export-design.md).

Quatro tarefas, um PR, de dentro para fora: o documento, o verbo, a rota, o
botão.

## Global Constraints

As mesmas da entrega irmã
([`2026-09-13-cross-branch-finding-state.md`](2026-09-13-cross-branch-finding-state.md)),
e mais estas três:

- **Nada muda nos relatórios por análise.** `report.as_json`, `as_markdown` e
  `as_html` continuam a receber `(analysis, findings, coverage_note)` e a
  produzir o que produzem hoje. Os testes que já existem para eles passam sem
  alteração — esta entrega **acrescenta** um renderizador, não altera três.
- **A rota `/api/security/report` não é tocada.** A guarda dela foi construída
  à volta de um id inteiro e de um formato de lista fechada, e o comentário do
  código diz que nenhuma string do chamador chega ao cabeçalho. Alargá-la é
  desfazer isso. A rota nova é nova.
- **Pré-requisito:** o merge do OpenCode (bundles), e **de preferência** a
  entrega irmã já fundida — ver a Tarefa 1.

---

## Tarefa 1: o renderizador consolidado

**Muda:** `bin/security/report.py` (acrescenta), `tests/security/`.

```
def consolidated_as_markdown(project, groups, meta) -> str
def consolidated_as_json(project, groups, meta) -> str
```

`groups` é uma lista por branch, cada uma com a análise que a produziu
(`id`, `commit_sha`, `at`) e as suas linhas. `meta` leva o que o cabeçalho tem
de dizer: quantos findings vão no documento, quantos o ecrã estava a mostrar,
e que **os filtros do ecrã não foram aplicados**.

**O cabeçalho é a parte que interessa e não é decoração.** Quem lê isto é um
agente sem contexto. Tem de dizer, antes de qualquer finding: o projecto, o
instante, quantas branches, o commit analisado de cada uma, que a lista é
tudo o que está registado (não o que estava filtrado), e — se a entrega irmã
já estiver fundida — quantos destes findings já estão corrigidos noutra
branch.

**Uma branch sem findings aparece na mesma**, a dizer que está limpa. Um
agente que não veja a branch não sabe se ela está boa ou se foi esquecida, e
essas duas coisas exigem acções opostas.

**Ordem estável:** por branch (alfabética), dentro dela por severidade
decrescente, e empates pelo `fingerprint`. Duas exportações do mesmo estado
têm de dar ficheiros iguais byte a byte — senão não se consegue fazer diff
entre elas, que é a segunda coisa que alguém vai querer fazer.

**Testes:** três branches, uma delas vazia; a ordem; o cabeçalho com os três
números; o mesmo conjunto exportado duas vezes dá o mesmo byte; um finding com
o campo `fixed_elsewhere` (da entrega irmã) traz essa coluna, e sem o campo o
documento não a inventa.

---

## Tarefa 2: o verbo

**Muda:** `bin/security/cli.py`, `tests/security/`.

```
agentloop security export-findings --project <nome> --format md|json
```

Reúne, por cada branch do projecto, a análise mais recente `done`/`capped` e
as linhas dela — **pelo mesmo caminho que o ecrã usa** (`queries.finding_rows`
/ `checklist`), nunca por SQL próprio. O ecrã e o documento têm de discordar
nunca; a única maneira de garantir isso é uma fonte só.

**Sem filtros no verbo.** O documento é tudo o que está registado (a decisão
está na spec). O verbo não recebe `--severity` nem `--state`: não existe o
argumento, portanto não existe a dúvida sobre se foi aplicado.

**Testes:** um projecto com três branches; um projecto inexistente → erro com
código de saída ≠ 0 e mensagem que nomeia o projecto; um projecto sem análise
nenhuma → um documento válido a dizer isso (não um erro: o projecto existe e a
resposta é "ainda ninguém olhou").

---

## Tarefa 3: a rota

**Muda:** `bin/agentloop-server`, `tests/test_platforms_api.py` (ou o ficheiro
de testes do servidor que cobre `/api/security/*`).

`GET /api/security/findings-export?project=<nome>&format=md|json`

- O formato vem de uma **lista fechada**, como na rota irmã.
- O projecto é texto livre e viaja como **um elemento de argv**, nunca shell —
  a regra que `security_findings` já documenta.
- O nome do ficheiro no `Content-Disposition` é derivado de um **saneamento**
  do nome do projecto (só `[A-Za-z0-9._-]`, o resto vira `-`), nunca da string
  do chamador. Esta é a linha que a rota antiga se dá ao trabalho de garantir
  e que seria fácil perder aqui.
- Projecto inexistente → **404**, não um documento vazio. Um agente que receba
  um documento vazio de um projecto mal escrito começa a trabalhar em nada e
  reporta que estava tudo bem.
- O download deixa um evento `findings_exported` no histórico do projecto,
  como o `report_exported` já faz.

**Testes:** formato inválido → 400; projecto inexistente → 404; o cabeçalho do
ficheiro com o nome saneado (testar com um projecto chamado `../etc/passwd` e
com um que tenha espaços e acentos); o evento registado.

---

## Tarefa 4: o botão

**Muda:** `ui/security/findings-screen.js`, `tests/test_page_contract.py`, as
bundles no mesmo commit.

O `exportBtn.onclick` deixa de ser `secSwitchProjectTab("reports")` e passa a
descarregar da rota nova, pelo mesmo mecanismo que o `secDownload` do
`dashboard.html` já usa para os relatórios por análise. O `title` passa a
descrever o que faz — *"Download every recorded finding in this project, all
branches"* — em vez de anunciar uma navegação.

**Um escolhedor de formato**, não dois botões: um menu pequeno (Markdown por
omissão, JSON a seguir), como o separador de relatórios já faz.

**A frase por baixo dos números fica.** Ela já ensina o contrato
(*"Downloads always contain every recorded finding"*) e agora passa a ser
verdade também para este botão — antes era verdade só para os relatórios por
análise.

**Contrato da página:** o botão existe, aponta para a rota nova, **não**
navega para o separador de relatórios, e a frase do contrato continua lá.

---

## Auto-revisão do plano

- **A Tarefa 1 é a que decide se isto presta.** Um documento que um agente não
  consiga usar sem fazer perguntas falhou, mesmo com as quatro suites verdes.
  Quando estiver escrito, **dá-o a um agente sem contexto e vê se ele consegue
  começar** — é o único teste que conta e não cabe numa suite.
- **A Tarefa 3 é onde mora o risco de segurança** desta entrega: um nome de
  ficheiro construído a partir de texto do chamador. O plano diz saneamento e
  o teste diz `../etc/passwd`; se essa asserção for cortada por ser
  "paranóica", a entrega perde a única coisa que a protege.
- **Ordem com a entrega irmã:** se esta for primeiro, o documento sai sem a
  coluna de "corrigido noutra branch" e ganha-a depois. Se for a seguir, sai
  completo à primeira. **Recomendo a seguir**, e a spec explica porquê: sem o
  estado, o documento manda um agente refazer trabalho já feito.
