# Uma linha por finding, e SAST decididos que não voltam — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectivo:** o separador *Findings* passa a mostrar uma linha por finding (por fingerprint) em vez de uma por branch, com o estado que pede atenção primeiro e o estado de cada branch quando divergem; e o `checklist` do agente passa a trazer `decided_sast`, para que um SAST decidido numa branch não volte como `new` noutra.

**Arquitectura:** `queries.finding_rows` ganha `group=True` (default): as linhas por branch de hoje são agrupadas por `_group_by_fingerprint` depois dos filtros de âmbito (`branch`, `analysis`) e antes dos restantes; o `export-findings` pede `group=False` e o cabeçalho do documento mede o `shown` do ecrã contra fingerprints abertos distintos. `ui/security/findings-screen.js` desenha as colunas Branch e Analysis run a partir do campo novo `branches` e perde o cartão *Unique issues*. `queries.decided_sast` alimenta uma chave nova na saída do verbo `checklist`, e o Job 3 da skill manda fundir nela. A spec é [docs/superpowers/specs/2026-09-23-security-findings-one-row-design.md](../specs/2026-09-23-security-findings-one-row-design.md).

**Tech stack:** Python 3.13 (stdlib `sqlite3`/`json`), pytest 9, ES modules empacotados por esbuild 0.25 (`build/build-ui.sh`), Node para os testes de contrato da página.

## Restrições globais

- **Worktree:** `<WT>` = `~/Projects/agentloop/.claude/worktrees/fix+security-status-carryover`, branch `fix/security-findings-one-row` (já existe, com a spec). Todos os comandos correm em `<WT>`. Nunca editar o checkout principal.
- **O guarda do Bash nesta worktree:** um comando simples por chamada — nada de `&&`, `;`, `$( )` nem pipes; git sempre como `/usr/bin/git …` (nunca via `rtk`).
- **Testes em primeiro plano**, `timeout` 600000, nunca em background à espera de notificação. `pytest` só existe em `python3.13`; correr como `rtk proxy python3.13 -m pytest … -p no:cacheprovider` (o `rtk` sem `proxy` resume a saída e chega a dizer "No tests collected" numa execução com `-k`).
- **`tests/security` precisa de** `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true` à frente do comando.
- **Ler ficheiros com a ferramenta `Read`**, não com `cat`/`grep` pelo Bash (o hook `rtk` trunca sem aviso).
- **Nunca tocar no ledger real** (`~/Projects/agentloop/data/security.db`): aceitação só sobre uma cópia na pasta de rascunho da sessão (`<SCRATCH>`).
- **Nenhum ficheiro versionado nomeia um home real** (`/Users/<nome>`): o selftest recusa-o. Usar `~/…` ou `/Users/me/…`.
- **Qualquer edição sob `ui/`** obriga a `bash build/build-ui.sh` e `node --check bin/static/security.js` no mesmo commit.
- **Os testes de contrato extraem funções pelo nome** (`_plainfn`) e correm-nas em Node sem o resto do módulo: uma função nova chamada por `secFindRow` teria de entrar nos tuplos de deps de todos os testes que o extraem. Este plano não cria nenhuma — as células novas ficam dentro de `secFindRow`. Uma classe nova num `secEl(...)` precisaria de regra CSS (`test_no_class_the_shipped_ui_uses_lacks_a_css_rule`); este plano não cria nenhuma.
- **`CHANGELOG.md` por commit**, sob `## [Unreleased]` → `### Fixed`, a dizer o que mudou e o que custava não ter.
- **Código, docstrings, comentários, README, CHANGELOG e mensagens de commit em inglês.** Todo o commit termina com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Um editor por ficheiro:** as tarefas são sequenciais (1 → 2 → 3 → 4); a 3 toca `queries.py`, `cli.py`, `README.md` e `CHANGELOG.md`, tal como a 1 e a 2.

## Estrutura de ficheiros

| ficheiro | responsabilidade nesta entrega |
|---|---|
| `bin/security/queries.py` | `GROUP_STATE_ORDER`, `_search_text`, `_group_by_fingerprint`, `finding_rows(group=True)`; `decided_sast` |
| `bin/security/cli.py` | `cmd_export_findings` pede `group=False`; `cmd_checklist` imprime `decided_sast` |
| `bin/security/report.py` | `_consolidated_meta_lines` mede o `shown` contra fingerprints abertos distintos |
| `ui/security/findings-screen.js` | células Branch e Analysis run, tooltip do badge, faixa sem *Unique issues*, comentários |
| `bin/static/security.js`, `bin/static/app.js`, `bin/static/app.css` | regenerados por `build/build-ui.sh` |
| `skills/security-analysis/SKILL.md` | parágrafo do `decided_sast` no Job 3 |
| `tests/security/test_queries.py`, `test_export_findings.py`, `test_consolidated_report.py`, `test_cli.py` | testes |
| `tests/security/test_decided_sast.py` (novo) | testes do `decided_sast` e da frase da skill |
| `tests/test_page_contract.py` | testes da linha, da faixa e do allowlist |
| `README.md`, `CHANGELOG.md` | documentação entregue |

---

### Task 1: `finding_rows` agrupa por fingerprint; o export continua por branch

**Files:**
- Modify: `bin/security/queries.py` (bloco novo antes de `def finding_rows`; `finding_rows`)
- Modify: `bin/security/cli.py` (`cmd_export_findings`)
- Modify: `bin/security/report.py` (`_consolidated_meta_lines`)
- Test: `tests/security/test_queries.py`, `tests/security/test_export_findings.py`, `tests/security/test_consolidated_report.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `queries.finding_rows(conn, project, filters=None, sort="severity", direction="desc", page=1, per_page=25, repo_paths=None, group=True) -> dict` — com `group`, cada linha ganha `branches: list[{"branch": str, "analysis_id": int, "state": str, "severity": str}]` (por nome de branch) e herda `branch`/`analysis_id`/texto do representante; `total == unique`. `queries.GROUP_STATE_ORDER: tuple[str, ...]`. `queries._group_by_fingerprint(rows: list[dict], started: dict[int, int]) -> list[dict]`. `queries._search_text(row: dict) -> str`.

- [ ] **Step 1: escrever os testes que falham (queries)**

Em `tests/security/test_queries.py`, **substituir** o teste `test_unique_counts_fingerprints_not_rows` inteiro por:

```python
def test_group_off_is_one_row_per_branch_as_it_was(conn):
    """`group=False` is the union one row per finding per branch -- what the
    consolidated export reads, because a fix is applied on a branch. Two rows
    and one fingerprint there; one of each on the screen."""
    fp = "d" * 64
    for br in ("main", "develop"):
        aid = ledger.start_analysis(conn, "web", "web", br, "s", "quick", "r")
        ledger.record_finding(conn, aid, {
            "fingerprint": fp, "category": "secret", "rule": "aws_access_key",
            "severity": "critical", "title": "t", "occurrences": []})
        ledger.mark_prepared(conn, aid)
        ledger.finish_analysis(conn, aid, "done")
    per_branch = queries.finding_rows(conn, "web", group=False)
    assert per_branch["total"] == 2 and per_branch["unique"] == 1
    assert all("branches" not in r for r in per_branch["rows"])
    grouped = queries.finding_rows(conn, "web")
    assert grouped["total"] == 1 and grouped["unique"] == 1
```

E acrescentar, logo a seguir, o helper e os testes do agrupamento:

```python
def _on(conn, branch, fp=None, severity="critical", title="t", file="k.py"):
    """One finished analysis of `branch` holding `fp` -- or nothing, which is
    how a finding the branch held last time becomes `fixed` there: its minter
    is deterministic (no producer, a `secret`), so `prepared` proves it gone."""
    aid = ledger.start_analysis(conn, "web", "web", branch, "s", "quick", "r")
    if fp:
        ledger.record_finding(conn, aid, {
            "fingerprint": fp, "category": "secret", "rule": "aws-access-token",
            "severity": severity, "title": title,
            "occurrences": [{"file": file, "line": 3, "snippet_hash": ""}]})
    ledger.mark_prepared(conn, aid)
    ledger.finish_analysis(conn, aid, "done")
    return aid


def test_one_finding_on_two_branches_is_one_row_naming_both(conn):
    fp = "1" * 64
    _on(conn, "main", fp)
    _on(conn, "develop", fp)
    got = queries.finding_rows(conn, "web")
    assert got["total"] == 1 and got["unique"] == 1
    (row,) = got["rows"]
    assert [b["branch"] for b in row["branches"]] == ["develop", "main"]
    assert {b["state"] for b in row["branches"]} == {"new"}


def test_a_decision_taken_once_is_one_resolved_row_not_one_per_branch(conn):
    """The screen the operator sent (2026-09-23): the same false positive,
    decided once, listed under develop AND main -- which read as the decision
    coming undone every time the other branch was analysed."""
    fp = "2" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    ledger.set_decision(conn, "web", fp, "false_positive", "synthetic fixture", "me")
    assert queries.finding_rows(conn, "web")["total"] == 0, \
        "resolved on every branch: hidden by default"
    (row,) = queries.finding_rows(conn, "web", {"state": ["false_positive"]})["rows"]
    assert row["state"] == "false_positive"
    assert [b["branch"] for b in row["branches"]] == ["develop", "main"]


def test_open_on_one_branch_outranks_fixed_on_another(conn):
    fp = "3" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    _on(conn, "main")                      # gone from main: fixed there
    (row,) = queries.finding_rows(conn, "web")["rows"]
    assert row["state"] == "new" and row["branch"] == "develop"
    assert {b["branch"]: b["state"] for b in row["branches"]} == \
        {"develop": "new", "main": "fixed"}


def test_a_decision_outranks_fixed_and_fixed_needs_every_branch(conn):
    fp = "4" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    _on(conn, "main")                      # fixed on main
    ledger.set_decision(conn, "web", fp, "accepted", "tracked in RP-1", "me")
    (row,) = queries.finding_rows(conn, "web", {"show_resolved": True})["rows"]
    assert row["state"] == "accepted", "still on develop, and the decision covers it"
    _on(conn, "develop")                   # and now gone from develop too
    (row,) = queries.finding_rows(conn, "web", {"show_resolved": True})["rows"]
    assert row["state"] == "fixed"


def test_the_row_reads_the_newest_holder_and_the_worst_open_severity(conn):
    fp = "5" * 64
    older = _on(conn, "develop", fp, severity="critical", title="the older reading")
    newer = _on(conn, "main", fp, severity="high", title="the newer reading")
    conn.execute("UPDATE analysis SET started=100 WHERE id=?", (older,))
    conn.execute("UPDATE analysis SET started=200 WHERE id=?", (newer,))
    conn.commit()
    (row,) = queries.finding_rows(conn, "web")["rows"]
    assert row["title"] == "the newer reading" and row["analysis_id"] == newer
    assert row["severity"] == "critical", "the donut's rule: the worst open reading"
    assert {b["branch"]: b["severity"] for b in row["branches"]} == \
        {"develop": "critical", "main": "high"}


def test_the_branch_filter_reads_the_finding_as_that_branch_sees_it(conn):
    fp = "6" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    _on(conn, "main")                      # fixed on main, still new on develop
    got = queries.finding_rows(conn, "web", {"branch": ["main"], "show_resolved": True})
    (row,) = got["rows"]
    assert row["state"] == "fixed", "main's reading, not the group across branches"
    assert [b["branch"] for b in row["branches"]] == ["main"]


def test_a_state_filter_reads_the_group_not_one_branch(conn):
    fp = "7" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    _on(conn, "main")                      # fixed on main, still new on develop
    assert queries.finding_rows(conn, "web", {"state": ["fixed"]})["total"] == 0, \
        "fixed on main but open on develop is not a fixed finding"
    assert queries.finding_rows(conn, "web", {"state": ["new"]})["total"] == 1


def test_path_and_q_find_a_group_through_any_branch(conn):
    fp = "8" * 64
    older = _on(conn, "develop", fp, file="legacy/keys.py")
    newer = _on(conn, "main", fp, file="config/keys.py")
    conn.execute("UPDATE analysis SET started=100 WHERE id=?", (older,))
    conn.execute("UPDATE analysis SET started=200 WHERE id=?", (newer,))
    conn.commit()
    # main's reading is the row; develop's file lives only in its member
    assert queries.finding_rows(conn, "web", {"path": "legacy/"})["total"] == 1
    assert queries.finding_rows(conn, "web", {"q": "legacy/keys"})["total"] == 1
    assert queries.finding_rows(conn, "web", {"path": "nowhere/"})["total"] == 0


def test_counts_and_pages_are_of_findings_not_rows(conn):
    fps = [c * 64 for c in "abc"]
    for br in ("develop", "main"):
        aid = ledger.start_analysis(conn, "web", "web", br, "s", "quick", "r")
        for fp in fps:
            ledger.record_finding(conn, aid, {
                "fingerprint": fp, "category": "secret", "rule": "aws-access-token",
                "severity": "high", "title": "t",
                "occurrences": [{"file": "k.py", "line": 1, "snippet_hash": ""}]})
        ledger.mark_prepared(conn, aid)
        ledger.finish_analysis(conn, aid, "done")
    first = queries.finding_rows(conn, "web", per_page=2, page=1)
    second = queries.finding_rows(conn, "web", per_page=2, page=2)
    assert first["total"] == 3 and first["unique"] == 3
    assert first["by_severity"]["high"] == 3
    assert len(first["rows"]) == 2 and len(second["rows"]) == 1
    assert {r["fingerprint"] for r in first["rows"] + second["rows"]} == set(fps)


def test_the_grouping_state_never_leaves_the_function(conn):
    fp = "9" * 64
    _on(conn, "develop", fp)
    _on(conn, "main", fp)
    (row,) = queries.finding_rows(conn, "web")["rows"]
    assert "_members" not in row
    assert all("_members" not in r
               for r in queries.finding_rows(conn, "web", group=False)["rows"])
```

- [ ] **Step 2: correr e ver falhar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_queries.py -p no:cacheprovider -q`
Expected: FAIL — `TypeError: finding_rows() got an unexpected keyword argument 'group'` e asserções de `total == 1` a falhar (hoje dá 2).

- [ ] **Step 3: implementar o agrupamento em `bin/security/queries.py`**

(a) Imediatamente **antes** de `def finding_rows(`, acrescentar:

```python
# The order a grouped row's state is chosen in -- see `_group_by_fingerprint`.
# The first state any branch holds wins: open anywhere outranks a decision,
# and a decision outranks `fixed`, so a finding reads `fixed` only once every
# branch it is on says so -- the "open on one branch is still exposure" rule
# `_open_findings_by_fingerprint` already gives the donut. A decision is
# recorded per project, so decided and open states never meet in one group;
# the two real contests are open-versus-fixed and decided-versus-fixed, and
# this order settles both. Among the open states `regressed` leads: fixed
# once and back is the worst news the checklist can give.
GROUP_STATE_ORDER = ("regressed", "new", "open", "partial", "pending",
                     "accepted", "false_positive", "fixed")


def _search_text(row) -> str:
    """What the `q` filter searches in one finding row, lower-cased: title,
    rule, rationale, every occurrence's file, and the candidate's own prose
    -- a trace step's sentence, the intended control, a reason."""
    return " ".join([
        row.get("title", ""), row.get("rule", ""), row.get("rationale", ""),
        " ".join(o["file"] for o in row.get("occurrences", [])),
        candidate.search_text(row.get("candidate"))]).lower()


def _group_by_fingerprint(rows, started):
    """One row per fingerprint out of `finding_rows`'s per-branch rows.

    THE ROW IS ITS REPRESENTATIVE'S ROW: among the branches holding the
    group's state (GROUP_STATE_ORDER), the newest reading -- `started` maps
    each branch's latest analysis id to its `started`, the id breaking a tie.
    Its title, occurrences, candidate, analysis and branch all describe the
    one reading that decides the Status, never a patchwork of two branches.

    TWO FIELDS ARE THE GROUP'S OWN. `severity` is the worst of the open
    members, or of all of them when none is open -- the donut's rule
    (`_open_findings_by_fingerprint`), so the strip and the donut cannot
    disagree about one finding. `branches` lists every member's branch,
    analysis, state and severity, by branch name: the screen says there what
    each branch reads when they disagree.

    `_members` rides along for the `path` and `q` filters, which keep a group
    when ANY member matches -- a file can move on one branch and not on the
    other -- and is dropped before a row leaves `finding_rows`.
    """
    rank = {s: i for i, s in enumerate(GROUP_STATE_ORDER)}
    by_fp = {}
    for r in rows:
        by_fp.setdefault(r["fingerprint"], []).append(r)
    out = []
    for members in by_fp.values():
        state = min((m["state"] for m in members),
                    key=lambda s: rank.get(s, len(GROUP_STATE_ORDER)))
        rep = max((m for m in members if m["state"] == state),
                  key=lambda m: (started.get(m["analysis_id"], 0), m["analysis_id"]))
        pool = [m for m in members if is_open(m["state"])] or members
        row = dict(rep)
        row["severity"] = min((m["severity"] for m in pool),
                              key=lambda s: _SEV_RANK.get(s, 9))
        row["branches"] = [{"branch": m["branch"], "analysis_id": m["analysis_id"],
                            "state": m["state"], "severity": m["severity"]}
                           for m in sorted(members, key=lambda m: m["branch"])]
        row["_members"] = members
        out.append(row)
    return out
```

(b) A assinatura de `finding_rows` passa a ser:

```python
def finding_rows(conn, project, filters=None, sort="severity",
                 direction="desc", page=1, per_page=25, repo_paths=None,
                 group=True):
```

(c) Substituir o primeiro parágrafo da docstring:

```python
    """The findings browser: one checklist per branch -- the latest finished
    analysis of each -- unioned. That union is what lets the browser show a
    state at all: it is the state that branch's newest analysis gives the
    finding, not a column stored anywhere.
```

por:

```python
    """The findings browser: one checklist per branch -- the latest finished
    analysis of each -- unioned, and then, unless `group` is off, ONE ROW PER
    FINDING. That union is what lets the browser show a state at all: it is
    the state a branch's newest analysis gives the finding, not a column
    stored anywhere.

    ONE ROW PER FINDING, because a decision is recorded against the project
    (`decision`, ledger._SCHEMA) and a list with one row per branch put every
    finding the operator had already ruled on back in front of them, as a
    second row, each time another branch was analysed -- measured on one
    project (2026-09-23): 46 secrets on develop and main, every one decided,
    every one listed twice. `_group_by_fingerprint` builds the rows and says
    which branch's reading each field comes from. The `branch` and `analysis`
    filters pick which branches are grouped at all, BEFORE the grouping;
    every other filter reads the grouped row. `group=False` is the union as
    it was, one row per finding per branch, and is what `cmd_export_findings`
    asks for: its document is organised by branch on purpose, because a fix
    is applied on a branch.
```

(d) Substituir o bloco de filtros — de `    # \`show_resolved\` off hides resolved findings BY DEFAULT -- it is a` até ao fim do filtro `q` (`            candidate.search_text(r.get("candidate"))]).lower()]`) — por:

```python
    # WHICH BRANCHES' READINGS, chosen BEFORE anything is grouped: "Branch:
    # main" asks for the finding as main reads it, and a filter applied after
    # the grouping would put main's name on a row whose state develop
    # decided. A branch holds one row per fingerprint, so under either of
    # these two the grouping below changes nothing -- and with `group` off,
    # running them ahead of the others changes nothing either: every filter
    # here is a predicate on a row, and predicates commute.
    if f.get("branch"):
        rows = [r for r in rows if r["branch"] in f["branch"]]
    if f.get("analysis"):
        rows = [r for r in rows if r["analysis_id"] in f["analysis"]]
    if group:
        rows = _group_by_fingerprint(
            rows, {a["id"]: a["started"] for a in analyses_available})

    # `show_resolved` off hides resolved findings BY DEFAULT -- it is a
    # convenience, not a veto. A Status filter that names a resolved state is
    # an explicit request for exactly those rows, and used to lose to this
    # gate: the resolved rows were dropped here first, then "state == fixed"
    # was applied to what was left, which by construction held no fixed row.
    # Status: Fixed showed "No findings match these filters" on a project with
    # dozens of them. A state the operator asked for by name passes the gate.
    # On a grouped row the state is the group's, so the gate hides a finding
    # only when it is resolved on every branch it is on.
    asked_for = set(f.get("state") or ())
    if not f.get("show_resolved"):
        rows = [r for r in rows if is_open(r["state"]) or r["state"] in asked_for]
    for key in ("severity", "state", "category", "confidence"):
        if f.get(key):
            rows = [r for r in rows if r.get(key) in f[key]]
    if f.get("fingerprint"):
        # A PREFIX match, not equality: the Activity screen's own deep link
        # (Task 12) only ever has the first 12 characters of a fingerprint --
        # `related` on a `decision_made` event is truncated by `cmd_decide` --
        # so the one caller of this filter could never match on the full
        # 64-character string.
        needle = f["fingerprint"]
        rows = [r for r in rows if r["fingerprint"].startswith(needle)]
    # `path` and `q` keep a group when ANY of its branches matches: a file can
    # move on one branch and not on the other, and the finding is still the
    # one being looked for. With `group` off there is no `_members`, and the
    # row is its own only member.
    if f.get("path"):
        needle = f["path"].lower()
        rows = [r for r in rows
                if any(needle in o["file"].lower()
                       for m in r.get("_members") or [r]
                       for o in m.get("occurrences", []))]
    if f.get("q"):
        needle = f["q"].lower()
        rows = [r for r in rows
                if any(needle in _search_text(m) for m in r.get("_members") or [r])]
```

(e) No fim da função, substituir:

```python
    return {"rows": rows[start:start + per_page], "total": total,
```

por:

```python
    # `_members` is the grouping's working state, never payload: every member
    # is already summarised in `branches`, and shipping them would send each
    # finding's whole text once per branch it is on.
    served = [{k: v for k, v in r.items() if k != "_members"}
              for r in rows[start:start + per_page]]
    return {"rows": served, "total": total,
```

- [ ] **Step 4: correr e ver passar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_queries.py tests/security/test_fixed_elsewhere_rows.py -p no:cacheprovider -q`
Expected: PASS (os testes de `fixed_elsewhere` filtram por `branch=["develop"]`, que agora escolhe os membros antes do agrupamento — descrevem o mesmo que antes).

- [ ] **Step 5: escrever os testes que falham (export)**

Em `tests/security/test_export_findings.py`, acrescentar:

```python
def test_the_document_stays_one_row_per_branch(tmp_path):
    # The screen groups a finding on two branches into one row; this document
    # does not -- a fix is applied on a branch, and each branch's section has
    # to list what there is to fix on it.
    db = tmp_path / "l.db"
    a1 = _prepared(db, tmp_path, "web", "main", "1111111111111111")
    _finding(db, a1, "f" * 64, title="on both")
    _close(db, a1)
    a2 = _prepared(db, tmp_path, "web", "develop", "2222222222222222")
    _finding(db, a2, "f" * 64, title="on both")
    _close(db, a2)
    doc = json.loads(_run(db, "export-findings", "--project", "web",
                          "--format", "json").stdout)
    on = {b["branch"]: [f["fingerprint"] for f in b["open"]] for b in doc["branches"]}
    assert on == {"develop": ["f" * 64], "main": ["f" * 64]}
```

Em `tests/security/test_consolidated_report.py`, acrescentar:

```python
def test_a_finding_open_on_two_branches_is_one_on_the_screen_and_the_header_says_so():
    # The screen counts findings -- one row per fingerprint across branches --
    # while this document lists a finding once per branch it is on. Measured
    # against rows, a screen showing its one finding read as a screen that
    # had hidden another.
    rows = [_f("a" * 16, "high"), _f("a" * 16, "high", branch="main")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META),
                                         {"shown_on_screen": 1})
    assert "**Findings:** 2 open (1 distinct across branches)" in md
    assert "The screen was showing" not in md
```

- [ ] **Step 6: correr e ver falhar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_export_findings.py tests/security/test_consolidated_report.py -p no:cacheprovider -q`
Expected: FAIL — o export agrupa e o finding só aparece numa branch; o cabeçalho diz `2 open` sem o número distinto e imprime "The screen was showing 1 of these".

- [ ] **Step 7: o export pede `group=False`, e o cabeçalho mede contra distintos**

Em `bin/security/cli.py`, `cmd_export_findings`: acrescentar ao fim do primeiro parágrafo da docstring (a seguir a "…which is how this repository has been bitten before."):

```python
    The screen asks for it grouped, one row per finding; this asks for
    `group=False` -- the same union, one row per finding per BRANCH --
    because a fix is applied on a branch, and each branch's section has to
    list what there is to fix on it.
```

e mudar a chamada:

```python
        payload = queries.finding_rows(conn, args.project,
                                       filters={"show_resolved": True},
                                       page=page, per_page=queries.MAX_PER_PAGE,
                                       repo_paths=repo_paths, group=False)
```

Em `bin/security/report.py`, `_consolidated_meta_lines`, substituir:

```python
    total = sum(len(g["open"]) + len(g["resolved"]) for g in groups)
    open_n = sum(len(g["open"]) for g in groups)
    res_n = total - open_n
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(meta.get("at") or time.time()))
    out = [f"- **Exported:** {when}",
           f"- **Branches:** {len(groups)}",
           f"- **Findings:** {open_n} open" + (f", {res_n} resolved (listed last)" if res_n else "")]
```

por:

```python
    total = sum(len(g["open"]) + len(g["resolved"]) for g in groups)
    open_n = sum(len(g["open"]) for g in groups)
    # THE SCREEN COUNTS FINDINGS, THIS DOCUMENT COUNTS ROWS. The browser shows
    # one row per fingerprint across branches (queries.finding_rows, grouped);
    # this document lists a finding once per branch it is on, because a fix is
    # applied on a branch. Both numbers are said when they differ, and the
    # screen's own count below is measured against the distinct one -- against
    # rows, a screen showing its one finding read as a screen that had hidden
    # another.
    open_distinct = len({f["fingerprint"] for g in groups for f in g["open"]})
    res_n = total - open_n
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(meta.get("at") or time.time()))
    out = [f"- **Exported:** {when}",
           f"- **Branches:** {len(groups)}",
           f"- **Findings:** {open_n} open"
           + (f" ({open_distinct} distinct across branches)" if open_distinct != open_n else "")
           + (f", {res_n} resolved (listed last)" if res_n else "")]
```

e, mais abaixo na mesma função, `if shown is not None and shown != open_n:` passa a `if shown is not None and shown != open_distinct:`.

- [ ] **Step 8: correr e ver passar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_export_findings.py tests/security/test_consolidated_report.py tests/security/test_queries.py tests/security/test_fixed_elsewhere_rows.py tests/security/test_cli.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Step 9: CHANGELOG**

Em `CHANGELOG.md`, sob `## [Unreleased]` → `### Fixed`, como primeira entrada:

```markdown
- **A finding on several branches is one row in the findings browser, and a
  decision no longer seems to come undone when another branch is analysed.**
  `queries.finding_rows` united one checklist per branch, so a finding on
  `develop` and on `main` was two rows — and every finding the operator had
  already ruled on came back in front of them, as a second row, each time the
  other branch was analysed: on one project, 46 secrets decided once and
  listed twice. The decisions were never lost (they are recorded against the
  project); the rows were duplicated. The browser now groups by fingerprint:
  one row, whose state is the reading that needs attention first across the
  branches (open anywhere, then a decision, then `fixed` only once every
  branch says so), whose severity is the worst open reading — the donut's
  rule — and which lists each branch's analysis, state and severity in
  `branches`. The `branch` and `analysis` filters choose which branches are
  grouped at all; every other filter reads the grouped row. The consolidated
  export stays one row per branch (`group=False`), and its header now
  measures the count the screen was showing against distinct open findings,
  not rows.
```

- [ ] **Step 10: commit**

```bash
/usr/bin/git add bin/security/queries.py bin/security/cli.py bin/security/report.py tests/security/test_queries.py tests/security/test_export_findings.py tests/security/test_consolidated_report.py CHANGELOG.md
```

```bash
/usr/bin/git commit -m "fix(security): one row per finding in the findings browser, the export still per branch" -m "A decision is recorded against the project, and the browser listed a finding once per branch: every finding already ruled on came back as a second row each time the other branch was analysed. finding_rows groups by fingerprint (state: open anywhere, then a decision, then fixed only when every branch says so; severity: the worst open reading), after the branch/analysis filters; export-findings asks for group=False and its header measures the screen's count against distinct open findings." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: a lista no ecrã — Branch, "+N", o badge e a faixa

**Files:**
- Modify: `ui/security/findings-screen.js` (comentário de topo, comentário da faixa, `ROW_PILL_TITLE`, `secFindStrip`, comentário da tabela, `secFindRow`)
- Test: `tests/test_page_contract.py`
- Regenerate: `bin/static/security.js`, `bin/static/app.js`, `bin/static/app.css`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: o campo `branches` de cada linha (Task 1): `[{branch, analysis_id, state, severity}]`; `f.branch`/`f.analysis_id` são os do representante. Uma linha sem `branches` é desenhada como a sua própria branch.

- [ ] **Step 1: escrever e ajustar os testes de contrato**

Em `tests/test_page_contract.py`:

(a) Substituir o teste `test_the_strip_labels_total_and_unique_and_counts_the_floor_from_the_whole_filtered_set` inteiro por:

```python
@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_strip_counts_each_finding_once_and_the_floor_from_the_whole_filtered_set(
        srv, tmp_path):
    """One row per finding (queries.finding_rows groups by fingerprint), so
    the strip shows one count: the Unique issues card could only ever repeat
    the total, and is gone. The count of what the severity floor hides still
    comes from `by_severity` (every row the current filters match, computed
    BEFORE pagination), not from the slice of rows on THIS page."""
    block = _security_js(srv)
    consts = (_const(block, "SEV_ORDER") + _const(block, "ROW_PILL_TITLE")
              + _const(block, "SEV_KPI_ICON") + _const(block, "SEV_KPI_TONE"))
    deps = "\n".join(_plainfn(block, n) for n in
                     ("secEl", "secIcon", "_secCap", "secFindHiddenByFloor", "secFindStrip"))
    script = tmp_path / "find-strip.js"
    script.write_text(_INDEX_DOM_HARNESS + _KPI_CARD_STUB + """
    function secMinSeverity(_p){ return "medium"; }
    const fs = {project: "web"};
    """ + consts + deps + """
    const data = {total: 10, unique: 10,
      by_severity: {critical: 1, high: 4, medium: 0, low: 3, info: 2}, page: 1, per_page: 25};
    console.log(JSON.stringify(collectAll(secFindStrip(fs, data), [])));
    """)
    out = json.loads(subprocess.run(["node", str(script)],
                                    capture_output=True, text=True, check=True).stdout)
    joined = " ".join(r["text"] for r in out)
    total_stat = next(r for r in out if "secfind-stat total" in r["cls"])
    assert "Total findings" in total_stat["text"] and "10" in total_stat["text"], \
        f"the Total stat must carry both its label and its number: {total_stat}"
    assert not [r for r in out if "secfind-stat unique" in r["cls"]], \
        "one row per finding: a Unique card could only repeat the total"
    assert "Unique issues" not in joined
    assert "5 findings below medium" in joined, \
        f"the hidden count must be 3 low + 2 info = 5, read from by_severity: {joined}"
    assert "every recorded finding" in joined, "the downloads-are-unfiltered sentence is missing"
```

(b) Em `test_the_two_kinds_of_severity_pill_each_say_what_they_count`, substituir a docstring e as duas asserções sobre o título da faixa:

```python
    """IMPORTANT 5(a). The sidebar donut is a flex sibling of the tab panes,
    so it is on screen DURING the Findings tab, four inches from the strip,
    in identical markup. Both count a finding once however many branches it
    is on (the browser is one row per finding), and they still answer
    different questions -- the strip, the findings the current filters
    match; the donut, every open problem -- so each says which."""
```

```python
    assert "matching the current filters" in out["strip"].get("title", ""), \
        f"the strip's severity pill does not say what it counts: {out['strip']}"
    assert "counts once" in out["strip"].get("title", ""), out["strip"]
```

(no lugar de `assert "Rows" in …` e `assert "counts twice" in …`; as asserções sobre a legenda e a desigualdade dos dois títulos ficam).

(c) Acrescentar a seguir a `test_a_fixed_finding_gets_no_decision_controls`:

```python
_FIND_ROW_CONSTS = ("SEC_STATE_LABEL", "SEC_STATE_HELP", "SEV_ORDER", "SEC_STATES",
                    "ICON_HYGIENE", "SEC_CATEGORY_LABEL", "SEC_CATEGORY_ICON")
_FIND_ROW_DEPS = ("secEl", "secIcon", "_secCap", "secCategoryMeta", "secConfidenceChip",
                  "secFindRow", "secFindDecisionControls", "secFindActionsCell")


def _find_row_script(block):
    consts = "".join(_const(block, n) for n in _FIND_ROW_CONSTS)
    arrows = (re.search(r"const secSevKey = .*?;", block).group(0) + "\n"
              + re.search(r"const secStateKey = .*?;", block).group(0) + "\n")
    deps = "\n".join(_plainfn(block, n) for n in _FIND_ROW_DEPS)
    return _INDEX_DOM_HARNESS + """
    function fmtWhen(t){ return "w" + String(t); }
    const fs = {project: "web", data: {analyses: [{id: 18, profile: "deep", started: 5}]}};
    const base = {title: "t", severity: "high", category: "sast", first_seen: 1,
      occurrences: [], fingerprint: "a".repeat(64)};
    """ + consts + arrows + deps


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_a_finding_on_two_branches_names_both_and_each_state_when_they_differ(srv, tmp_path):
    """One row per finding: the Branch cell names every branch the finding is
    on, and when they read it differently each branch carries its own state --
    the Status beside it is the reading that needs attention first, and this
    cell is where the rest is said. The run shown is the representative's;
    "+N" counts the others, their runs one hover away."""
    script = tmp_path / "find-row-branches.js"
    script.write_text(_find_row_script(_security_js(srv)) + """
    const mixed = secFindRow(fs, Object.assign({}, base, {state: "open", branch: "main",
      analysis_id: 18, branches: [
        {branch: "develop", analysis_id: 16, state: "fixed", severity: "high"},
        {branch: "main", analysis_id: 18, state: "open", severity: "high"}]}));
    const same = secFindRow(fs, Object.assign({}, base, {state: "false_positive",
      branch: "main", analysis_id: 18, branches: [
        {branch: "develop", analysis_id: 16, state: "false_positive", severity: "high"},
        {branch: "main", analysis_id: 18, state: "false_positive", severity: "high"}]}));
    console.log(JSON.stringify({mixed: collectAll(mixed, []), same: collectAll(same, [])}));
    """)
    out = json.loads(subprocess.run(["node", str(script)],
                                    capture_output=True, text=True, check=True).stdout)
    mixed = " ".join(r["text"] for r in out["mixed"])
    assert "develop · Fixed" in mixed and "main · Open" in mixed, mixed
    more = [r for r in out["mixed"] if r["text"].strip() == "+1"]
    assert more and more[0]["title"] == "#16 develop", out["mixed"]
    same = [r["text"] for r in out["same"]]
    assert "develop, main" in same, same
    assert "develop · False positive" not in " ".join(same), \
        "branches that agree carry no per-branch state"


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_fixed_elsewhere_badge_names_the_branch_it_speaks_about(srv, tmp_path):
    """On a row that can stand for several branches, "this branch" no longer
    says which: the badge's title names the representative's branch -- the
    one whose ancestry git was asked about."""
    script = tmp_path / "find-row-badge.js"
    script.write_text(_find_row_script(_security_js(srv)) + """
    const row = secFindRow(fs, Object.assign({}, base, {state: "open", branch: "develop",
      analysis_id: 16, fixed_elsewhere: {branch: "main", commit: "abcdef0123456789",
      in_this_branch: false}}));
    console.log(JSON.stringify(collectAll(row, [])));
    """)
    out = json.loads(subprocess.run(["node", str(script)],
                                    capture_output=True, text=True, check=True).stdout)
    badge = next(r for r in out if "fixed-elsewhere" in r["cls"])
    assert "NOT in develop" in badge["title"], badge
    assert "this branch" not in badge["title"], badge
```

(d) Em `_UNSTYLED_CLASS_ALLOWLIST`, substituir a entrada das classes da faixa:

```python
    # secFindStrip's Total KPI card (findings-screen.js): pure MARKER classes
    # appended to a .kpi-card element whose whole layout and colour come from
    # the shared component -- the hooks the pinned strip test finds it by,
    # styled by nothing on purpose.
    "secfind-stat",
    "total",
```

(sai `"unique"`, que deixa de ser usado).

- [ ] **Step 2: correr e ver falhar**

Run: `rtk proxy python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "strip or pill or two_branches or badge_names"`
Expected: FAIL — o cartão *Unique issues* ainda existe, o título da faixa ainda diz "counts twice", a célula Branch mostra só `f.branch`, não há "+1", e o tooltip do badge diz "this branch".

- [ ] **Step 3: implementar em `ui/security/findings-screen.js`**

(a) No comentário de topo do ficheiro, substituir o parágrafo que começa por `` `total` vs `unique`: the strip shows both`` (cinco linhas) por:

```js
   ONE ROW PER FINDING. `queries.finding_rows` groups the branches' checklists
   by fingerprint: the same finding on `main` and on `develop` is one row
   naming both, its Status the reading that needs attention first (open on
   any branch, then a decision, then `fixed` only once every branch says so),
   and each branch's own state beside its name when they disagree. A decision
   is recorded against the project, so one row is also the honest shape of
   what the operator decides on -- one row per branch put every finding
   already ruled on back in front of them each time another branch was
   analysed. `total` counts these rows; `unique`, still in the payload, is the
   same number, so the strip shows one.
```

(b) Substituir o comentário da secção da faixa:

```js
/* ------------------------------------------------------------------ strip
   total, unique issues, and the five severities -- see this file's own
   comment for why total and unique are both shown, labelled, rather than
   collapsed into one number. */
```

por:

```js
/* ------------------------------------------------------------------ strip
   the total and the five severities -- one row per finding (see this file's
   own comment), so there is no second, fingerprint-distinct number to show
   beside the total. */
```

(c) Substituir o comentário e a constante `ROW_PILL_TITLE`:

```js
// What the strip's per-severity stats COUNT. Threaded onto every stat's own
// `.title` -- this strip and the sidebar donut legend (index-screen.js, see
// DONUT_PILL_TITLE there) both count a finding once however many branches
// it is on, and still answer different questions: this one, the findings
// the current filters match; the donut, every open problem, filters or not.
const ROW_PILL_TITLE = "Findings matching the current filters — one row per "
  + "finding, so the same finding on two branches counts once here.";
```

(d) Em `secFindStrip`, substituir o comentário que começa por `// Seven KPI CARDS (ProjectFindings.png)` por:

```js
  // Six KPI CARDS (ProjectFindings.png), the house kpi-grid replacing the
  // one-container stat strip this used to be: Total findings and the five
  // severities (each with its share of the total on the same delta line the
  // Overview's cards use). The seventh, Unique issues, went when the rows
  // became one per finding: it could only ever repeat the total.
  // ROW_PILL_TITLE on every card, and the marker class on Total the pinned
  // tests find it by. The severity cards wear the shared severity icon/tone
  // maps (SEV_KPI_ICON/SEV_KPI_TONE, overview-tab.js), so the two tabs'
  // cards can never drift apart.
```

e apagar o cartão *Unique issues* (as seis linhas de `const uniqueCard = kpiCard({icon: "diamond", …` até `strip.appendChild(uniqueCard);`, mais a linha em branco a seguir).

(e) Substituir o comentário da secção da tabela:

```js
/* ------------------------------------------------------------------ table
   The state a row shows is the state its OWN branch's latest finished
   analysis gives it -- a list that crosses branches (and so crosses
   analyses) has to say which one it is speaking about, hence the Branch and
   Analysis run columns beside Status rather than a bare severity/title
   pair. */
```

por:

```js
/* ------------------------------------------------------------------ table
   A row is one finding across the branches it is on (queries.finding_rows
   groups by fingerprint), and the state it shows is the reading that needs
   attention first among them -- so the row has to say whose reading that
   is and what the others read: the Analysis run column names the
   representative's run and counts the rest, the Branch column names every
   branch and, when they disagree, each one's own state. */
```

(f) Em `secFindRow`, a célula ANALYSIS RUN: acrescentar ao fim do seu comentário

```js
  // The run is the REPRESENTATIVE's -- the branch whose reading decides the
  // Status (queries._group_by_fingerprint) -- and "+N" beside it counts the
  // other branches carrying the same finding, their runs one hover away.
  // Button and count share one line: `.secfind-run` is a flex column and
  // would otherwise stack them.
```

e substituir o corpo, de `const tdRun = document.createElement("td");` até `tr.appendChild(tdRun);`, por:

```js
  const tdRun = document.createElement("td");
  const runWrap = secEl("div", "secfind-run");
  const runInfo = ((fs.data || {}).analyses || []).find(a => a.id === f.analysis_id);
  const runLine = secEl("div");
  if(f.analysis_id != null){
    const runBtn = document.createElement("button");
    runBtn.type = "button";
    runBtn.title = "Show this analysis";
    const profileWord = runInfo && runInfo.profile ? " (" + _secCap(runInfo.profile) + ")" : "";
    runBtn.appendChild(document.createTextNode("#" + f.analysis_id + profileWord));
    runBtn.onclick = (e) => {
      e.stopPropagation();
      secSwitchProjectTab("runs");
      secShowAnalysis(f.analysis_id, true);
    };
    runLine.appendChild(runBtn);
  }
  const otherRuns = (f.branches || []).filter(b => b.analysis_id !== f.analysis_id);
  if(otherRuns.length){
    const more = secEl("span", "secmeta", " +" + otherRuns.length);
    more.title = otherRuns.map(b => "#" + b.analysis_id + " " + b.branch).join(", ");
    runLine.appendChild(more);
  }
  runWrap.appendChild(runLine);
  if(runInfo && runInfo.started){
    runWrap.appendChild(secEl("div", "secmeta", fmtWhen(runInfo.started)));
  }
  tdRun.appendChild(runWrap);
  tr.appendChild(tdRun);
```

(g) Substituir a célula BRANCH:

```js
  // BRANCH
  const tdBranch = document.createElement("td");
  tdBranch.textContent = f.branch || "";
  tr.appendChild(tdBranch);
```

por:

```js
  // BRANCH: every branch this finding is on. When they all read it the same,
  // just their names; when they disagree, each branch with its own state --
  // the Status beside this cell is the reading that needs attention first,
  // and this is where the others are said. A row without `branches` is its
  // own branch, as it always was. Each branch's run and state are one hover
  // away.
  const tdBranch = document.createElement("td");
  const onBranches = (f.branches && f.branches.length) ? f.branches
    : [{branch: f.branch || "", analysis_id: f.analysis_id, state: f.state}];
  const stateWord = (s) => SEC_STATE_LABEL[s] || s;
  if(onBranches.some(b => b.state !== onBranches[0].state)){
    onBranches.forEach(b => tdBranch.appendChild(
      secEl("div", null, b.branch + " · " + stateWord(b.state))));
  }else{
    tdBranch.textContent = onBranches.map(b => b.branch).join(", ");
  }
  if(onBranches.length > 1){
    tdBranch.title = onBranches.map(b => b.branch + " — #" + b.analysis_id
      + " — " + stateWord(b.state)).join("\n");
  }
  tr.appendChild(tdBranch);
```

(h) No badge FIXED ELSEWHERE, substituir a atribuição `feBadge.title = merged ? … : …;` por:

```js
    // NAMED, not "this branch": a row can stand for several branches now,
    // and the ancestry git was asked about is the representative's -- the
    // branch in this row's own `branch` field.
    const here = f.branch || "this branch";
    feBadge.title = merged
      ? "Fixed on " + where + ", and that commit is already in " + here + " — very likely resolved there too. Re-analyse " + here + " to confirm; nothing is marked fixed until somebody looks again."
      : pending
        ? "Fixed on " + where + ", and that commit is NOT in " + here + " yet — the hole is real there; read that fix before writing a new one."
        : "Fixed on " + where + "; whether that fix is in " + here + " could not be determined (" + (fe.unknown_reason || "unknown") + ").";
```

- [ ] **Step 4: correr e ver passar**

Run: `rtk proxy python3.13 -m pytest tests/test_page_contract.py tests/test_security_api.py -p no:cacheprovider -q`
Expected: PASS (todos; os testes que extraem `secFindRow` sem `fs.data` continuam a não chamar `_secCap`).

- [ ] **Step 5: reconstruir o bundle**

Run: `bash build/build-ui.sh`
Expected: `built bin/static/security.js, bin/static/app.js, bin/static/app.css`

Run: `node --check bin/static/security.js`
Expected: sem saída, exit 0.

- [ ] **Step 6: README e CHANGELOG**

Em `README.md`, substituir o parágrafo que começa por `` `total` and `unique` are shown as two labelled numbers above it`` (quatro linhas, até "…whichever question you were not asking.") por:

```markdown
**One row per finding, not one per branch.** The browser unions the latest
finished analysis of every branch and groups it by fingerprint: the same
finding on `main` and on `develop` is one row naming both. Its Status is the
reading that needs attention first — open on any branch outranks a decision,
and a decision outranks `fixed`, so a finding reads fixed only once every
branch it is on says so — and when the branches disagree, each one's own
state is written beside its name. A decision is recorded against the
project, so one row is also the honest shape of what you decide on: before
this, every finding already ruled on came back in front of you, as a second
row, each time another branch was analysed. *Branch: main* shows the finding
as `main` reads it. The consolidated export stays one row per branch,
because a fix is applied on a branch.
```

Em `CHANGELOG.md`, acrescentar ao fim da entrada da Task 1 (a que começa por **A finding on several branches is one row in the findings browser**), antes da linha em branco:

```markdown
  On the screen, the Branch column names every branch a finding is on and,
  when they disagree, each one's own state; the Analysis run shows the
  representative's run with `+N` for the others; the *Unique issues* card is
  gone, since it could only repeat the total.
```

- [ ] **Step 7: commit**

```bash
/usr/bin/git add ui/security/findings-screen.js tests/test_page_contract.py bin/static/security.js bin/static/app.js bin/static/app.css README.md CHANGELOG.md
```

```bash
/usr/bin/git commit -m "fix(dashboard): the findings list names every branch a finding is on" -m "One row per finding needs the row to say whose reading the Status is and what the other branches read: the Branch cell lists every branch (each with its own state when they disagree), the Analysis run shows the representative's run with +N for the others, and the fixed-elsewhere badge names the branch it speaks about. The Unique issues card is gone -- it could only repeat the total." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `decided_sast` no checklist do agente, e a regra na skill

**Files:**
- Modify: `bin/security/queries.py` (`decided_sast`, a seguir a `checklist`)
- Modify: `bin/security/cli.py` (`cmd_checklist`)
- Modify: `skills/security-analysis/SKILL.md` (Job 3)
- Create: `tests/security/test_decided_sast.py`
- Modify: `tests/security/test_cli.py`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Produces: `queries.decided_sast(conn, analysis_id) -> list[dict]`, cada entrada `{"fingerprint": str, "rule": str, "title": str, "severity": str, "occurrences": [{"file": str, "line": int}], "last_seen": {"branch": str, "analysis_id": int}, "decision": {"state": str, "reason": str}}`, ordenada por `(rule, fingerprint)`. A saída de `agentloop security checklist` passa a `{"analysis", "findings", "decided_sast"}`.

- [ ] **Step 1: escrever os testes que falham**

Criar `tests/security/test_decided_sast.py`:

```python
"""`queries.decided_sast` -- the `sast` findings the operator already ruled on
that an analysis's checklist does not list, handed to the agent beside the
checklist so the same hole found again is folded into the decided identity
instead of minted a second time.

Measured on one project's ledger (2026-09-23): one access-control hole was
minted under one fingerprint on main and under another on develop, and was
accepted twice. Every case below is a way this list could hand the agent too
much or too little.
"""
import re
from pathlib import Path

import pytest

from security import ledger, queries

SKILL = Path(__file__).resolve().parents[2] / "skills" / "security-analysis" / "SKILL.md"
FP = "a" * 64


@pytest.fixture
def conn(tmp_path):
    return ledger.connect(tmp_path / "security.db")


def _analysis(conn, branch, findings=(), state="done", project="web", repo="web"):
    """One analysis of `branch` holding `findings` -- each an agent `sast`
    unless it says otherwise -- closed in `state`; `running` leaves it open,
    the way the agent's own analysis is while it reads the checklist."""
    aid = ledger.start_analysis(conn, project, repo, branch, "sha", "quick", "r")
    for extra in findings:
        finding = {"category": "sast", "rule": "broken-access-control",
                   "severity": "medium", "title": "the drawer proxies any candidate",
                   "producer": "agent",
                   "occurrences": [{"file": "app/queue.php", "line": 54}]}
        finding.update(extra)
        ledger.record_finding(conn, aid, finding)
    ledger.mark_prepared(conn, aid)
    if state != "running":
        ledger.finish_analysis(conn, aid, state)
    return aid


def test_a_sast_decided_on_another_branch_is_handed_to_the_agent(conn):
    dev = _analysis(conn, "develop", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "accepted", "product decision RP-217", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == [{
        "fingerprint": FP, "rule": "broken-access-control",
        "title": "the drawer proxies any candidate", "severity": "medium",
        "occurrences": [{"file": "app/queue.php", "line": 54}],
        "last_seen": {"branch": "develop", "analysis_id": dev},
        "decision": {"state": "accepted", "reason": "product decision RP-217"}}]


def test_a_decided_sast_the_checklist_already_lists_is_not_repeated(conn):
    _analysis(conn, "main", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "false_positive", "not reachable", "me")
    nxt = _analysis(conn, "main", state="running")      # FP is in its baseline
    assert queries.decided_sast(conn, nxt) == []


def test_a_decided_sast_this_branch_lost_from_its_baseline_is_handed_back(conn):
    _analysis(conn, "main", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    _analysis(conn, "main")                             # not re-reported: out of the baseline
    nxt = _analysis(conn, "main", state="running")
    assert [e["fingerprint"] for e in queries.decided_sast(conn, nxt)] == [FP]


def test_only_the_agents_own_sast_is_handed_over(conn):
    semgrep, secret = "5" * 64, "6" * 64
    _analysis(conn, "develop", [
        {"fingerprint": semgrep, "producer": "semgrep", "rule": "sql-injection"},
        {"fingerprint": secret, "category": "secret", "rule": "aws-access-token",
         "producer": "gitleaks"}])
    for fp in (semgrep, secret):
        ledger.set_decision(conn, "web", fp, "false_positive", "fixture", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_a_sast_nobody_ruled_on_is_not_handed_over(conn):
    _analysis(conn, "develop", [{"fingerprint": FP}])
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_another_project_or_repository_is_another_thing(conn):
    other = "7" * 64
    _analysis(conn, "develop", [{"fingerprint": FP}], project="api", repo="api")
    ledger.set_decision(conn, "api", FP, "accepted", "theirs", "me")
    _analysis(conn, "develop", [{"fingerprint": other}], repo="web-admin")
    ledger.set_decision(conn, "web", other, "accepted", "another repository", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_the_newest_finished_record_describes_the_entry(conn):
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the old words",
                                 "occurrences": [{"file": "app/old.php", "line": 1}]}])
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the new words",
                                 "occurrences": [{"file": "app/new.php", "line": 2}]}])
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "a failed run's words"}],
              state="failed")
    _analysis(conn, "feature", [{"fingerprint": FP, "title": "a running run's words"}],
              state="running")
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    (entry,) = queries.decided_sast(conn, main)
    assert entry["title"] == "the new words"
    assert entry["occurrences"] == [{"file": "app/new.php", "line": 2}]


def test_the_list_comes_in_a_stable_order(conn):
    xss, bac = "b" * 64, "c" * 64
    _analysis(conn, "develop", [{"fingerprint": xss, "rule": "xss"},
                                {"fingerprint": bac, "rule": "broken-access-control"}])
    for fp in (xss, bac):
        ledger.set_decision(conn, "web", fp, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    assert [e["rule"] for e in queries.decided_sast(conn, main)] == \
        ["broken-access-control", "xss"]


def test_the_skill_tells_the_agent_to_fold_into_a_decided_sast_and_never_to_copy_one():
    """The list is inert without the instruction: an agent that is never told
    to look in `decided_sast` mints the second identity anyway. And an agent
    told only to use it would re-report every entry as if it were work carried
    over -- so the same paragraph has to say both halves."""
    text = SKILL.read_text()
    job3 = re.search(r"\*\*3\. The SAST pass\*\*(.*?)## Rules that are not negotiable",
                     text, re.DOTALL)
    assert job3, "SKILL.md no longer has a Job 3 section this test can read"
    blocks = [b for b in job3.group(1).split("\n\n") if "`decided_sast`" in b]
    assert blocks, "Job 3 never tells the agent about `decided_sast`"
    assert any("copied exactly" in b and "did not find yourself" in b for b in blocks), \
        "no paragraph both says to reuse the entry's fingerprint and not to copy entries"
```

Em `tests/security/test_cli.py`, a seguir a `test_a_decision_wins_over_the_derived_state`, acrescentar:

```python
def test_the_checklist_hands_the_agent_the_sast_decided_on_another_branch(tmp_path):
    """`decided_sast` rides BESIDE the checklist: an agent-minted `sast` the
    operator ruled on while another branch's analysis held it, which this
    analysis's checklist cannot list -- see queries.decided_sast."""
    db = tmp_path / "security.db"
    fp = "c" * 64
    dev = prepared_analysis(db, tmp_path, branch="develop", run_id="r-dev")
    run(db, "report-finding", "--analysis", str(dev), stdin=json.dumps({
        "fingerprint": fp, "category": "sast", "rule": "broken-access-control",
        "severity": "low", "title": "the drawer proxies any candidate",
        "rationale": "any id reaches the upstream", "remediation": "scope the id",
        "candidate": TRIAGE_CANDIDATE,
        "occurrences": [{"file": "app/queue.php", "line": 54}]}))
    run(db, "finish", "--analysis", str(dev), "--state", "done")
    run(db, "decide", "--project", "web", "--fingerprint", fp, "--state", "accepted",
        "--reason", "product decision RP-217", "--by", "me")
    main = prepared_analysis(db, tmp_path, branch="main", run_id="r-main")
    out = run(db, "checklist", "--analysis", str(main))
    assert [e["fingerprint"] for e in out["decided_sast"]] == [fp]
    assert out["decided_sast"][0]["decision"]["state"] == "accepted"
    assert all(f["fingerprint"] != fp for f in out["findings"]), \
        "beside the checklist, never inside it"
```

- [ ] **Step 2: correr e ver falhar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_decided_sast.py tests/security/test_cli.py -p no:cacheprovider -q -k "decided or skill_tells"`
Expected: FAIL — `AttributeError: module 'security.queries' has no attribute 'decided_sast'`, `KeyError: 'decided_sast'` e a asserção da skill.

- [ ] **Step 3: implementar `decided_sast` e a saída do `checklist`**

Em `bin/security/queries.py`, imediatamente a seguir à função `checklist`, acrescentar:

```python
def decided_sast(conn, analysis_id):
    """The agent's own `sast` findings the operator has already ruled on that
    this analysis's checklist does not list -- handed to the agent beside the
    checklist (`cmd_checklist`) so the same hole found again is re-reported
    under the decided identity instead of minted a second time.

    WHY THIS EXISTS. The agent mints a `sast` fingerprint from the rule, the
    path and the snippet IT chose, and the skill has it reuse one only when a
    row it can see already lists the weakness. `checklist` compares with the
    same branch only, so a finding decided on develop was invisible from main
    and was minted again there, without its decision -- measured on one
    project (2026-09-23): one access-control hole accepted twice, under two
    fingerprints, once per branch. A decision is recorded against the
    project; this is what lets the identity it is keyed to survive the
    branch.

    WHICH FINDINGS. Every fingerprint with a decision in this project whose
    most recent record -- in the finished (`done`/`capped`) analysis of this
    project and repository with the highest id, whatever its branch -- is a
    `sast` the AGENT minted. Semgrep's rows are left out: their identity is
    built from its own check id and does not drift. Another repository is
    left out: there the same fingerprint is another thing with the same name
    (the rule `fixed_elsewhere` keeps). And what the checklist of this
    analysis already lists -- this analysis and its baseline -- is left out,
    because the agent already sees those, with the decision's state.

    Each entry carries what the agent needs to RECOGNISE the finding and
    nothing it would have to read at length: rule, title, severity,
    occurrences, where it was last seen, and the decision with its reason.
    Ordered by (rule, fingerprint), so two runs over the same ledger hand the
    agent the same list.
    """
    analysis = dict(_analysis_row(conn, analysis_id))
    decisions = ledger.decisions_for(conn, analysis["project"])
    if not decisions:
        return []
    _an, listed = checklist(conn, analysis_id)
    listed_fps = {f["fingerprint"] for f in listed}
    out = []
    for fp, decision in decisions.items():
        if fp in listed_fps:
            continue
        row = conn.execute(
            "SELECT f.id, f.category, f.producer, f.rule, f.title, f.severity,"
            " a.id AS analysis_id, a.branch FROM finding f"
            " JOIN analysis a ON a.id = f.analysis_id"
            " WHERE f.fingerprint=? AND a.project=? AND a.repo=?"
            " AND a.state IN ('done','capped')"
            " ORDER BY a.id DESC LIMIT 1",
            (fp, analysis["project"], analysis["repo"])).fetchone()
        if row is None or row["category"] != "sast" or row["producer"] != diff.AGENT:
            continue
        occurrences = [{"file": o["file"], "line": o["line"]} for o in conn.execute(
            "SELECT file, line FROM occurrence WHERE finding_id=? ORDER BY id",
            (row["id"],))]
        out.append({"fingerprint": fp, "rule": row["rule"], "title": row["title"],
                    "severity": row["severity"], "occurrences": occurrences,
                    "last_seen": {"branch": row["branch"],
                                  "analysis_id": row["analysis_id"]},
                    "decision": {"state": decision["state"],
                                 "reason": decision["reason"]}})
    out.sort(key=lambda e: (e["rule"], e["fingerprint"]))
    return out
```

Em `bin/security/cli.py`, substituir `cmd_checklist` por:

```python
def cmd_checklist(args):
    conn = _conn(args)
    try:
        analysis, findings = queries.checklist(conn, args.analysis)
    except queries.AnalysisNotFound as e:
        sys.exit(str(e))
    # `decided_sast` rides BESIDE the checklist, never inside it: `findings`
    # is this analysis and its baseline, which every screen and report reads,
    # while the list describes no state of this analysis at all -- it is for
    # the agent's fold-before-you-mint rule (SKILL.md, Job 3).
    print(json.dumps({"analysis": analysis, "findings": findings,
                      "decided_sast": queries.decided_sast(conn, args.analysis)},
                     indent=2))
```

- [ ] **Step 4: correr — os testes da query e do CLI passam, o da skill ainda não**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_decided_sast.py tests/security/test_cli.py -p no:cacheprovider -q -k "decided or skill_tells"`
Expected: 1 failed (`test_the_skill_tells_the_agent_…`), os restantes PASS.

- [ ] **Step 5: o parágrafo na skill**

Em `skills/security-analysis/SKILL.md`, no Job 3, a seguir ao parágrafo que começa por "Fold in only what is genuinely the same weakness in the same place." (e antes de `## Rules that are not negotiable`), acrescentar:

```markdown
**`checklist` also prints `decided_sast`: the `sast` findings the operator has already ruled on — accepted or false positive — that this checklist does not list,** because they were recorded on another branch, or in an older analysis of this one. Your own pass mints a `sast` fingerprint from the rule, the path and the snippet you chose, so the same hole found from another branch comes out under a new identity that no decision reaches: the operator rules on it a second time, or watches a finding they already dismissed come back as `new`. One access-control hole was accepted twice on one project that way, once per branch.

So before you mint a fingerprint with `--snippet`, read `decided_sast` too. If the weakness you are about to report is one of its entries — the same flaw, in the same place — re-report it under **that entry's fingerprint, copied exactly**, with your own rationale, occurrences and `candidate`; the operator's decision then applies here as well. The list is for folding into and nothing else: an entry you did not find yourself in this run is not re-reported, because it is not work carried over — nobody asked you to check it — and an entry that only resembles what you found, another flaw in the same file, is not one to fold into.
```

- [ ] **Step 6: correr e ver passar**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security/test_decided_sast.py tests/security/test_cli.py tests/security/test_queries.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Step 7: README e CHANGELOG**

Em `README.md`, na secção "A fact belongs to a branch; a decision belongs to the project", a seguir ao parágrafo que começa por "**Change the code around a decided finding and it comes back as `new`.**", acrescentar:

```markdown
**The agent's own finding keeps its identity across branches.** A `sast`
fingerprint the agent mints is built from the rule, the path and the snippet
it chose, and it reuses one only when the checklist it works from lists the
weakness — a checklist that compares with the same branch alone. So a finding
decided on `develop` was minted again on `main`, without its decision: one
access-control hole was accepted twice on one project, once per branch.
`agentloop security checklist` now also prints `decided_sast` — every `sast`
the agent minted in this project and repository that carries a decision the
checklist does not already list, with its rule, title, occurrences, where it
was last seen and the decision — and the skill tells the agent to re-report
the same flaw in the same place under that fingerprint, so the decision
applies instead of the finding coming back as `new`. Semgrep's rows are left
out: their identity comes from Semgrep's own check id and does not drift.
```

Em `CHANGELOG.md`, sob `### Fixed`, a seguir à entrada da Task 1:

```markdown
- **A `sast` finding the operator ruled on no longer comes back as `new` when
  another branch's analysis finds it.** The agent mints a `sast` fingerprint
  from the rule, path and snippet it chose, and reuses one only when the
  checklist lists the weakness — and the checklist compares with the same
  branch only. So a finding decided on `develop` was minted again on `main`,
  without its decision: one access-control hole was accepted twice, under two
  identities. `agentloop security checklist` now also prints `decided_sast` —
  every agent-minted `sast` of the same project and repository with an
  operator decision the checklist does not already list, with its rule,
  title, occurrences, where it was last seen and the decision — and the
  skill's Job 3 tells the agent to re-report the same flaw in the same place
  under that fingerprint. Semgrep's rows are left out: their identity is
  deterministic and does not drift.
```

- [ ] **Step 8: commit**

```bash
/usr/bin/git add bin/security/queries.py bin/security/cli.py skills/security-analysis/SKILL.md tests/security/test_decided_sast.py tests/security/test_cli.py README.md CHANGELOG.md
```

```bash
/usr/bin/git commit -m "fix(security): a decided sast keeps its identity across branches" -m "The agent reuses a sast fingerprint only when the checklist lists the weakness, and the checklist compares with the same branch only -- so a finding decided on develop was minted again on main without its decision (one access-control hole was accepted twice). The checklist verb now also prints decided_sast, the agent-minted sast of the project and repository that carry a decision the checklist does not list, and the skill's Job 3 tells the agent to fold the same flaw in the same place into that fingerprint." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: verificação completa e aceitação sobre uma cópia do ledger

**Files:** nenhum versionado (os scripts de aceitação vivem em `<SCRATCH>`).

- [ ] **Step 1: a metade pytest sem segurança**

Run: `rtk proxy python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q`
Expected: PASS (todos).

- [ ] **Step 2: a metade de segurança**

Run: `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true rtk proxy python3.13 -m pytest tests/security -p no:cacheprovider -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on`
Expected: PASS (todos).

- [ ] **Step 3: o selftest**

Run: `rtk proxy bash bin/agentloop selftest`
Expected: tudo verde excepto, no máximo, a falha conhecida de uma worktree sem `config/jobs.json` (git-ignored). Qualquer outra falha — bundle desactualizado, home real num ficheiro versionado, CHANGELOG — é deste trabalho e corrige-se antes de seguir.

- [ ] **Step 4: aceitação sobre uma cópia do ledger real**

Copiar o ledger para o rascunho (o ledger real nunca é aberto por código desta branch):

Run: `cp ~/Projects/agentloop/data/security.db <SCRATCH>/accept.db`

Criar `<SCRATCH>/accept.py`:

```python
"""Acceptance over a COPY of the live ledger -- never the ledger itself."""
import sys

sys.path.insert(0, sys.argv[1] + "/bin")
from security import queries  # noqa: E402

conn = queries.read_only(sys.argv[2])
fp_state = {"state": ["false_positive"]}
grouped = queries.finding_rows(conn, "Minerva", fp_state, per_page=100)
flat = queries.finding_rows(conn, "Minerva", fp_state, per_page=100, group=False)
print("false positives: grouped", grouped["total"], "per branch", flat["total"])
for r in grouped["rows"]:
    if r["rule"] == "aws-access-token":
        print("aws:", r["fingerprint"][:12], [(b["branch"], b["state"]) for b in r["branches"]])
latest_main = max(a["id"] for a in grouped["analyses"] if a["branch"] == "main")
print("decided_sast for", latest_main, ":",
      [e["fingerprint"][:12] for e in queries.decided_sast(conn, latest_main)])
```

Run: `python3.13 <SCRATCH>/accept.py <WT> <SCRATCH>/accept.db`
Expected (números de 2026-09-23; o ledger pode ter mudado desde então): `grouped` cerca de metade de `per branch` (35 contra 70); uma única linha `aws:` com `('develop', 'false_positive'), ('main', 'false_positive')`; `decided_sast` com os 4 SAST do agente (`0e0587a64535`, `60288a312941`, `9e141cbdc85b`, `ece2e8e433c9`, por ordem de regra).

- [ ] **Step 5: verificação visual**

O ecrã só se vê com sessão iniciada no dashboard, e a sessão é do operador. Pedir ao operador que abra o separador *Findings* do Minerva depois de instalar a branch (ou num servidor de rascunho sobre a cópia, com o login dele) e confirme: o aws token numa linha só, com `develop, main`; um finding aberto num branch e fixed no outro, com `develop · …` / `main · …`; nenhum cartão *Unique issues*.

- [ ] **Step 6: revisão e entrega**

Pedir revisão de código (skill `requesting-code-review`) sobre `main..fix/security-findings-one-row`, tratar o que vier (skill `receiving-code-review`), e fechar com a skill `finishing-a-development-branch`. Se o 4.2 (`feat/security-verdicts`) tiver entrado no `main` entretanto: fazer rebase e aplicar a adaptação da spec (secção "Convivência com o 4.2") — `counted()` no gate do grupo e no conjunto de membros abertos, e o filtro `verdict` sobre o representante.
