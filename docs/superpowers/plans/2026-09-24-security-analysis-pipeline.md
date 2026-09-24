# Análise de segurança em pipeline — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectivo:** uma análise de segurança de qualquer repositório, de qualquer
tamanho e em qualquer das três plataformas cobre o âmbito do seu perfil. Um
`deep` lê cada ficheiro do âmbito do princípio ao fim, e o `done` é provado
pelo motor, não afirmado pelo modelo.

**Arquitectura:** o `prepare` passa a gravar um inventário determinístico do
âmbito e um plano de unidades (`triage`, `hunt`, `read`, `verify`). Um
orquestrador em Python, lançado pelo motor, corre cada unidade como um run
normal do job derivado, com um prompt cunhado pelo CLI. No fecho de cada run,
`unit-close` avalia a prova (stream para as leituras, ledger para a triagem e
os veredictos) e gera continuações do que falta. O `finish --from-units`
decide `done`/`capped` com as lacunas nomeadas. Stop e crash deixam a análise
`interrupted`, e a retoma continua sem repetir o que já foi pago.

**Stack:** Python 3.13 (stdlib: `sqlite3`, `subprocess`, `signal`, `json`,
`shlex`), bash 3.2 (`bin/agentloop`), JavaScript sem framework
(`ui/security/*.js`, empacotado com esbuild 0.25.0 por `build/build-ui.sh`),
pytest, o selftest e o e2e em bash.

**Spec:** [2026-09-24-security-analysis-pipeline-design.md](../specs/2026-09-24-security-analysis-pipeline-design.md)

## Restrições globais

- Fatia `read`: `SLICE_BYTES = 300_000`. Um ficheiro maior é partido em intervalos de linhas de até 300 000 bytes.
- Lote de triagem: `TRIAGE_BATCH = 25` linhas por unidade.
- Tentativas por linhagem: `MAX_ATTEMPTS = 3`.
- Paralelismo: `security.parallel`, inteiro de 1 a 8, `3` por omissão.
- Tecto por unidade: o que resta do orçamento ÷ unidades em voo, com um mínimo de `0.50` USD.
- Retomas automáticas por análise: `MAX_AUTO_RESUMES = 3`.
- Gerado: `*.min.js`, `*.min.mjs`, `*.min.css`, `*.map`, ou uma linha com mais de `5_000` bytes, ou uma média acima de `300` bytes por linha.
- Prosa: `.md`, `.markdown`, `.rst`, `.adoc`, `.txt`.
- Árvores de dependências: `node_modules`, `vendor`, `.venv`, `bower_components`, em qualquer profundidade.
- `!defaults` desliga `generated` e `prose`, além do filtro de ruído que já desliga.
- Estados de unidade: `pending`, `running`, `done`, `incomplete`, `failed`. Tipos: `triage`, `hunt`, `read`, `verify`.
- Estado novo da análise: `interrupted`. A postura, o índice e os roll-ups tratam-no como `running`.
- Código, docstrings, comentários, mensagens de commit e CHANGELOG em inglês; prosa deste plano em pt-PT.
- Módulos novos em `bin/security/` abrem com `# bin/security/<name>.py` e uma docstring cujos parágrafos começam por uma frase em maiúsculas que diz porquê. Testes novos abrem com `# tests/security/test_<name>.py` e uma docstring de uma linha, e os nomes dos testes são frases.
- Cada commit que toque em `bin/`, `skills/` ou `test/` leva a sua entrada no `CHANGELOG.md` no mesmo commit (o selftest verifica).
- Qualquer alteração em `ui/` obriga a `bash build/build-ui.sh` e ao commit dos `bin/static/*` no mesmo commit.
- Nada de dados de clientes nem de caminhos pessoais em ficheiros versionados: fixtures neutros, `/Users/me` ou `/Users/example` quando for preciso um caminho.
- A suite de segurança tem de passar com `AL_SECURITY_ENGINES=on` e sem ele, e nenhum teste novo pode ser saltado.

---

## Estrutura de ficheiros

| Ficheiro | Responsabilidade | Tarefa |
|---|---|---|
| `bin/security/ledger.py` | tabelas `unit`, `unit_read`, `unit_gone`, `analysis_inventory`; colunas `analysis.resumes`, `finding.unit`; estado `interrupted`; `add_units` (o plano numa transacção) | 1, 5, 10 |
| `bin/security/inventory.py` (novo) | o inventário do `deep` e as regras de exclusão | 2 |
| `bin/security/slices.py` (novo) | as fatias de leitura | 3 |
| `bin/security/evidence.py` (novo) | a prova de leitura a partir do stream e do que `read` serviu | 4 |
| `bin/platforms/opencode_stream.py` | o `read` do OpenCode guarda o intervalo na forma do Claude | 4 |
| `bin/security/units.py` (novo) | o plano, a fila, o julgamento, o fecho de uma unidade, as continuações, a dívida do `deep`, o sumário, as lacunas | 5, 7, 9 |
| `bin/security/prompts.py` | os prompts das unidades | 6 |
| `bin/security/cli.py` | `prepare` planeia; `unit-prompt`, `unit-close`, `units`, `read`, `report-gone`, `interrupt`, `resume`, `abandon`, `orchestrate`; `finish --from-units`; as portas | 7, 8, 9, 10, 13 |
| `bin/security/orchestrator.py` (novo) | o processo que corre a análise até ao fim | 10 |
| `bin/security/queries.py` | a fila de verificação só desta análise | 8 |
| `bin/security/report.py` | a frase de uma análise `interrupted` | 13 |
| `bin/agentloop` | `security_engine_py`; orquestrador, unidades, lock, stop, resume, tick; prompt e orçamento da unidade no `run_job` | 8, 11, 12 |
| `bin/agentloop-server` | op `security_resume`; rótulo das runs de unidade; `orchestrator` (vivo, fase) no `checklist` | 13 |
| `ui/security/*.js`, `ui/app/runs.js`, `ui/css/*.css`, `bin/dashboard.html`, `bin/static/*` | bloco «Pipeline», estado `interrupted`, Stop, Resume, rótulo | 14 |
| `skills/security-analysis/SKILL.md` | a skill por papel | 8, 15 |
| `README.md` | a secção de segurança | 11, 15 |
| `test/fake-claude` | simulador de unidades | 11 |
| `test/selftest.sh`, `test/e2e.test.sh` | blocos e cenários do motor | 8, 11, 12, 16 |
| `tests/security/*` | os testes Python de cada tarefa, o motor falso `fixtures/fake-engine` e os streams de `fixtures/streams/` | 1–10, 13, 15 |
| `tests/test_checks_24h.py`, `tests/test_security_api.py`, `tests/test_platform_runs.py`, `tests/test_page_contract.py` | o formato do log do orquestrador, o `orchestrator` do checklist, o rótulo das runs, a página | 10, 13, 14 |

## Emendas à spec, decididas no planeamento

Cada uma saiu de um facto medido no código ou em dados reais durante o planeamento; a spec descreve a intenção, o plano o que se constrói.

1. **O inventário vive numa tabela própria, `analysis_inventory` (uma linha por análise `deep`), e não numa coluna `analysis.scope`**: a tabela `finding` já tem uma `scope` com outro sentido (dependência de runtime ou de desenvolvimento), e todos os leitores de `analysis` fazem `SELECT *` (`queries.recent_analyses`, que o índice consulta a cada poll; `report.as_json`; `cmd_analysis`, que o motor lê) — o inventário de um repositório grande tem centenas de KB e viajaria em todos eles. Numa tabela à parte, nenhum leitor de `analysis` o pode levar por engano.
2. **A prova de leitura conta o que o resultado trouxe, não o que se pediu.** Medido em 1 620 `Read` reais: um `Read` sem `limit` pode vir cortado por um tecto de tokens, e um resultado sem erro pode não ter lido nada. Conta `tool_use_result.file.{startLine, numLines}` ou, sem ele, as linhas numeradas do conteúdo.
3. **No Codex, a leitura faz-se com `agentloop security read`**, que serve blocos numerados e regista-os no ledger (`unit_read`). As leituras por shell do Codex não são prováveis a partir do stream: vêm embrulhadas em `/bin/zsh -lc`, encadeadas, cortadas em 8 KB e às vezes perdidas. O verbo vale em todas as plataformas.
4. **O normalizador do OpenCode passa a guardar o intervalo de um `read`** (`metadata.display`), que deitava fora.
5. **As unidades de triagem levam as linhas herdadas de qualquer produtor**, não só as do agente. Uma linha determinista `pending` tem de ser re-reportada tal como está, senão sai da base seguinte e volta como `regressed`.
6. **Um `sast` herdado que desapareceu diz-se com `report-gone`, com a razão** (`unit_gone`). O silêncio não distingue «li e sumiu» de «não li».
7. **A fila de verificação passa a listar só as linhas desta análise.** Uma linha herdada nunca podia receber veredicto e baixava `done` para `capped` sem remédio (defeito latente encontrado no planeamento).
8. **O rótulo das runs de unidade sai do cabeçalho do precheck**, que o índice já guarda. Não há campo novo no diário.
9. **Parar qualquer run de uma análise pára a análise inteira**: o orquestrador vivo lançaria a unidade seguinte no slot libertado.
10. **Os guias de cada unidade `read` são escolhidos por fatia no `prepare`** (ATTACK-CLASSES e os dois mais próximos), com os sinais que a análise já usa.
11. **Exclusões a mais no inventário**: symlinks (ler um lê para onde aponta), submódulos e ficheiros ilegíveis, cada um com o seu motivo; a lista de lockfiles cobre os ecossistemas que o Trivy lê.
12. **O `prepare` corre numa worktree do orquestrador**, fora de qualquer sessão de agente, e passa a ser do motor em todas as plataformas.
13. **O plano é tudo ou nada, e só uma análise do pipeline planeia.** `ledger.add_units` escreve o plano inteiro numa só transacção; só o `prepare` que o orquestrador corre (`--plan`) planeia, e um plano que falha falha alto (saída não-zero, o motivo no stderr) — o orquestrador fecha então a análise `capped`, com o motivo, em vez de a correr com metade das unidades.
14. **A dívida do `deep` calcula-se a partir do inventário, não das unidades.** Cada unidade `read` grava na prova os intervalos do seu payload que provou ter lido (`evidence["covered"]`); o que falta ler é o inventário menos a união desses intervalos, seja qual for o estado da unidade. Uma fatia sem unidade, ou uma unidade que desistiu sem dizer o que faltava (crash, subagente, o motor que não a consegue correr), continua em dívida e é nomeada no fecho.
15. **A vida do orquestrador é um dado.** O orquestrador escreve a sua fase (`preparing`, `running units`, `finishing`, `stopping`) no ficheiro `phase` dentro do seu lock (`$LOCK_DIR/<job>/.analysis/`); o servidor junta ao JSON do `checklist` `orchestrator: {alive, phase}` (vivo pela mesma regra dos slots) e a página trata um orquestrador vivo como análise viva — entre duas unidades não há slot, e isso não é uma análise morta.
16. **A worktree do `prepare` fica em `$DATA_DIR/security/prepare/<job>-<análise>`, fora de `$WORKTREES_DIR`**, e não «dentro da pasta de worktrees do motor»: lá, o varrimento de órfãos do tick adoptá-la-ia (escrevendo `.ended` no checkout que está a ser analisado) e desmontá-la-ia ao fim do TTL, e o servidor percorria-a inteira a cada poll. É o orquestrador que a limpa: remove o que um crash tenha deixado antes de a criar, e remove-a (com `git worktree prune`) quando o `prepare` acaba, corra bem ou mal.
17. **Um run que acabou sem fechar a sua unidade é julgado pelo que deixou, e o stream encontra-se pelo nome.** O `run_job` escreve `<log>/<job>/<stamp UTC>-<pid>.stream.ndjson`, e `<pid>` é o processo que o orquestrador lançou; o orquestrador julga essa unidade como o `unit-close` a julgaria (a mesma função, `units.close`, sob `stopped`): o que provou conta, o resto continua na mesma tentativa. Três runs seguidos de uma linhagem que morrem sem fechar dão a linhagem por perdida, com o motivo.
18. **No OpenCode a skill é invocada pelo nome, e também pelo caminho** — não «lida pelo caminho»: é o que o prompt de hoje faz, e o CLI do OpenCode lê `~/.claude/skills` (medido). Só no Codex a skill é lida pelo caminho.

## Notas de execução (para quem implementa cada tarefa)

- **Worktree:** `.claude/worktrees/feat+security-analysis-pipeline`, ramo `feat/security-analysis-pipeline`. Git sempre como `/usr/bin/git …`, um comando simples por chamada (sem `&&`, `;`, `$( )` nem pipes para o git); o guarda recusa o resto.
- **Leituras:** o Bash passa pelo `rtk`, que corta ficheiros sem aviso. Ler com o Read; `rtk proxy <cmd>` quando for preciso a saída crua.
- **pytest:** só existe no `python3.13` (`python3.13 -m pytest … -p no:cacheprovider`). Correr sempre em primeiro plano com `timeout` de 600000 ms; nunca em segundo plano, nunca terminar a vez «à espera».
- **Segurança:** `tests/security` com `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true` e, localmente, `--deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on`.
- **Selftest:** num sítio com `config/jobs.json` semeado a partir de `config/jobs.example.json` (a worktree não o tem); o selftest embute o e2e, que partilha `test/sandbox`: nunca dois ao mesmo tempo.
- **CHANGELOG:** uma entrada por commit, no mesmo commit, escrita para quem não estava lá.
- **`ui/`:** qualquer mudança obriga a `bash build/build-ui.sh` e a juntar `bin/static/*` ao mesmo commit.
- **Fixtures neutros:** nada de nomes, caminhos ou achados de projectos reais; nenhum `/Users/<nome>` real em ficheiros versionados (`/Users/me`, `/Users/example`).
- **Sem push, sem PR.** O push só depois da CI completa local (os três jobs) e com autorização do utilizador.

---
### Task 1: Ledger — a tabela `unit`, o inventário numa tabela própria, as colunas `resumes`/`finding.unit` e o estado `interrupted`

> Nota: o desenho do inventário numa tabela própria (`analysis_inventory`, em vez da coluna `analysis.inventory`) foi aplicado como commit de correcção depois da Task 1 (`c69401f`, e `a88925b` para o erro que não é «no such table»); o texto abaixo descreve o que ficou construído.

**Ficheiros:**
- Modificar: `bin/security/ledger.py` (`_SCHEMA` ~linhas 30-187; constantes ~189-195; `_ANALYSIS_COLUMNS` ~208-227; `_FINDING_COLUMNS` ~234-270; `record_finding` ~668-689; funções novas no fim do ficheiro)
- Testes: `tests/security/test_ledger_units.py` (novo)

**Interfaces:**
- Produz (constantes): `ledger.UNIT_KINDS = ("triage", "hunt", "read", "verify")`, `ledger.UNIT_STATES = ("pending", "running", "done", "incomplete", "failed")`, `ledger.UNIT_SETTLED = ("done", "incomplete", "failed")`, `ledger.INTERRUPTED = "interrupted"`.
- Produz (funções):
  - `add_unit(conn, analysis_id, kind, payload: dict, attempt=1, parent=None) -> int`
  - `get_unit(conn, unit_id) -> dict | None` e `units_of(conn, analysis_id) -> list[dict]` (`payload` e `evidence` já descodificados em `dict`)
  - `start_unit(conn, unit_id, run_key="") -> bool` (`pending` → `running`, atómico)
  - `settle_unit(conn, unit_id, state, spend_usd=0.0, evidence=None, note="") -> bool` (`pending`/`running` → um dos `UNIT_SETTLED`; o custo acumula)
  - `reset_unit(conn, unit_id, spend_usd=0.0) -> bool` (`running` → `pending`, mesma tentativa)
  - `interrupt_analysis(conn, analysis_id) -> bool` (`running` → `interrupted`)
  - `resume_analysis(conn, analysis_id, automatic=False) -> bool` (`interrupted` → `running`; `resumes` +1 quando automática)
  - `close_interrupted(conn, analysis_id, note) -> bool` (`interrupted` → `failed`)
  - `set_inventory(conn, analysis_id, inventory: dict)` (upsert em `analysis_inventory`) e `inventory_of(conn, analysis_id) -> dict` (`{}` para uma análise sem inventário, um documento que não descodifica ou não é um objecto, e um ledger sem a tabela — uma ligação só-de-leitura a um ledger que o `connect()` nunca migrou; qualquer outro erro da base propaga-se)
  - `record_finding` aceita a chave opcional `unit` (inteiro; 0 = não veio de uma unidade)
  - `record_unit_read(conn, unit_id, path, first, last) -> None` e `unit_reads(conn, unit_id) -> list[tuple[str, int, int]]` (o que `security read` serviu à unidade)
  - `record_gone(conn, unit_id, fingerprint, reason) -> None` e `gone_in(conn, analysis_id) -> set[str]` (os achados `sast` herdados que uma unidade de triagem leu e deu como desaparecidos)

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_ledger_units.py`:

```python
# tests/security/test_ledger_units.py
"""The ledger's side of the pipeline: units, the deep scope, and the interrupted state."""
import sqlite3

import pytest

from security import ledger


@pytest.fixture
def conn(tmp_path):
    c = ledger.connect(tmp_path / "security.db")
    yield c
    c.close()


def _analysis(conn):
    return ledger.start_analysis(conn, "web", "web", "main", "abc", "deep", "security-web")


def _state(conn, aid):
    return conn.execute("SELECT state FROM analysis WHERE id=?", (aid,)).fetchone()["state"]


def test_a_fresh_ledger_has_the_unit_table_and_the_new_columns(conn):
    tables = {r["name"] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"unit", "unit_read", "unit_gone", "analysis_inventory"} <= tables
    analysis = {r["name"] for r in conn.execute("PRAGMA table_info(analysis)")}
    assert "resumes" in analysis
    assert "inventory" not in analysis, "the deep scope lives in its own table now"
    finding = {r["name"] for r in conn.execute("PRAGMA table_info(finding)")}
    assert "unit" in finding


def test_a_ledger_from_before_the_columns_gains_them_on_connect(tmp_path):
    path = tmp_path / "old.db"
    ledger.connect(path).close()
    raw = sqlite3.connect(path)
    raw.execute("ALTER TABLE analysis DROP COLUMN resumes")
    raw.execute("ALTER TABLE finding DROP COLUMN unit")
    raw.execute("DROP TABLE analysis_inventory")
    raw.commit()
    raw.close()
    conn = ledger.connect(path)
    assert "resumes" in {r["name"] for r in conn.execute("PRAGMA table_info(analysis)")}
    assert "unit" in {r["name"] for r in conn.execute("PRAGMA table_info(finding)")}
    assert "analysis_inventory" in {r["name"] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}


def test_units_are_numbered_per_analysis_and_keep_their_payload(conn):
    a, b = _analysis(conn), _analysis(conn)
    u1 = ledger.add_unit(conn, a, "read", {"ranges": [{"path": "x.py", "first": 1, "last": 9}]})
    u2 = ledger.add_unit(conn, a, "hunt", {})
    u3 = ledger.add_unit(conn, b, "triage", {"rows": ["f" * 64]})
    assert [u["seq"] for u in ledger.units_of(conn, a)] == [1, 2]
    assert ledger.get_unit(conn, u3)["seq"] == 1
    one = ledger.get_unit(conn, u1)
    assert one["payload"]["ranges"][0]["path"] == "x.py"
    assert (one["state"], one["attempt"], one["parent"], one["evidence"]) == ("pending", 1, None, {})
    assert ledger.get_unit(conn, u2)["kind"] == "hunt"


def test_a_kind_outside_the_vocabulary_is_refused(conn):
    with pytest.raises(ValueError):
        ledger.add_unit(conn, _analysis(conn), "explore", {})


def test_a_unit_starts_once(conn):
    uid = ledger.add_unit(conn, _analysis(conn), "hunt", {})
    assert ledger.start_unit(conn, uid, "security-web/123") is True
    assert ledger.start_unit(conn, uid, "security-web/456") is False
    unit = ledger.get_unit(conn, uid)
    assert (unit["state"], unit["run_key"]) == ("running", "security-web/123")
    assert unit["started"] is not None


def test_settling_records_the_outcome_and_accumulates_the_spend(conn):
    uid = ledger.add_unit(conn, _analysis(conn), "read", {"ranges": []})
    ledger.start_unit(conn, uid)
    assert ledger.reset_unit(conn, uid, spend_usd=0.25) is True
    ledger.start_unit(conn, uid)
    assert ledger.settle_unit(conn, uid, "incomplete", spend_usd=1.5,
                              evidence={"missing": [["x.py", 3, 9]]}, note="2 ranges unread")
    unit = ledger.get_unit(conn, uid)
    assert (unit["state"], unit["spend_usd"], unit["note"]) == ("incomplete", 1.75, "2 ranges unread")
    assert unit["evidence"] == {"missing": [["x.py", 3, 9]]}
    assert unit["ended"] is not None
    assert ledger.settle_unit(conn, uid, "done") is False, "a settled unit is never rewritten"


def test_settling_to_a_state_that_is_not_an_outcome_is_refused(conn):
    uid = ledger.add_unit(conn, _analysis(conn), "hunt", {})
    with pytest.raises(ValueError):
        ledger.settle_unit(conn, uid, "running")


def test_a_continuation_names_its_parent_and_its_attempt(conn):
    aid = _analysis(conn)
    first = ledger.add_unit(conn, aid, "read", {"ranges": []})
    second = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=2, parent=first)
    unit = ledger.get_unit(conn, second)
    assert (unit["attempt"], unit["parent"], unit["seq"]) == (2, first, 2)


def test_a_unit_whose_payload_or_evidence_does_not_decode_reads_empty(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {})
    conn.execute("UPDATE unit SET payload='{not json', evidence='[1,2]' WHERE id=?", (uid,))
    unit = ledger.get_unit(conn, uid)
    assert (unit["payload"], unit["evidence"]) == ({}, {})
    listed = ledger.units_of(conn, aid)[0]
    assert (listed["payload"], listed["evidence"]) == ({}, {})


def test_interrupting_and_resuming_move_only_between_running_and_interrupted(conn):
    aid = _analysis(conn)
    assert ledger.interrupt_analysis(conn, aid) is True
    assert _state(conn, aid) == ledger.INTERRUPTED
    assert ledger.interrupt_analysis(conn, aid) is False
    assert ledger.resume_analysis(conn, aid) is True
    assert _state(conn, aid) == "running"
    assert conn.execute("SELECT resumes FROM analysis WHERE id=?", (aid,)).fetchone()[0] == 0
    ledger.interrupt_analysis(conn, aid)
    ledger.resume_analysis(conn, aid, automatic=True)
    assert conn.execute("SELECT resumes FROM analysis WHERE id=?", (aid,)).fetchone()[0] == 1
    assert ledger.resume_analysis(conn, aid) is False, "only an interrupted analysis resumes"


def test_an_interrupted_analysis_is_never_a_baseline(conn):
    aid = _analysis(conn)
    ledger.interrupt_analysis(conn, aid)
    assert ledger.latest_analysis(conn, "web", "web", "main") is None


def test_closing_an_interrupted_analysis_fails_it_with_the_reason(conn):
    aid = _analysis(conn)
    ledger.interrupt_analysis(conn, aid)
    assert ledger.close_interrupted(conn, aid, "Superseded by analysis 9.") is True
    row = conn.execute("SELECT state, ended, coverage_note FROM analysis WHERE id=?", (aid,)).fetchone()
    assert (row["state"], row["coverage_note"]) == ("failed", "Superseded by analysis 9.")
    assert row["ended"] is not None
    assert ledger.close_interrupted(conn, aid, "again") is False


def test_the_inventory_round_trips_in_its_own_table_and_a_missing_or_broken_one_reads_empty(conn):
    aid = _analysis(conn)
    assert ledger.inventory_of(conn, aid) == {}
    ledger.set_inventory(conn, aid, {"totals": {"files": 2}, "files": []})
    assert ledger.inventory_of(conn, aid)["totals"] == {"files": 2}
    ledger.set_inventory(conn, aid, {"totals": {"files": 3}, "files": []})
    assert ledger.inventory_of(conn, aid)["totals"] == {"files": 3}
    assert conn.execute("SELECT COUNT(*) FROM analysis_inventory WHERE analysis_id=?",
                         (aid,)).fetchone()[0] == 1, "a second set_inventory upserts, not inserts"
    conn.execute("UPDATE analysis_inventory SET doc='{not json' WHERE analysis_id=?", (aid,))
    assert ledger.inventory_of(conn, aid) == {}
    conn.execute("UPDATE analysis_inventory SET doc='[1,2]' WHERE analysis_id=?", (aid,))
    assert ledger.inventory_of(conn, aid) == {}, "JSON that is not an object is not an inventory"
    row = conn.execute("SELECT * FROM analysis WHERE id=?", (aid,)).fetchone()
    assert "inventory" not in row.keys()


def test_a_read_only_connection_on_a_ledger_missing_the_inventory_table_reads_empty(tmp_path):
    path = tmp_path / "ro.db"
    conn = ledger.connect(path)
    aid = _analysis(conn)
    conn.close()
    raw = sqlite3.connect(path)
    raw.execute("DROP TABLE analysis_inventory")
    raw.commit()
    raw.close()
    ro = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    ro.row_factory = sqlite3.Row
    assert ledger.inventory_of(ro, aid) == {}
    ro.close()


def test_an_operational_error_that_is_not_a_missing_table_propagates():
    class _LockedConn:
        def execute(self, *args, **kwargs):
            raise sqlite3.OperationalError("database is locked")

    with pytest.raises(sqlite3.OperationalError):
        ledger.inventory_of(_LockedConn(), 1)


def test_the_reads_served_to_a_unit_are_kept_per_unit(conn):
    aid = _analysis(conn)
    u1 = ledger.add_unit(conn, aid, "read", {"ranges": []})
    u2 = ledger.add_unit(conn, aid, "read", {"ranges": []})
    ledger.record_unit_read(conn, u1, "src/a.py", 1, 200)
    ledger.record_unit_read(conn, u1, "src/a.py", 201, 260)
    ledger.record_unit_read(conn, u2, "src/b.py", 1, 9)
    assert ledger.unit_reads(conn, u1) == [("src/a.py", 1, 200), ("src/a.py", 201, 260)]
    assert ledger.unit_reads(conn, u2) == [("src/b.py", 1, 9)]


def test_a_carried_finding_reported_gone_is_known_to_its_analysis(conn):
    aid, other = _analysis(conn), _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": []})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    assert ledger.gone_in(conn, aid) == {"c" * 64}
    assert ledger.gone_in(conn, other) == set()


def _finding(fp, **extra):
    return {"fingerprint": fp, "category": "sast", "rule": "xss", "severity": "medium",
            "title": "t", "rationale": "r", "producer": "agent",
            "occurrences": [{"file": "a.py", "line": 1}], **extra}


def test_a_finding_remembers_the_unit_that_wrote_it(conn):
    aid = _analysis(conn)
    ledger.record_finding(conn, aid, _finding("a" * 64, unit=7))
    ledger.record_finding(conn, aid, _finding("b" * 64))
    units = dict(conn.execute("SELECT fingerprint, unit FROM finding WHERE analysis_id=?", (aid,)).fetchall())
    assert units == {"a" * 64: 7, "b" * 64: 0}
    ledger.record_finding(conn, aid, _finding("a" * 64, rationale="r2"))
    assert conn.execute("SELECT unit FROM finding WHERE fingerprint=?", ("a" * 64,)).fetchone()[0] == 7, \
        "a re-report from outside any unit keeps who wrote it"
    ledger.record_finding(conn, aid, _finding("a" * 64, rationale="r3", unit=9))
    assert conn.execute("SELECT unit FROM finding WHERE fingerprint=?", ("a" * 64,)).fetchone()[0] == 9
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_ledger_units.py -p no:cacheprovider -q`
Expected: FAIL — `no such table: unit` / `AttributeError: module 'security.ledger' has no attribute 'add_unit'`.

- [ ] **Passo 3: a tabela nova no `_SCHEMA`**

No fim da string `_SCHEMA` (depois do `CREATE TABLE IF NOT EXISTS history_sweep (...)`, antes do `"""` que a fecha):

```sql

-- THE WORK UNITS OF AN ANALYSIS (security/units.py). A NEW table, so IF NOT
-- EXISTS is enough -- the precedent `history_sweep` set above. One row per
-- session the engine runs for an analysis: `kind` is triage | hunt | read |
-- verify, `payload` the JSON its prompt is minted from (rows, line ranges, a
-- fingerprint), `evidence` the JSON `unit-close` wrote from the unit's own
-- stream and from the ledger. A unit that left work undone is never
-- rewritten: its continuation is a NEW row whose `parent` names it and whose
-- `attempt` is one higher, so the trail of what each session did survives
-- every retry.
CREATE TABLE IF NOT EXISTS unit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  analysis_id INTEGER NOT NULL REFERENCES analysis(id),
  seq INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  attempt INTEGER NOT NULL DEFAULT 1, parent INTEGER REFERENCES unit(id),
  run_key TEXT NOT NULL DEFAULT '',
  started INTEGER, ended INTEGER,
  spend_usd REAL NOT NULL DEFAULT 0,
  evidence TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
  UNIQUE(analysis_id, seq));
CREATE INDEX IF NOT EXISTS unit_by_analysis ON unit(analysis_id, state);

-- WHAT `security read` SERVED TO A UNIT, one row per chunk. The proof of
-- reading on a platform whose stream cannot carry it (Codex: every read is
-- a shell command whose output the stream caps at 8 KB, and sometimes
-- loses) -- and accepted on every platform beside the native Read tool.
-- Written by the CLI only after the lines were printed, never by the agent.
CREATE TABLE IF NOT EXISTS unit_read (
  unit_id INTEGER NOT NULL REFERENCES unit(id),
  path TEXT NOT NULL, first INTEGER NOT NULL, last INTEGER NOT NULL,
  at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS unit_read_by_unit ON unit_read(unit_id);

-- A CARRIED `sast` FINDING A TRIAGE UNIT READ AND FOUND GONE. Silence used
-- to be how such a finding became `fixed`, and silence cannot tell "read it,
-- it is gone" from "never opened it": the triage unit's proof needs the
-- first to be SAID. Written by `report-gone` only, with the reason.
CREATE TABLE IF NOT EXISTS unit_gone (
  unit_id INTEGER NOT NULL REFERENCES unit(id),
  fingerprint TEXT NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS unit_gone_by_unit ON unit_gone(unit_id);

-- THE DEEP SCOPE OF AN ANALYSIS (security/inventory.py): every file a
-- line-by-line read has to cover, and every file left out with the rule
-- that left it out. Kept OUT of `analysis` -- unlike `coverage` or `guides`
-- above -- because every reader of that table SELECTs * (queries
-- .recent_analyses, served by the dashboard's index poll; report.as_json;
-- cmd_analysis, read by the engine) and this document is hundreds of KB of
-- JSON on a large repository; no reader of `analysis` can carry it by
-- accident when it is not a column of `analysis` at all. One row per deep
-- analysis. A NEW table, so IF NOT EXISTS is enough -- the precedent
-- `history_sweep` and `unit` set above.
CREATE TABLE IF NOT EXISTS analysis_inventory (
  analysis_id INTEGER PRIMARY KEY REFERENCES analysis(id),
  doc TEXT NOT NULL);
```

- [ ] **Passo 4: as constantes**

Logo a seguir a `ANALYSIS_END_STATES` (~linha 190):

```python
UNIT_KINDS = ("triage", "hunt", "read", "verify")
UNIT_STATES = ("pending", "running", "done", "incomplete", "failed")
UNIT_SETTLED = ("done", "incomplete", "failed")
# NOT AN END STATE, and deliberately not in ANALYSIS_END_STATES: `finish`
# never writes it. An analysis the operator stopped, or whose orchestrator
# died, keeps its finished units and waits to be resumed; only
# `interrupt_analysis` puts it here and `resume_analysis` takes it back.
# Every baseline and posture query already reads `state IN ('done','capped')`,
# so an interrupted analysis is nobody's baseline without a line changing
# there.
INTERRUPTED = "interrupted"
```

- [ ] **Passo 5: as colunas aditivas**

No fim do tuplo `_ANALYSIS_COLUMNS` (só `resumes`: o inventário é a tabela do Passo 3, nunca uma coluna de `analysis`):

```python
    # How many times the tick resumed this analysis after its orchestrator
    # died, never an operator's Resume: the automatic ones are capped, so a
    # machine that keeps crashing stops spending.
    ("resumes", "INTEGER NOT NULL DEFAULT 0"),
```

No fim do tuplo `_FINDING_COLUMNS`:

```python
    # The unit whose session wrote this row -- stamped by the door from the
    # run's own AL_SECURITY_UNIT_ID, never read from a payload, on the rule
    # `producer` follows. 0 for a scanner's row and for every row written
    # before the pipeline existed.
    ("unit", "INTEGER NOT NULL DEFAULT 0"),
```

- [ ] **Passo 6: `record_finding` grava a unidade**

No `UPDATE` do ramo de linha existente (~linha 668), acrescentar a coluna `unit` sem nunca a apagar:

```python
            conn.execute(
                "UPDATE finding SET category=?, rule=?, severity=?, title=?,"
                " rationale=?, remediation=?, partial_note=?, cwe=?, owasp=?,"
                " candidate=?, triaged=MAX(triaged, ?),"
                " unit=CASE WHEN ? > 0 THEN ? ELSE unit END"
                " WHERE id=?",
                (finding["category"], finding["rule"], finding["severity"], finding["title"],
                 finding.get("rationale", ""), finding.get("remediation", ""),
                 finding.get("partial_note", ""), finding.get("cwe", ""),
                 finding.get("owasp", ""), finding.get("candidate", ""), triaged,
                 int(finding.get("unit") or 0), int(finding.get("unit") or 0), fid))
```

No `INSERT` do ramo de linha nova (~linha 679):

```python
            cur = conn.execute(
                "INSERT INTO finding (analysis_id, fingerprint, category, rule, severity,"
                " title, rationale, remediation, partial_note, cwe, owasp, producer,"
                " scope, candidate, unit)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (analysis_id, finding["fingerprint"], finding["category"], finding["rule"],
                 finding["severity"], finding["title"], finding.get("rationale", ""),
                 finding.get("remediation", ""), finding.get("partial_note", ""),
                 finding.get("cwe", ""), finding.get("owasp", ""),
                 finding.get("producer", ""), finding.get("scope", ""),
                 finding.get("candidate", ""), int(finding.get("unit") or 0)))
```

- [ ] **Passo 7: as funções novas, no fim de `ledger.py`**

```python
# ---- the pipeline's units (security/units.py decides; this only stores) ----

def _unit_row(row) -> dict:
    """A unit as every reader wants it: `payload` and `evidence` decoded to
    dicts. A cell that does not decode reads as `{}` -- never a traceback
    in the middle of an orchestration."""
    d = dict(row)
    for key in ("payload", "evidence"):
        try:
            value = json.loads(d.get(key) or "{}")
        except (ValueError, TypeError):
            value = {}
        d[key] = value if isinstance(value, dict) else {}
    return d


def add_unit(conn, analysis_id, kind, payload, attempt=1, parent=None) -> int:
    """A new `pending` unit, numbered after the analysis's last one.

    BEGIN IMMEDIATE, not the implicit deferred transaction: the orchestrator
    adds units while the closes of units running in parallel add their
    continuations, and two writers that both read MAX(seq) before either
    inserts would collide on UNIQUE(analysis_id, seq)."""
    if kind not in UNIT_KINDS:
        raise ValueError(f"bad unit kind: {kind}")
    conn.execute("BEGIN IMMEDIATE")
    try:
        seq = conn.execute("SELECT COALESCE(MAX(seq), 0) + 1 FROM unit WHERE analysis_id=?",
                           (analysis_id,)).fetchone()[0]
        cur = conn.execute(
            "INSERT INTO unit (analysis_id, seq, kind, payload, attempt, parent)"
            " VALUES (?,?,?,?,?,?)",
            (analysis_id, seq, kind, json.dumps(payload, sort_keys=True), attempt, parent))
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return cur.lastrowid


def get_unit(conn, unit_id):
    row = conn.execute("SELECT * FROM unit WHERE id=?", (unit_id,)).fetchone()
    return _unit_row(row) if row else None


def units_of(conn, analysis_id) -> list:
    return [_unit_row(r) for r in conn.execute(
        "SELECT * FROM unit WHERE analysis_id=? ORDER BY seq", (analysis_id,))]


def start_unit(conn, unit_id, run_key="") -> bool:
    """pending -> running. False when somebody else already started it: the
    WHERE is the lock, so two launches of one unit cannot both proceed."""
    with conn:
        cur = conn.execute(
            "UPDATE unit SET state='running', run_key=?, started=?, ended=NULL"
            " WHERE id=? AND state='pending'", (run_key, int(time.time()), unit_id))
    return cur.rowcount > 0


def settle_unit(conn, unit_id, state, spend_usd=0.0, evidence=None, note="") -> bool:
    """pending/running -> done | incomplete | failed, once. The spend is ADDED:
    a unit reset after a stop and run again paid for both runs."""
    if state not in UNIT_SETTLED:
        raise ValueError(f"bad unit state: {state}")
    with conn:
        cur = conn.execute(
            "UPDATE unit SET state=?, ended=?, spend_usd=spend_usd+?, evidence=?, note=?"
            " WHERE id=? AND state IN ('pending','running')",
            (state, int(time.time()), float(spend_usd or 0),
             json.dumps(evidence or {}, sort_keys=True), note or "", unit_id))
    return cur.rowcount > 0


def reset_unit(conn, unit_id, spend_usd=0.0) -> bool:
    """running -> pending in the SAME attempt: the run behind it ended with
    no verdict of its own to judge (the operator stopped the analysis, the
    orchestrator died), which is not the unit's failure."""
    with conn:
        cur = conn.execute(
            "UPDATE unit SET state='pending', run_key='', spend_usd=spend_usd+?"
            " WHERE id=? AND state='running'", (float(spend_usd or 0), unit_id))
    return cur.rowcount > 0


def interrupt_analysis(conn, analysis_id) -> bool:
    with conn:
        cur = conn.execute("UPDATE analysis SET state=? WHERE id=? AND state='running'",
                           (INTERRUPTED, analysis_id))
    return cur.rowcount > 0


def resume_analysis(conn, analysis_id, automatic=False) -> bool:
    with conn:
        cur = conn.execute(
            "UPDATE analysis SET state='running', resumes=resumes+? WHERE id=? AND state=?",
            (1 if automatic else 0, analysis_id, INTERRUPTED))
    return cur.rowcount > 0


def close_interrupted(conn, analysis_id, note) -> bool:
    """interrupted -> failed: superseded by a newer analysis of the same scope,
    or out of automatic resumes. The units it finished stay in the ledger."""
    with conn:
        cur = conn.execute(
            "UPDATE analysis SET state='failed', ended=?,"
            " coverage_note=TRIM(coverage_note || ' ' || ?) WHERE id=? AND state=?",
            (int(time.time()), note, analysis_id, INTERRUPTED))
    return cur.rowcount > 0


def set_inventory(conn, analysis_id, inventory) -> None:
    with conn:
        conn.execute(
            "INSERT INTO analysis_inventory (analysis_id, doc) VALUES (?, ?)"
            " ON CONFLICT(analysis_id) DO UPDATE SET doc=excluded.doc",
            (analysis_id, json.dumps(inventory, sort_keys=True, separators=(",", ":"))))


def inventory_of(conn, analysis_id) -> dict:
    """The stored deep inventory for this analysis. Returns {} for an
    analysis with no row, a doc that does not decode or is not an object,
    and a ledger whose `analysis_inventory` table does not exist on THIS
    connection (a read-only connection opened on a ledger `connect()`
    never migrated raises `sqlite3.OperationalError: no such table`,
    caught here and only here). Any other database error -- a lock, a
    disk I/O failure, ... -- propagates instead of reading as no
    inventory."""
    try:
        row = conn.execute("SELECT doc FROM analysis_inventory WHERE analysis_id=?",
                            (analysis_id,)).fetchone()
    except sqlite3.OperationalError as exc:
        if "no such table" not in str(exc):
            raise
        return {}
    if row is None:
        return {}
    try:
        doc = json.loads(row["doc"]) if row["doc"] else {}
    except (ValueError, TypeError):
        return {}
    return doc if isinstance(doc, dict) else {}


def record_unit_read(conn, unit_id, path, first, last) -> None:
    with conn:
        conn.execute("INSERT INTO unit_read (unit_id, path, first, last, at) VALUES (?,?,?,?,?)",
                     (unit_id, path, int(first), int(last), int(time.time())))


def unit_reads(conn, unit_id) -> list:
    return [(r["path"], r["first"], r["last"]) for r in conn.execute(
        "SELECT path, first, last FROM unit_read WHERE unit_id=? ORDER BY rowid", (unit_id,))]


def record_gone(conn, unit_id, fingerprint, reason) -> None:
    with conn:
        conn.execute("INSERT INTO unit_gone (unit_id, fingerprint, reason, at) VALUES (?,?,?,?)",
                     (unit_id, fingerprint, reason, int(time.time())))


def gone_in(conn, analysis_id) -> set:
    return {r[0] for r in conn.execute(
        "SELECT g.fingerprint FROM unit_gone g JOIN unit u ON u.id = g.unit_id"
        " WHERE u.analysis_id=?", (analysis_id,))}
```

Confirmar que `json`, `sqlite3` e `time` já estão importados no topo de `ledger.py` (estão).

- [ ] **Passo 8: correr e ver passar, mais a suite do ledger**

Run: `python3.13 -m pytest tests/security/test_ledger_units.py tests/security/test_ledger.py tests/security/test_queries.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Passo 9: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **The security ledger records an analysis's work units.** A new `unit`
  table holds every session the engine runs for an analysis — its kind
  (triage, hunt, read, verify), what it was given, what it proved, what it
  cost, and the attempt it was — with a retry recorded as a new row that
  names its parent, never as an overwrite. The deep scope an analysis has to
  cover is kept in a table of its own, so no reader of the analysis table
  ever carries it — a ledger an older version never migrated reads as
  having no inventory, while any other database error is reported rather
  than hidden; an analysis gains a count of automatic resumes and a
  resumable `interrupted` state that no baseline or posture ever reads; a
  finding records which unit wrote it, and every chunk `security read`
  serves a unit is kept as proof of what it read.
```

```bash
/usr/bin/git add bin/security/ledger.py tests/security/test_ledger_units.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): the ledger stores an analysis's work units and its interrupted state"
```

---

### Task 2: O inventário do âmbito `deep`

**Ficheiros:**
- Criar: `bin/security/inventory.py`
- Modificar: `bin/security/deps.py` (expor `LOCKFILE_NAMES` a seguir a `_READERS`, ~linha 278)
- Testes: `tests/security/test_inventory.py`

**Interfaces:**
- Consome: `ignores.ignored(rel, patterns) -> bool`, `ignores.defaults_apply(patterns) -> bool`, `deps.LOCKFILE_NAMES` (novo).
- Produz:
  - `inventory.RANGE_BYTES = 300_000`
  - `inventory.count_lines(data: bytes) -> int`
  - `inventory.line_ranges(data: bytes, budget: int) -> list[[first, last, bytes]]`
  - `inventory.build(root, patterns=()) -> dict` com a forma `{"files": [{"path", "lines", "bytes", "ranges"}], "excluded": {reason: {"count", "examples"}}, "totals": {"files", "lines", "bytes"}, "git": bool}`
  - `inventory.summary(scope: dict) -> str` (a frase da linha `scope` da tabela de cobertura)
  - `inventory.REASONS` (a ordem das regras)

- [ ] **Passo 1: expor os nomes dos lockfiles em `deps.py`**

Logo a seguir ao dicionário `_READERS` (~linha 278):

```python
# The file names the dependency phase reads, public so the deep scope
# (security/inventory.py) can leave the same files out: a lockfile's content
# is that phase's input, and reading it line by line is not a code review.
LOCKFILE_NAMES = frozenset(_READERS)
```

- [ ] **Passo 2: escrever os testes que falham**

`tests/security/test_inventory.py`:

```python
# tests/security/test_inventory.py
"""The deep scope: what a line-by-line read must cover, and what it leaves out by rule."""
import os
import subprocess

import pytest

from security import inventory

GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def _repo(tmp_path, files, links=()):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=GIT_ENV)
    for rel, data in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
    for rel, target in links:
        (root / rel).symlink_to(target)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    return root


def _paths(scope):
    return [f["path"] for f in scope["files"]]


def test_source_is_in_scope_with_its_lines_bytes_and_one_range(tmp_path):
    root = _repo(tmp_path, {"src/app.py": "a\nb\nc\n", "src/tail.py": "x\ny"})
    scope = inventory.build(root)
    assert _paths(scope) == ["src/app.py", "src/tail.py"]
    app, tail = scope["files"]
    assert (app["lines"], app["bytes"], app["ranges"]) == (3, 6, [[1, 3, 6]])
    assert tail["lines"] == 2, "a last line without a newline is still a line"
    assert scope["totals"] == {"files": 2, "lines": 5, "bytes": 9}
    assert scope["git"] is True


@pytest.mark.parametrize("rel, data, reason", [
    ("node_modules/lib/index.js", "x\n", "dependency-tree"),
    ("app/vendor/lib.php", "x\n", "dependency-tree"),
    ("package-lock.json", "{}\n", "lockfile"),
    ("yarn.lock", "x\n", "lockfile"),
    ("logo.png", b"\x89PNG\x00\x01", "binary"),
    ("legacy.c", b"caf\xe9\n", "binary"),
    ("public/app.min.js", "x\n", "generated"),
    ("dist/bundle.js", "x" * 5001 + "\n", "generated"),
    ("dist/wide.js", ("y" * 301 + "\n") * 10, "generated"),
    ("docs/guide.md", "# t\n", "prose"),
    ("tests/fixtures/key.pem", "k\n", "ignored"),
])
def test_each_rule_leaves_its_file_out_under_its_own_name(tmp_path, rel, data, reason):
    root = _repo(tmp_path, {rel: data, "src/keep.py": "k\n"})
    scope = inventory.build(root)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"][reason] == {"count": 1, "examples": [rel]}


def test_ignore_paths_leave_a_file_out_as_ignored(tmp_path):
    root = _repo(tmp_path, {"legacy/old.py": "x\n", "src/keep.py": "k\n"})
    scope = inventory.build(root, ["legacy/**"])
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["ignored"]["count"] == 1


def test_a_tracked_symlink_is_never_followed(tmp_path):
    root = _repo(tmp_path, {"src/keep.py": "k\n"}, links=[("escape", "/etc/hosts")])
    scope = inventory.build(root)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["symlink"] == {"count": 1, "examples": ["escape"]}


def test_defaults_off_reads_generated_files_and_prose_but_never_dependency_trees(tmp_path):
    root = _repo(tmp_path, {"public/app.min.js": "x\n", "docs/guide.md": "# t\n",
                            "vendor/lib.php": "x\n", "src/keep.py": "k\n"})
    scope = inventory.build(root, ["!defaults"])
    assert _paths(scope) == ["docs/guide.md", "public/app.min.js", "src/keep.py"]
    assert scope["excluded"]["dependency-tree"]["count"] == 1


def test_line_ranges_cut_on_line_boundaries_within_the_budget():
    four = b"aaaa\nbbbb\ncccc\ndddd\n"          # four lines of five bytes
    assert inventory.line_ranges(four, 10) == [[1, 2, 10], [3, 4, 10]]
    long_first = b"x" * 25 + b"\ny\n"          # a line is never split
    assert inventory.line_ranges(long_first, 10) == [[1, 1, 26], [2, 2, 2]]
    assert inventory.line_ranges(b"", 10) == []


def test_a_file_larger_than_one_reading_is_listed_as_several_ranges(tmp_path, monkeypatch):
    monkeypatch.setattr(inventory, "RANGE_BYTES", 10)
    root = _repo(tmp_path, {"src/big.py": "aaaa\nbbbb\ncccc\ndddd\n"})
    (big,) = inventory.build(root)["files"]
    assert big["ranges"] == [[1, 2, 10], [3, 4, 10]]


def test_only_newlines_split_lines_the_way_read_and_sed_number_them():
    assert inventory.count_lines(b"a\rb\x0cc\n") == 1
    assert inventory.count_lines(b"a\r\nb\r\n") == 2
    assert inventory.count_lines(b"") == 0


def test_an_empty_file_is_in_scope_with_nothing_to_read(tmp_path):
    root = _repo(tmp_path, {"src/__init__.py": "", "src/keep.py": "k\n"})
    empty = inventory.build(root)["files"][0]
    assert (empty["path"], empty["lines"], empty["ranges"]) == ("src/__init__.py", 0, [])


def test_the_first_three_examples_travel_with_the_count(tmp_path):
    files = {f"docs/{n}.md": "t\n" for n in "abcde"}
    files["src/keep.py"] = "k\n"
    slot = inventory.build(_repo(tmp_path, files))["excluded"]["prose"]
    assert slot == {"count": 5, "examples": ["docs/a.md", "docs/b.md", "docs/c.md"]}


def test_a_root_that_is_not_a_git_checkout_lists_every_file_and_says_so(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "a.py").write_text("x\n")
    scope = inventory.build(tmp_path)
    assert _paths(scope) == ["src/a.py"] and scope["git"] is False
    assert "not a git checkout" in inventory.summary(scope)


def test_the_summary_states_the_scope_and_names_each_rule_with_examples(tmp_path):
    root = _repo(tmp_path, {"src/a.py": "x\n", "public/app.min.js": "x\n"})
    text = inventory.summary(inventory.build(root))
    assert "The deep scope is 1 file (1 line, 2 bytes), each to be read in full." in text
    assert "generated or minified files: 1 (e.g. public/app.min.js)" in text
    assert '"!defaults"' in text
```

- [ ] **Passo 3: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_inventory.py -p no:cacheprovider -q`
Expected: FAIL — `ImportError: cannot import name 'inventory'`.

- [ ] **Passo 4: implementar `bin/security/inventory.py`**

```python
# bin/security/inventory.py
"""The deep profile's scope, listed before anyone reads a line of it.

WHY A LIST. `deep` promises "all versioned code". Until this module that
promise lived only in the skill's prose, and the agent that had to keep it
was the same agent that decided when it had: two analyses of a
~300,000-line repository closed `capped` because the agent chose to stop,
and below the size where a model gives up, `done` was only its word. The
inventory turns the promise into something the engine can check: the exact
files -- and, for a file too large for one reading, the exact line ranges --
a deep analysis has to read in full.

EVERY FILE LEFT OUT IS COUNTED UNDER THE RULE THAT LEFT IT OUT. The rules
run in a fixed order and the first that matches names the reason, so no file
is counted twice, and the first three paths under each reason travel with
the count into the coverage note:

  ignored          `ignore_paths` and the default noise filter (ignores.ignored)
  symlink          a tracked symlink: reading it reads wherever it points
  submodule        a gitlink: another repository's code
  dependency-tree  node_modules/, vendor/, .venv/, bower_components/
  lockfile         the dependency phase's own input
  unreadable       tracked, but the checkout cannot read it
  binary           a NUL byte, or not UTF-8
  generated        *.min.js/.min.mjs/.min.css/.map, a line over 5,000 bytes,
                   or more than 300 bytes per line on average
  prose            .md, .markdown, .rst, .adoc, .txt

`!defaults` (ignores.DEFAULTS_OFF) switches `generated` and `prose` off, on
top of the noise filter it already switched off. The others always apply: a
dependency tree is code nobody here wrote, a lockfile has its own phase, and
a binary has no lines to read.

LINES ARE COUNTED THE WAY A READER COUNTS THEM: the number of `\\n`, plus one
when the last byte is not one. Only `\\n` splits a line -- not `\\r`, form
feeds or the other separators `bytes.splitlines` honours -- because the Read
tool and `sed -n` both number lines that way, and the proof of reading
(security/evidence.py) compares these numbers with theirs.
"""

import subprocess
from pathlib import Path

from . import deps, ignores

# The size of one reading. A file up to this many bytes is one range; a
# larger one is cut into consecutive line ranges of at most this many bytes,
# and security/slices.py packs ranges into units of the same size: ~85k
# tokens of source, which keeps every unit's session far below any context
# window however large the repository is.
RANGE_BYTES = 300_000

DEPENDENCY_DIRS = frozenset({"node_modules", "vendor", ".venv", "bower_components"})
# What the dependency phase reads, plus the lockfiles of the ecosystems
# Trivy reads and security/deps.py does not.
LOCKFILES = deps.LOCKFILE_NAMES | frozenset({
    "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "Gemfile.lock",
    "Cargo.lock", "Pipfile.lock", "packages.lock.json", "mix.lock",
    "pubspec.lock", "gradle.lockfile", "bun.lockb"})
GENERATED_SUFFIXES = (".min.js", ".min.mjs", ".min.css", ".map")
LONGEST_LINE = 5_000
AVERAGE_LINE = 300
PROSE_SUFFIXES = (".md", ".markdown", ".rst", ".adoc", ".txt")
REASONS = ("ignored", "symlink", "submodule", "dependency-tree", "lockfile",
           "unreadable", "binary", "generated", "prose")
EXAMPLES = 3

_LABELS = {
    "ignored": "ignored by ignore_paths or the default filter",
    "symlink": "symlinks, never followed",
    "submodule": "submodules",
    "dependency-tree": "files in dependency trees",
    "lockfile": "lockfiles (read by the dependency phase)",
    "unreadable": "unreadable files",
    "binary": "binary or non-UTF-8 files",
    "generated": "generated or minified files",
    "prose": "prose documents",
}
_MODE_SYMLINK = "120000"
_MODE_GITLINK = "160000"


def count_lines(data: bytes) -> int:
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def _lines(data: bytes):
    """Each line WITH its terminating `\\n`, split on `\\n` only."""
    start, end_of_data = 0, len(data)
    while start < end_of_data:
        end = data.find(b"\n", start)
        if end == -1:
            yield data[start:]
            return
        yield data[start:end + 1]
        start = end + 1


def line_ranges(data: bytes, budget: int) -> list:
    """[first, last, bytes] ranges covering every line, each at most `budget`
    bytes -- except a single line longer than the budget, which is a range
    of its own: a line is never split, because nothing reads half of one."""
    ranges, first, size, number = [], 1, 0, 0
    for chunk in _lines(data):
        number += 1
        if size and size + len(chunk) > budget:
            ranges.append([first, number - 1, size])
            first, size = number, 0
        size += len(chunk)
    if number:
        ranges.append([first, number, size])
    return ranges


def _generated(name: str, data: bytes, lines: int) -> bool:
    if name.endswith(GENERATED_SUFFIXES):
        return True
    if not lines:
        return False
    longest = max(len(chunk.rstrip(b"\r\n")) for chunk in _lines(data))
    return longest > LONGEST_LINE or len(data) / lines > AVERAGE_LINE


def _tracked(root: Path):
    """(mode, path) for every entry the checkout's index tracks, or None
    when `root` is not a git checkout."""
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-s", "-z"],
                             capture_output=True, check=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    entries = []
    for record in out.split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        entries.append((meta.split(b" ", 1)[0].decode(),
                        path.decode("utf-8", "surrogateescape")))
    return entries


def _walked(root: Path) -> list:
    """The fallback for a root that is not a git checkout (a test's empty
    directory, a hand run): every regular file outside `.git`. Never what an
    engine run meets -- the orchestrator prepares a worktree."""
    out = []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if ".git" in rel.parts:
            continue
        if path.is_symlink():
            out.append((_MODE_SYMLINK, rel.as_posix()))
        elif path.is_file():
            out.append(("100644", rel.as_posix()))
    return out


def _classify(root: Path, mode: str, rel: str, patterns, defaults: bool):
    """(reason, None) for a file left out, (None, bytes) for one in scope."""
    if ignores.ignored(rel, patterns):
        return "ignored", None
    if mode == _MODE_SYMLINK:
        return "symlink", None
    if mode == _MODE_GITLINK:
        return "submodule", None
    parts = rel.split("/")
    if any(part in DEPENDENCY_DIRS for part in parts[:-1]):
        return "dependency-tree", None
    name = parts[-1]
    if name in LOCKFILES:
        return "lockfile", None
    try:
        data = (root / rel).read_bytes()
    except OSError:
        return "unreadable", None
    if b"\0" in data:
        return "binary", None
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return "binary", None
    if defaults and _generated(name, data, count_lines(data)):
        return "generated", None
    if defaults and name.lower().endswith(PROSE_SUFFIXES):
        return "prose", None
    return None, data


def build(root, patterns=()) -> dict:
    """The deep scope of the checkout at `root`, as the ledger's
    `analysis_inventory` table stores it. `files` is sorted by path; a
    file with no lines is listed with no ranges, because there is
    nothing in it to read."""
    root = Path(root)
    patterns = tuple(p for p in (patterns or ()) if p)
    defaults = ignores.defaults_apply(patterns)
    entries = _tracked(root)
    in_git = entries is not None
    if not in_git:
        entries = _walked(root)
    files = []
    excluded = {reason: {"count": 0, "examples": []} for reason in REASONS}
    for mode, rel in sorted(entries, key=lambda entry: entry[1]):
        reason, data = _classify(root, mode, rel, patterns, defaults)
        if reason:
            slot = excluded[reason]
            slot["count"] += 1
            if len(slot["examples"]) < EXAMPLES:
                slot["examples"].append(rel)
            continue
        lines = count_lines(data)
        files.append({"path": rel, "lines": lines, "bytes": len(data),
                      "ranges": line_ranges(data, RANGE_BYTES) if lines else []})
    return {"files": files, "excluded": excluded, "git": in_git,
            "totals": {"files": len(files),
                       "lines": sum(f["lines"] for f in files),
                       "bytes": sum(f["bytes"] for f in files)}}


def _plural(n: int, word: str) -> str:
    return f"{n:,} {word}{'' if n == 1 else 's'}"


def summary(scope: dict) -> str:
    """The `scope` coverage row's sentence: what the deep read covers, and
    what it leaves out, rule by rule, with examples."""
    totals = scope.get("totals") or {"files": 0, "lines": 0, "bytes": 0}
    text = (f"The deep scope is {_plural(totals['files'], 'file')} "
            f"({_plural(totals['lines'], 'line')}, {_plural(totals['bytes'], 'byte')}), "
            "each to be read in full.")
    if scope.get("git") is False:
        text += (" This root is not a git checkout, so every file under it was "
                 "listed, not only the versioned ones.")
    left = [(reason, slot) for reason, slot in (scope.get("excluded") or {}).items()
            if slot.get("count")]
    if left:
        text += " Left out by rule: " + "; ".join(
            f"{_LABELS.get(reason, reason)}: {slot['count']:,} "
            f"(e.g. {', '.join(slot['examples'])})" for reason, slot in left) + "."
    if any(reason in ("generated", "prose") for reason, _ in left):
        text += (' Add "!defaults" to the project\'s ignore_paths to read '
                 "generated files and prose as well.")
    return text
```

- [ ] **Passo 5: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_inventory.py -p no:cacheprovider -q`
Expected: PASS (todos).

- [ ] **Passo 6: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **A deep analysis lists its scope before it reads anything.** `prepare`
  now records every versioned file a line-by-line read has to cover, with
  its lines and bytes — a file over 300 KB as consecutive line ranges — and
  counts every file it leaves out under the rule that left it out
  (ignored, symlink, submodule, dependency tree, lockfile, unreadable,
  binary, generated, prose), with examples. `deep` promised "all versioned
  code" in prose only, and the agent that had to keep the promise was the
  one deciding when it had.
```

```bash
/usr/bin/git add bin/security/inventory.py bin/security/deps.py tests/security/test_inventory.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): the deep scope is an inventory, not a promise"
```

---

### Task 3: As fatias

**Ficheiros:**
- Criar: `bin/security/slices.py`
- Testes: `tests/security/test_slices.py`

**Interfaces:**
- Consome: `inventory.RANGE_BYTES`; a lista `files` de `inventory.build` (cada ficheiro com `ranges: [[first, last, bytes], ...]`).
- Produz: `slices.SLICE_BYTES` (= `inventory.RANGE_BYTES`) e `slices.pack(files, budget=SLICE_BYTES) -> list[list[{"path", "first", "last", "bytes"}]]`.

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_slices.py`:

```python
# tests/security/test_slices.py
"""Packing the deep inventory into units: bounded, in path order, never splitting a range."""
from security import slices


def _file(path, *ranges):
    return {"path": path, "lines": ranges[-1][1] if ranges else 0,
            "bytes": sum(r[2] for r in ranges), "ranges": [list(r) for r in ranges]}


def _shape(out):
    return [[(e["path"], e["first"], e["last"]) for e in s] for s in out]


def test_ranges_are_packed_in_path_order_up_to_the_budget():
    files = [_file("b/two.py", (1, 5, 40)), _file("a/one.py", (1, 3, 70)),
             _file("c/three.py", (1, 2, 50))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("a/one.py", 1, 3)], [("b/two.py", 1, 5), ("c/three.py", 1, 2)]]


def test_a_range_larger_than_the_budget_is_a_slice_of_its_own():
    files = [_file("big.py", (1, 1, 500)), _file("small.py", (1, 1, 10))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("big.py", 1, 1)], [("small.py", 1, 1)]]


def test_each_range_of_a_cut_file_is_its_own_entry():
    files = [_file("huge.py", (1, 100, 90), (101, 180, 90))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("huge.py", 1, 100)], [("huge.py", 101, 180)]]


def test_a_file_with_nothing_to_read_contributes_nothing():
    assert slices.pack([_file("empty.py")], budget=100) == []


def test_every_entry_carries_its_bytes_and_no_slice_exceeds_the_budget():
    files = [_file(f"d/{n:02}.py", (1, 10, 30)) for n in range(10)]
    out = slices.pack(files, budget=100)
    assert all(sum(e["bytes"] for e in s) <= 100 for s in out)
    assert sum(len(s) for s in out) == 10


def test_the_default_budget_is_one_reading():
    assert slices.SLICE_BYTES == 300_000
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_slices.py -p no:cacheprovider -q`
Expected: FAIL — `ImportError: cannot import name 'slices'`.

- [ ] **Passo 3: implementar `bin/security/slices.py`**

```python
# bin/security/slices.py
"""The deep inventory, packed into the units a single session reads in full.

WHY PACK AT ALL. A unit per file would pay a session's fixed cost -- the
skill, the guides, the prompt -- once per file: thousands of sessions on a
large repository. One unit for everything is the context window this whole
design exists to escape. A unit of about one reading (inventory.RANGE_BYTES)
of source is neither: ~85k tokens to read, a few dozen sessions for a very
large repository.

IN PATH ORDER, so the files of one directory travel together: a session that
reads a controller reads its neighbours, which is where a trace goes first.
A range larger than the budget -- one enormous line -- is a unit of its own;
it is never split, because nothing reads half a line.
"""

from .inventory import RANGE_BYTES

SLICE_BYTES = RANGE_BYTES


def pack(files, budget: int = SLICE_BYTES) -> list:
    """`files` as security/inventory.build lists them. A list of slices, each
    a list of {"path", "first", "last", "bytes"} in path order, none larger
    than `budget` unless it is a single range that is."""
    out, current, size = [], [], 0
    for f in sorted(files, key=lambda f: f["path"]):
        for first, last, nbytes in f["ranges"]:
            if current and size + nbytes > budget:
                out.append(current)
                current, size = [], 0
            current.append({"path": f["path"], "first": first, "last": last,
                            "bytes": nbytes})
            size += nbytes
    if current:
        out.append(current)
    return out
```

- [ ] **Passo 4: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_slices.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Passo 5: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo (acima da da Task 2):

```markdown
- **The deep scope is cut into readings a single session can hold.** The
  inventory is packed, in path order, into slices of at most 300 KB of
  source (~85k tokens); a range bigger than that is a slice of its own.
  However large the repository, no session is asked to hold more than one
  slice — the single agent before this read until its context was full and
  then stopped.
```

```bash
/usr/bin/git add bin/security/slices.py tests/security/test_slices.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): pack the deep scope into slices one session can read"
```

---

### Task 4: A prova de leitura

**Ficheiros:**
- Criar: `bin/security/evidence.py`
- Criar: `tests/security/fixtures/streams/claude-reads.ndjson`, `tests/security/fixtures/streams/opencode-reads.ndjson`
- Modificar: `bin/platforms/opencode_stream.py` (`Normalizer._tool`, ~linhas 192-207)
- Testes: `tests/security/test_evidence.py` (novo), `tests/test_opencode_stream.py` (um teste novo)

**Porque é que a prova sai do resultado e não do pedido (medido a 2026-09-24 sobre 1 620 `Read` reais):** um `Read` sem `limit` pode ser cortado por um tecto de tokens (linhas 1–1096 de 1 724, com `truncatedByTokenCap: true`). Um resultado que não é erro pode não ter lido nada («shorter than the provided offset», «contents are empty»). O que o modelo recebeu vem em `tool_use_result.file.{startLine, numLines}` no evento `user` do agente principal, e as linhas do conteúdo vêm numeradas (`N\t` no Claude, `N: ` no OpenCode). A prova conta só isso. O normalizador do OpenCode deitava fora o intervalo (`state.metadata.display`) e corta o resultado em 8 KB; passa a copiá-lo para `tool_use_result.file`, na forma do Claude. O Codex não tem ferramenta de leitura, e as leituras por shell não são prováveis a partir do stream (vêm embrulhadas em `/bin/zsh -lc`, encadeadas, cortadas em 8 KB e às vezes perdidas): lá a leitura faz-se com `agentloop security read` (Task 7), cujo registo no ledger é a prova, juntada aqui com `with_served`.

**Interfaces:**
- Consome: nada de tarefas anteriores (o formato vem dos streams normalizados).
- Produz:
  - `evidence.Session` (dataclass): `reads: dict[str, list[tuple[int, int]]]` (caminho relativo → intervalos lidos, fechados), `tasks: int`, `guides: set[str]`
  - `evidence.EMPTY` (uma `Session` vazia)
  - `evidence.parse(lines, root) -> Session`
  - `evidence.read_session(stream_path, root) -> Session` (ficheiro em falta ou ilegível → `EMPTY`)
  - `evidence.with_served(session, served) -> Session` (junta os `(path, first, last)` de `ledger.unit_reads`)
  - `evidence.missing(ranges, reads) -> list[{"path", "first", "last", "bytes"}]` (o que falta de cada intervalo pedido; `bytes` 0 num pedaço parcial)

- [ ] **Passo 1: os fixtures, derivados das amostras reais e neutralizados**

Cada linha tem a forma exacta de um evento real (as mesmas chaves, a mesma aninhagem), com caminhos e conteúdo neutros. `/Users/me/run` faz de raiz do run.

`tests/security/fixtures/streams/claude-reads.ndjson`:

```
{"type":"system","subtype":"init","cwd":"/Users/me/run","session_id":"s1","tools":["Read","Bash","Agent"]}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"Read","input":{"file_path":"/Users/me/run/src/app.py"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"1\talpha\n2\tbeta\n3\tgamma\n"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/run/src/app.py","content":"alpha\nbeta\ngamma\n","numLines":3,"startLine":1,"totalLines":3}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_b","name":"Read","input":{"file_path":"/Users/me/run/src/big.py"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_b","type":"tool_result","content":"<system-reminder>PARTIAL view — showing lines 1-1096 of 1724 total</system-reminder>\n1\tone\n2\ttwo\n"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/run/src/big.py","content":"one\ntwo\n","numLines":1096,"startLine":1,"totalLines":1724,"truncatedByTokenCap":true}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_c","name":"Read","input":{"file_path":"/Users/me/run/src/big.py","offset":1097,"limit":700}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_c","type":"tool_result","content":"1097\tthree\n"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/run/src/big.py","content":"three\n","numLines":628,"startLine":1097,"totalLines":1724}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_d","name":"Read","input":{"file_path":"/Users/me/run/src/short.py","offset":50,"limit":12}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_d","type":"tool_result","content":"<system-reminder>Warning: the file exists but is shorter than the provided offset (50). The file has 12 lines.</system-reminder>"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/run/src/short.py","content":"","numLines":0,"startLine":50,"totalLines":12}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_e","name":"Read","input":{"file_path":"/Users/me/run/src/gone.py"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"File does not exist. Note: your current working directory is /Users/me/run.","is_error":true,"tool_use_id":"toolu_e"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":"Error: File does not exist. Note: your current working directory is /Users/me/run."}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_f","name":"Read","input":{"file_path":"/Users/me/elsewhere/secret.py"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_f","type":"tool_result","content":"1\tx\n"}]},"parent_tool_use_id":null,"session_id":"s1","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/elsewhere/secret.py","content":"x\n","numLines":1,"startLine":1,"totalLines":1}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_g","name":"Read","input":{"file_path":"/Users/me/run/.claude/skills/security-analysis/references/ATTACK-CLASSES.md"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_h","name":"Agent","input":{"description":"split","prompt":"read the rest","subagent_type":"general-purpose"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_i","name":"Read","input":{"file_path":"/Users/me/run/src/sub.py","offset":1,"limit":20}}]},"parent_tool_use_id":"toolu_h","session_id":"s1","subagent_type":"general-purpose"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_i","type":"tool_result","content":"1\tsub\n"}]},"parent_tool_use_id":"toolu_h","session_id":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_j","name":"Read","input":{"file_path":"/Users/me/run/src/noresult.py"}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_k","type":"tool_result","content":"7\tseven\n8\teight\n"}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_k","name":"Read","input":{"file_path":"/Users/me/run/src/prefix.py","offset":7,"limit":2}}]},"parent_tool_use_id":null,"session_id":"s1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_k","type":"tool_result","content":"7\tseven\n8\teight\n"}]},"parent_tool_use_id":null,"session_id":"s1"}
not json at all
{"type":"result","subtype":"success","is_error":false,"session_id":"s1","total_cost_usd":0.1}
```

(Linha 19: um `tool_result` cujo `tool_use_id` ainda não foi pedido — é ignorado. `toolu_j` nunca recebe resultado. `toolu_k` não traz `tool_use_result` e cai no recurso aos prefixos numerados.)

`tests/security/fixtures/streams/opencode-reads.ndjson` — a saída do normalizador depois do Passo 5, sobre um `read` com o intervalo em `metadata.display`:

```
{"type":"system","subtype":"init","session_id":"ses_x","model":"m","platform":"opencode","permissionMode":"auto","cwd":"/Users/me/run","tools":[]}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"Read","input":{"filePath":"/Users/me/run/src/a.txt"}}]},"session_id":"ses_x"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"<path>/Users/me/run/src/a.txt</path>\n<type>file</type>\n<content>\n1: alpha\n2: beta\n\n(End of file - total 2 lines)\n</content>","is_error":false}]},"session_id":"ses_x","tool_use_result":{"type":"text","file":{"filePath":"/Users/me/run/src/a.txt","startLine":1,"numLines":2,"totalLines":2}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_2","name":"Read","input":{"filePath":"/Users/me/run/src/b.txt"}}]},"session_id":"ses_x"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_2","content":"<path>/Users/me/run/src/b.txt</path>\n<type>file</type>\n<content>\n4: d\n5: e\n</content>","is_error":false}]},"session_id":"ses_x"}
{"type":"result","subtype":"success","is_error":false,"session_id":"ses_x"}
```

- [ ] **Passo 2: escrever os testes que falham**

`tests/security/test_evidence.py`:

```python
# tests/security/test_evidence.py
"""The proof of reading: what a unit's own stream shows it read, and nothing it only asked for.

The fixtures are real captured event shapes (2026-09-24, 1,620 Claude Code
`Read` calls) with neutral paths and content; see the task that added them."""
from pathlib import Path

from security import evidence

FIXTURES = Path(__file__).parent / "fixtures" / "streams"
ROOT = "/Users/me/run"


def _claude():
    return evidence.read_session(FIXTURES / "claude-reads.ndjson", ROOT)


def test_a_read_counts_the_lines_its_result_carried():
    assert _claude().reads["src/app.py"] == [(1, 3)]


def test_a_read_cut_by_the_token_cap_counts_only_what_came_back():
    first_five = (FIXTURES / "claude-reads.ndjson").read_text().splitlines()[:5]
    assert evidence.parse(first_five, ROOT).reads["src/big.py"] == [(1, 1096)]
    assert _claude().reads["src/big.py"] == [(1, 1724)], "the next read picked up where the cap cut"


def test_a_result_that_read_nothing_counts_nothing():
    assert "src/short.py" not in _claude().reads


def test_an_error_counts_nothing():
    assert "src/gone.py" not in _claude().reads


def test_a_read_outside_the_run_root_counts_nothing():
    assert not any("secret" in path for path in _claude().reads)


def test_a_subagent_s_reads_count_nothing_and_its_launch_is_counted():
    session = _claude()
    assert "src/sub.py" not in session.reads
    assert session.tasks == 1


def test_a_read_with_no_result_counts_nothing_and_a_stray_result_is_ignored():
    assert "src/noresult.py" not in _claude().reads


def test_without_the_structured_range_the_numbered_lines_are_the_proof():
    assert _claude().reads["src/prefix.py"] == [(7, 8)]


def test_the_guides_a_session_opened_are_named():
    assert _claude().guides == {"ATTACK-CLASSES"}


def test_opencode_reads_count_by_the_range_the_normaliser_now_keeps():
    session = evidence.read_session(FIXTURES / "opencode-reads.ndjson", ROOT)
    assert session.reads["src/a.txt"] == [(1, 2)]
    assert session.reads["src/b.txt"] == [(4, 5)]


def test_a_missing_stream_is_an_empty_session():
    assert evidence.read_session(FIXTURES / "nope.ndjson", ROOT) == evidence.EMPTY
    assert evidence.read_session(None, ROOT) == evidence.EMPTY


def test_what_security_read_served_joins_the_stream_s_reads():
    session = evidence.with_served(_claude(), [("src/app.py", 4, 9), ("src/new.py", 1, 5)])
    assert session.reads["src/app.py"] == [(1, 9)], "adjacent spans are one span"
    assert session.reads["src/new.py"] == [(1, 5)]


def test_missing_is_what_the_reads_do_not_cover_of_each_range():
    reads = {"a.py": [(1, 10), (21, 30)], "b.py": [(1, 100)]}
    wanted = [{"path": "a.py", "first": 1, "last": 30, "bytes": 300},
              {"path": "b.py", "first": 1, "last": 50, "bytes": 90},
              {"path": "c.py", "first": 1, "last": 5, "bytes": 5}]
    assert evidence.missing(wanted, reads) == [
        {"path": "a.py", "first": 11, "last": 20, "bytes": 0},
        {"path": "c.py", "first": 1, "last": 5, "bytes": 5}]


def test_adjacent_reads_cover_a_range_together():
    assert evidence.missing([{"path": "a.py", "first": 1, "last": 9, "bytes": 1}],
                            {"a.py": [(5, 9), (1, 4)]}) == []


def test_a_relative_root_path_and_a_symlinked_root_resolve_to_the_same_files(tmp_path):
    real = tmp_path / "real"
    (real / "src").mkdir(parents=True)
    link = tmp_path / "link"
    link.symlink_to(real)
    line = ('{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read",'
            '"input":{"file_path":"%s/src/x.py"}}]},"parent_tool_use_id":null}\n'
            '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1",'
            '"content":"1\\tx\\n"}]},"parent_tool_use_id":null}\n') % real
    session = evidence.parse(line.splitlines(), str(link))
    assert session.reads == {"src/x.py": [(1, 1)]}
```

No fim de `tests/test_opencode_stream.py`, seguindo o estilo do ficheiro (ver como ele já normaliza `test/fixtures/opencode/02-tool-use-bash-and-read.jsonl` à volta da linha 118 e reutilizar o mesmo helper):

```python
def test_a_read_keeps_the_range_it_showed_in_the_claude_shape():
    """The proof of reading (bin/security/evidence.py) counts the lines a read
    returned. OpenCode reports them in `state.metadata.display`, which the
    normaliser used to drop -- and the output itself is capped at 8 KB, so the
    numbered lines alone cannot prove a long read."""
    events = _normalise("02-tool-use-bash-and-read.jsonl")   # the helper this file already uses
    result = next(e for e in events if e.get("type") == "user"
                  and e["message"]["content"][0].get("tool_use_id", "").startswith("call_3439"))
    assert result["tool_use_result"] == {"type": "text", "file": {
        "filePath": "/tmp/probe/p/a.txt", "startLine": 1, "numLines": 1, "totalLines": 1}}
```

(Se o helper do ficheiro tiver outro nome, usar esse; o que importa é normalizar esse fixture real e procurar o resultado do `read` com `callID` `call_3439a058fa6044169376f428`.)

- [ ] **Passo 3: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_evidence.py tests/test_opencode_stream.py -p no:cacheprovider -q`
Expected: FAIL — `ImportError: cannot import name 'evidence'` e o teste do OpenCode sem `tool_use_result`.

- [ ] **Passo 4: implementar `bin/security/evidence.py`**

```python
# bin/security/evidence.py
"""What a unit's session proves it read -- off its own stream, never its word.

THE RESULT, NOT THE REQUEST. Measured on 1,620 real Claude Code `Read`
calls (2026-09-24): a read asked without a limit can come back cut by a
token cap (lines 1-1096 of 1,724), and a result that is not an error can
hold nothing ("shorter than the provided offset", "contents are empty").
Counting what was ASKED would swear to lines nobody saw. What the model
received is on the result: `tool_use_result.file.{startLine, numLines}` on
the main agent's `user` event (OpenCode's normaliser now writes the same
shape from `state.metadata.display`), and failing that the numbered lines
of the content itself (`N\\t` on Claude Code, `N: ` on OpenCode).

ONLY THE UNIT'S OWN READS. An event with a `parent_tool_use_id` is a
subagent's: the engine distributes the work, so a subagent's reads prove
nothing about this unit -- its launch is counted instead (`tasks`), and the
unit that launched one is judged a failed attempt (security/units.py).

ONLY INSIDE THE RUN. A path is made relative to the run's root after both
are resolved (a worktree under a symlinked temp dir is the same place);
anything outside the root is not this analysis's code and counts nothing.

THE CODEX CLI HAS NO READ TOOL, and its shell reads cannot be proven from
the stream (wrapped in `/bin/zsh -lc`, chained, capped at 8 KB, sometimes
lost). There the reading goes through `agentloop security read`, whose
ledger record is the proof; `with_served` joins it to the stream's reads,
and a unit on any platform may use either.
"""

import json
import os
import re
from dataclasses import dataclass, field

_GUIDE = re.compile(r"security-analysis/references/([A-Z][A-Z-]*)\.md")
_NUMBERED = re.compile(r"^\s*(\d+)(?:\t|: )", re.MULTILINE)


@dataclass(frozen=True)
class Session:
    reads: dict = field(default_factory=dict)
    tasks: int = 0
    guides: set = field(default_factory=set)


EMPTY = Session()


def _relative(path, root_real):
    if not isinstance(path, str) or not path:
        return None
    full = path if os.path.isabs(path) else os.path.join(root_real, path)
    real = os.path.realpath(full)
    if real != root_real and not real.startswith(root_real + os.sep):
        return None
    return os.path.relpath(real, root_real).replace(os.sep, "/")


def _numbered_range(content):
    if isinstance(content, list):
        content = "\n".join(b.get("text", "") for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str):
        return None
    numbers = [int(n) for n in _NUMBERED.findall(content)]
    return (min(numbers), max(numbers)) if numbers else None


def _structured_range(event):
    result = event.get("tool_use_result")
    file = result.get("file") if isinstance(result, dict) else None
    if not isinstance(file, dict):
        return None
    try:
        start, count = int(file.get("startLine")), int(file.get("numLines"))
    except (TypeError, ValueError):
        return None
    return (start, start + count - 1) if count > 0 else ()


def _merge(spans):
    out = []
    for first, last in sorted(spans):
        if out and first <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], last))
        else:
            out.append((first, last))
    return out


def parse(lines, root) -> Session:
    root_real = os.path.realpath(str(root))
    asked, reads, guides, tasks = {}, {}, set(), 0
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict) or event.get("parent_tool_use_id"):
            continue
        blocks = ((event.get("message") or {}).get("content")) or []
        if not isinstance(blocks, list):
            continue
        if event.get("type") == "assistant":
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                guides.update(_GUIDE.findall(json.dumps(inp)))
                if block.get("name") in ("Task", "Agent"):
                    tasks += 1
                elif block.get("name") == "Read":
                    asked[block.get("id")] = inp.get("file_path") or inp.get("filePath")
        elif event.get("type") == "user":
            results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
            for block in results:
                path = asked.pop(block.get("tool_use_id"), None)
                if path is None or block.get("is_error"):
                    continue
                span = _structured_range(event) if len(results) == 1 else None
                if span is None:
                    span = _numbered_range(block.get("content"))
                rel = _relative(path, root_real)
                if span and rel:
                    reads.setdefault(rel, []).append(span)
    return Session(reads={p: _merge(s) for p, s in reads.items()}, tasks=tasks, guides=guides)


def read_session(stream_path, root) -> Session:
    if not stream_path:
        return EMPTY
    try:
        with open(stream_path, encoding="utf-8", errors="replace") as handle:
            return parse(handle, root)
    except OSError:
        return EMPTY


def with_served(session, served) -> Session:
    reads = {p: list(s) for p, s in session.reads.items()}
    for path, first, last in served:
        reads.setdefault(path, []).append((int(first), int(last)))
    return Session(reads={p: _merge(s) for p, s in reads.items()},
                   tasks=session.tasks, guides=set(session.guides))


def missing(ranges, reads) -> list:
    """The part of each wanted range no read covers, as ranges of its own. A
    range untouched keeps its bytes; a piece of one carries 0 (only its lines
    are known)."""
    out = []
    for wanted in ranges:
        first, last = int(wanted["first"]), int(wanted["last"])
        cursor, gaps = first, []
        for a, b in _merge(reads.get(wanted["path"], [])):
            if b < cursor or a > last:
                continue
            if a > cursor:
                gaps.append((cursor, a - 1))
            cursor = max(cursor, b + 1)
            if cursor > last:
                break
        if cursor <= last:
            gaps.append((cursor, last))
        for a, b in gaps:
            whole = (a, b) == (first, last)
            out.append({"path": wanted["path"], "first": a, "last": b,
                        "bytes": int(wanted.get("bytes", 0)) if whole else 0})
    return out
```

- [ ] **Passo 5: o normalizador do OpenCode guarda o intervalo**

Em `bin/platforms/opencode_stream.py`, em `Normalizer._tool`, substituir o `return` final por:

```python
        result = self._msg("user", [{"type": "tool_result", "tool_use_id": call,
                                     "content": out, "is_error": is_error}])
        # THE RANGE A READ SHOWED, in Claude Code's own shape. The proof of
        # reading (bin/security/evidence.py) counts the lines a read returned,
        # and OpenCode reports them only in `metadata.display` -- the output
        # above is capped at OUTPUT_CAP, so its numbered lines alone cannot
        # prove a long read.
        display = (state.get("metadata") or {}).get("display") if isinstance(state.get("metadata"), dict) else None
        if name == "Read" and not is_error and isinstance(display, dict):
            try:
                start, end = int(display["lineStart"]), int(display["lineEnd"])
                total = int(display.get("totalLines", end))
            except (KeyError, TypeError, ValueError):
                start = None
            if start is not None:
                result["tool_use_result"] = {"type": "text", "file": {
                    "filePath": display.get("path") or inp.get("filePath", ""),
                    "startLine": start, "numLines": max(0, end - start + 1),
                    "totalLines": total}}
        return [self._assistant([{"type": "tool_use", "id": call, "name": name, "input": inp}]),
                result]
```

- [ ] **Passo 6: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_evidence.py tests/test_opencode_stream.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Passo 7: CHANGELOG e commit**

Duas entradas em `CHANGELOG.md`, `## [Unreleased]`. Em `### Added`, no topo:

```markdown
- **What a unit read is proven from its own stream.** A read counts only
  the lines its result carried — Claude Code's `tool_use_result` range, or
  the numbered lines of the content — never what it asked for: a read with
  no limit can come back cut by a token cap, and one past the end of a file
  returns nothing without being an error. Errors, reads outside the run's
  root and a subagent's reads count nothing; a subagent's launch is counted
  instead.
```

Em `### Changed`, no topo:

```markdown
- **OpenCode's normalised stream keeps the range a read showed.** The
  `metadata.display` line range is copied onto the result in Claude Code's
  `tool_use_result.file` shape; the output itself is capped at 8 KB, so the
  numbered lines alone could never prove a long read.
```

```bash
/usr/bin/git add bin/security/evidence.py bin/platforms/opencode_stream.py tests/security/test_evidence.py tests/security/fixtures/streams/claude-reads.ndjson tests/security/fixtures/streams/opencode-reads.ndjson tests/test_opencode_stream.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): prove a unit's reading from what its reads returned"
```

---

### Task 5: As unidades — plano, fila e julgamento

**Ficheiros:**
- Criar: `bin/security/units.py`
- Modificar: `bin/security/ledger.py` (`add_units`, logo a seguir a `add_unit`)
- Testes: `tests/security/test_units.py` (novo), `tests/security/test_ledger_units.py` (os testes de `add_units`)

**Interfaces:**
- Consome: Task 1 (`ledger.add_unit`, `units_of`, `get_unit`, `settle_unit`, `inventory_of(conn, analysis_id)`), Task 3 (`slices.pack`), Task 4 (`evidence.Session` com `reads`, `tasks`, `guides`; `evidence.missing(ranges, reads)`), `queries.checklist`, `queries.verify_queue`, `queries.is_open`, `diff.AGENT`.
- Produz:
  - `ledger.add_units(conn, analysis_id, specs) -> list[int]` — `specs` é uma lista de `(kind, payload)`; uma só `BEGIN IMMEDIATE` para todas, numeradas seguidas a partir do último `seq` da análise; tudo ou nada (um `kind` fora do vocabulário é recusado antes de se escrever uma linha; um erro a meio desfaz as anteriores)
  - `units.TRIAGE_BATCH = 25`, `units.MAX_ATTEMPTS = 3`, `units.BLOCKING = ("critical", "high", "medium")`, `units.KIND_RANK`
  - `units.triage_items(conn, analysis_id) -> list[{"fingerprint", "kind", "severity"}]` (`kind` ∈ `scanner`, `carried`)
  - `units.plan(conn, analysis_id, slice_guides=None) -> list[int]` (idempotente e **atómico**: calcula o plano inteiro e escreve-o com `ledger.add_units`, por isso uma falha a meio — uma excepção, um kill — não deixa unidade nenhuma e a análise pode ser planeada outra vez; `slice_guides(ranges) -> list[str]` escolhe os guias de cada unidade `read`, e sem ele vai só `ATTACK-CLASSES`)
  - `units.plan_verification(conn, analysis_id) -> list[int]` (idempotente)
  - `units.launchable(conn, analysis_id, capacity) -> list[dict]`
  - `units.unsettled(units, kinds=None) -> list[dict]`
  - `units.judge(conn, unit, session, status, reason="") -> (done: bool, remaining: dict | None, evidence: dict, note: str)` — uma sessão que lançou um subagente (`session.tasks > 0`) falha a tentativa **em qualquer tipo de unidade**; a prova de uma `read` leva `evidence["covered"] = {path: [[first, last], ...]}`, a intersecção das leituras provadas com os intervalos do seu payload (`{}` quando nada conta)
  - `units.conclude(conn, unit, *, done, evidence, note, spend_usd, remaining=None, stopped=False) -> {"state", "continuation"}`
  - `units.lineage_root(conn, unit) -> dict` (a primeira unidade da linhagem) e `units.label(conn, unit) -> str` (ex.: `"read 7/25 · attempt 2"`)

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_units.py`:

```python
# tests/security/test_units.py
"""The pipeline's units: what the plan holds, what runs next, and how a unit is judged."""
import pytest

from security import cli as security_cli
from security import evidence, ledger, units


@pytest.fixture
def conn(tmp_path):
    c = ledger.connect(tmp_path / "security.db")
    yield c
    c.close()


def _analysis(conn, profile="deep", commit="c1"):
    return ledger.start_analysis(conn, "web", "web", "main", commit, profile, "security-web")


def _scanner(conn, aid, fp, severity="high", producer="semgrep"):
    ledger.record_finding(conn, aid, {
        "fingerprint": fp, "category": "sast", "rule": "r", "severity": severity,
        "title": "t", "rationale": "scanner text", "producer": producer,
        "occurrences": [{"file": "a.py", "line": 3}]})


def _agent(conn, aid, fp, severity="medium", unit=0):
    ledger.record_finding(conn, aid, {
        "fingerprint": fp, "category": "sast", "rule": "xss", "severity": severity,
        "title": "t", "rationale": "the agent read it", "producer": "agent", "unit": unit,
        "occurrences": [{"file": "a.py", "line": 3}]})


def _inventory(conn, aid, files):
    ledger.set_inventory(conn, aid, {"files": files, "excluded": {}, "git": True,
                                     "totals": {"files": len(files), "lines": 0, "bytes": 0}})


def _file(path, *ranges):
    return {"path": path, "lines": ranges[-1][1], "bytes": sum(r[2] for r in ranges),
            "ranges": [list(r) for r in ranges]}


def test_the_triage_floor_is_the_close_s_own():
    assert units.BLOCKING == security_cli.TRIAGE_BLOCKING


def test_a_carried_sast_finding_reported_gone_is_settled_and_a_deterministic_one_is_not(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"},
        {"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    ledger.record_gone(conn, uid, "d" * 64, "not how a dependency row is settled")
    done, remaining, ev, note = units.judge(conn, ledger.get_unit(conn, uid), _session(), "success")
    assert remaining == {"items": [{"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]}


def test_triage_owes_every_open_scanner_row_and_every_agent_finding_left_open(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "low")
    _scanner(conn, aid, "b" * 64, "critical")
    items = units.triage_items(conn, aid)
    assert [(i["fingerprint"][0], i["kind"]) for i in items] == [("b", "scanner"), ("c", "carried"), ("a", "scanner")]


def test_the_plan_is_triage_batches_one_hunt_and_a_read_per_slice(conn, monkeypatch):
    monkeypatch.setattr(units, "TRIAGE_BATCH", 2)
    aid = _analysis(conn)
    for n in "abcde":
        _scanner(conn, aid, n * 64)
    _inventory(conn, aid, [_file("a.py", (1, 10, 200_000)), _file("b.py", (1, 10, 200_000))])
    ids = units.plan(conn, aid)
    kinds = [(u["kind"], len(u["payload"].get("items", u["payload"].get("ranges", []))))
             for u in ledger.units_of(conn, aid)]
    assert kinds == [("triage", 2), ("triage", 2), ("triage", 1), ("hunt", 0), ("read", 1), ("read", 1)]
    assert len(ids) == 6
    assert units.plan(conn, aid) == [], "a second plan of the same analysis adds nothing"
    reads = [u for u in ledger.units_of(conn, aid) if u["kind"] == "read"]
    assert reads[0]["payload"]["guides"] == ["ATTACK-CLASSES"]


def test_each_read_unit_carries_the_guides_its_slice_calls_for(conn):
    aid = _analysis(conn)
    _inventory(conn, aid, [_file("web/a.tsx", (1, 10, 100))])
    units.plan(conn, aid, slice_guides=lambda ranges: ["ATTACK-CLASSES", "CLIENT-SIDE"]
               if any(r["path"].endswith(".tsx") for r in ranges) else ["ATTACK-CLASSES"])
    read = next(u for u in ledger.units_of(conn, aid) if u["kind"] == "read")
    assert read["payload"]["guides"] == ["ATTACK-CLASSES", "CLIENT-SIDE"]


def test_a_plan_that_fails_part_way_leaves_no_unit_and_can_be_planned_again(conn):
    """ALL OR NOTHING. `plan` refuses an analysis that already has units, so a
    plan cut off after its first units -- an exception, a kill -- used to
    leave slices no unit would ever read, and nothing said so."""
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64)
    _inventory(conn, aid, [_file("a.py", (1, 10, 200_000)), _file("b.py", (1, 10, 200_000))])
    calls = []

    def guides_that_break_on_the_second_slice(ranges):
        calls.append(ranges)
        if len(calls) == 2:
            raise RuntimeError("the guide table could not be read")
        return ["ATTACK-CLASSES"]
    with pytest.raises(RuntimeError):
        units.plan(conn, aid, slice_guides=guides_that_break_on_the_second_slice)
    assert ledger.units_of(conn, aid) == [], "a failed plan writes nothing, not its first half"
    assert len(units.plan(conn, aid)) == 4, \
        "and the analysis is planned again, whole: triage, hunt and a read per slice"


def test_a_profile_other_than_deep_plans_no_reads(conn):
    aid = _analysis(conn, profile="standard")
    _inventory(conn, aid, [_file("a.py", (1, 10, 100))])
    units.plan(conn, aid)
    assert [u["kind"] for u in ledger.units_of(conn, aid)] == ["hunt"]
    assert ledger.units_of(conn, aid)[0]["payload"] == {"profile": "standard"}


def test_units_run_triage_then_hunt_then_read_then_verify(conn):
    aid = _analysis(conn)
    r = ledger.add_unit(conn, aid, "read", {"ranges": []})
    v = ledger.add_unit(conn, aid, "verify", {"fingerprint": "f" * 64})
    h = ledger.add_unit(conn, aid, "hunt", {})
    t = ledger.add_unit(conn, aid, "triage", {"items": []})
    assert [u["id"] for u in units.launchable(conn, aid, 10)] == [t, h, r, v]
    assert [u["id"] for u in units.launchable(conn, aid, 2)] == [t, h]
    ledger.start_unit(conn, t)
    assert [u["id"] for u in units.launchable(conn, aid, 10)] == [h, r, v]
    assert units.launchable(conn, aid, 0) == []


def test_verification_is_planned_once_per_finding_of_this_analysis(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    _agent(conn, aid, "a" * 64, "high")
    _agent(conn, aid, "b" * 64, "low")
    ids = units.plan_verification(conn, aid)
    assert [ledger.get_unit(conn, i)["payload"] for i in ids] == [{"fingerprint": "a" * 64}], \
        "a low finding is out of scope, and a carried one belongs to its own analysis"
    assert units.plan_verification(conn, aid) == []


def _session(reads=None, tasks=0, guides=()):
    return evidence.Session(reads=reads or {}, tasks=tasks, guides=set(guides))


def test_a_read_that_covered_every_range_is_done(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [
        {"path": "a.py", "first": 1, "last": 50, "bytes": 1}]})
    unit = ledger.get_unit(conn, uid)
    done, remaining, ev, note = units.judge(conn, unit, _session({"a.py": [(1, 2000)]}, guides=["ATTACK-CLASSES"]), "success")
    assert (done, remaining) == (True, None)
    assert ev["missing"] == [] and ev["guides"] == ["ATTACK-CLASSES"]
    assert ev["covered"] == {"a.py": [[1, 50]]}, "only the unit's own lines, not all the session read"


def test_a_read_that_skipped_part_of_a_range_owes_exactly_that_part(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [
        {"path": "a.py", "first": 1, "last": 300, "bytes": 1},
        {"path": "b.py", "first": 1, "last": 10, "bytes": 1}]})
    unit = ledger.get_unit(conn, uid)
    done, remaining, ev, note = units.judge(conn, unit, _session({"a.py": [(1, 100)], "c.py": [(1, 9)]}), "success")
    assert done is False
    assert remaining == {"ranges": [{"path": "a.py", "first": 101, "last": 300, "bytes": 0},
                                    {"path": "b.py", "first": 1, "last": 10, "bytes": 1}]}
    assert ev["covered"] == {"a.py": [[1, 100]]}, \
        "what it proved of its own ranges is kept, and a file outside them is not its to cover"
    assert "2 of 2 range(s) not read in full" in note


@pytest.mark.parametrize("kind, payload", [
    ("triage", {"items": []}),
    ("hunt", {"profile": "deep"}),
    ("read", {"ranges": [{"path": "a.py", "first": 1, "last": 5, "bytes": 1}]}),
    ("verify", {"fingerprint": "a" * 64}),
])
def test_a_session_that_launched_subagents_fails_its_attempt_whatever_its_kind(conn, kind, payload):
    """Each of these would be `done` on its own evidence -- nothing to triage,
    a run that worked, every line read, a verdict recorded. A subagent in the
    unit's own stream undoes all of it: the engine distributes the work."""
    aid = _analysis(conn)
    if kind == "verify":
        _agent(conn, aid, "a" * 64, "high")
        ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "a subagent read it", by="unit:1")
    uid = ledger.add_unit(conn, aid, kind, payload)
    done, remaining, ev, note = units.judge(conn, ledger.get_unit(conn, uid),
                                            _session({"a.py": [(1, 5)]}, tasks=2), "success")
    assert (done, remaining, ev["tasks"]) == (False, None, 2)
    assert "subagent" in note
    if kind == "read":
        assert ev["covered"] == {}, "what a session that fanned out read proves nothing"


def test_triage_is_done_when_every_blocking_row_was_triaged_or_decided(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "high")
    _scanner(conn, aid, "b" * 64, "low")
    _scanner(conn, aid, "d" * 64, "medium")
    ledger.set_decision(conn, "web", "d" * 64, "accepted", "known", "operator")
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "a" * 64, "kind": "scanner"}, {"fingerprint": "b" * 64, "kind": "scanner"},
        {"fingerprint": "c" * 64, "kind": "carried"}, {"fingerprint": "d" * 64, "kind": "scanner"}]})
    unit = ledger.get_unit(conn, uid)
    done, remaining, ev, note = units.judge(conn, unit, _session(), "success")
    assert done is False
    assert remaining == {"items": [{"fingerprint": "a" * 64, "kind": "scanner"},
                                   {"fingerprint": "c" * 64, "kind": "carried"}]}, \
        "items built by hand without a category keep the keys they had"
    _agent(conn, aid, "a" * 64, "high")   # the agent's re-report marks the scanner row triaged
    _agent(conn, aid, "c" * 64)           # the carried finding is re-checked in this analysis
    done, remaining, ev, note = units.judge(conn, unit, _session(), "success")
    assert (done, remaining) == (True, None)


def test_verify_is_done_only_with_a_verdict_on_its_finding(conn):
    aid = _analysis(conn)
    _agent(conn, aid, "a" * 64, "high")
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    unit = ledger.get_unit(conn, uid)
    assert units.judge(conn, unit, _session(), "success")[0] is False
    ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it", by=f"unit:{uid}")
    assert units.judge(conn, unit, _session(), "success")[0] is True


@pytest.mark.parametrize("status, reason, done", [
    ("success", "", True),
    ("warning", "stderr had 3 bytes", True),
    ("warning", "UNDECLARED ENDING: no run-ending line", False),
    ("warning", "BUDGET LIMITED: spent $1 of a $1 cap", False),
    ("error", "", False),
    ("stopped", "", False),
])
def test_a_hunt_is_done_when_its_run_worked(conn, status, reason, done):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    assert units.judge(conn, ledger.get_unit(conn, uid), _session(), status, reason)[0] is done


def test_conclude_settles_done_and_plans_nothing(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {})
    ledger.start_unit(conn, uid)
    out = units.conclude(conn, ledger.get_unit(conn, uid), done=True, evidence={}, note="ok", spend_usd=1.0)
    assert out == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["spend_usd"] == 1.0


def test_conclude_continues_what_is_left_one_attempt_up_until_the_third(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 9, "bytes": 1}]})
    left = {"ranges": [{"path": "a.py", "first": 5, "last": 9, "bytes": 0}]}
    out = units.conclude(conn, ledger.get_unit(conn, uid), done=False, evidence={}, note="n",
                         spend_usd=0, remaining=left)
    second = ledger.get_unit(conn, out["continuation"])
    assert (out["state"], second["attempt"], second["parent"], second["payload"]) == ("incomplete", 2, uid, left)
    out = units.conclude(conn, second, done=False, evidence={}, note="n", spend_usd=0, remaining=left)
    third = ledger.get_unit(conn, out["continuation"])
    out = units.conclude(conn, third, done=False, evidence={}, note="still short.", spend_usd=0, remaining=left)
    assert out == {"state": "failed", "continuation": None}
    assert "Gave up after 3 attempts" in ledger.get_unit(conn, third["id"])["note"]


def test_a_stop_continues_at_the_same_attempt(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    out = units.conclude(conn, ledger.get_unit(conn, uid), done=False, evidence={}, note="stopped",
                         spend_usd=0, stopped=True)
    cont = ledger.get_unit(conn, out["continuation"])
    assert (cont["attempt"], cont["payload"]) == (1, {"profile": "deep"})


def test_the_label_names_the_kind_its_place_and_the_attempt(conn):
    aid = _analysis(conn)
    first = ledger.add_unit(conn, aid, "read", {"ranges": []})
    ledger.add_unit(conn, aid, "read", {"ranges": []})
    cont = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=2, parent=first)
    assert units.label(conn, ledger.get_unit(conn, first)) == "read 1/2"
    assert units.label(conn, ledger.get_unit(conn, cont)) == "read 1/2 · attempt 2"
```

No fim de `tests/security/test_ledger_units.py`:

```python
def test_several_units_are_added_in_one_transaction_numbered_after_the_last(conn):
    aid = _analysis(conn)
    ledger.add_unit(conn, aid, "hunt", {})
    ids = ledger.add_units(conn, aid, [("triage", {"items": []}), ("read", {"ranges": []})])
    assert [ledger.get_unit(conn, i)["seq"] for i in ids] == [2, 3]
    assert [ledger.get_unit(conn, i)["kind"] for i in ids] == ["triage", "read"]
    assert ledger.add_units(conn, aid, []) == []


def test_a_batch_with_one_kind_outside_the_vocabulary_writes_nothing(conn):
    aid = _analysis(conn)
    with pytest.raises(ValueError):
        ledger.add_units(conn, aid, [("hunt", {}), ("explore", {})])
    assert ledger.units_of(conn, aid) == []


def test_a_batch_that_fails_half_way_writes_nothing(conn):
    aid = _analysis(conn)

    class NotJson:
        pass
    with pytest.raises(TypeError):
        ledger.add_units(conn, aid, [("hunt", {}), ("read", {"ranges": NotJson()})])
    assert ledger.units_of(conn, aid) == [], "the hunt written before the failure is rolled back"
```

Nota: `ledger.set_decision(conn, project, fingerprint, state, reason, decided_by)` e `ledger.record_verdict(conn, analysis_id, fingerprint, verdict, reason, by=...)` já existem (ver `ledger.py`).

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_units.py tests/security/test_ledger_units.py -p no:cacheprovider -q`
Expected: FAIL — `ImportError: cannot import name 'units'` e `AttributeError: module 'security.ledger' has no attribute 'add_units'`.

- [ ] **Passo 3: `ledger.add_units`, logo a seguir a `add_unit` em `bin/security/ledger.py`**

```python
def add_units(conn, analysis_id, specs) -> list:
    """Several new `pending` units in ONE transaction, numbered one after the
    other from the analysis's last `seq` -- all of them, or none.

    WHY ALL OR NONE. `units.plan` refuses to plan an analysis that already has
    units (a resume, a second prepare must not run the work twice), so a plan
    written unit by unit and cut off half way -- an exception, a kill -- left
    the analysis with the first half of its plan and nobody to write the rest:
    the slices without a unit were never read, and nothing said so. One BEGIN
    IMMEDIATE for the whole plan makes that state impossible to write. Every
    kind is checked before the transaction opens, so a bad one writes nothing
    either."""
    specs = list(specs)
    for kind, _payload in specs:
        if kind not in UNIT_KINDS:
            raise ValueError(f"bad unit kind: {kind}")
    if not specs:
        return []
    conn.execute("BEGIN IMMEDIATE")
    try:
        seq = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM unit WHERE analysis_id=?",
                           (analysis_id,)).fetchone()[0]
        ids = []
        for kind, payload in specs:
            seq += 1
            cur = conn.execute(
                "INSERT INTO unit (analysis_id, seq, kind, payload) VALUES (?,?,?,?)",
                (analysis_id, seq, kind, json.dumps(payload, sort_keys=True)))
            ids.append(cur.lastrowid)
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return ids
```

- [ ] **Passo 4: implementar `bin/security/units.py`**

```python
# bin/security/units.py
"""The work an analysis is split into, and what each piece owes.

THE ENGINE PLANS; A SESSION EXECUTES. Until this module an analysis was one
agent doing four jobs in one context and deciding for itself when it had
done enough -- and on a large repository it always decided early, because
the repository did not fit. Now `prepare` ends by writing the plan: units,
each small enough for a fresh session and closed in scope, each run by the
engine (security/orchestrator.py) and judged by what it left behind --
never by what it said.

  triage  up to TRIAGE_BATCH rows: the scanners' findings (Job 2) and the
          agent findings the previous analysis left open (Job 1)
  hunt    the profile's reachability pass (in deep bounded to standard's
          scope: the exhaustive read belongs to the read units)
  read    deep only: one slice of the inventory (security/slices.py)
  verify  one finding of THIS analysis in the verification queue, planned
          only once every other unit has settled -- the queue is only final
          then

A UNIT IS NEVER REWRITTEN. What it left undone becomes a NEW unit whose
`parent` is this one, carrying only what is missing, one attempt up; a
lineage gets MAX_ATTEMPTS, and what the last one still left is a gap the
close names. A stop is not the unit's failure: its continuation keeps the
same attempt.
"""

from . import diff, evidence, ledger, queries, slices

TRIAGE_BATCH = 25
MAX_ATTEMPTS = 3
# The close's own floor (cli.TRIAGE_BLOCKING, pinned equal by a test): a
# scanner row below it never blocks `done`, so it never keeps a unit open.
BLOCKING = ("critical", "high", "medium")
KIND_RANK = {"triage": 0, "hunt": 1, "read": 2, "verify": 3}
_SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
# The classifier notes that make a `warning` a truncated run rather than a
# noisy one -- the reading `security_close_analysis` applies in the engine.
_TRUNCATED = ("BUDGET LIMITED", "UNDECLARED ENDING", "UNDELIVERED")


def triage_items(conn, analysis_id) -> list:
    """What Jobs 1 and 2 owe, worst first: every open scanner row of this
    analysis, and every open agent finding a previous analysis left."""
    _analysis, findings = queries.checklist(conn, analysis_id)
    items = []
    for f in findings:
        if not queries.is_open(f.get("state", "")):
            continue
        producer = f.get("producer") or ""
        if f.get("analysis_id") == analysis_id and producer not in ("", diff.AGENT):
            kind = "scanner"
        elif f.get("analysis_id") != analysis_id and producer:
            # CARRIED, of any producer: an agent finding the last analysis left
            # open, and a deterministic row whose producer did not run this time
            # (`pending`) -- which vanishes from the next baseline unless it is
            # re-reported, and comes back as `regressed` when the engine returns.
            kind = "carried"
        else:
            continue
        items.append({"fingerprint": f["fingerprint"], "kind": kind,
                      "category": f.get("category", ""), "severity": f.get("severity", "")})
    items.sort(key=lambda i: (_SEV_RANK.get(i["severity"], 9), i["kind"] != "scanner",
                              i["fingerprint"]))
    return items


def plan(conn, analysis_id, slice_guides=None) -> list:
    """The analysis's first units, written once. An analysis that already has
    units -- a resume, a second `prepare` -- gets none: planning twice would
    run the same work twice. `slice_guides(ranges)` names the hunting guides
    a read unit's files call for (`prepare` builds it from the same signals
    the analysis's own recommendation reads); without it a read unit gets
    ATTACK-CLASSES alone.

    COMPUTED WHOLE, THEN WRITTEN IN ONE TRANSACTION (ledger.add_units). The
    refusal above makes a partial plan permanent, so nothing is written until
    every unit is known: a failure anywhere -- the checklist, a slice's
    guides -- leaves the analysis with no unit at all, to be planned again."""
    if ledger.units_of(conn, analysis_id):
        return []
    profile = conn.execute("SELECT profile FROM analysis WHERE id=?",
                           (analysis_id,)).fetchone()["profile"]
    specs = []
    items = triage_items(conn, analysis_id)
    for start in range(0, len(items), TRIAGE_BATCH):
        batch = [{"fingerprint": i["fingerprint"], "kind": i["kind"], "category": i["category"]}
                 for i in items[start:start + TRIAGE_BATCH]]
        specs.append(("triage", {"items": batch}))
    specs.append(("hunt", {"profile": profile}))
    if profile == "deep":
        for piece in slices.pack(ledger.inventory_of(conn, analysis_id).get("files", [])):
            chosen = slice_guides(piece) if slice_guides else ["ATTACK-CLASSES"]
            specs.append(("read", {"ranges": piece, "guides": chosen}))
    return ledger.add_units(conn, analysis_id, specs)


def plan_verification(conn, analysis_id) -> list:
    """One verify unit per finding OF THIS ANALYSIS in the queue that has none
    yet. A carried row belongs to another analysis and cannot take a verdict
    here -- its re-check is the triage units' debt."""
    have = {u["payload"].get("fingerprint") for u in ledger.units_of(conn, analysis_id)
            if u["kind"] == "verify"}
    ids = []
    for f in queries.verify_queue(conn, analysis_id):
        if f.get("analysis_id") != analysis_id or f["fingerprint"] in have:
            continue
        ids.append(ledger.add_unit(conn, analysis_id, "verify", {"fingerprint": f["fingerprint"]}))
        have.add(f["fingerprint"])
    return ids


def launchable(conn, analysis_id, capacity) -> list:
    """Pending units in the order they run, then by number; at most `capacity`."""
    if capacity <= 0:
        return []
    pending = [u for u in ledger.units_of(conn, analysis_id) if u["state"] == "pending"]
    pending.sort(key=lambda u: (KIND_RANK.get(u["kind"], 9), u["seq"]))
    return pending[:capacity]


def unsettled(all_units, kinds=None) -> list:
    return [u for u in all_units if u["state"] in ("pending", "running")
            and (kinds is None or u["kind"] in kinds)]


def _decided(conn, project, fingerprint) -> bool:
    return conn.execute("SELECT 1 FROM decision WHERE project=? AND fingerprint=?",
                        (project, fingerprint)).fetchone() is not None


def _merge_spans(spans) -> list:
    """[first, last] spans, sorted, with the overlapping and the adjacent
    joined into one."""
    out = []
    for first, last in sorted((int(a), int(b)) for a, b in spans):
        if out and first <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], last)
        else:
            out.append([first, last])
    return out


def _covered(wanted, reads) -> dict:
    """{path: [[first, last], ...]}: what of this unit's OWN ranges the session
    proved it read -- each proven span cut to the ranges the payload holds.

    RECORDED WHATEVER THE OUTCOME. The deep read's debt is the inventory minus
    the union of these spans over every read unit (`owed`), so a unit that
    read half its slice before it fell short has paid for that half, and one
    that gave up without saying what it missed -- no `covered` at all --
    still owes the whole slice. Lines read outside the payload count for
    nothing here: they are some other unit's to prove."""
    out = {}
    for r in wanted:
        first, last = int(r["first"]), int(r["last"])
        for a, b in reads.get(r["path"], []):
            lo, hi = max(int(a), first), min(int(b), last)
            if lo <= hi:
                out.setdefault(r["path"], []).append((lo, hi))
    return {path: _merge_spans(spans) for path, spans in out.items()}


def _judge_read(unit, session):
    wanted = unit["payload"].get("ranges") or []
    left = evidence.missing(wanted, session.reads)
    ev = {"ranges": len(wanted), "missing": left, "covered": _covered(wanted, session.reads),
          "guides": sorted(session.guides)}
    if not left:
        return True, None, ev, f"Read in full: {len(wanted)} range(s)."
    remaining = {"ranges": left}
    if unit["payload"].get("guides"):
        remaining["guides"] = unit["payload"]["guides"]   # the continuation hunts with the same guides
    return False, remaining, ev, f"{len(left)} of {len(wanted)} range(s) not read in full."


def _judge_triage(conn, unit):
    aid = unit["analysis_id"]
    project = conn.execute("SELECT project FROM analysis WHERE id=?", (aid,)).fetchone()["project"]
    owed = unit["payload"].get("items") or []
    gone = ledger.gone_in(conn, aid)
    left = []
    for item in owed:
        fp = item["fingerprint"]
        if _decided(conn, project, fp):
            continue
        row = conn.execute("SELECT triaged, severity, producer FROM finding"
                           " WHERE analysis_id=? AND fingerprint=?", (aid, fp)).fetchone()
        if item["kind"] == "scanner":
            if row is None or row["triaged"] or row["severity"] not in BLOCKING:
                continue
        elif row is not None:
            continue
        elif item.get("category") == "sast" and fp in gone:
            # A carried sast finding the unit read and SAID is gone
            # (`report-gone`): its absence from this analysis is a reading,
            # not a silence, and it closes `fixed`.
            continue
        left.append({k: item[k] for k in ("fingerprint", "kind", "category") if k in item})
    ev = {"items": len(owed), "missing": [i["fingerprint"] for i in left]}
    if not left:
        return True, None, ev, f"Triaged: {len(owed)} row(s)."
    return False, {"items": left}, ev, f"{len(left)} of {len(owed)} row(s) not triaged."


def _judge_verify(conn, unit):
    fp = unit["payload"].get("fingerprint", "")
    row = conn.execute("SELECT verdict FROM finding WHERE analysis_id=? AND fingerprint=?",
                       (unit["analysis_id"], fp)).fetchone()
    if row is not None and row["verdict"]:
        return True, None, {"verdict": row["verdict"]}, f"Verdict: {row['verdict']}."
    return False, None, {"verdict": ""}, "No verdict was recorded."


def _judge_hunt(status, reason):
    worked = status == "success" or (
        status == "warning" and not any(mark in (reason or "") for mark in _TRUNCATED))
    if worked:
        return True, None, {"status": status}, "The pass ran to its end."
    return False, None, {"status": status, "reason": reason or ""}, (
        f"The run ended {status}{': ' + reason if reason else ''}.")


def judge(conn, unit, session, status, reason=""):
    """(done, remaining, evidence, note) for one run of `unit`. `remaining`
    is the payload of the continuation -- only what is still owed -- or None
    for "all of it again".

    A SESSION THAT LAUNCHED A SUBAGENT FAILS ITS ATTEMPT, WHATEVER ITS KIND.
    The engine distributes the work; a triage, a hunt or a verdict a
    subagent produced is not this unit's work any more than a subagent's
    reads are (security/evidence.py counts only the unit's own), so nothing
    this attempt did counts and the whole payload runs again, one attempt up.
    A read unit records no `covered` span for it: its slice stays owed."""
    if session.tasks:
        ev = {"tasks": session.tasks, "guides": sorted(session.guides)}
        if unit["kind"] == "read":
            ev.update({"ranges": len(unit["payload"].get("ranges") or []), "covered": {}})
        return False, None, ev, (
            f"This session launched {session.tasks} subagent(s). The engine distributes "
            "the work, so nothing this attempt did counts.")
    if unit["kind"] == "read":
        done, remaining, ev, note = _judge_read(unit, session)
    elif unit["kind"] == "triage":
        done, remaining, ev, note = _judge_triage(conn, unit)
    elif unit["kind"] == "verify":
        done, remaining, ev, note = _judge_verify(conn, unit)
    else:
        done, remaining, ev, note = _judge_hunt(status, reason)
    # What each session opened of the hunting guides, whatever its kind: the
    # close aggregates them into the analysis's `guides.read`.
    ev.setdefault("guides", sorted(session.guides))
    return done, remaining, ev, note


def conclude(conn, unit, *, done, evidence, note, spend_usd, remaining=None, stopped=False):
    """Settle `unit` and plan what it left. Returns the unit's final state and
    the id of its continuation, if one was planned."""
    if done:
        ledger.settle_unit(conn, unit["id"], "done", spend_usd, evidence, note)
        return {"state": "done", "continuation": None}
    attempt = unit["attempt"] if stopped else unit["attempt"] + 1
    if attempt > MAX_ATTEMPTS:
        ledger.settle_unit(conn, unit["id"], "failed", spend_usd, evidence,
                           f"{note} Gave up after {MAX_ATTEMPTS} attempts.".strip())
        return {"state": "failed", "continuation": None}
    ledger.settle_unit(conn, unit["id"], "incomplete", spend_usd, evidence, note)
    payload = remaining if remaining is not None else unit["payload"]
    cid = ledger.add_unit(conn, unit["analysis_id"], unit["kind"], payload,
                          attempt=attempt, parent=unit["id"])
    return {"state": "incomplete", "continuation": cid}


def lineage_root(conn, unit):
    """The first unit of this unit's lineage -- what the label numbers, and
    what the orchestrator counts a lineage's runs that died by."""
    while unit["parent"]:
        unit = ledger.get_unit(conn, unit["parent"])
    return unit


def label(conn, unit) -> str:
    """"read 7/25", "read 7/25 · attempt 2": the place of the unit's lineage
    among the analysis's first units of its kind, and the attempt."""
    root = lineage_root(conn, unit)
    firsts = [u for u in ledger.units_of(conn, unit["analysis_id"])
              if u["kind"] == unit["kind"] and not u["parent"]]
    place = next((n for n, u in enumerate(firsts, 1) if u["id"] == root["id"]), 0)
    text = f"{unit['kind']} {place}/{len(firsts)}"
    return text if unit["attempt"] == 1 else f"{text} · attempt {unit['attempt']}"
```

- [ ] **Passo 5: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_units.py tests/security/test_ledger_units.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Passo 6: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **An analysis is planned as units the engine runs and judges.** The plan
  is triage batches of 25 rows (the scanners' findings and the agent
  findings the last analysis left open), one reachability pass, and — in a
  deep analysis — one read unit per slice; verification units are planned
  once the rest has settled, one per finding of the analysis. The plan is
  written in one transaction, all of it or none, so a plan cut short can
  never leave slices no unit will read. A unit is judged by what it left:
  the ranges its own stream proves it read (kept on the unit, whatever its
  outcome, as the lines it covered), the rows the ledger shows it triaged,
  the verdict it wrote. What it left undone becomes a new unit carrying
  only what is missing, up to three attempts; a session that launched a
  subagent does not count, whatever kind of unit it was.
```

```bash
/usr/bin/git add bin/security/units.py bin/security/ledger.py tests/security/test_units.py tests/security/test_ledger_units.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): plan an analysis as units and judge each by what it left"
```

---

### Task 6: Os prompts das unidades

**Ficheiros:**
- Modificar: `bin/security/prompts.py` (acrescentar no fim; `verifier_prompt` fica igual)
- Testes: `tests/security/test_unit_prompts.py` (novo)

**Interfaces:**
- Consome: nada de tarefas anteriores (recebe dicionários simples; o CLI da Task 7 é quem os monta a partir do ledger).
- Produz:
  - `prompts.SKILL_DIR` (a pasta `skills/security-analysis` do repositório)
  - `prompts.unit_prompt(analysis, label, platform, kind, context) -> str`, onde:
    - `analysis`: `{"id", "project", "repo", "branch", "commit_sha", "profile"}`
    - `label`: o texto de `units.label` (ex.: `"read 7/25 · attempt 2"`)
    - `platform`: `anthropic` | `openai` | `opencode`
    - `context` por tipo:
      - `triage`: `{"rows": [{"fingerprint", "kind", "category", "rule", "severity", "title", "file", "line", "producer", "occurrences": [{"file", "line"}]}]}` — `file`/`line` são a primeira localização; `occurrences` são **todas** (um re-report substitui a lista guardada, por isso o prompt tem de as mostrar todas)
      - `hunt`: `{"guides": [nome, ...]}`
      - `read`: `{"ranges": [{"path", "first", "last", "bytes"}], "guides": [...], "known": [linha], "decided": [linha]}` (cada `linha`: `{"fingerprint", "category", "rule", "severity", "state", "title", "file", "line"}` — a Task 7 constrói as do `decided` a partir de `queries.decided_sast`, cujas entradas não trazem `category` nem `state`: acrescenta `category="sast"` e o `state` da decisão)
      - `verify`: `{"finding": <linha da verify_queue>}`
  - por plataforma: a skill é **invocada pelo nome** no Claude Code e no OpenCode (no OpenCode também com o caminho, como hoje: o CLI lê `~/.claude/skills`, medido) e **lida pelo caminho** no Codex; a regra dos subagentes diz a ferramenta de cada uma (`Agent`/`Task` fechada no Claude Code, `task` fechada no OpenCode, `spawn_agent` proibido por palavras no Codex)

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_unit_prompts.py`:

```python
# tests/security/test_unit_prompts.py
"""The prompt of each unit: minted from the ledger, one job each, and the reading the platform can prove."""
import pytest

from security import prompts

ANALYSIS = {"id": 21, "project": "web", "repo": "web", "branch": "main",
            "commit_sha": "0123456789abcdef", "profile": "deep"}
ROW = {"fingerprint": "a" * 64, "kind": "scanner", "category": "dependency",
       "rule": "CVE-2024-0001", "severity": "high", "title": "lib 1.0 is vulnerable",
       "file": "composer.lock", "line": 0, "producer": "trivy", "state": "new"}
RANGES = [{"path": "src/Auth/Login.php", "first": 1, "last": 240, "bytes": 9000},
          {"path": "src/Auth/Reset.php", "first": 1, "last": 80, "bytes": 3000}]


def _p(kind, context, platform="anthropic", label=None):
    return prompts.unit_prompt(ANALYSIS, label or f"{kind} 1/1", platform, kind, context)


@pytest.mark.parametrize("kind, context", [
    ("triage", {"rows": [ROW]}),
    ("hunt", {"guides": ["ATTACK-CLASSES"]}),
    ("read", {"ranges": RANGES, "guides": ["ATTACK-CLASSES"], "known": [], "decided": []}),
])
def test_every_unit_names_its_analysis_its_place_and_the_three_rules(kind, context):
    out = _p(kind, context, label=f"{kind} 3/9 · attempt 2")
    assert "SECURITY ANALYSIS 21 · unit " + f"{kind} 3/9 · attempt 2" in out
    assert "branch main · commit 0123456789ab" in out
    assert "agentloop security finish" in out and "Never" in out
    assert "subagent" in out
    assert f'section "Unit: {kind}"' in out


def test_the_skill_is_invoked_by_name_on_claude_code_and_opencode_and_read_by_path_on_codex():
    assert "Invoke the `security-analysis` skill" in _p("hunt", {"guides": []})
    opencode = _p("hunt", {"guides": []}, platform="opencode")
    assert "Invoke the `security-analysis` skill" in opencode, \
        "OpenCode's CLI reads ~/.claude/skills (measured): by name, as before the pipeline"
    assert str(prompts.SKILL_DIR / "SKILL.md") in opencode, "and by path, for a machine where the link is missing"
    codex = _p("hunt", {"guides": []}, platform="openai")
    assert str(prompts.SKILL_DIR / "SKILL.md") in codex
    assert "Invoke the" not in codex


def test_each_platform_is_told_how_its_subagent_tool_is_closed():
    claude = _p("hunt", {"guides": []})
    assert "the `Agent` tool (the CLI's roster calls it `Task`) is closed for this run" in claude
    assert "The `task` tool is closed for this run" in _p("hunt", {"guides": []}, platform="opencode")
    codex = _p("hunt", {"guides": []}, platform="openai")
    assert "Never call `spawn_agent`" in codex
    assert "`Agent`" not in codex and "`task`" not in codex, "the Codex CLI has neither tool"


def test_a_triage_unit_lists_each_row_with_what_it_is():
    carried = dict(ROW, fingerprint="c" * 64, kind="carried", category="sast", rule="xss",
                   producer="agent", file="src/View.php", line=12, title="unescaped name")
    out = _p("triage", {"rows": [ROW, carried]})
    assert "[scanner] " + "a" * 64 + " · dependency/CVE-2024-0001 · high · composer.lock · by trivy" in out
    assert "[carried] " + "c" * 64 + " · sast/xss · high · src/View.php:12 · by agent" in out
    assert "re-report it under the fingerprint given" in out
    assert "agentloop security report-gone" in out and "no `candidate`" in out


def test_a_triage_row_shows_every_location_it_has():
    """A re-report REPLACES the stored locations (ledger.record_finding), so a
    row shown by its first location alone and re-reported "exactly as shown"
    would be narrowed to that one."""
    many = dict(ROW, occurrences=[{"file": "api/composer.lock", "line": 0},
                                  {"file": "web/composer.lock", "line": 4},
                                  {"file": "cli/composer.lock", "line": 0}])
    out = _p("triage", {"rows": [many]})
    assert "locations (3): api/composer.lock, web/composer.lock:4, cli/composer.lock" in out
    assert "EVERY location listed" in out


def test_a_read_unit_lists_its_ranges_and_says_how_reading_is_proven():
    known = [{"fingerprint": "k" * 64, "category": "sast", "rule": "sql-injection", "severity": "high",
              "state": "open", "title": "raw query", "file": "src/Auth/Login.php", "line": 40}]
    decided = [{"fingerprint": "d" * 64, "category": "sast", "rule": "open-redirect", "severity": "low",
                "state": "accepted", "title": "next param", "file": "src/Auth/Reset.php", "line": 7}]
    out = _p("read", {"ranges": RANGES, "guides": ["ATTACK-CLASSES", "WEB-PROTOCOL-AND-AUTH"],
                      "known": known, "decided": decided})
    assert "src/Auth/Login.php:1-240" in out and "src/Auth/Reset.php:1-80" in out
    assert "2 ranges, 12,000 bytes" in out
    assert "Read tool" in out
    assert "k" * 64 + " · sast/sql-injection · high · src/Auth/Login.php:40 — raw query" in out
    assert "d" * 64 + " · sast/open-redirect · accepted · src/Auth/Reset.php:7 — next param" in out
    assert str(prompts.SKILL_DIR / "references" / "WEB-PROTOCOL-AND-AUTH.md") in out
    assert "sink" in out


def test_on_codex_a_read_unit_reads_through_security_read_only():
    out = _p("read", {"ranges": RANGES, "guides": [], "known": [], "decided": []}, platform="openai")
    assert "agentloop security read --path <path> --from <line>" in out
    assert "A `cat` or `sed` of a file proves nothing" in out
    assert "Read tool" not in out


def test_a_hunt_unit_carries_the_profile_s_scope():
    deep = _p("hunt", {"guides": ["ATTACK-CLASSES"]})
    assert "following the calls in depth" in deep
    assert "Other units of this analysis read every file line by line" in deep
    quick = prompts.unit_prompt(dict(ANALYSIS, profile="quick"), "hunt 1/1", "anthropic", "hunt", {"guides": []})
    assert "only code that touches external input" in quick
    assert "line by line" not in quick


def test_a_verify_unit_is_the_verifier_prompt_under_the_unit_header():
    finding = {"fingerprint": "b" * 64, "rule": "xss", "severity": "high", "title": "t",
               "rationale": "PERSUASION", "occurrences": [{"file": "a.py", "line": 3}], "candidate": {}}
    out = _p("verify", {"finding": finding})
    assert out.startswith("SECURITY ANALYSIS 21 · unit verify 1/1")
    assert prompts.verifier_prompt(21, finding) in out
    assert "PERSUASION" not in out
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_unit_prompts.py -p no:cacheprovider -q`
Expected: FAIL — `AttributeError: module 'security.prompts' has no attribute 'unit_prompt'`.

- [ ] **Passo 3: implementar, no fim de `bin/security/prompts.py`**

Acrescentar `from pathlib import Path` aos imports do topo do ficheiro (o módulo hoje não importa nada) e, no fim:

```python
# ---- the unit prompts (security/units.py plans the units; the CLI mints these) ----
#
# ONE JOB PER PROMPT, AND THE ENGINE CHECKS IT. A unit is a fresh session
# given exactly one piece of the analysis. It is told what it owes and how the
# engine will check it -- because the check is what decides whether its work
# counts, and a session that does not know the rule spends the analysis's
# money on reads that prove nothing.

SKILL_DIR = Path(__file__).resolve().parents[2] / "skills" / "security-analysis"

_SCOPE = {
    "quick": ("only code that touches external input: HTTP handlers, CLI entry "
              "points, queue consumers, deserialisation, SQL, exec/eval"),
    "standard": ("the code that touches external input, plus the code those "
                 "reachable paths call, following the calls in depth"),
}
_SCOPE["deep"] = _SCOPE["standard"]


def _skill_line(platform, kind):
    rules = f'its "Rules for every unit" and its section "Unit: {kind}"'
    if platform == "anthropic":
        return f"Invoke the `security-analysis` skill first, then follow {rules}."
    if platform == "opencode":
        # BY NAME, AS BEFORE THE PIPELINE, AND BY PATH BESIDE IT: OpenCode's
        # CLI reads ~/.claude/skills (measured), so its `skill` tool lists
        # this one; the path is for a machine where the link is missing.
        return (f"Invoke the `security-analysis` skill (your `skill` tool lists it; the file "
                f"is {SKILL_DIR / 'SKILL.md'}) first, then follow {rules}.")
    return f"Read {SKILL_DIR / 'SKILL.md'} first, then follow {rules}."


# How each platform's subagent tool is kept out of a unit: closed at launch on
# Claude Code (`--disallowedTools Agent`; the roster calls the same tool
# `Task`) and on OpenCode (`task: deny` in the permission block), forbidden in
# words on the Codex CLI, where nothing closes `spawn_agent` by flag. Named
# per platform so a session is never told about a tool it does not have.
_SUBAGENT_RULE = {
    "anthropic": ["- Never launch a subagent: the `Agent` tool (the CLI's roster calls it `Task`) is closed for this run.",
                  "  The engine distributes the work, and a unit whose stream shows a subagent",
                  "  does not count."],
    "opencode": ["- The `task` tool is closed for this run: never launch a subagent. The engine",
                 "  distributes the work, and a unit whose stream shows one does not count."],
    "openai": ["- Never call `spawn_agent`: nothing closes it by flag on this CLI, so this line",
               "  is the rule. The engine distributes the work, and a unit that launches a",
               "  subagent does not count."],
}


def _guides_line(names):
    if not names:
        return []
    paths = ", ".join(str(SKILL_DIR / "references" / f"{name}.md") for name in names)
    return ["", f"GUIDES: read {paths} before the code, in that order."]


def _where(row):
    return f"{row['file']}:{row['line']}" if row.get("line") else (row.get("file") or "(no file)")


def _header(analysis, label, platform, kind):
    return [
        f"SECURITY ANALYSIS {analysis['id']} · unit {label}",
        f"project {analysis['project']} · repository {analysis['repo']} · branch "
        f"{analysis['branch']} · commit {analysis['commit_sha'][:12]} · profile {analysis['profile']}",
        "",
        "You are one unit of an analysis the engine runs as a pipeline of sessions. Do",
        "this unit's job and nothing else: other units cover the rest, and the engine",
        "checks what you did against your own tool calls and the ledger -- never",
        "against what you say.",
        "",
        _skill_line(platform, kind),
        "- Never run `agentloop security finish`: the engine closes the analysis.",
        *_SUBAGENT_RULE.get(platform, _SUBAGENT_RULE["openai"]),
        "- Report only through `agentloop security report-finding` (and, in a verify",
        "  unit, `report-verdict`), exactly as the skill shows.",
        "",
    ]


def _row(row, with_producer=False):
    text = (f"{row['fingerprint']} · {row['category']}/{row['rule']} · "
            f"{row.get('state') if row.get('state') in ('accepted', 'false_positive') else row['severity']} · {_where(row)}")
    return text + (f" · by {row.get('producer') or 'unknown'}" if with_producer else "")


def _triage(context):
    rows = context.get("rows") or []
    lines = [
        f"YOUR JOB: triage these {len(rows)} rows. Read the code at each location first.",
        "A re-report REPLACES a row's stored locations: a location you leave out is",
        "dropped from the report.",
        "- A [scanner] row: re-report it under the fingerprint given, with your own",
        "  severity, rationale and `candidate.confidence`, and every location still",
        "  affected. A row at medium or above that you do not re-report keeps this",
        "  unit open, and another session is sent for it.",
        "- A [carried] row is one the previous analysis recorded and nothing re-found",
        "  this time. If it is NOT `sast` (secret, dependency, hygiene, iac), its",
        "  producer did not run: re-report it exactly as shown -- same fingerprint,",
        "  category, rule, severity, title and EVERY location listed, with no `candidate`",
        "  -- or it vanishes from the next baseline. If it IS `sast`, read the code:",
        "  still there -> re-report it under the fingerprint given, with the full",
        "  `candidate`; genuinely gone -> say so, with the reason, through",
        "  `agentloop security report-gone --analysis <id> --fingerprint <fp>`",
        "  (stdin: {\"reason\": \"...\"}). Silence proves nothing and keeps this",
        "  unit open.",
        "",
        "ROWS",
    ]
    for n, row in enumerate(rows, 1):
        lines.append(f"  {n}. [{row['kind']}] {_row(row, with_producer=True)}")
        lines.append(f"     {row.get('title', '')}")
        places = row.get("occurrences") or []
        if places:
            lines.append(f"     locations ({len(places)}): " + ", ".join(_where(o) for o in places))
    return lines


def _hunt(analysis, context):
    profile = analysis["profile"]
    lines = [f"YOUR JOB: the {profile} pass -- {_SCOPE.get(profile, _SCOPE['standard'])}."]
    if profile == "deep":
        lines += ["Other units of this analysis read every file line by line; your part is",
                  "reachability: the entry points, and the flows that cross files."]
    return lines + _guides_line(context.get("guides") or [])


def _read(platform, context):
    ranges = context.get("ranges") or []
    total = sum(int(r.get("bytes") or 0) for r in ranges)
    if platform == "openai":
        how = [
            "HOW READING IS PROVEN: read with `agentloop security read --path <path> --from <line>`,",
            "one call per chunk. It prints up to 200 numbered lines and the command for the",
            "next chunk, and it is the only reading this analysis can prove on this",
            "platform. A `cat` or `sed` of a file proves nothing.",
        ]
    else:
        how = [
            "HOW READING IS PROVEN: use your Read tool. A range counts when your Read",
            "results show every one of its lines -- a read cut short by the tool (a token",
            "cap, an offset past the end) counts only what came back, so continue from",
            "where it stopped. `agentloop security read --path <path> --from <line>`",
            "counts too.",
        ]
    lines = [
        "YOUR JOB: read every line of the ranges below, in full, and report every",
        "weakness you find in them.",
        "",
        *how,
        "A range you do not finish is read again by another session, at this",
        "analysis's cost.",
        "",
        f"RANGES ({len(ranges)} range{'s' if len(ranges) != 1 else ''}, {total:,} bytes)",
        *[f"  {r['path']}:{r['first']}-{r['last']}" for r in ranges],
    ]
    known = context.get("known") or []
    if known:
        lines += ["", "ALREADY RECORDED IN THESE FILES -- fold into these fingerprints; never mint",
                  "a second identity for a weakness listed here:"]
        lines += [f"  {_row(row)} — {row.get('title', '')}" for row in known]
    decided = context.get("decided") or []
    if decided:
        lines += ["", "DECIDED BY THE OPERATOR IN THESE FILES -- fold only the same flaw in the same",
                  "place, under this fingerprint and rule:"]
        lines += [f"  {_row(row)} — {row.get('title', '')}" for row in decided]
    lines += ["", "Report a weakness at the file of its sink -- where the vulnerable operation",
              "happens. Follow a trace into other files when you need to; your obligation is",
              "these ranges."]
    return lines + _guides_line(context.get("guides") or [])


def unit_prompt(analysis, label, platform, kind, context) -> str:
    """The whole prompt of one unit. The run-ending contract is appended by
    the engine (`run_ending_contract` in bin/agentloop), as for every run."""
    lines = _header(analysis, label, platform, kind)
    if kind == "triage":
        lines += _triage(context)
    elif kind == "hunt":
        lines += _hunt(analysis, context)
    elif kind == "read":
        lines += _read(platform, context)
    elif kind == "verify":
        lines.append(verifier_prompt(analysis["id"], context["finding"]))
    else:
        raise ValueError(f"no prompt for unit kind {kind!r}")
    lines += ["", "End with a short summary of what this unit did: what you reported, and",
              "anything in your job you could not do."]
    return "\n".join(lines)
```

Nota ao implementador: `_row` usa o estado em vez da severidade só para linhas decididas (`accepted`/`false_positive`), que é o que o teste do `decided` espera; nas outras mostra a severidade.

- [ ] **Passo 4: correr e ver passar, com os testes do prompt do verificador**

Run: `python3.13 -m pytest tests/security/test_unit_prompts.py tests/security/test_prompts.py -p no:cacheprovider -q`
Expected: PASS.

- [ ] **Passo 5: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **Each unit of an analysis is given one job, and told how it is checked.**
  The CLI mints the prompt of every unit from the ledger: a triage unit's
  rows with every location each one has (a re-report replaces the stored
  list), a read unit's line ranges with the rows already recorded in those
  files and the hunting guides its files call for, a hunt unit's profile,
  a verify unit's finding. Every prompt forbids closing the analysis and
  names the subagent tool its platform closes, invokes the skill by name on
  Claude Code and OpenCode (by path on Codex), and says how its work is
  proven — on Codex, where no shell read can be proven from the stream, a
  read unit reads through `agentloop security read`.
```

```bash
/usr/bin/git add bin/security/prompts.py tests/security/test_unit_prompts.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): mint one prompt per unit, each saying how its work is checked"
```

---

### Task 7: O CLI das unidades — `prepare` planeia, `unit-prompt`, `unit-close`, `units`, `read`

**Ficheiros:**
- Modificar: `bin/security/cli.py` (import da linha ~45; `cmd_prepare` ~1450-1619; verbos novos a seguir a `cmd_report_verdict` ~1704; subparsers a seguir ao de `report-verdict` ~3690; `--plan` no subparser do `prepare` ~3652)
- Modificar: `bin/security/units.py` (acrescentar `_lineages`, `owed`, `summary` e `close`)
- Testes: `tests/security/test_cli_units.py` (novo), `tests/security/test_units.py` (os testes de `owed`, `summary` e `close`)

**Interfaces:**
- Consome: Tasks 1–6 (`ledger.inventory_of(conn, analysis_id)`, `ledger.add_units` via `units.plan`, `evidence["covered"]` das unidades `read`).
- Produz (verbos, todos com `--db` e prontos para o motor da Task 11):
  - `security prepare … --plan` → só com `--plan` o `prepare` planeia (é o que o orquestrador da Task 10 passa); sem ele não planeia nada, como antes do pipeline. Um plano que falha sai com código ≠ 0, o motivo no stderr, nenhum JSON no stdout e nenhuma unidade escrita (os resultados das fases ficam: são desta análise)
  - `security unit-prompt --analysis N --unit U --platform P` → imprime o prompt (texto)
  - `security unit-close --analysis N --unit U [--stream F] [--root R] [--status S] [--reason T] [--spend X]` → imprime `{"state", "continuation"}` (é `units.close`); um segundo fecho da mesma unidade não faz nada e imprime `{"state": <o que já está>, "continuation": null}`
  - `security units --analysis N [--label U]` → o JSON de `units.summary`, ou só o rótulo da unidade `U`
  - `security read --path P [--from A]` → linhas numeradas (`N\t...`), até `READ_LINES = 200` linhas ou `READ_BYTES = 8000` bytes; lê `AL_SECURITY_ANALYSIS_ID`, `AL_SECURITY_UNIT_ID` e `AL_RUN_CWD` do ambiente; regista o bloco em `unit_read` depois de o imprimir
  - `units.close(conn, unit, *, stream="", root="", status="error", reason="", spend_usd=0.0) -> {"state", "continuation"}` — o fecho de UMA corrida de uma unidade (o stream, o que `security read` lhe serviu, o ledger → `judge` → `conclude`); o único caminho, usado pelo `unit-close` e pelo orquestrador (Task 10) para um run que morreu sem fechar
  - `units.owed(conn, analysis_id, all_units=None, inventory=None) -> list[{"path", "first", "last"}]` — a dívida do `deep`: cada intervalo do inventário menos a união dos `covered` de todas as unidades `read` da análise, qualquer que seja o seu estado; `[]` sem inventário. A única conta da dívida (o `summary` e, na Task 9, o `gaps` usam-na)
  - `units.summary(conn, analysis_id) -> dict | None`: `{"kinds": {kind: {"total", "done", "running", "pending", "failed"}}, "deep": {"files", "files_read", "lines", "lines_read"} | None, "spend_usd", "units"}` (`None` num ledger sem a tabela; o `deep` sai de `owed`)
  - `units._lineages(all_units) -> list[(root, last)]` (a Task 9 reutiliza-o)
  - o JSON do `prepare` ganha `"units": <quantas planeou>` (0 sem `--plan`)
  - `security report-gone --analysis N --fingerprint FP` (stdin `{"reason": "..."}`) → regista em `unit_gone`; aceite só numa sessão de agente cuja unidade (`AL_SECURITY_UNIT_ID`) seja uma `triage` desta análise, em curso, com `FP` entre os seus itens `carried` de categoria `sast`

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_cli_units.py`:

```python
# tests/security/test_cli_units.py
"""The CLI of the pipeline's units: the plan prepare writes, the prompt, the close, the progress, the reader."""
import json
import os
import subprocess
import sys

import pytest
from test_cli import CLI, fails, open_analysis, raw, run  # noqa: F401 -- the suite's own helpers

from security import cli as security_cli
from security import ledger
from security import units as security_units

GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def _repo(tmp_path, files):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=GIT_ENV)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    return root


def _deep(db, tmp_path, files):
    """A deep analysis prepared the way its orchestrator prepares it: with
    `--plan`, the one flag that makes `prepare` write the plan."""
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, files)
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline", "--plan")
    return aid, root, out


def _units(db, aid):
    conn = ledger.connect(db)
    try:
        return ledger.units_of(conn, aid)
    finally:
        conn.close()


def _unit(db, aid, kind):
    """The first unit of `kind`. Never by position: an offline prepare can
    still record hygiene rows, and their triage units come first."""
    return next(u for u in _units(db, aid) if u["kind"] == kind)


def test_a_deep_prepare_lists_the_scope_and_plans_a_hunt_and_the_reads(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, out = _deep(db, tmp_path, {"src/a.py": "x = 1\n", "docs/readme.md": "# t\n"})
    assert out["units"] == len(_units(db, aid))
    assert [u["kind"] for u in _units(db, aid) if u["kind"] != "triage"] == ["hunt", "read"]
    read = _unit(db, aid, "read")
    assert read["payload"]["ranges"] == [{"path": "src/a.py", "first": 1, "last": 1, "bytes": 6}]
    assert read["payload"]["guides"][0] == "ATTACK-CLASSES"
    assert "The deep scope is 1 file (1 line, 6 bytes)" in out["coverage_note"]
    assert "prose documents: 1 (e.g. docs/readme.md)" in out["coverage_note"]


def test_a_quick_prepare_plans_a_hunt_and_no_reads(tmp_path):
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline", "--plan")
    assert [u["kind"] for u in _units(db, aid) if u["kind"] != "triage"] == ["hunt"]
    assert "deep scope" not in out["coverage_note"]


def test_a_prepare_without_plan_plans_nothing(tmp_path):
    """ONLY A PIPELINE ANALYSIS PLANS. The orchestrator's prepare passes
    --plan; a hand run, the selftest's own fixtures and every test that
    prepares an analysis to exercise something else get the deterministic
    phase and no unit, exactly as before the pipeline -- so none of them can
    meet a planning failure it was not written about."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    assert (out["units"], _units(db, aid)) == (0, [])
    assert "The deep scope is 1 file" in out["coverage_note"], "the scope is still listed"


def test_a_plan_that_fails_fails_prepare_loudly_and_leaves_no_unit(tmp_path, monkeypatch, capsys):
    """A planning failure is never reported as success: non-zero, the reason
    on stderr, no JSON, and no half of a plan -- ledger.add_units writes all
    of it or none. The phases' results stay: they are this analysis's, and
    the orchestrator closes it `capped` rather than paying for them twice.
    In-process, the way this suite's other prepare failures are, because a
    subprocess cannot be monkeypatched."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})

    def broken(*_a, **_k):
        raise RuntimeError("the checklist could not be read")
    monkeypatch.setattr(security_units, "triage_items", broken)
    with pytest.raises(SystemExit) as refused:
        security_cli.main(["prepare", "--analysis", str(aid), "--root", str(root), "--offline",
                           "--plan", "--db", str(db)])
    assert refused.value.code not in (0, None)
    assert "could not be planned" in str(refused.value.code)
    assert "RuntimeError" in str(refused.value.code)
    assert capsys.readouterr().out == "", "no JSON: a failed plan is not an analysis ready to run"
    assert _units(db, aid) == []
    assert run(db, "analysis", "--id", str(aid))["prepared"] == 1


def test_the_deep_scope_sentence_keeps_the_scope_row_a_substring_of_the_paragraph(tmp_path):
    """The invariant test_every_phases_prose_is_a_substring_of_the_paragraph
    (test_cli.py) pins for a quick prepare, on the deep one: the inventory
    sentence is filed under `scope`, so it has to stand beside the scope's
    other sentences at the head of the paragraph -- appended after the
    secret phase's notes, the scope row stopped being one run of it."""
    db = tmp_path / "security.db"
    aid, _root, out = _deep(db, tmp_path, {"src/a.py": "x = 1\n"})
    phases = json.loads(run(db, "analysis", "--id", str(aid))["coverage"])["phases"]
    notes = {p["name"]: p["note"] for p in phases}
    assert "The deep scope is 1 file" in notes["scope"]
    # The scope row is the paragraph's head, whatever the secret phase has to
    # say -- in this suite's engines-off configuration it says which scanner
    # ran, which is what used to sit between the scope's sentences.
    assert out["coverage_note"].startswith(notes["scope"])
    for name, note in notes.items():
        assert note in out["coverage_note"], f"{name}'s note is not in the paragraph: {note!r}"


def test_unit_prompt_prints_the_minted_prompt(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "x = 1\n"})
    read = _unit(db, aid, "read")
    text = raw(db, "unit-prompt", "--analysis", str(aid), "--unit", str(read["id"]), "--platform", "anthropic")
    assert f"SECURITY ANALYSIS {aid} · unit read 1/1" in text
    assert "src/a.py:1-1" in text


def _prompt(db, aid, uid):
    return raw(db, "unit-prompt", "--analysis", str(aid), "--unit", str(uid), "--platform", "anthropic")


def test_a_triage_prompt_lists_every_location_of_its_row(tmp_path):
    """A re-report REPLACES the stored locations, and the prompt asks for the
    row "exactly as shown": shown by its first location alone, a row of three
    would be narrowed to one."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    ledger.record_finding(conn, aid, {
        "fingerprint": "f" * 64, "category": "dependency", "rule": "CVE-2024-0001", "severity": "high",
        "title": "lib 1.0 is vulnerable", "producer": "trivy",
        "occurrences": [{"file": "api/composer.lock", "line": 0}, {"file": "web/composer.lock", "line": 0},
                        {"file": "cli/composer.lock", "line": 0}]})
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "f" * 64, "kind": "scanner", "category": "dependency"}]})
    text = _prompt(db, aid, uid)
    assert "locations (3): " in text
    for place in ("api/composer.lock", "web/composer.lock", "cli/composer.lock"):
        assert place in text


def test_a_read_prompt_names_a_decision_by_its_category_and_its_state(tmp_path):
    """`queries.decided_sast` entries carry neither `category` nor `state` --
    the real shape, produced here by a real decision on another branch, not a
    row built by hand with the two keys already in it."""
    db = tmp_path / "security.db"
    conn = ledger.connect(db)
    old = ledger.start_analysis(conn, "web", "web", "develop", "c0", "deep", "security-web")
    ledger.record_finding(conn, old, {
        "fingerprint": "d" * 64, "category": "sast", "rule": "open-redirect", "severity": "low",
        "title": "next param", "producer": "agent", "occurrences": [{"file": "src/a.py", "line": 1}]})
    ledger.finish_analysis(conn, old, "done")
    ledger.set_decision(conn, "web", "d" * 64, "accepted", "known and accepted", "operator")
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    text = _prompt(db, aid, _unit(db, aid, "read")["id"])
    assert "d" * 64 + " · sast/open-redirect · accepted · src/a.py:1 — next param" in text


def test_a_read_prompt_carries_what_the_operator_decided_on_this_branch(tmp_path):
    """A row the checklist lists with a decision is not open -- so `known`
    left it out -- and `decided_sast` leaves out whatever the checklist lists:
    a decision on this branch reached the unit from nowhere, and the unit
    minted the weakness again under a second identity."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    ledger.record_finding(conn, aid, {
        "fingerprint": "e" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "unescaped name", "producer": "agent", "occurrences": [{"file": "src/a.py", "line": 1}]})
    ledger.set_decision(conn, "web", "e" * 64, "false_positive", "escaped by the template", "operator")
    text = _prompt(db, aid, _unit(db, aid, "read")["id"])
    assert "e" * 64 + " · sast/xss · false_positive · src/a.py:1 — unescaped name" in text


def _stream(tmp_path, root, path, first, last):
    events = [
        {"type": "system", "subtype": "init", "cwd": str(root)},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Read",
                                                        "input": {"file_path": str(root / path)}}]},
         "parent_tool_use_id": None},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                                                   "content": "".join(f"{n}\tx\n" for n in range(first, last + 1))}]},
         "parent_tool_use_id": None,
         "tool_use_result": {"type": "text", "file": {"filePath": str(root / path), "startLine": first,
                                                      "numLines": last - first + 1, "totalLines": last}}},
    ]
    stream = tmp_path / f"stream-{path.replace('/', '_')}-{first}.ndjson"
    stream.write_text("".join(json.dumps(e) + "\n" for e in events))
    return stream


def test_unit_close_settles_a_read_the_stream_proves_and_a_second_close_is_a_no_op(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\nc\n"})
    read = _unit(db, aid, "read")
    stream = _stream(tmp_path, root, "src/a.py", 1, 3)
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--stream", str(stream),
              "--root", str(root), "--status", "success", "--spend", "0.75")
    assert out == {"state": "done", "continuation": None}
    unit = _unit(db, aid, "read")
    assert (unit["state"], unit["spend_usd"]) == ("done", 0.75)
    again = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--status", "success")
    assert again == {"state": "done", "continuation": None}
    assert _unit(db, aid, "read")["spend_usd"] == 0.75


def test_unit_close_continues_what_a_read_left(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\nc\nd\n"})
    read = _unit(db, aid, "read")
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]),
              "--stream", str(_stream(tmp_path, root, "src/a.py", 1, 2)), "--root", str(root), "--status", "success")
    assert out["state"] == "incomplete"
    cont = next(u for u in _units(db, aid) if u["id"] == out["continuation"])
    assert (cont["attempt"], cont["payload"]["ranges"]) == (2, [{"path": "src/a.py", "first": 3, "last": 4, "bytes": 0}])


def test_unit_close_after_a_stop_keeps_the_attempt(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--status", "stopped")
    cont = next(u for u in _units(db, aid) if u["id"] == out["continuation"])
    assert cont["attempt"] == 1


def test_unit_close_refuses_a_unit_of_another_analysis(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    other = open_analysis(db, profile="deep", commit="def", run_id="r2")
    hunt = _unit(db, aid, "hunt")
    out = fails(db, "unit-close", "--analysis", str(other), "--unit", str(hunt["id"]), "--status", "success")
    assert out.returncode != 0 and "is not a unit of analysis" in out.stderr
    assert _unit(db, aid, "hunt")["state"] == "pending"


def _reader_env(aid, uid, root):
    return {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
            "AL_SECURITY_UNIT_ID": str(uid), "AL_RUN_CWD": str(root)}


def test_security_read_serves_numbered_chunks_and_records_them(tmp_path):
    db = tmp_path / "security.db"
    body = "".join(f"line {n}\n" for n in range(1, 251))
    aid, root, _ = _deep(db, tmp_path, {"src/big.py": body})
    read = _unit(db, aid, "read")
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/big.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    assert out.stdout.splitlines()[0] == "== src/big.py lines 1-200 of 250 =="
    assert out.stdout.splitlines()[1] == "1\tline 1"
    assert "-- next: agentloop security read --path src/big.py --from 201" in out.stdout
    nxt = subprocess.run([sys.executable, str(CLI), "read", "--path", str(root / "src/big.py"), "--from", "201",
                          "--db", str(db)], capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert "-- end of file" in nxt.stdout
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [("src/big.py", 1, 200), ("src/big.py", 201, 250)]


def test_security_read_stops_at_the_byte_budget(tmp_path):
    db = tmp_path / "security.db"
    body = "".join("y" * 199 + "\n" for _ in range(100))   # 200 bytes a line
    aid, root, _ = _deep(db, tmp_path, {"src/wide.py": body})
    read = _unit(db, aid, "read")
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/wide.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.stdout.splitlines()[0] == "== src/wide.py lines 1-40 of 100 =="


def test_security_read_refuses_outside_a_unit_and_outside_the_run(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    no_unit = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                             capture_output=True, text=True,
                             env={k: v for k, v in _reader_env(aid, read["id"], root).items()
                                  if k != "AL_SECURITY_UNIT_ID"})
    assert no_unit.returncode != 0 and "only a unit of an analysis" in no_unit.stderr
    outside = subprocess.run([sys.executable, str(CLI), "read", "--path", "/etc/hosts", "--db", str(db)],
                             capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert outside.returncode != 0 and "outside this run" in outside.stderr


def test_what_security_read_served_counts_at_the_close(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\n"})
    read = _unit(db, aid, "read")
    subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                   capture_output=True, text=True, env=_reader_env(aid, read["id"], root), check=True)
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--root", str(root),
              "--status", "success")
    assert out["state"] == "done"


def test_report_gone_is_accepted_only_for_a_carried_sast_row_of_the_session_s_triage_unit(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"},
        {"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]})
    ledger.start_unit(conn, uid)
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(uid)}
    ok = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                         "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                        text=True, input=json.dumps({"reason": "the handler was deleted in this commit"}))
    assert ok.returncode == 0, ok.stderr
    assert ledger.gone_in(conn, aid) == {"c" * 64}
    for fp, reason in (("d" * 64, "r"), ("c" * 64, "")):
        bad = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                              "--fingerprint", fp, "--db", str(db)], env=env, capture_output=True,
                             text=True, input=json.dumps({"reason": reason}))
        assert bad.returncode != 0


def test_units_prints_the_progress_and_a_unit_s_label(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n", "src/b.py": "b\n"})
    summary = run(db, "units", "--analysis", str(aid))
    assert summary["kinds"]["read"] == {"total": 1, "done": 0, "running": 0, "pending": 1, "failed": 0}
    assert summary["deep"] == {"files": 2, "files_read": 0, "lines": 2, "lines_read": 0}
    hunt = _unit(db, aid, "hunt")
    assert raw(db, "units", "--analysis", str(aid), "--label", str(hunt["id"])).strip() == "hunt 1/1"
```

No fim de `tests/security/test_units.py`:

```python
def test_the_summary_counts_lineages_by_their_last_attempt_and_the_lines_still_owed(conn):
    aid = _analysis(conn)
    ledger.set_inventory(conn, aid, {"files": [_file("a.py", (1, 10, 100)), _file("b.py", (1, 5, 50))],
                                     "excluded": {}, "git": True,
                                     "totals": {"files": 2, "lines": 15, "bytes": 150}})
    first = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    other = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "b.py", "first": 1, "last": 5, "bytes": 50}]})
    ledger.settle_unit(conn, first, "incomplete", 1.0, {"covered": {"a.py": [[1, 5]]}})
    ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 6, "last": 10, "bytes": 0}]},
                    attempt=2, parent=first)
    ledger.settle_unit(conn, other, "done", 0.5, {"covered": {"b.py": [[1, 5]]}})
    s = units.summary(conn, aid)
    assert s["kinds"]["read"] == {"total": 2, "done": 1, "running": 0, "pending": 1, "failed": 0}
    assert s["deep"] == {"files": 2, "files_read": 1, "lines": 15, "lines_read": 10}
    assert (s["spend_usd"], s["units"]) == (1.5, 3)


def test_owed_is_the_inventory_minus_every_span_a_read_unit_proved(conn):
    """FROM THE INVENTORY, NOT FROM THE UNITS: a file no unit carries is owed
    whole, a unit that gave up without saying what it missed owes its whole
    slice, and what a unit covered counts whatever state it ended in."""
    aid = _analysis(conn)
    ledger.set_inventory(conn, aid, {
        "files": [_file("a.py", (1, 20, 200)), _file("b.py", (1, 5, 50)), _file("c.py", (1, 3, 30)),
                  _file("d.py", (1, 4, 40))],
        "excluded": {}, "git": True, "totals": {"files": 4, "lines": 32, "bytes": 320}})
    first = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 20, "bytes": 200}]})
    ledger.settle_unit(conn, first, "incomplete", 0, {"covered": {"a.py": [[1, 10]]}})
    cont = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 11, "last": 20, "bytes": 0}]},
                           attempt=2, parent=first)
    ledger.settle_unit(conn, cont, "failed", 0, {"covered": {"a.py": [[11, 14]]}})
    other = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "b.py", "first": 1, "last": 5, "bytes": 50}]})
    ledger.settle_unit(conn, other, "done", 0, {"covered": {"b.py": [[1, 5]]}})
    silent = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "d.py", "first": 1, "last": 4, "bytes": 40}]})
    ledger.settle_unit(conn, silent, "failed", 0, {})        # a crash, a subagent, a strike-out
    # c.py is in no unit at all: a plan an older engine cut short, a unit lost
    assert units.owed(conn, aid) == [{"path": "a.py", "first": 15, "last": 20},
                                     {"path": "c.py", "first": 1, "last": 3},
                                     {"path": "d.py", "first": 1, "last": 4}]
    assert units.owed(conn, _analysis(conn)) == [], "no inventory, no debt"


def test_close_judges_a_run_and_settles_its_unit_once(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 3, "bytes": 9}]})
    ledger.start_unit(conn, uid)
    ledger.record_unit_read(conn, uid, "a.py", 1, 3)       # what `security read` served it
    out = units.close(conn, ledger.get_unit(conn, uid), status="success", spend_usd=0.5)
    assert out == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["evidence"]["covered"] == {"a.py": [[1, 3]]}
    again = units.close(conn, ledger.get_unit(conn, uid), status="error", spend_usd=9)
    assert again == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["spend_usd"] == 0.5, "a settled unit is never closed twice"
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_cli_units.py tests/security/test_units.py -p no:cacheprovider -q`
Expected: FAIL — `unrecognized arguments: --plan` / `invalid choice: 'unit-close'` / `KeyError: 'units'` / `AttributeError: ... 'summary'`, `'owed'`, `'close'`.

- [ ] **Passo 3: `_lineages`, `owed`, `summary` e `close`, no fim de `bin/security/units.py`**

```python
def _lineages(all_units):
    """(root, last attempt) for every lineage, in the order of the roots --
    how a unit that was continued is counted: by where its lineage ended."""
    children = {}
    for u in all_units:
        if u["parent"]:
            children.setdefault(u["parent"], []).append(u)
    out = []
    for root in (u for u in all_units if not u["parent"]):
        last = root
        while children.get(last["id"]):
            last = max(children[last["id"]], key=lambda c: c["seq"])
        out.append((root, last))
    return out


def owed(conn, analysis_id, all_units=None, inventory=None) -> list:
    """The deep scope's lines no read unit proved it read, as
    [{"path", "first", "last"}] in inventory order: every range of the
    inventory minus the union of the `covered` spans the read units of this
    analysis recorded (`_judge_read`), WHATEVER THEIR STATE.

    FROM THE INVENTORY, NOT FROM THE UNITS. Counting what each lineage's last
    attempt still carried left out everything no unit carries -- a slice a
    plan cut short never got -- and everything a unit gave up on without
    naming it: a crash, a subagent, three runs the engine could not finish
    all settle with no `missing`, and each read "in full". A unit that
    covered nothing proved nothing. THE ONE COMPUTATION OF THE DEBT: `summary`
    reads it for the page, and the close (`gaps`, security/units.py) for the
    report."""
    if inventory is None:
        inventory = ledger.inventory_of(conn, analysis_id)
    if not inventory:
        return []
    if all_units is None:
        all_units = ledger.units_of(conn, analysis_id)
    covered = {}
    for u in all_units:
        spans = u["evidence"].get("covered") if u["kind"] == "read" else None
        if not isinstance(spans, dict):
            continue
        for path, pairs in spans.items():
            for pair in pairs if isinstance(pairs, list) else []:
                try:
                    covered.setdefault(path, []).append((int(pair[0]), int(pair[1])))
                except (TypeError, ValueError, IndexError):
                    continue    # a cell nobody could have written: it proves nothing
    merged = {path: _merge_spans(spans) for path, spans in covered.items()}
    out = []
    for f in inventory.get("files") or []:
        for rng in f.get("ranges") or []:
            first, last = int(rng[0]), int(rng[1])
            cursor = first
            for a, b in merged.get(f["path"], []):
                if b < cursor or a > last:
                    continue
                if a > cursor:
                    out.append({"path": f["path"], "first": cursor, "last": a - 1})
                cursor = max(cursor, b + 1)
                if cursor > last:
                    break
            if cursor <= last:
                out.append({"path": f["path"], "first": cursor, "last": last})
    return out


def summary(conn, analysis_id):
    """What the page shows while an analysis runs and after it: per kind, how
    many lineages are done, running, waiting or given up (each judged by its
    LAST attempt); in a deep analysis, how much of the inventory has been
    read (`owed`); and what the units cost. None on a ledger that predates the
    unit table -- the read-only paths never migrate."""
    try:
        all_units = ledger.units_of(conn, analysis_id)
    except sqlite3.OperationalError:
        return None
    lineages = _lineages(all_units)
    kinds = {}
    for kind in ledger.UNIT_KINDS:
        lasts = [last for root, last in lineages if root["kind"] == kind]
        if not lasts:
            continue
        counts = {"total": len(lasts), "done": 0, "running": 0, "pending": 0, "failed": 0}
        for last in lasts:
            state = last["state"]
            counts[state if state in ("done", "running", "failed") else "pending"] += 1
        kinds[kind] = counts
    deep = None
    inventory = ledger.inventory_of(conn, analysis_id)
    if inventory:
        left = owed(conn, analysis_id, all_units, inventory)
        paths_left = {s["path"] for s in left}
        lines = int((inventory.get("totals") or {}).get("lines", 0))
        files = inventory.get("files") or []
        deep = {"files": len(files),
                "files_read": sum(1 for f in files if f["path"] not in paths_left),
                "lines": lines,
                "lines_read": lines - sum(s["last"] - s["first"] + 1 for s in left)}
    return {"kinds": kinds, "deep": deep, "units": len(all_units),
            "spend_usd": round(sum(u["spend_usd"] for u in all_units), 4)}


def close(conn, unit, *, stream="", root="", status="error", reason="", spend_usd=0.0) -> dict:
    """Judge one run of `unit` by what it left -- its stream, what `security
    read` served it, the ledger -- and conclude it. {"state", "continuation"}.

    THE ONE CLOSE OF A UNIT. The engine's `unit-close` (a run that ended) and
    the orchestrator (a run that died without closing, security/orchestrator.py)
    both come here, so a unit is judged the same way whichever of them saw its
    run end. A unit already settled is left exactly as it is: the orchestrator
    closes a unit whose run died before its own close could."""
    if unit["state"] not in ("pending", "running"):
        return {"state": unit["state"], "continuation": None}
    session = evidence.read_session(stream or None, root or ".")
    session = evidence.with_served(session, ledger.unit_reads(conn, unit["id"]))
    done, remaining, ev, note = judge(conn, unit, session, status, reason)
    return conclude(conn, unit, done=done, evidence=ev, note=note, spend_usd=spend_usd,
                    remaining=remaining, stopped=status == "stopped")
```

Acrescentar `import sqlite3` ao topo de `units.py`.

- [ ] **Passo 4: o `prepare` lista o âmbito e planeia**

Em `bin/security/cli.py`, no import da linha ~45, acrescentar `inventory, units` à lista (por ordem alfabética, como está). O `cli.py` não precisa de `evidence` nem de `slices`: o fecho de uma unidade é `units.close`.

O bloco dos guias (a seguir a `recommended, guides_note = guides.recommend(...)`, ~linha 1450) passa a ser este, com o inventário logo a seguir:

```python
    recommended, guides_note = guides.recommend(root, ignore, components, row["profile"])
    # THE SCOPE ROW'S SENTENCES STAND TOGETHER AT THE HEAD OF THE PARAGRAPH.
    # `notes` already opens with the switch and noise-filter sentences (the
    # two inserts above), and the scope row's note is those plus the two
    # below, joined: appended after the secret phase's notes instead, the row
    # stopped being one contiguous run of the paragraph -- the invariant
    # test_every_phases_prose_is_a_substring_of_the_paragraph pins, and
    # test_the_deep_scope_sentence_keeps_the_scope_row_a_substring_of_the_paragraph
    # (test_cli_units.py) pins for the deep case. So each goes in right after
    # the scope sentences already there, in the order the row carries them.
    if guides_note:
        notes.insert(len(scope_notes), guides_note)
        scope_notes.append(guides_note)
        print(f"prepare: {guides_note}", file=sys.stderr)
    # THE DEEP SCOPE, listed before any unit reads a line of it -- see
    # security/inventory.py. Filed under `scope` like the guides: it is what
    # this analysis was set up to read.
    deep_inventory = None
    if row["profile"] == "deep":
        deep_inventory = inventory.build(root, ignore)
        inventory_note = inventory.summary(deep_inventory)
        notes.insert(len(scope_notes), inventory_note)
        scope_notes.append(inventory_note)
```

(Isto substitui o `if guides_note: notes.append(...)` de hoje: o `append` punha a frase dos guias depois das notas dos segredos, o mesmo defeito, até aqui escondido por só acontecer quando a selecção dos guias falha.)

No fim de `cmd_prepare`, substituir as quatro últimas linhas (de `ledger.set_guides(...)` ao `print(...)`) por:

```python
    ledger.set_guides(conn, aid, recommended=recommended)
    if deep_inventory is not None:
        ledger.set_inventory(conn, aid, deep_inventory)
    ledger.mark_prepared(conn, aid, produced)
    # THE PLAN -- only for an analysis the engine runs as a pipeline: the one
    # its orchestrator prepares, which passes --plan. A hand run, the
    # selftest's fixtures and every test that prepares an analysis to exercise
    # something else plan nothing, as before the pipeline, so none of them can
    # meet a planning failure it was not written about.
    #
    # After `prepared`: the checklist the triage units are drawn from
    # classifies what the last analysis left by what THIS one ran, and until
    # `mark_prepared` it cannot know. ALL OR NOTHING (ledger.add_units), and a
    # plan that fails fails LOUDLY -- non-zero, the reason on stderr, no JSON
    # on stdout. It used to be swallowed and printed as success with no units
    # (and a kill mid-plan left half a plan `plan` then refused to complete):
    # the analysis closed `done` with slices nobody read. The phases' results
    # stay, because they are this analysis's and running them again would pay
    # for them twice; the orchestrator closes the analysis `capped`, naming
    # the failure (security/orchestrator.py).
    planned = []
    if args.plan:
        try:
            planned = units.plan(conn, aid, slice_guides=_slice_guides(root, ignore, components))
        except Exception as exc:  # noqa: BLE001 -- reported below, never swallowed
            sys.exit(f"prepare: the units could not be planned ({type(exc).__name__}: {exc}). "
                     "No unit was written; the deterministic phase's results are kept.")
    print(json.dumps({"coverage_note": note, "findings": len(findings),
                      "guides": {"recommended": recommended}, "units": len(planned)}))
```

E o helper, logo antes de `def cmd_prepare`:

```python
def _slice_guides(root, ignore, components):
    """The hunting guides each read unit's files call for: this analysis's own
    signals (security/guides.py) narrowed to the slice's paths --
    ATTACK-CLASSES and the two best-matched domain guides. The inventory
    signal is left out on purpose: it fires on nearly every project and would
    hand SUPPLY-CHAIN to every slice. Advice never fails the plan: on any
    error -- reading the signals, or choosing for one slice -- the units get
    ATTACK-CLASSES alone, and only a real planning failure fails `prepare`."""
    try:
        sig = guides.signals(root, ignore, components)
    except Exception:  # noqa: BLE001 -- advice must not fail the phase
        return None

    def pick(ranges):
        paths = sorted({r["path"] for r in ranges})
        try:
            return guides.select({"deps": sig["deps"], "paths": paths, "inventory": False},
                                 "standard")[:3]
        except Exception:  # noqa: BLE001 -- advice must not fail the plan
            return [guides.ALWAYS]
    return pick
```

- [ ] **Passo 5: os verbos novos**

Logo a seguir a `cmd_report_verdict` (~linha 1704):

```python
# ---- the pipeline's units (security/units.py) -------------------------------

def _session_unit() -> int:
    """This session's unit id, or 0 outside one (a hand run, a test)."""
    value = _agent_env("SECURITY_UNIT_ID")
    return int(value) if value.isdigit() else 0


READ_LINES = 200
READ_BYTES = 8000


def _unit_of(conn, analysis_id, unit_id):
    unit = ledger.get_unit(conn, unit_id)
    if unit is None or unit["analysis_id"] != analysis_id:
        sys.exit(f"unit {unit_id} is not a unit of analysis {analysis_id}")
    return unit


def _finding_row(f, kind=None):
    """One ledger row as a unit's prompt shows it: its first location on its
    own line, and EVERY location beside it. A re-report REPLACES the stored
    list (ledger.record_finding), so a triage unit shown one location of
    five, and told to re-report the row as shown, would narrow it to one."""
    places = [{"file": o.get("file", ""), "line": o.get("line", 0)}
              for o in f.get("occurrences") or []]
    first = places[0] if places else {}
    row = {"fingerprint": f["fingerprint"], "category": f.get("category", ""),
           "rule": f.get("rule", ""), "severity": f.get("severity", ""),
           "state": f.get("state", ""), "title": f.get("title", ""),
           "file": first.get("file", ""), "line": first.get("line", 0),
           "producer": f.get("producer", ""), "occurrences": places}
    if kind:
        row["kind"] = kind
    return row


def cmd_unit_prompt(args):
    """The prompt of one unit, minted from the ledger -- the text the engine
    launches the unit's session with (bin/agentloop, run_job). Read-only, so
    it is not in AGENT_FORBIDDEN: the engine calls it inside the run's own
    environment."""
    conn = _conn(args)
    row = _analysis(conn, args.analysis)
    unit = _unit_of(conn, args.analysis, args.unit)
    _a, findings = queries.checklist(conn, args.analysis)
    by_fp = {f["fingerprint"]: f for f in findings}
    kind = unit["kind"]
    if kind == "triage":
        context = {"rows": [_finding_row(by_fp[i["fingerprint"]], i["kind"])
                            for i in unit["payload"].get("items", []) if i["fingerprint"] in by_fp]}
    elif kind == "hunt":
        context = {"guides": ledger.guides_of(row).get("recommended") or [guides.ALWAYS]}
    elif kind == "read":
        ranges = unit["payload"].get("ranges", [])
        paths = {r["path"] for r in ranges}

        def in_ranges(f):
            return any(o.get("file") in paths for o in f.get("occurrences") or [])
        # WHAT IS ALREADY RECORDED IN THESE FILES: every open row, AND every
        # row the operator decided on this branch. The checklist lists those
        # with the decision's state, which is not open, and `decided_sast`
        # leaves out whatever the checklist lists -- so a decided row filtered
        # out here reached the unit from nowhere, and was minted again under a
        # second identity no decision matches.
        known = [_finding_row(f) for f in findings if in_ranges(f)
                 and (queries.is_open(f.get("state", ""))
                      or f.get("state") in ledger.DECISION_STATES)]
        # A `decided_sast` entry carries neither a category (every one is a
        # sast finding) nor a state (the decision's is inside `decision`), and
        # the prompt's line shows both.
        decided = [_finding_row(dict(e, category="sast", state=e["decision"]["state"]))
                   for e in queries.decided_sast(conn, args.analysis, listed=findings)
                   if in_ranges(e)]
        context = {"ranges": ranges, "guides": unit["payload"].get("guides") or [guides.ALWAYS],
                   "known": known, "decided": decided}
    else:
        finding = by_fp.get(unit["payload"].get("fingerprint", ""))
        if finding is None:
            sys.exit(f"unit-prompt: unit {args.unit}'s finding is not in analysis {args.analysis}")
        context = {"finding": finding}
    analysis = {k: row[k] for k in ("id", "project", "repo", "branch", "commit_sha", "profile")}
    print(prompts.unit_prompt(analysis, units.label(conn, unit), args.platform, kind, context))


def cmd_unit_close(args):
    """Judge one run of a unit by what it left -- its stream, what `read`
    served it, the ledger -- and plan what it left undone (units.close). The
    ENGINE's verb: run_job calls it when a unit's run ends, with the agent
    flag removed, so it is in AGENT_FORBIDDEN (a session does not grade
    itself). Closing a unit that is already settled is a no-op: the
    orchestrator judges a unit whose run died before this close could run,
    through the same function, and whichever comes second finds it settled."""
    conn = _conn(args)
    _analysis(conn, args.analysis)
    unit = _unit_of(conn, args.analysis, args.unit)
    print(json.dumps(units.close(conn, unit, stream=args.stream, root=args.root,
                                 status=args.status, reason=args.reason,
                                 spend_usd=_spend(args.spend))))


def cmd_report_gone(args):
    """A carried `sast` finding the session's triage unit read and found gone,
    SAID, with the reason -- the one way such a finding leaves the report
    without a silence the unit's proof could not tell from a skipped row."""
    uid = _session_unit()
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError as exc:
        sys.exit(f"report-gone: stdin is not valid JSON: {exc}")
    reason = (payload.get("reason") or "").strip() if isinstance(payload, dict) else ""
    if not reason:
        sys.exit("report-gone: a reason is required -- what you read that shows it is gone. Nothing was recorded")
    _refuse_if_secret("report-gone: reason", reason)
    conn = _conn(args)
    _running(conn, args.analysis)
    unit = ledger.get_unit(conn, uid) if uid else None
    carried = [] if unit is None else [i for i in unit["payload"].get("items", [])
                                       if i.get("kind") == "carried" and i.get("category") == "sast"]
    if (unit is None or unit["kind"] != "triage" or unit["analysis_id"] != args.analysis
            or unit["state"] != "running"
            or args.fingerprint not in {i["fingerprint"] for i in carried}):
        sys.exit(f"report-gone: {args.fingerprint[:12]}… is not a carried sast finding of this "
                 "session's triage unit. Nothing was recorded")
    ledger.record_gone(conn, uid, args.fingerprint, reason)


def cmd_units(args):
    conn = _conn(args)
    _analysis(conn, args.analysis)
    if args.label is not None:
        print(units.label(conn, _unit_of(conn, args.analysis, args.label)))
        return
    print(json.dumps(units.summary(conn, args.analysis), indent=2))


def cmd_read(args):
    """A chunk of a file, numbered, for a unit that must PROVE it read it --
    the only proof on the Codex CLI, whose shell reads the stream cannot carry
    (security/evidence.py). Records the chunk only after printing it: the
    record says what was put in front of the session, never what it asked
    for. Served to a unit of a running analysis only, and only inside the
    unit's own run."""
    aid, uid = _agent_env("SECURITY_ANALYSIS_ID"), _agent_env("SECURITY_UNIT_ID")
    if not (aid.isdigit() and uid.isdigit()):
        sys.exit("read: serves only a unit of an analysis -- AL_SECURITY_ANALYSIS_ID and "
                 "AL_SECURITY_UNIT_ID are not set in this session")
    conn = _conn(args)
    _running(conn, int(aid))
    _unit_of(conn, int(aid), int(uid))
    root = os.path.realpath(_agent_env("RUN_CWD") or os.getcwd())
    full = os.path.realpath(args.path if os.path.isabs(args.path) else os.path.join(root, args.path))
    if full != root and not full.startswith(root + os.sep):
        sys.exit(f"read: {args.path} is outside this run's checkout ({root})")
    rel = os.path.relpath(full, root).replace(os.sep, "/")
    try:
        data = Path(full).read_bytes()
    except OSError as exc:
        sys.exit(f"read: cannot read {rel}: {exc.strerror or exc}")
    lines = data.decode("utf-8", errors="replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    total, first = len(lines), max(1, args.start)
    if first > total:
        print(f"== {rel} has {total} line{'s' if total != 1 else ''}; nothing at line {first} ==")
        return
    out, size, last = [], 0, first - 1
    for number in range(first, total + 1):
        text = lines[number - 1]
        if out and (len(out) >= READ_LINES or size + len(text) + 1 > READ_BYTES):
            break
        out.append(f"{number}\t{text}")
        size += len(text) + 1
        last = number
    print(f"== {rel} lines {first}-{last} of {total} ==")
    print("\n".join(out))
    print(f"-- next: agentloop security read --path {rel} --from {last + 1}" if last < total
          else "-- end of file")
    sys.stdout.flush()
    ledger.record_unit_read(conn, int(uid), rel, first, last)
```

Confirmar que `os` e `Path` já estão importados no topo de `cli.py` (estão).

- [ ] **Passo 6: os subparsers**

No subparser do `prepare` (`pr = sub.add_parser("prepare", …)`, ~linha 3652), a seguir a `--offline`:

```python
    # The orchestrator's prepare only (security/orchestrator.py): write the
    # analysis's plan. Without it `prepare` plans nothing -- see cmd_prepare.
    pr.add_argument("--plan", action="store_true")
```

A seguir ao subparser de `report-verdict` (~linha 3692):

```python
    # The pipeline's units. `unit-prompt`, `units` and `read` are reads (and
    # `read` exists for the agent), so they stay reachable under the agent
    # flag; `unit-close` is the engine's and joins AGENT_FORBIDDEN (Task 8).
    up = sub.add_parser("unit-prompt", parents=[dbflag]); up.set_defaults(fn=cmd_unit_prompt)
    up.add_argument("--analysis", type=int, required=True)
    up.add_argument("--unit", type=int, required=True)
    up.add_argument("--platform", default="anthropic", choices=("anthropic", "openai", "opencode"))

    uc = sub.add_parser("unit-close", parents=[dbflag]); uc.set_defaults(fn=cmd_unit_close)
    uc.add_argument("--analysis", type=int, required=True)
    uc.add_argument("--unit", type=int, required=True)
    uc.add_argument("--stream", default="")
    uc.add_argument("--root", default="")
    uc.add_argument("--status", default="error")
    uc.add_argument("--reason", default="")
    uc.add_argument("--spend", default="0")

    us = sub.add_parser("units", parents=[dbflag]); us.set_defaults(fn=cmd_units)
    us.add_argument("--analysis", type=int, required=True)
    us.add_argument("--label", type=int, default=None)

    rg = sub.add_parser("report-gone", parents=[dbflag]); rg.set_defaults(fn=cmd_report_gone)
    rg.add_argument("--analysis", type=int, required=True)
    rg.add_argument("--fingerprint", required=True)

    rd = sub.add_parser("read", parents=[dbflag]); rd.set_defaults(fn=cmd_read)
    rd.add_argument("--path", required=True)
    rd.add_argument("--from", type=int, default=1, dest="start")
```

- [ ] **Passo 7: correr e ver passar, com a suite do CLI**

Run: `python3.13 -m pytest tests/security/test_cli_units.py tests/security/test_units.py tests/security/test_cli.py -p no:cacheprovider -q`
Expected: PASS — `test_every_phases_prose_is_a_substring_of_the_paragraph` (test_cli.py) incluído: é a invariante que o novo teste do âmbito `deep` estende. Se algum teste antigo do `prepare` comparar o JSON impresso por igualdade, acrescentar-lhe a chave `"units"` (é a única mudança na saída de um `prepare` sem `--plan`).

- [ ] **Passo 8: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **The security CLI runs units.** `prepare` lists a deep analysis's scope,
  and — with `--plan`, which only the engine's orchestrator passes — writes
  the plan, all of it or none: a plan that fails exits non-zero with the
  reason and writes no unit, instead of reporting success over half a plan.
  `unit-prompt` prints a unit's minted prompt — a triage row with every
  location it has, a read unit's files with what is already recorded or
  decided in them — `unit-close` judges a unit's run from its stream and
  the ledger and plans what it left undone, `units` prints the progress (per
  kind, and how much of a deep scope has been read, counted against the
  inventory itself), and `read` serves a file to a unit in numbered chunks
  of 200 lines or 8 KB, recording each chunk as proof of reading — the only
  proof there is on Codex.
```

```bash
/usr/bin/git add bin/security/cli.py bin/security/units.py tests/security/test_cli_units.py tests/security/test_units.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): the CLI plans, prompts, closes and serves an analysis's units"
```

---

### Task 8: As portas e o ciclo de vida — quem pode fechar, verificar, interromper e retomar

**Ficheiros:**
- Modificar: `bin/security/cli.py` (`AGENT_FORBIDDEN` ~133; docstring de `_refuse_if_agent` ~144-205; `_running` ~223-239; `cmd_open_analysis` ~321-346; `cmd_report_verdict` ~1659-1704; `cmd_report_finding` ~2048; verbos e subparsers novos)
- Modificar: `bin/security/queries.py` (`verify_queue` ~78-97)
- Modificar: `bin/agentloop` (helper `security_engine_py` junto de `security_py`, ~1007; as três chamadas `security_py finish` em ~1095, ~1139, ~1357)
- Modificar: `skills/security-analysis/SKILL.md` (nomear os verbos recusados; a reescrita completa é a Task 14)
- Modificar: `test/selftest.sh` (um bloco novo, junto dos de `security_close_analysis`, ~7578)
- Testes: `tests/security/test_cli_doors.py` (novo); `tests/security/test_cli.py` e `tests/security/test_verify_queue.py` (ajustes indicados abaixo)

**Interfaces:**
- Consome: Task 1 (`interrupt_analysis`, `resume_analysis`, `close_interrupted`, `INTERRUPTED`, `get_unit`), Task 7.
- Produz:
  - `AGENT_FORBIDDEN` passa a incluir `finish`, `unit-close`, `orchestrate`, `interrupt`, `resume`, `abandon`
  - verbos `security interrupt --analysis N`, `security resume --analysis N [--automatic]`, `security abandon --analysis N --note T`: imprimem `{"state": <novo>}`; saem com código 1 e uma frase quando a transição não se aplica
  - `report-finding` carimba `unit` com o `AL_SECURITY_UNIT_ID` da sessão (0 fora de uma unidade); o payload nunca o escolhe
  - `report-verdict` de uma sessão de agente só é aceite se `AL_SECURITY_UNIT_ID` for a unidade `verify`, em curso, desse fingerprint e desta análise; grava `verified_by = "unit:<id>"`; fora de uma sessão de agente grava `"operator"`
  - `queries.verify_queue` só lista linhas desta análise
  - `open-analysis` falha (`abandon`) as análises `interrupted` do mesmo projecto, repositório e ramo, com a nota «Superseded by analysis N…»
  - no motor: `security_engine_py <verbo> …` = `security_py` sem `AL_SECURITY_AGENT`/`CC_SECURITY_AGENT`

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_cli_doors.py`:

```python
# tests/security/test_cli_doors.py
"""Who may close, grade, verify, interrupt and resume an analysis now that the engine runs it."""
import json
import os

import pytest
from test_cli import AS_AGENT, fails, open_analysis, prepared_analysis, run

from security import cli as security_cli
from security import ledger


def _conn(db):
    return ledger.connect(db)


@pytest.mark.parametrize("verb", ["finish", "unit-close", "orchestrate", "interrupt", "resume", "abandon"])
def test_the_engine_s_verbs_are_refused_to_an_agent_session(verb):
    assert verb in security_cli.AGENT_FORBIDDEN


def test_finish_is_refused_under_the_agent_flag(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    out = fails(db, "finish", "--analysis", str(aid), "--state", "done", env=AS_AGENT)
    assert out.returncode != 0 and "refused inside a security analysis" in out.stderr


def _agent_in_unit(aid, uid):
    return {**AS_AGENT, "AL_SECURITY_ANALYSIS_ID": str(aid), "AL_SECURITY_UNIT_ID": str(uid)}


def _sast(db, aid, fp, env=None):
    run(db, "report-finding", "--analysis", str(aid), env=env or AS_AGENT, stdin=json.dumps({
        "fingerprint": fp, "category": "sast", "rule": "sql-injection", "severity": "high",
        "title": "t", "rationale": "the query is concatenated",
        "occurrences": [{"file": "app/db.py", "line": 12}],
        "candidate": {"trace": [{"kind": "entrypoint", "file": "app/api.py", "line": 4, "scope": "s",
                                 "description": "input"},
                                {"kind": "sink", "file": "app/db.py", "line": 12, "scope": "f",
                                 "description": "execute"}],
                      "intended_control": "parameterised queries",
                      "confidence": {"score": "high", "reason": "r"},
                      "likelihood": {"score": "high", "reason": "r"},
                      "impact": {"score": "high", "reason": "r"}}}))


def test_a_finding_carries_the_unit_of_the_session_that_wrote_it(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    conn = _conn(db)
    uid = ledger.add_unit(conn, aid, "hunt", {})
    _sast(db, aid, "b" * 64, env=_agent_in_unit(aid, uid))
    assert conn.execute("SELECT unit FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()[0] == uid


def test_a_verdict_from_an_agent_session_must_come_from_that_finding_s_verify_unit(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    _sast(db, aid, "b" * 64)
    conn = _conn(db)
    other = ledger.add_unit(conn, aid, "hunt", {})
    wrong = ledger.add_unit(conn, aid, "verify", {"fingerprint": "c" * 64})
    right = ledger.add_unit(conn, aid, "verify", {"fingerprint": "b" * 64})
    verdict = json.dumps({"verdict": "confirmed", "reason": "read app/db.py:12"})
    for uid in (None, other, wrong):
        env = AS_AGENT if uid is None else _agent_in_unit(aid, uid)
        out = fails(db, "report-verdict", "--analysis", str(aid), "--fingerprint", "b" * 64, stdin=verdict, env=env)
        assert out.returncode != 0 and "verify unit" in out.stderr
    ledger.start_unit(conn, right)
    run(db, "report-verdict", "--analysis", str(aid), "--fingerprint", "b" * 64, stdin=verdict,
        env=_agent_in_unit(aid, right))
    row = conn.execute("SELECT verdict, verified_by FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()
    assert (row["verdict"], row["verified_by"]) == ("confirmed", f"unit:{right}")


def test_a_verdict_written_outside_any_agent_session_is_the_operator_s(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    _sast(db, aid, "b" * 64)
    env = {k: v for k, v in os.environ.items() if k != "AL_SECURITY_AGENT"}
    run(db, "report-verdict", "--analysis", str(aid), "--fingerprint", "b" * 64, env=env,
        stdin=json.dumps({"verdict": "rejected", "reason": "parameterised one frame up"}))
    assert _conn(db).execute("SELECT verified_by FROM finding WHERE fingerprint=?",
                             ("b" * 64,)).fetchone()[0] == "operator"


def test_the_verify_queue_lists_only_this_analysis_s_rows(tmp_path):
    """The carried row has NO verdict -- a verdict takes a row out of the
    queue on its own (`in_verify_scope`), which would make this pass before
    the rule it is about existed. The old analysis closes without one, so it
    closes `capped`, which is still the next analysis's baseline."""
    db = tmp_path / "security.db"
    old = prepared_analysis(db, tmp_path)
    _sast(db, old, "c" * 64)
    run(db, "finish", "--analysis", str(old), "--state", "done")
    assert next(r for r in run(db, "list", "--project", "web") if r["id"] == old)["state"] == "capped"
    new = prepared_analysis(db, tmp_path)
    carried = next(f for f in run(db, "checklist", "--analysis", str(new))["findings"]
                   if f["fingerprint"] == "c" * 64)
    assert carried["state"] == "pending" and not carried.get("verdict"), \
        "the case is reached: an open, unverified agent finding the new analysis carries"
    assert run(db, "verify-queue", "--analysis", str(new)) == [], \
        "a carried row belongs to the analysis that recorded it and cannot take a verdict here"


def test_interrupt_resume_and_abandon_move_the_state_and_refuse_the_impossible(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    assert run(db, "interrupt", "--analysis", str(aid)) == {"state": "interrupted"}
    assert fails(db, "interrupt", "--analysis", str(aid)).returncode != 0
    assert run(db, "resume", "--analysis", str(aid), "--automatic") == {"state": "running"}
    assert _conn(db).execute("SELECT resumes FROM analysis WHERE id=?", (aid,)).fetchone()[0] == 1
    run(db, "interrupt", "--analysis", str(aid))
    assert run(db, "abandon", "--analysis", str(aid), "--note", "Out of automatic resumes.") == {"state": "failed"}
    out = fails(db, "resume", "--analysis", str(aid))
    assert out.returncode != 0 and "not interrupted" in out.stderr


def test_nothing_is_written_into_an_interrupted_analysis(tmp_path):
    """A COMPLETE, VALID finding: `report-finding` validates the payload before
    it opens the ledger, so an empty one would be refused for its shape and
    never reach the question this test asks."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    run(db, "interrupt", "--analysis", str(aid))
    out = fails(db, "report-finding", "--analysis", str(aid), env=AS_AGENT, stdin=json.dumps({
        "fingerprint": "b" * 64, "category": "hygiene", "rule": "world_writable", "severity": "high",
        "title": "t", "rationale": "the file is writable by anyone",
        "occurrences": [{"file": "app.py", "line": 1}]}))
    assert out.returncode != 0 and "is interrupted" in out.stderr
    assert all(f["fingerprint"] != "b" * 64 for f in run(db, "findings", "--analysis", str(aid)))


def test_a_new_analysis_supersedes_an_interrupted_one_on_the_same_branch(tmp_path):
    db = tmp_path / "security.db"
    old = open_analysis(db)
    other_branch = open_analysis(db, branch="develop")
    run(db, "interrupt", "--analysis", str(old))
    run(db, "interrupt", "--analysis", str(other_branch))
    new = open_analysis(db)
    rows = {r["id"]: r for r in run(db, "list", "--project", "web")}
    assert rows[old]["state"] == "failed"
    assert f"Superseded by analysis {new}" in rows[old]["coverage_note"]
    assert rows[other_branch]["state"] == "interrupted"
```

Ajustes em testes existentes (cada um porque a regra mudou, não por conveniência):
- `tests/security/test_cli.py`, `test_the_work_the_agent_is_there_to_do_still_works_under_the_flag` (~1225): o `finish` da linha ~1241 corre **sem** `env=AS_AGENT` — o teste é sobre o trabalho do agente sob a flag e sobre o `finish` em si, e o `finish` passa a ser do motor (a recusa ao agente tem teste próprio, `test_finish_is_refused_under_the_agent_flag`). A linha fica `run(db, "finish", "--analysis", str(aid), "--state", "done")`, e o docstring passa a dizer:

  ```python
      """The flag is on for the WHOLE of an agent's session: refusing more than
      the verbs AGENT_FORBIDDEN names would break the analysis it is supposed to
      protect. `finish` is one of those verbs since the pipeline -- the engine
      closes the analysis through `security_engine_py`, with the flag removed --
      so the close below runs without it; the door's refusal of `finish` to an
      agent has its own test (test_cli_doors.py)."""
  ```
- `tests/security/test_cli.py`, `test_finish_refuses_a_note_that_looks_like_a_live_credential` (~5868): o `fails(…)` corre **sem** `env=AS_AGENT` — sob a flag, a recusa da porta (`_refuse_if_agent`, em `main()`) corre antes da do segredo e o teste deixava de ver «live credential». O teste é sobre o gate do `--note`, que fica para as notas do motor e do operador.
- `tests/security/test_cli.py`, `test_a_refused_note_leaves_the_analysis_open_rather_than_half_closed` (~5881): o mesmo, e pela mesma razão — sob a flag passaria pela recusa da porta, não pela do segredo que o docstring descreve. O `fails(…)` corre sem `env=AS_AGENT`.
- `tests/security/test_cli.py`, `test_verify_queue_lists_the_scope_and_report_verdict_writes_it` (~6428): o `report-verdict` corre sem sessão de agente, por isso `verified_by` passa a ser `"operator"` — trocar `assert row["verified_by"] == "subagent"` por `assert row["verified_by"] == "operator"`.
- Qualquer teste em `tests/security/test_cli.py` que chame `report-verdict` com `env=AS_AGENT` sem unidade passa a falhar pela regra nova: passar a usar o ambiente sem `AL_SECURITY_AGENT` (a verificação, a partir daqui, é das unidades `verify` e está coberta pelos testes novos).
- `tests/security/test_verify_queue.py`: um caso que espere ver na fila uma linha de outra análise deixa de a ver — actualizar a expectativa e dizer no nome do teste porquê.

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_cli_doors.py -p no:cacheprovider -q`
Expected: FAIL (verbos desconhecidos; `finish` aceite com a flag; `verified_by` antigo).

- [ ] **Passo 3: `AGENT_FORBIDDEN` e o seu docstring**

```python
AGENT_FORBIDDEN = ("decide", "rename-project", "open-analysis", "event",
                   "filters save", "filters delete",
                   # THE ENGINE'S VERBS. A session does not close the analysis
                   # it is a unit of, grade its own unit, or stop and restart
                   # the pipeline it runs inside: the engine calls these with
                   # the agent flag removed (`security_engine_py` in
                   # bin/agentloop), so refusing them here costs the engine
                   # nothing and closes the one door a unit could misuse.
                   "finish", "unit-close", "orchestrate", "interrupt", "resume", "abandon")
```

No docstring de `_refuse_if_agent`, substituir o parágrafo que diz que `finish` fica de fora de propósito por: «`finish` joined the refused verbs with the pipeline: the engine's own closes now run through `security_engine_py`, which removes the flag, so an agent session is the only caller left under it.» Estender a mensagem de `sys.exit` do `_refuse_if_agent` com «…, close or grade the analysis the engine is running, …» no sítio natural da frase.

As outras duas frases que ainda dizem que o `finish` fica aberto ao agente passam a dizer o que é verdade: no docstring de `_refuse_if_secret`, «and is deliberately reachable by the agent (see `_refuse_if_agent`: closing the row is the one thing that must always work)» passa a «and is written by the engine's close and by an operator (the agent is refused the verb, see `_refuse_if_agent`)»; no comentário do topo de `cmd_finish` (~2312-2318), «and it is agent-writable -- `finish` is deliberately NOT in AGENT_FORBIDDEN.» passa a «and it is free text an operator or the engine types.»

- [ ] **Passo 4: `_running` diz o que é uma análise interrompida**

Em `_running`, antes do `sys.exit` actual:

```python
    if row["state"] == ledger.INTERRUPTED:
        sys.exit(f"analysis {analysis_id} is interrupted: nothing is written into it "
                 "until it is resumed (`agentloop security resume`), and a unit of it "
                 "that is still running was stopped with it.")
```

- [ ] **Passo 5: `report-finding` carimba a unidade**

A seguir a `payload["producer"] = diff.AGENT` (~linha 2048):

```python
    # The unit whose session wrote this row -- from the run's own environment,
    # never the payload, on the rule `producer` follows.
    payload["unit"] = _session_unit()
```

(`_session_unit` já existe desde a Task 7.)

- [ ] **Passo 6: a porta do `report-verdict`**

Em `cmd_report_verdict`, logo a seguir a `_running(conn, args.analysis)`:

```python
    # WHO MAY WRITE A VERDICT. Inside an agent session, only the verify unit
    # the engine launched for THIS finding -- the write is the evidence that a
    # second, independent session read the code, and it is checked here
    # instead of counted afterwards. Outside any session it is the operator's.
    by = "operator"
    if _agent_env("SECURITY_AGENT"):
        uid = _session_unit()
        unit = ledger.get_unit(conn, uid) if uid else None
        if (unit is None or unit["kind"] != "verify" or unit["analysis_id"] != args.analysis
                or unit["state"] != "running"
                or unit["payload"].get("fingerprint") != args.fingerprint):
            sys.exit(f"report-verdict: only the verify unit the engine launched for "
                     f"{args.fingerprint[:12]}… may record its verdict. Nothing was recorded")
        by = f"unit:{uid}"
```

E na chamada a `ledger.record_verdict(...)`, passar `by=by`. Actualizar o docstring de `cmd_report_verdict`: a verificação passou a ser uma unidade do motor, e a porta confere a unidade em vez de contar subagentes.

- [ ] **Passo 7: a fila de verificação é desta análise**

Em `queries.verify_queue`:

```python
    _analysis, findings = checklist(conn, analysis_id)
    # THIS ANALYSIS'S ROWS ONLY. A carried row -- the previous analysis's,
    # `pending` until this one re-checks it -- can never take a verdict here
    # (`record_verdict` writes only rows of this analysis), so listing it kept
    # a queue no verifier could empty. Its re-check is the triage units' debt.
    rows = [f for f in findings if f.get("analysis_id") == analysis_id and in_verify_scope(f)]
```

- [ ] **Passo 8: `open-analysis` abandona as interrompidas do mesmo ramo, e os três verbos**

Em `cmd_open_analysis`, logo a seguir ao `start_analysis`:

```python
    # A NEW ANALYSIS OF THE SAME BRANCH SUPERSEDES AN INTERRUPTED ONE. Resuming
    # the old one after this would file two readings of one branch out of
    # order; its finished units stay in the ledger, and its note says why the
    # rest never ran.
    for (old,) in conn.execute(
            "SELECT id FROM analysis WHERE project=? AND repo=? AND branch=? AND state=? AND id<>?",
            (args.project, args.repo, args.branch, ledger.INTERRUPTED, aid)).fetchall():
        ledger.close_interrupted(conn, old, f"Superseded by analysis {aid}, opened on the same "
                                            "branch before this one was resumed.")
```

Verbos novos, a seguir aos da Task 7:

```python
def _transition(ok, analysis_id, state, why):
    if not ok:
        sys.exit(f"analysis {analysis_id} {why}")
    print(json.dumps({"state": state}))


def cmd_interrupt(args):
    conn = _conn(args)
    _analysis(conn, args.analysis)
    _transition(ledger.interrupt_analysis(conn, args.analysis), args.analysis,
                ledger.INTERRUPTED, "is not running: only a running analysis is interrupted")


def cmd_resume(args):
    conn = _conn(args)
    _analysis(conn, args.analysis)
    _transition(ledger.resume_analysis(conn, args.analysis, automatic=args.automatic),
                args.analysis, "running", "is not interrupted: there is nothing to resume")


def cmd_abandon(args):
    _refuse_if_secret("abandon: --note", args.note)
    conn = _conn(args)
    _analysis(conn, args.analysis)
    _transition(ledger.close_interrupted(conn, args.analysis, args.note), args.analysis,
                "failed", "is not interrupted: only an interrupted analysis is abandoned")
```

Subparsers:

```python
    # The pipeline's lifecycle, the engine's to drive (all three in AGENT_FORBIDDEN).
    it = sub.add_parser("interrupt", parents=[dbflag]); it.set_defaults(fn=cmd_interrupt)
    it.add_argument("--analysis", type=int, required=True)

    rs = sub.add_parser("resume", parents=[dbflag]); rs.set_defaults(fn=cmd_resume)
    rs.add_argument("--analysis", type=int, required=True)
    rs.add_argument("--automatic", action="store_true")

    ab = sub.add_parser("abandon", parents=[dbflag]); ab.set_defaults(fn=cmd_abandon)
    ab.add_argument("--analysis", type=int, required=True)
    ab.add_argument("--note", required=True)
```

- [ ] **Passo 9: a skill nomeia os verbos recusados**

Em `skills/security-analysis/SKILL.md`, na frase de «Ending the run» que lista os verbos recusados (a que começa por «`finish` is the only closing verb that is yours: `decide`, `rename-project`, …»), substituí-la por:

```markdown
None of the closing verbs is yours any more: the engine runs the analysis as units and closes it itself. `finish`, `unit-close`, `orchestrate`, `interrupt`, `resume` and `abandon` are refused to every agent session, and so are `decide`, `rename-project`, `event`, `filters save` and `filters delete` — you do not dismiss the finding you filed, rename the ledger out from under the project, write by hand into the audit trail that exists to say what you did, or edit a working set a human curated — and `open-analysis` already happened before you started. The read verbs beside them (`events`, `filters list`) are *not* refused; there is nothing there to protect.
```

(O resto da skill é reescrito na Task 14; esta frase tem de existir já, porque `test_the_skill_names_every_verb_the_door_refuses_the_agent` exige cada verbo recusado entre crases.)

- [ ] **Passo 10: o motor chama os seus verbos sem a flag do agente**

Em `bin/agentloop`, a seguir a `security_py() { … }` (~linha 1007):

```bash
# The ENGINE's own security calls: `finish`, `unit-close` and the pipeline's
# lifecycle verbs are refused to an agent session (AGENT_FORBIDDEN), and the
# engine makes them from inside the same run_job that exported
# AL_SECURITY_AGENT for the agent. The subshell drops the flag for this one
# call and nothing else.
security_engine_py() { ( unset AL_SECURITY_AGENT CC_SECURITY_AGENT; security_py "$@" ); }
```

E trocar `security_py finish` por `security_engine_py finish` nas três chamadas (~1095 em `security_run_analysis`, ~1139 no sweep de `cmd_security_analyze`, ~1357 em `security_close_analysis`).

- [ ] **Passo 11: o bloco do selftest**

Em `test/selftest.sh`, logo antes do bloco que começa por `# security_close_analysis must ignore every job that is not a derived one` (~7578):

```bash
  # The engine's own security calls run without the agent's flag. `finish`,
  # `unit-close` and the lifecycle verbs are refused to an agent session,
  # and the engine makes them from inside the run_job that exported
  # AL_SECURITY_AGENT for the agent: without the unset every close of every
  # analysis would be refused, and every analysis would stay `running`.
  ( AL_SECURITY_AGENT=1; CC_SECURITY_AGENT=1; export AL_SECURITY_AGENT CC_SECURITY_AGENT
    PYTHON="$tmp/env-python"
    printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${AL_SECURITY_AGENT:-}" "${CC_SECURITY_AGENT:-}"\n' > "$PYTHON"
    chmod +x "$PYTHON"
    [ "$(security_engine_py finish --analysis 1 --state done)" = "|" ] \
      && [ "$(security_py finish --analysis 1 --state done)" = "1|1" ] ) \
    && ok "security_engine_py calls the CLI with the agent flag removed, and only that call" \
    || bad "security_engine_py passed the agent flag through, or security_py lost it"
```

- [ ] **Passo 12: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_cli_doors.py tests/security/test_cli.py tests/security/test_verify_queue.py tests/security/test_cli_units.py -p no:cacheprovider -q`
Expected: PASS.

Correr o bloco novo do selftest isolado com o script de blocos do scratchpad (ver `agentloop-selftest-bloco-isolado` na memória), com os marcadores `"security_engine_py calls the CLI"` e o `echo` seguinte, e confirmar `RESULT pass=1 fail=0`.

- [ ] **Passo 13: CHANGELOG e commit**

Duas entradas em `CHANGELOG.md`, `## [Unreleased]` → `### Changed`, no topo:

```markdown
- **An agent session can no longer close, grade, interrupt or resume the
  analysis it works for.** `finish`, `unit-close`, `orchestrate`,
  `interrupt`, `resume` and `abandon` are refused under the agent flag; the
  engine makes them with the flag removed. A verdict from an agent session
  is accepted only from the verify unit the engine launched for that very
  finding (`verified_by` names the unit), instead of being counted against
  subagents after the fact; one written outside any session is recorded as
  the operator's.
- **The verification queue lists only the analysis's own rows.** A finding
  the previous analysis recorded, not yet re-checked, used to sit in the
  queue where no verifier could ever clear it — `record_verdict` writes only
  this analysis's rows — and lowered `done` to `capped` for a reason nobody
  could act on. Its re-check is the triage's job.
```

E em `### Added`, no topo:

```markdown
- **An analysis can be interrupted and resumed.** `interrupt`, `resume` and
  `abandon` move an analysis into and out of the new `interrupted` state;
  nothing is written into an interrupted analysis, and opening a new
  analysis of the same branch abandons an interrupted one, saying so in its
  note.
```

```bash
/usr/bin/git add bin/security/cli.py bin/security/queries.py bin/agentloop skills/security-analysis/SKILL.md test/selftest.sh tests/security/test_cli_doors.py tests/security/test_cli.py tests/security/test_verify_queue.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): only the engine closes an analysis, and only a verify unit writes a verdict"
```

---

### Task 9: O fecho decidido pelas unidades — `finish --from-units`

**Ficheiros:**
- Modificar: `bin/security/units.py` (acrescentar `gaps`, `coverage_sentence`, `guides_read`; o `owed`, o `_lineages` e o `summary` são da Task 7 e não mudam)
- Modificar: `bin/security/cli.py` (`cmd_finish` ~2285-2650; subparser do `finish` ~3694)
- Testes: `tests/security/test_finish_units.py` (novo)

**Interfaces:**
- Consome: Tasks 1, 5, 7, 8 — em particular `units.owed(conn, analysis_id, all_units=None, inventory=None)` (a dívida do `deep`, calculada a partir do inventário e dos `covered`), `units._lineages(all_units)` e `units.summary` da Task 7.
- Produz:
  - `units.gaps(conn, analysis_id) -> list[str]` — as frases das lacunas: unidades por acabar, linhagens que desistiram, e as linhas do inventário que ficaram em dívida (`owed`: a mesma conta que o `summary` usa, nunca uma segunda)
  - `units.coverage_sentence(conn, analysis_id) -> str` — a frase da linha `sast`
  - `units.guides_read(conn, analysis_id) -> list[str]` — a união dos guias abertos, na ordem de `guides.NAMES`
  - `finish --from-units`: o gasto passa a ser a soma das unidades; cada lacuna baixa `done` para `capped` e entra na nota; a linha `sast` leva a frase de cobertura, e a frase entra também no parágrafo, junto das outras frases dessa linha (a invariante de que a prosa de cada fase é um pedaço contíguo do parágrafo); `guides.read` passa a ser a união

- [ ] **Passo 1: escrever os testes que falham**

`tests/security/test_finish_units.py`:

```python
# tests/security/test_finish_units.py
"""The close the engine makes: done only with every unit's proof, capped with each gap named."""
import json

from test_cli import run

from security import ledger


def _conn(db):
    return ledger.connect(db)


def _deep(db, tmp_path, lines=10):
    """A prepared deep analysis with a one-file inventory and NO units: made in
    the ledger, not through `prepare`, which would plan a hunt unit of its own."""
    conn = _conn(db)
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "deep", "security-web")
    ledger.set_inventory(conn, aid, {
        "files": [{"path": "a.py", "lines": lines, "bytes": 100, "ranges": [[1, lines, 100]]}],
        "excluded": {}, "git": True, "totals": {"files": 1, "lines": lines, "bytes": 100}})
    ledger.mark_prepared(conn, aid, ["secrets"])
    return aid, conn


def _done(conn, uid, spend=1.0, guides=(), covered=None):
    """A unit settled `done`, as its close settles one -- a read unit with the
    spans it proved (`covered`), which is what the deep debt is counted from."""
    ledger.start_unit(conn, uid)
    ev = {"missing": [], "guides": list(guides)}
    if covered is not None:
        ev["covered"] = covered
    ledger.settle_unit(conn, uid, "done", spend, ev, "ok")


def _analysis(db, aid):
    return next(r for r in run(db, "list", "--project", "web") if r["id"] == aid)


def test_every_unit_done_and_the_scope_read_closes_done_with_the_units_spend(tmp_path):
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    _done(conn, hunt, 2.0, ["ATTACK-CLASSES"])
    _done(conn, read, 1.5, ["ATTACK-CLASSES", "CLIENT-SIDE"], covered={"a.py": [[1, 10]]})
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert (row["state"], row["spend_usd"]) == ("done", 3.5)
    checklist = run(db, "checklist", "--analysis", str(aid))
    phases = {p["name"]: p for p in json.loads(checklist["analysis"]["coverage"])["phases"]}
    assert phases["sast"]["status"] == "ran"
    assert "1 of 1 files, 10 of 10 lines" in phases["sast"]["note"]
    assert checklist["analysis"]["guides"]["read"] == ["ATTACK-CLASSES", "CLIENT-SIDE"]


def test_a_lineage_that_gave_up_lowers_done_and_is_named(tmp_path):
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    ledger.start_unit(conn, read)
    ledger.settle_unit(conn, read, "failed", 0.5,
                       {"missing": [{"path": "a.py", "first": 6, "last": 10, "bytes": 0}],
                        "covered": {"a.py": [[1, 5]]}},
                       "1 of 1 range(s) not read in full. Gave up after 3 attempts.")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "1 unit gave up after 3 attempts: read 1/1" in row["coverage_note"]
    assert "5 of 10 lines in the deep scope (1 of 1 files) were never read in full" in row["coverage_note"]
    assert "a.py:6-10" in row["coverage_note"]


def test_a_read_unit_that_gave_up_without_saying_what_it_missed_owes_its_whole_slice(tmp_path):
    """The shape a crash, a subagent and the engine's strike-out all leave: a
    read unit settled `failed` with no `missing` and nothing `covered`. The
    debt used to be read off `missing`, which is empty here, so the `sast` row
    said every line was read and the gaps named none of them."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    ledger.start_unit(conn, read)
    ledger.settle_unit(conn, read, "failed", 0, {},
                       "The engine could not run this unit: 3 runs ended without a close (see tick.log).")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "10 of 10 lines in the deep scope (1 of 1 files) were never read in full" in row["coverage_note"]
    assert "a.py:1-10" in row["coverage_note"]
    phases = {p["name"]: p for p in json.loads(run(db, "analysis", "--id", str(aid))["coverage"])["phases"]}
    assert "0 of 1 files, 0 of 10 lines" in phases["sast"]["note"]


def test_a_close_from_the_units_keeps_every_row_a_substring_of_the_paragraph(tmp_path):
    """The invariant test_every_phases_prose_is_a_substring_of_the_paragraph
    (test_cli.py) pins, on the engine's close of a pipeline analysis: the
    `sast` row carries the units' sentence, the `--note` and the guides
    sentence, and the paragraph has to carry the three together, in that
    order -- the units' sentence used to be on the row and nowhere else."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    _done(conn, hunt, 1.0, ["ATTACK-CLASSES"])
    _done(conn, read, 1.0, ["ATTACK-CLASSES"], covered={"a.py": [[1, 10]]})
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units",
        "--note", "The analysis budget of $5.00 was spent before every unit ran.")
    row = run(db, "analysis", "--id", str(aid))
    phases = json.loads(row["coverage"])["phases"]
    sast = next(p for p in phases if p["name"] == "sast")
    assert "Deep read:" in sast["note"] and "Guides read:" in sast["note"]
    for p in phases:
        if p["name"] in ("triage", "verification"):
            continue    # their summary sentences are the invariant's named exemption
        assert p["note"] in row["coverage_note"], f"{p['name']}'s note is not in the paragraph: {p['note']!r}"


def test_a_unit_that_never_finished_lowers_done(tmp_path):
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units",
        "--note", "The budget of $5.00 was spent before every unit ran.")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "1 unit never finished: hunt 1/1" in row["coverage_note"]
    assert "The budget of $5.00 was spent" in row["coverage_note"]


def test_without_from_units_the_close_is_what_it_was(tmp_path):
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--spend", "0.25")
    row = _analysis(db, aid)
    assert (row["state"], row["spend_usd"]) == ("done", 0.25)
```

(O teste de `owed` é da Task 7, onde a função nasce: `test_owed_is_the_inventory_minus_every_span_a_read_unit_proved`, em `tests/security/test_units.py`.)

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_finish_units.py -p no:cacheprovider -q`
Expected: FAIL — `unrecognized arguments: --from-units`.

- [ ] **Passo 3: `gaps`, `coverage_sentence`, `guides_read`, no fim de `units.py`**

O `_lineages`, o `owed` e o `summary` já existem (Task 7); o `gaps` usa-os, nunca uma segunda conta da dívida.

```python
def gaps(conn, analysis_id) -> list:
    """Each reason this analysis's units do not add up to `done`, as a sentence
    the report can print: the units that never finished, the lineages that
    gave up, and the deep scope's lines nobody proved they read -- the same
    `owed` the page's Pipeline block counts, from the inventory, so a slice no
    unit ever carried and a unit that gave up saying nothing are both named."""
    all_units = ledger.units_of(conn, analysis_id)
    lineages = _lineages(all_units)
    out = []
    open_ = [last for _r, last in lineages if last["state"] in ("pending", "running")]
    if open_:
        names = "; ".join(label(conn, u) for u in open_[:3])
        out.append(f"{len(open_)} unit{'s' if len(open_) != 1 else ''} never finished: {names}"
                   f"{' and others' if len(open_) > 3 else ''}.")
    failed = [last for _r, last in lineages if last["state"] == "failed"]
    if failed:
        names = "; ".join(f"{label(conn, u)} ({u['note']})" for u in failed[:3])
        out.append(f"{len(failed)} unit{'s' if len(failed) != 1 else ''} gave up after "
                   f"{MAX_ATTEMPTS} attempts: {names}.")
    inventory = ledger.inventory_of(conn, analysis_id)
    left = owed(conn, analysis_id, all_units, inventory)
    if inventory and left:
        lines = int((inventory.get("totals") or {}).get("lines", 0))
        files = len(inventory.get("files") or [])
        missing_lines = sum(s["last"] - s["first"] + 1 for s in left)
        missing_files = len({s["path"] for s in left})
        first_ten = ", ".join(f"{s['path']}:{s['first']}-{s['last']}" for s in left[:10])
        out.append(f"{missing_lines:,} of {lines:,} lines in the deep scope ({missing_files:,} of "
                   f"{files:,} files) were never read in full. The first ten: {first_ten}.")
    return out


def coverage_sentence(conn, analysis_id) -> str:
    """The `sast` coverage row's sentence: how the pass ran, and in a deep
    analysis how much of the inventory the read units proved they read."""
    s = summary(conn, analysis_id) or {}
    kinds = s.get("kinds") or {}
    parts = []
    hunt = kinds.get("hunt")
    if hunt:
        parts.append(f"Reachability pass: {hunt['done']} of {hunt['total']} unit(s) done.")
    deep = s.get("deep")
    read = kinds.get("read")
    if deep and read:
        continued = sum(1 for u in ledger.units_of(conn, analysis_id)
                        if u["kind"] == "read" and u["parent"])
        parts.append(f"Deep read: {read['total']} read unit(s), {continued} continuation(s); read in "
                     f"full: {deep['files_read']:,} of {deep['files']:,} files, "
                     f"{deep['lines_read']:,} of {deep['lines']:,} lines.")
    return " ".join(parts)


def guides_read(conn, analysis_id) -> list:
    from . import guides as guide_table     # local: guides imports nothing of ours, but keep the graph flat
    opened = set()
    for u in ledger.units_of(conn, analysis_id):
        opened.update(u["evidence"].get("guides") or [])
    return [name for name in guide_table.NAMES if name in opened]
```

- [ ] **Passo 4: `cmd_finish` aprende `--from-units`**

No subparser do `finish`:

```python
    # The ENGINE's close of a pipeline analysis (security/orchestrator.py):
    # the spend is the units' sum, and every gap the units leave lowers `done`.
    fn.add_argument("--from-units", action="store_true", dest="from_units")
```

Em `cmd_finish`, logo depois do bloco da verificação (a seguir a `verify_phase = coverage.phase(...)`, ~linha 2518) e antes de `stored = row["coverage_note"] or ""`:

```python
    # THE UNITS' ACCOUNT, on the engine's close of a pipeline analysis. Each
    # gap -- a unit that never finished, a lineage that gave up after
    # MAX_ATTEMPTS, a line of the deep scope nobody proved they read -- lowers
    # `done` exactly as the three guards above do, and goes into the paragraph
    # by name. The spend is the units' own sum: each unit's cost was recorded
    # by its close, and no caller of `finish` knows the total better.
    units_gap = ""
    units_sentence = ""
    if args.from_units and row["prepared"]:
        found = units.gaps(conn, args.analysis)
        if found and state == "done":
            state = "capped"
            print(f"finish: analysis {args.analysis} — {' '.join(found)}", file=sys.stderr)
        units_gap = " ".join(found)
        units_sentence = units.coverage_sentence(conn, args.analysis)
        args.spend = (units.summary(conn, args.analysis) or {}).get("spend_usd", 0)
        read = units.guides_read(conn, args.analysis)
        ledger.set_guides(conn, args.analysis, read=read)
        guides_note = _guides_sentence(ledger.guides_of(row).get("recommended", []), read)
```

Na montagem da nota, o `for part in (stored, args.note or "", unprepared_note, …)` passa a ler as partes de dois tuplos, e só o fecho a partir das unidades muda de ordem:

```python
    # THE `sast` ROW'S PROSE STANDS TOGETHER IN THE PARAGRAPH, in the order the
    # row carries it: the invariant every phase keeps (each row's note is one
    # contiguous run of the paragraph, test_every_phases_prose_is_a_substring_of_the_paragraph)
    # and the one test_a_close_from_the_units_keeps_every_row_a_substring_of_the_paragraph
    # (test_finish_units.py) pins for this close. On the engine's close of a
    # pipeline analysis the row is the units' sentence, the `--note` and the
    # guides sentence, so the three go in together, ahead of the gaps; every
    # other close keeps the order it always had.
    if args.from_units:
        parts = (stored, units_sentence, args.note or "", guides_note, units_gap,
                 unprepared_note, untriaged_note, decided_note, verify_gap)
    else:
        parts = (stored, args.note or "", unprepared_note, untriaged_note,
                 decided_note, guides_note, verify_gap)
    for part in parts:
```

(o corpo do ciclo — `part = part.strip()` e o `if part and part not in note` — fica como está.)

E na linha `sast` (no ramo `else:` de `if not row["prepared"]`), a frase das unidades à frente, a seguir ao bloco que já junta o `guides_note`:

```python
        sast_note = (args.note or "").strip() or prior_sast
        if guides_note and guides_note not in sast_note:
            sast_note = f"{sast_note} {guides_note}".strip()
        if units_sentence:
            sast_note = f"{units_sentence} {sast_note}".strip()
```

- [ ] **Passo 5: correr e ver passar, mais as suites do `finish`**

Run: `python3.13 -m pytest tests/security/test_finish_units.py tests/security/test_units.py tests/security/test_cli.py -p no:cacheprovider -q`
Expected: PASS (com `test_every_phases_prose_is_a_substring_of_the_paragraph`: um fecho sem `--from-units` monta o parágrafo pela ordem de sempre).

- [ ] **Passo 6: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **The engine closes a pipeline analysis from what its units proved.**
  `finish --from-units` records the units' summed cost and lowers `done` to
  `capped` for each gap the units leave — a unit that never finished, a
  lineage that gave up after three attempts, the lines of the deep scope no
  unit proved it read, counted against the inventory itself, so a slice no
  unit carried or a unit that gave up without saying what it missed is
  named too — naming the first of each in the report. The `sast` coverage
  row, and the paragraph beside it, say how much of the deep scope was read
  in full, and the guides read are the union of what every unit opened.
```

```bash
/usr/bin/git add bin/security/units.py bin/security/cli.py tests/security/test_finish_units.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): the close counts what the units proved, and names every gap"
```

---

### Task 10: O orquestrador

**Ficheiros:**
- Criar: `bin/security/orchestrator.py`
- Criar: `tests/security/fixtures/fake-engine` (executável; faz de `bin/agentloop` nos dois verbos que o orquestrador usa)
- Modificar: `bin/security/cli.py` (verbo `orchestrate` e o seu subparser)
- Modificar: `bin/security/ledger.py` (acrescentar `set_run_key`)
- Testes: `tests/security/test_orchestrator.py` (novo), `tests/test_checks_24h.py` (um teste: o formato das linhas do orquestrador contra a leitura do servidor)

**O contrato com o motor (a Task 11 implementa-o em `bin/agentloop`):**
- `"$ENGINE" __run-unit <job> <analysis> <unit> <commit> <repo>` corre UM run da unidade e fecha-a com `unit-close` antes de sair; o ambiente pode trazer `AL_SECURITY_UNIT_BUDGET` (o tecto da unidade, em USD). O run escreve o seu stream em `<log-root>/<job>/<stamp UTC %Y%m%dT%H%M%SZ>-<pid>.stream.ndjson`, onde `<pid>` é o do processo que o orquestrador lançou (o `$$` do `run_job`, que corre dentro desse processo): é por esse nome que o orquestrador encontra o que um run deixou quando morreu sem fechar a unidade.
- `"$ENGINE" stop <job>` com `AL_SECURITY_ORCHESTRATOR=1` pára todos os runs das unidades (cada um fecha a sua unidade com `--status stopped`) sem sinalizar o orquestrador.
- O pid do orquestrador é o do lock `<lock-dir>/pid`; o orquestrador escreve lá a sua fase (`<lock-dir>/phase`: `preparing`, `running units`, `finishing`, `stopping`), que o servidor lê (Task 13), e ao sair remove o lock se ainda for dele.
- A worktree do `prepare` vive em `<prepare-root>/<job>-<analysis>` — `$DATA_DIR/security/prepare` em produção, fora de `$WORKTREES_DIR`, que o varrimento de órfãos do tick (`wt_prune_orphans`) adoptaria e desmontaria e o servidor (`retained_worktrees`) percorreria a cada poll.
- O orçamento chega já validado pela derivação (Task 11: o `max_budget_usd` do job derivado); um valor que não é número é recusado com uma frase, nunca com um traceback.

**Interfaces:**
- Consome: Tasks 1, 5, 7, 8, 9 — em particular `units.close` (Task 7), `units.lineage_root` (Task 5) e o `prepare --plan` (Task 7).
- Produz:
  - `orchestrator.Orchestrator(db, analysis_id, *, engine, job, commit, repo, repo_path, prepare_root, log_root=None, parallel=3, budget=None, ignore="", log=None, lock_dir=None, poll=2.0, offline=False).run() -> int` (0; 2 para um `budget` que não é número, recusado antes de tudo)
  - `ledger.set_run_key(conn, unit_id, run_key) -> None`
  - `security orchestrate --analysis N --engine E --job J --commit C --repo R --repo-path P --prepare-root D [--log-root L] [--parallel K] [--budget B] [--ignore I] [--log F] [--lock-dir D] [--offline]` (em `AGENT_FORBIDDEN` desde a Task 8)
  - as linhas que o orquestrador escreve no `--log` têm o formato do `log_tick` (`<ISO UTC> <job>: …`), o que o `checks_24h` do servidor lê

- [ ] **Passo 1: o motor falso**

`tests/security/fixtures/fake-engine` (com `chmod +x`):

```python
#!/usr/bin/env python3
"""A stand-in for bin/agentloop in the two verbs the orchestrator uses.

__run-unit <job> <analysis> <unit> <commit> <repo>
    plays one run of the unit and closes it with `unit-close`, as run_job does.
    Its stream goes where run_job writes one --
    <FAKE_ENGINE_LOG_ROOT>/<job>/<UTC stamp>-<pid>.stream.ndjson, <pid> this
    very process -- because that is where the orchestrator looks for what a
    run left when it died without its close.
    FAKE_ENGINE_MODE:
      complete (default)  every unit does its job and closes
      skip-first          a read unit's first attempt leaves its last range unread
      crash               exits without a close and without a stream
      crash-after-read    a read unit reads every range, then exits WITHOUT a
                          close; the other kinds play `complete`
      slow                waits for the stop marker, then closes the unit `stopped`
      die-on-stop         a read unit reads its first range; every unit then
                          waits for the stop marker and exits WITHOUT a close
    FAKE_ENGINE_FIND=1: the hunt unit reports one sast finding, so a verify
    unit is planned.
stop <job>
    touches FAKE_ENGINE_STOP, which a `slow` or `die-on-stop` unit is waiting for.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).resolve().parents[3] / "bin"
sys.path.insert(0, str(BIN))
from security import ledger  # noqa: E402

CLI = BIN / "security" / "cli.py"
DB = os.environ["FAKE_ENGINE_DB"]
ROOT = os.environ.get("FAKE_ENGINE_ROOT", "/Users/me/run")
MODE = os.environ.get("FAKE_ENGINE_MODE", "complete")
BASE = {k: v for k, v in os.environ.items() if k not in ("AL_SECURITY_AGENT", "AL_SECURITY_UNIT_ID")}


def cli(*args, env=None, stdin=None):
    return subprocess.run([sys.executable, str(CLI), "--db", DB, *args], env=env or BASE,
                          input=stdin, capture_output=True, text=True)


def close(aid, uid, status, stream=""):
    cli("unit-close", "--analysis", aid, "--unit", uid, "--status", status, "--spend", "0.1",
        "--root", ROOT, *(["--stream", stream] if stream else []))


def write_stream(job, ranges):
    """An init event naming the run's root -- the orchestrator relativises a
    dead run's reads by it -- then a Read of each range, with the result
    shape Claude Code writes (tool_use_result.file)."""
    events = [{"type": "system", "subtype": "init", "cwd": ROOT}]
    for n, r in enumerate(ranges):
        path = f"{ROOT}/{r['path']}"
        events.append({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
            {"type": "tool_use", "id": f"t{n}", "name": "Read", "input": {"file_path": path}}]}})
        events.append({"type": "user", "parent_tool_use_id": None,
                       "message": {"content": [{"type": "tool_result", "tool_use_id": f"t{n}", "content": ""}]},
                       "tool_use_result": {"type": "text", "file": {
                           "filePath": path, "startLine": r["first"],
                           "numLines": r["last"] - r["first"] + 1, "totalLines": r["last"]}}})
    folder = Path(os.environ.get("FAKE_ENGINE_LOG_ROOT") or os.environ.get("TMPDIR", "/tmp")) / job
    folder.mkdir(parents=True, exist_ok=True)
    stream = folder / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}.stream.ndjson"
    stream.write_text("".join(json.dumps(e) + "\n" for e in events))
    return str(stream)


def wait_for_stop():
    marker = Path(os.environ["FAKE_ENGINE_STOP"])
    while not marker.exists():
        time.sleep(0.05)


def run_unit(job, aid, uid):
    conn = ledger.connect(DB)
    unit = ledger.get_unit(conn, int(uid))
    if MODE == "crash":
        sys.exit(3)
    if MODE in ("slow", "die-on-stop"):
        if MODE == "die-on-stop" and unit["kind"] == "read":
            write_stream(job, unit["payload"]["ranges"][:1])
        wait_for_stop()
        if MODE == "slow":
            close(aid, uid, "stopped")
        return
    agent = {**BASE, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": aid, "AL_SECURITY_UNIT_ID": uid}
    if unit["kind"] == "read":
        ranges = unit["payload"]["ranges"]
        if MODE == "skip-first" and unit["attempt"] == 1:
            ranges = ranges[:-1] or []
        stream = write_stream(job, ranges)
        if MODE == "crash-after-read":
            sys.exit(3)
        close(aid, uid, "success", stream)
        return
    if unit["kind"] == "triage":
        # Re-report every scanner row, as a triage unit must: its own category,
        # rule, severity and locations, a rationale of its own, a confidence.
        for item in unit["payload"].get("items", []):
            row = conn.execute("SELECT * FROM finding WHERE analysis_id=? AND fingerprint=?",
                               (int(aid), item["fingerprint"])).fetchone()
            if row is None:
                continue
            occ = [{"file": o["file"], "line": o["line"]} for o in conn.execute(
                "SELECT file, line FROM occurrence WHERE finding_id=?", (row["id"],))]
            cli("report-finding", "--analysis", aid, env=agent, stdin=json.dumps({
                "fingerprint": row["fingerprint"], "category": row["category"], "rule": row["rule"],
                "severity": row["severity"], "title": row["title"],
                "rationale": "the fake triage read the code around it",
                "occurrences": occ or [{"file": "src/a.py", "line": 1}],
                "candidate": {"confidence": {"score": "high", "reason": "fake"}}}))
    if unit["kind"] == "hunt" and os.environ.get("FAKE_ENGINE_FIND"):
        cli("report-finding", "--analysis", aid, env=agent, stdin=json.dumps({
            "fingerprint": "e" * 64, "category": "sast", "rule": "sql-injection", "severity": "high",
            "title": "t", "rationale": "the query is concatenated",
            "occurrences": [{"file": "src/a.py", "line": 1}],
            "candidate": {"trace": [{"kind": "entrypoint", "file": "src/a.py", "line": 1, "scope": "s",
                                     "description": "input"},
                                    {"kind": "sink", "file": "src/a.py", "line": 1, "scope": "s",
                                     "description": "execute"}],
                          "intended_control": "parameterised queries",
                          "confidence": {"score": "high", "reason": "r"},
                          "likelihood": {"score": "high", "reason": "r"},
                          "impact": {"score": "high", "reason": "r"}}}))
    if unit["kind"] == "verify":
        cli("report-verdict", "--analysis", aid, "--fingerprint", unit["payload"]["fingerprint"],
            env=agent, stdin=json.dumps({"verdict": "confirmed", "reason": "read src/a.py:1"}))
    close(aid, uid, "success")


if sys.argv[1] == "__run-unit":
    run_unit(sys.argv[2], sys.argv[3], sys.argv[4])
elif sys.argv[1] == "stop":
    Path(os.environ["FAKE_ENGINE_STOP"]).touch()
```

- [ ] **Passo 2: escrever os testes que falham**

`tests/security/test_orchestrator.py`:

```python
# tests/security/test_orchestrator.py
"""The orchestrator: every unit run to the end, continued when it falls short, and the analysis closed from the proof."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
from test_cli import open_analysis, run

from security import ledger, orchestrator

FAKE = Path(__file__).parent / "fixtures" / "fake-engine"
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


@pytest.fixture
def world(tmp_path, monkeypatch):
    """A git repository, an open deep analysis of it, and the fake engine's environment."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True, env=GIT_ENV)
    (repo / "src").mkdir()
    (repo / "src" / "a.py").write_text("".join(f"x{n} = {n}\n" for n in range(40)))
    (repo / "src" / "b.py").write_text("y = 1\n")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True,
                         text=True, check=True).stdout.strip()
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep", commit=sha)
    monkeypatch.setenv("FAKE_ENGINE_DB", str(db))
    monkeypatch.setenv("FAKE_ENGINE_STOP", str(tmp_path / "stop-marker"))
    monkeypatch.setenv("FAKE_ENGINE_LOG_ROOT", str(tmp_path / "logs"))
    monkeypatch.setenv("TMPDIR", str(tmp_path))
    return {"db": db, "aid": aid, "repo": repo, "sha": sha, "tmp": tmp_path}


def _kwargs(world, **kw):
    return dict(engine=str(FAKE), job="security-web", commit=world["sha"], repo="web",
                repo_path=str(world["repo"]), prepare_root=str(world["tmp"] / "prepare"),
                log_root=str(world["tmp"] / "logs"), poll=0.05, offline=True, **kw)


def _orchestrator(world, **kw):
    return orchestrator.Orchestrator(world["db"], world["aid"], **_kwargs(world, **kw))


def _spawn(world, **kw):
    """The orchestrator in a process of its own, as the engine runs it -- so a
    test can send it the signal a stop sends."""
    code = (f"import sys; sys.path.insert(0, {str(Path(orchestrator.__file__).parents[1])!r});"
            "from security import orchestrator as o;"
            f"sys.exit(o.Orchestrator({str(world['db'])!r}, {world['aid']}, "
            f"**{_kwargs(world, **kw)!r}).run())")
    return subprocess.Popen([sys.executable, "-c", code], env=os.environ.copy())


def _row(world):
    return next(r for r in run(world["db"], "list", "--project", "web") if r["id"] == world["aid"])


def _units(world):
    return ledger.units_of(ledger.connect(world["db"]), world["aid"])


def _last_attempts(world):
    """{lineage root id: its last unit} -- how a lineage ended."""
    all_units = _units(world)
    children = {}
    for u in all_units:
        if u["parent"]:
            children.setdefault(u["parent"], []).append(u)
    out = {}
    for root in (u for u in all_units if not u["parent"]):
        last = root
        while children.get(last["id"]):
            last = max(children[last["id"]], key=lambda c: c["seq"])
        out[root["id"]] = last
    return out


def _read_events(ranges, root="/Users/me/run"):
    """A stream reading every range, in the shape the fake engine writes."""
    events = [{"type": "system", "subtype": "init", "cwd": root}]
    for n, r in enumerate(ranges):
        path = f"{root}/{r['path']}"
        events.append({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
            {"type": "tool_use", "id": f"t{n}", "name": "Read", "input": {"file_path": path}}]}})
        events.append({"type": "user", "parent_tool_use_id": None,
                       "message": {"content": [{"type": "tool_result", "tool_use_id": f"t{n}", "content": ""}]},
                       "tool_use_result": {"type": "text", "file": {
                           "filePath": path, "startLine": r["first"],
                           "numLines": r["last"] - r["first"] + 1, "totalLines": r["last"]}}})
    return "".join(json.dumps(e) + "\n" for e in events)


def test_it_prepares_runs_every_unit_verifies_what_was_found_and_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_FIND", "1")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    kinds = sorted(u["kind"] for u in _units(world))
    assert "hunt" in kinds and "read" in kinds and "verify" in kinds
    assert all(u["state"] == "done" for u in _units(world))
    assert row["state"] == "done", row["coverage_note"]
    assert row["spend_usd"] == pytest.approx(0.1 * len(_units(world)))
    assert not (world["tmp"] / "prepare" / f"security-web-{world['aid']}").exists()


def test_the_prepare_worktree_is_its_own_and_a_leftover_is_cleared_first(world):
    """OUTSIDE the run worktrees, which the tick's orphan sweep adopts and tears
    down and the dashboard walks on every poll. A leftover a dead prepare left
    at the path is cleared before the checkout is cut, and nothing -- neither
    the directory nor git's registration of it -- outlives the phase."""
    leftover = world["tmp"] / "prepare" / f"security-web-{world['aid']}"
    leftover.mkdir(parents=True)
    (leftover / "stale.txt").write_text("from a prepare that died\n")
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]
    assert not leftover.exists()
    listed = subprocess.run(["git", "-C", str(world["repo"]), "worktree", "list", "--porcelain"],
                            capture_output=True, text=True, check=True).stdout
    assert listed.count("worktree ") == 1, f"only the repository's own checkout is registered: {listed}"


def test_a_read_that_fell_short_is_continued_and_the_analysis_still_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "skip-first")
    _orchestrator(world).run()
    reads = [u for u in _units(world) if u["kind"] == "read"]
    assert any(u["attempt"] == 2 and u["state"] == "done" for u in reads)
    assert _row(world)["state"] == "done"


def test_units_whose_runs_never_close_are_struck_out_and_their_reads_are_owed(world, monkeypatch):
    """A run that dies without its close is judged from what it left (here:
    nothing) and continued at the SAME attempt -- a crash is not the unit's
    failure -- until three runs of the lineage have died, which is the engine
    saying it cannot run it. The read unit covered nothing, so its whole slice
    is owed and the close names it: the crash scenario, where nothing was read."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash")
    _orchestrator(world).run()
    last = _last_attempts(world).values()
    struck = [u for u in last if u["kind"] in ("hunt", "read")]
    assert struck and all(u["state"] == "failed" for u in struck)
    assert all(u["attempt"] == 1 for u in _units(world)), "no attempt is spent on a run that died"
    row = _row(world)
    assert row["state"] == "capped"
    assert "could not run this unit" in row["coverage_note"]
    assert "were never read in full" in row["coverage_note"]
    assert "src/a.py:1-40" in row["coverage_note"]


def test_a_read_whose_run_died_after_reading_everything_is_done_not_run_again(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-after-read")
    _orchestrator(world).run()
    reads = [u for u in _units(world) if u["kind"] == "read"]
    assert [(u["state"], u["attempt"], u["parent"]) for u in reads] == [("done", 1, None)]
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_resume_judges_a_unit_whose_run_died_with_the_orchestrator(world):
    """The unit a dead orchestrator left `running`, its run gone: judged from
    the stream it left -- found by the name run_job gives it, <stamp>-<pid> --
    and, having read everything, done; never run a second time."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    conn = ledger.connect(world["db"])
    read = next(u for u in ledger.units_of(conn, world["aid"]) if u["kind"] == "read")
    gone = subprocess.Popen(["true"])
    gone.wait()
    ledger.start_unit(conn, read["id"], f"security-web/{gone.pid}")
    logs = world["tmp"] / "logs" / "security-web"
    logs.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    (logs / f"{stamp}-{gone.pid}.stream.ndjson").write_text(_read_events(read["payload"]["ranges"]))
    assert _orchestrator(world).run() == 0
    after = ledger.get_unit(conn, read["id"])
    assert (after["state"], after["attempt"]) == ("done", 1)
    assert not [u for u in ledger.units_of(conn, world["aid"]) if u["parent"] == read["id"]]
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_the_budget_stops_the_launches_and_the_close_says_so(world):
    """0.05: the first unit launched -- whichever kind it is, with or without
    the sandbox's hygiene row -- spends 0.10, so the rest never start."""
    _orchestrator(world, budget=0.05, parallel=1).run()
    row = _row(world)
    assert row["state"] == "capped"
    assert "The analysis budget of $0.05 was spent before every unit ran." in row["coverage_note"]
    assert any(u["state"] == "pending" for u in _units(world))


def test_a_budget_the_last_unit_spends_to_the_cent_is_not_a_gap(world):
    """The sentence says units were left unrun; with none left it would be a
    false statement in the report."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    planned = len(_units(world))
    _orchestrator(world, budget=round(0.1 * planned, 2), parallel=1).run()
    row = _row(world)
    assert row["state"] == "done", row["coverage_note"]
    assert "budget" not in row["coverage_note"]


def test_a_budget_that_is_not_a_number_is_refused_with_a_sentence(world, tmp_path, capsys):
    lock = tmp_path / "lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    assert _orchestrator(world, budget="5 USD", lock_dir=str(lock)).run() == 2
    err = capsys.readouterr().err
    assert "--budget must be a number" in err and "'5 USD'" in err
    assert "Traceback" not in err
    assert (_row(world)["state"], _units(world)) == ("running", []), "nothing was started, nothing closed"
    assert not lock.exists(), "released: the tick must not resume a run that can never start"


def test_a_stop_interrupts_and_a_resume_finishes(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "slow")
    proc = _spawn(world)
    deadline = time.time() + 60
    while time.time() < deadline and not any(u["state"] == "running" for u in _units(world)):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=60) == 0
    assert _row(world)["state"] == "interrupted"
    assert not any(u["state"] == "running" for u in _units(world))
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    _orchestrator(world).run()
    assert _row(world)["state"] == "done"


def test_a_stop_judges_what_a_run_that_died_without_its_close_had_read(world, monkeypatch):
    """The runs a stop ends here die WITHOUT closing their units (a kill that
    reached them before their close could). What the read unit had read --
    its first range -- counts; the rest continues at the SAME attempt, and a
    resume reads only that."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "die-on-stop")
    proc = _spawn(world)
    logs = world["tmp"] / "logs" / "security-web"
    deadline = time.time() + 60
    while time.time() < deadline and not list(logs.glob("*.stream.ndjson")):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=60) == 0
    assert _row(world)["state"] == "interrupted"
    reads = [u for u in _units(world) if u["kind"] == "read"]
    first = next(u for u in reads if not u["parent"])
    assert first["state"] == "incomplete"
    assert first["evidence"]["covered"] == {"src/a.py": [[1, 40]]}
    cont = next(u for u in reads if u["parent"] == first["id"])
    assert (cont["attempt"], cont["state"]) == (1, "pending")
    assert [r["path"] for r in cont["payload"]["ranges"]] == ["src/b.py"]
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    _orchestrator(world).run()
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_the_orchestrator_writes_its_phase_into_its_own_lock(world, tmp_path, monkeypatch):
    """Between two units no slot is alive; the phase in the lock is what the
    page reads to know the analysis is still in hand (Task 13)."""
    lock = tmp_path / "lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    seen = []
    real = orchestrator.Orchestrator._set_phase

    def spy(self, phase):
        real(self, phase)
        seen.append((lock / "phase").read_text().strip())
    monkeypatch.setattr(orchestrator.Orchestrator, "_set_phase", spy)
    assert _orchestrator(world, lock_dir=str(lock)).run() == 0
    assert seen == ["preparing", "running units", "finishing"]
    assert not lock.exists(), "released on the way out, phase file and all"


def test_a_plan_that_fails_closes_the_analysis_capped_never_done(world, monkeypatch):
    """A quick analysis has no inventory, so no gap of its own would lower a
    `done` over units nobody planned: the failure has to."""
    aid = open_analysis(world["db"], profile="quick", commit=world["sha"], run_id="r2")
    run(world["db"], "prepare", "--analysis", str(aid), "--root", str(world["repo"]), "--offline")

    def broken(*_a, **_k):
        raise RuntimeError("the checklist could not be read")
    monkeypatch.setattr(orchestrator.units, "plan", broken)
    assert orchestrator.Orchestrator(world["db"], aid, **_kwargs(world)).run() == 0
    row = next(r for r in run(world["db"], "list", "--project", "web") if r["id"] == aid)
    assert row["state"] == "capped"
    assert "could not plan this analysis's units" in row["coverage_note"]


def test_the_lock_is_released_only_if_it_is_still_the_orchestrator_s(world, tmp_path):
    mine = tmp_path / "lock-mine"
    mine.mkdir()
    (mine / "pid").write_text(str(os.getpid()))
    _orchestrator(world, lock_dir=str(mine)).run()
    assert not mine.exists()
    theirs = tmp_path / "lock-theirs"
    theirs.mkdir()
    (theirs / "pid").write_text("1")
    # the analysis is closed now, so this run returns at once -- and must leave the lock alone
    _orchestrator(world, lock_dir=str(theirs)).run()
    assert theirs.exists()
```

E em `tests/test_checks_24h.py`, no fim (o formato das linhas do orquestrador contra a leitura do servidor, `checks_24h`; o `bin/` entra no `sys.path` aqui, como o `tests/security/conftest.py` faz para a suite de segurança):

```python
def test_an_orchestrator_line_is_read_by_the_same_parse_as_every_tick_line(clean_data, tmp_path):
    """`checks_24h` reads a tick.log line's first 20 characters as an ISO UTC
    stamp and the job up to the first `: ` -- log_tick's format. The
    orchestrator writes into the same file, and a line in any other shape is
    silently skipped. A probe message ending `, skipped` is one the server
    counts, so the count proves the stamp and the job were both parsed."""
    import sys
    bin_dir = str(Path(__file__).resolve().parent.parent / "bin")
    if bin_dir not in sys.path:
        sys.path.insert(0, bin_dir)
    from security import orchestrator
    srv = clean_data
    o = orchestrator.Orchestrator(tmp_path / "security.db", 1, engine="/usr/bin/true",
                                  job="security-web", commit="c", repo="web",
                                  repo_path=str(tmp_path), prepare_root=str(tmp_path / "prepare"),
                                  log=str(srv.DATA_DIR / "tick.log"))
    o.log("a probe of the line format, skipped")
    assert _counts(srv)["security-web"]["failed"] == 1, (srv.DATA_DIR / "tick.log").read_text()
```

(`from pathlib import Path` no topo de `tests/test_checks_24h.py`, se ainda lá não estiver.)

- [ ] **Passo 3: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_orchestrator.py -p no:cacheprovider -q`
Expected: FAIL — `ImportError: cannot import name 'orchestrator'`.

- [ ] **Passo 4: implementar `bin/security/orchestrator.py`**

```python
# bin/security/orchestrator.py
"""Runs an analysis's units to the end and closes it: the engine's half of the pipeline.

WHY A PROCESS OF ITS OWN, AND WHY IT IS NOT A MODEL. An analysis used to be
one agent deciding when it had done enough; on a large repository it always
decided early. This loop decides instead, from the ledger: it launches every
unit the plan holds (security/units.py), at most `parallel` at a time, each
as an ordinary run of the derived job (`__run-unit` in bin/agentloop); it
lets each run's own close judge the unit and plan what it left undone; it
launches the continuations; it plans verification once everything else has
settled; and it closes the analysis from what the units proved (`finish
--from-units`). Nothing here reads a model's opinion of its own progress.

EVERYTHING IS IN THE LEDGER, so this process can die at any moment and a new
one picks up where it stopped: a unit whose run is still alive is adopted, a
unit whose run died without a close is judged from the stream and the ledger
it left -- exactly as its own close would have judged it (units.close) -- and
a done unit never runs twice.

A RUN THAT DIED IS NOT THE UNIT'S FAILURE. What it proved counts; what it did
not becomes a continuation at the SAME attempt. Three runs of one lineage in a
row that end without a close are the engine saying it cannot run it: the
lineage is given up with that reason, and the close names it.

A STOP IS NOT A FAILURE EITHER. SIGTERM (the engine's `stop`, which signals
the pid in the analysis lock) stops launching, has the engine stop the units'
runs -- each closes its unit `stopped`, which continues at the same attempt;
one that dies before its close is judged as above -- and leaves the analysis
`interrupted`, to be resumed.

THE BUDGET IS THE ANALYSIS'S. The spend is the units' sum; nothing is
launched once it reaches `budget`, and each unit is given an even share of
what remains (never under MIN_UNIT_BUDGET) -- on Claude Code the engine turns
it into `--max-budget-usd`; elsewhere it is read at the end, which is why
this loop checks the sum itself before every launch.

ITS LIFE IS DATA. The phase it is in goes into its lock (`phase`), and the
page reads it beside the lock's liveness (security_checklist in
bin/agentloop-server): between two units no run is alive, and that is not an
analysis that died.
"""

import calendar
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import ledger, units

MIN_UNIT_BUDGET = 0.50
LAUNCH_STRIKES = 3
STOP_GRACE_SECONDS = 300
CLI = Path(__file__).resolve().parent / "cli.py"
# The engine exports these into a unit's run; the orchestrator must never pass
# them on -- its own CLI calls are the engine's, not an agent's.
_SESSION_VARS = ("AL_SECURITY_AGENT", "CC_SECURITY_AGENT", "AL_SECURITY_UNIT_ID",
                 "CC_SECURITY_UNIT_ID", "AL_SECURITY_UNIT_BUDGET")
PREPARE_FAILED_NOTE = ("The deterministic phase did not complete -- a phase, or the planning "
                       "of the units, failed (see tick.log) -- so no unit ran.")


def _alive(pid) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _pid_of(run_key):
    tail = (run_key or "").rsplit("/", 1)[-1]
    return int(tail) if tail.isdigit() else None


def _parse_budget(value):
    """(budget, refusal). The engine hands the derivation's own value
    (security_analysis_budget in bin/agentloop: the derived job's
    max_budget_usd, whose fallback for a declared value that is not a number
    is SECURITY_FALLBACK_BUDGET_USD), so text float() cannot read is a hand
    run -- refused with a sentence, never a traceback the tick would take for
    a crash and resume three times."""
    text = str(value if value is not None else "").strip()
    if not text:
        return None, ""
    try:
        budget = float(text)
    except ValueError:
        budget = math.nan
    if not math.isfinite(budget):
        return None, f"--budget must be a number of US dollars, not {text!r}"
    return budget, ""


def _stream_root(stream):
    """The run's own root, off its stream's init event (`cwd`, which every
    platform's normalised stream carries): a dead run's reads are made
    relative to it, as the engine's close makes them relative to run_job's
    cwd."""
    try:
        with open(stream, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(event, dict) and event.get("type") == "system"
                        and event.get("subtype") == "init"):
                    return str(event.get("cwd") or "")
    except OSError:
        pass
    return ""


class Orchestrator:
    def __init__(self, db, analysis_id, *, engine, job, commit, repo, repo_path, prepare_root,
                 log_root=None, parallel=3, budget=None, ignore="", log=None, lock_dir=None,
                 poll=2.0, offline=False):
        self.db, self.aid = str(db), int(analysis_id)
        self.engine, self.job, self.commit, self.repo = str(engine), job, commit, repo
        self.repo_path, self.prepare_root = str(repo_path), Path(prepare_root)
        self.log_root = Path(log_root) if log_root else None
        self.parallel = max(1, min(8, int(parallel or 3)))
        self.budget, self.budget_error = _parse_budget(budget)
        self.ignore, self.log_path, self.lock_dir, self.poll = ignore or "", log, lock_dir, poll
        self.offline = bool(offline)     # tests: `prepare --offline`, no network
        self.conn = ledger.connect(self.db)
        self.children = {}        # pid -> (Popen, unit id)
        self.adopted = {}         # pid -> unit id: runs a previous orchestrator left alive
        self.strikes = {}         # lineage root id -> its runs in a row that died unclosed
        self.stopping = False
        self.budget_spent = False
        self.prepare_proc = None
        self.env = {k: v for k, v in os.environ.items() if k not in _SESSION_VARS}

    # -- small helpers -------------------------------------------------------
    def log(self, message):
        """One tick.log line in log_tick's own format -- `<ISO UTC> <job>:
        <message>` (bin/agentloop) -- because the dashboard reads that file
        by exactly that shape (checks_24h, bin/agentloop-server) and skips a
        line in any other."""
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = f"{stamp} {self.job}: analysis {self.aid} — {message}\n"
        if self.log_path:
            try:
                with open(self.log_path, "a", encoding="utf-8") as out:
                    out.write(line)
                return
            except OSError:
                pass
        sys.stderr.write(line)

    def _on_signal(self, _signum, _frame):
        self.stopping = True
        proc = self.prepare_proc
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)   # `prepare` leads its own group
            except OSError:
                pass

    def _cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), "--db", self.db, *args],
                              env=self.env, capture_output=True, text=True)

    def _row(self):
        return self.conn.execute("SELECT * FROM analysis WHERE id=?", (self.aid,)).fetchone()

    def _git(self, *args):
        return subprocess.run(["git", "-C", self.repo_path, *args], capture_output=True, text=True)

    def _lock_is_mine(self) -> bool:
        if not self.lock_dir:
            return False
        try:
            return Path(self.lock_dir, "pid").read_text().strip() == str(os.getpid())
        except OSError:
            return False

    def _set_phase(self, phase):
        """The phase this orchestrator is in -- preparing, running units,
        finishing, stopping -- written into its lock, where the server reads
        it beside the lock's liveness for the page (security_checklist):
        between two units no slot is alive, and the phase is what says the
        analysis is still in hand. Only into a lock that is still this
        process's own, and atomically, so a reader never sees half a word."""
        if not self._lock_is_mine():
            return
        tmp = Path(self.lock_dir, ".phase.tmp")
        try:
            tmp.write_text(phase + "\n")
            os.replace(tmp, Path(self.lock_dir, "phase"))
        except OSError:
            pass

    # -- the run ---------------------------------------------------------------
    def run(self) -> int:
        previous = {s: signal.signal(s, self._on_signal)
                    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            if self.budget_error:
                # Before anything else, and inside the `finally` that lets the
                # lock go: nothing started, so nothing is closed either, and a
                # lock left behind would have the tick resume a run that can
                # never start.
                message = f"{self.budget_error}. Nothing was started."
                sys.stderr.write(f"orchestrate: {message}\n")
                self.log(message)
                return 2
            row = self._row()
            if row is None or row["state"] != "running":
                self.log(f"is {row['state'] if row else 'missing'}; nothing to run")
                return 0
            if not row["prepared"] and not self._prepare():
                if self.stopping:
                    return self._interrupt()
                self._finish(PREPARE_FAILED_NOTE, state="capped")
                return 0
            if not ledger.units_of(self.conn, self.aid) and not self._plan():
                return 0
            self._adopt()
            self._set_phase("running units")
            self._loop()
            if self.stopping:
                return self._interrupt()
            # THE BUDGET SENTENCE ONLY WHEN IT IS TRUE: units left unsettled. A
            # budget the last unit spent to the cent left nothing unrun, and
            # "spent before every unit ran" would be a false line in the report.
            left = units.unsettled(ledger.units_of(self.conn, self.aid))
            self._finish(f"The analysis budget of ${self.budget:.2f} was spent before every unit ran."
                         if self.budget_spent and left else "")
            return 0
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)
            self._release()

    def _prepare(self) -> bool:
        """The deterministic phase, once, in a checkout of the analysed commit
        that is this orchestrator's alone, and with `--plan`: only the
        orchestrator's prepare writes the plan (security/cli.py, cmd_prepare).

        OUTSIDE THE ENGINE'S WORKTREES FOLDER -- <prepare-root>/<job>-<id>,
        $DATA_DIR/security/prepare in production. Every directory under
        $WORKTREES_DIR is a run dir to the engine and the server: the tick's
        orphan sweep adopts it (writing `.ended` into the very checkout being
        analysed) and tears it down once its TTL is up, and the dashboard
        os.walk()s it on every poll. Whatever a prepare that died left at the
        path is cleared before the checkout is cut, and the checkout -- and
        git's record of it -- goes when the phase ends, whatever the outcome.

        A failure here is non-zero from `prepare`: a phase that broke, or a
        plan that could not be written (all or nothing, so there is no half of
        one). Either way the caller closes the analysis `capped`."""
        self._set_phase("preparing")
        tree = self.prepare_root / f"{self.job}-{self.aid}"
        tree.parent.mkdir(parents=True, exist_ok=True)
        self._drop_tree(tree)
        made = self._git("worktree", "add", "--detach", str(tree), self.commit)
        if made.returncode != 0:
            self.log(f"could not cut a worktree at {self.commit[:12]} for the deterministic "
                     f"phase: {made.stderr.strip()}")
            self._drop_tree(tree)
            return False
        try:
            self.log("deterministic phase started")
            self.prepare_proc = subprocess.Popen(
                [sys.executable, str(CLI), "--db", self.db, "prepare", "--analysis", str(self.aid),
                 "--root", str(tree), "--ignore", self.ignore, "--plan",
                 *(["--offline"] if self.offline else [])],
                env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            _out, err = self.prepare_proc.communicate()
            code = self.prepare_proc.returncode
        finally:
            self.prepare_proc = None
            self._drop_tree(tree)
        if code != 0:
            self.log(f"deterministic phase failed (rc {code}): {(err or '').strip()[-400:]}")
            return False
        self.log("deterministic phase done")
        return True

    def _drop_tree(self, tree):
        """The prepare checkout gone, and git's record of it with it: `worktree
        remove --force` for a registered one, rmtree for whatever is left (a
        directory a crash left behind unregistered), then `worktree prune`, so
        no registration outlives its directory in the operator's checkout."""
        if tree.exists():
            self._git("worktree", "remove", "--force", str(tree))
            shutil.rmtree(tree, ignore_errors=True)
        self._git("worktree", "prune")

    def _plan(self) -> bool:
        """A prepared analysis with no units: prepared before the pipeline, or
        a resume after a prepare whose plan failed (nothing half-written: the
        plan is all or nothing). Planned here, without the per-slice guides.
        A plan that fails closes the analysis `capped` with the reason, never
        a `done` over units nobody planned."""
        try:
            planned = units.plan(self.conn, self.aid)
        except Exception as exc:  # noqa: BLE001 -- said in tick.log and in the report
            self.log(f"could not plan its units: {type(exc).__name__}: {exc}")
            self._finish(f"The engine could not plan this analysis's units "
                         f"({type(exc).__name__}), so no unit ran.", state="capped")
            return False
        self.log(f"{len(planned)} unit(s) planned")
        return True

    def _adopt(self):
        """Every unit a previous orchestrator left `running`: a run still alive
        is adopted and waited for (its own close settles the unit); one that is
        gone is judged from what it left, as `_after` judges a child of this
        orchestrator that died unclosed."""
        for u in ledger.units_of(self.conn, self.aid):
            if u["state"] != "running":
                continue
            pid = _pid_of(u["run_key"])
            if pid and _alive(pid):
                self.adopted[pid] = u["id"]
            else:
                self._after(u["id"], pid)

    def _loop(self):
        verify_planned = False
        while not self.stopping:
            self._reap()
            everything = ledger.units_of(self.conn, self.aid)
            spend = sum(u["spend_usd"] for u in everything)
            if self.budget is not None and spend >= self.budget:
                self.budget_spent = True
            if not verify_planned and not units.unsettled(everything, ("triage", "hunt", "read")):
                planned = units.plan_verification(self.conn, self.aid)
                verify_planned = True
                if planned:
                    self.log(f"{len(planned)} verify unit(s) planned")
                continue
            if not self.budget_spent:
                room = self.parallel - len(self.children) - len(self.adopted)
                for unit in units.launchable(self.conn, self.aid, room):
                    self._launch(unit, spend)
            if not self.children and not self.adopted:
                waiting = any(u["state"] == "pending" for u in ledger.units_of(self.conn, self.aid))
                if self.budget_spent or (verify_planned and not waiting):
                    return
            time.sleep(self.poll)

    def _launch(self, unit, spend):
        env = dict(self.env)
        if self.budget is not None:
            share = (self.budget - spend) / (len(self.children) + len(self.adopted) + 1)
            env["AL_SECURITY_UNIT_BUDGET"] = f"{max(MIN_UNIT_BUDGET, share):.2f}"
        # RUNNING BEFORE THE LAUNCH, not after: a verify unit's session writes
        # its verdict through a door that only opens for a running unit, and a
        # fast one would otherwise reach it first.
        if not ledger.start_unit(self.conn, unit["id"], f"{self.job}/launching"):
            return
        proc = subprocess.Popen([self.engine, "__run-unit", self.job, str(self.aid),
                                 str(unit["id"]), self.commit, self.repo],
                                env=env, stdin=subprocess.DEVNULL)
        ledger.set_run_key(self.conn, unit["id"], f"{self.job}/{proc.pid}")
        self.children[proc.pid] = (proc, unit["id"])
        self.log(f"unit {units.label(self.conn, unit)} launched (pid {proc.pid})")

    def _reap(self):
        for pid, (proc, uid) in list(self.children.items()):
            if proc.poll() is None:
                continue
            del self.children[pid]
            self._after(uid, pid)
        for pid, uid in list(self.adopted.items()):
            if _alive(pid):
                continue
            del self.adopted[pid]
            self._after(uid, pid)

    def _after(self, uid, pid):
        unit = ledger.get_unit(self.conn, uid)
        if unit is None:
            return
        lineage = units.lineage_root(self.conn, unit)["id"]
        if unit["state"] not in ("pending", "running"):
            self.strikes.pop(lineage, None)      # a run closed it: the engine can run it
            self.log(f"unit {units.label(self.conn, unit)} {unit['state']} "
                     f"(${unit['spend_usd']:.2f}) — {unit['note']}")
            return
        # THE RUN ENDED WITHOUT CLOSING ITS UNIT -- killed, crashed, refused by
        # the engine before it started, or orphaned by an orchestrator that
        # died. Judged from what it left, as its own close would have judged it
        # (units.close, under `stopped`): what it proved counts, and the rest
        # continues at the SAME attempt, because a run that died is not the
        # unit's failure. Three such endings in a row of one lineage are the
        # engine saying it cannot run it: the continuation is given up with
        # that reason, and the close names it.
        self.strikes[lineage] = self.strikes.get(lineage, 0) + 1
        out = self._judge_orphan(unit, pid)
        cont = out.get("continuation")
        if cont and self.strikes[lineage] >= LAUNCH_STRIKES:
            ledger.settle_unit(self.conn, cont, "failed", 0, {},
                               f"The engine could not run this unit: {LAUNCH_STRIKES} runs "
                               "ended without a close (see tick.log).")
            self.log(f"unit {units.label(self.conn, unit)} failed: the engine could not run it")
        else:
            self.log(f"unit {units.label(self.conn, unit)} ended without its close — judged "
                     f"{out.get('state')} from what its run left")

    def _stream_of(self, unit, pid):
        """The stream a unit's run left, found by the name run_job gives it:
        <log-root>/<job>/<UTC stamp>-<pid>.stream.ndjson, <pid> being the
        process this orchestrator launched (the run's own $$). The newest one
        stamped no earlier than the unit started -- a pid the kernel reissued
        names older files too. None without a log root or a file."""
        if not self.log_root or not pid:
            return None
        started = int(unit.get("started") or 0)
        best = None
        for path in Path(self.log_root, self.job).glob(f"*-{pid}.stream.ndjson"):
            try:
                when = calendar.timegm(time.strptime(path.name.split("-", 1)[0], "%Y%m%dT%H%M%SZ"))
            except ValueError:
                continue
            if when >= started - 5 and (best is None or when > best[0]):
                best = (when, path)
        return str(best[1]) if best else None

    def _judge_orphan(self, unit, pid) -> dict:
        stream = self._stream_of(unit, pid)
        try:
            return units.close(self.conn, unit, stream=stream or "",
                               root=_stream_root(stream) if stream else "", status="stopped")
        except Exception as exc:  # noqa: BLE001 -- a unit must never stay `running` for ever
            self.log(f"could not judge unit {unit['id']} ({type(exc).__name__}: {exc}) — running it again")
            ledger.reset_unit(self.conn, unit["id"])
            return {"state": "pending", "continuation": None}

    def _interrupt(self) -> int:
        self._set_phase("stopping")
        self.log("stopping its units")
        try:
            subprocess.run([self.engine, "stop", self.job], capture_output=True, timeout=120,
                           env={**self.env, "AL_SECURITY_ORCHESTRATOR": "1"})
        except (OSError, subprocess.SubprocessError) as exc:
            self.log(f"could not ask the engine to stop the units: {exc}")
        deadline = time.time() + STOP_GRACE_SECONDS
        while (self.children or self.adopted) and time.time() < deadline:
            self._reap()
            time.sleep(min(self.poll, 1.0))
        # Past the grace, a unit whose run is STILL ALIVE stays `running`: its
        # own close settles it whenever it ends, and a resume adopts it. One
        # whose run is gone -- including one a predecessor left and this loop
        # never launched -- is judged from what it left.
        for u in ledger.units_of(self.conn, self.aid):
            pid = _pid_of(u["run_key"])
            if u["state"] == "running" and not (pid and _alive(pid)):
                self._judge_orphan(u, pid)
        ledger.interrupt_analysis(self.conn, self.aid)
        self.log("interrupted — `agentloop security resume` continues it")
        return 0

    def _finish(self, note, state="done"):
        self._set_phase("finishing")
        args = ["finish", "--analysis", str(self.aid), "--state", state, "--from-units"]
        if note:
            args += ["--note", note]
        out = self._cli(*args)
        if out.returncode != 0:
            self.log(f"could not close: {out.stderr.strip()[-400:]}")
        row = self._row()
        self.log(f"closed {row['state']} (${row['spend_usd']:.2f})")

    def _release(self):
        if self._lock_is_mine():
            shutil.rmtree(self.lock_dir, ignore_errors=True)
```

- [ ] **Passo 5: `ledger.set_run_key`**

No fim de `bin/security/ledger.py`, junto das funções das unidades:

```python
def set_run_key(conn, unit_id, run_key) -> None:
    """Which run carries a unit: `<job>/<pid>`, written once the launch has a
    pid. A resume reads it to adopt a run that is still alive."""
    with conn:
        conn.execute("UPDATE unit SET run_key=? WHERE id=?", (run_key, unit_id))
```

- [ ] **Passo 5b: o verbo `orchestrate`**

Em `cli.py`, acrescentar `orchestrator` ao import de `security` e, a seguir aos verbos da Task 8:

```python
def cmd_orchestrate(args):
    """The engine's long-running half of an analysis (security/orchestrator.py).
    `__run-analysis` in bin/agentloop takes the analysis lock and execs this,
    so the lock's pid IS this process: a stop signals it directly. A budget
    that is not a number exits 2 with a sentence (Orchestrator.run)."""
    sys.exit(orchestrator.Orchestrator(
        args.db, args.analysis, engine=args.engine, job=args.job, commit=args.commit,
        repo=args.repo, repo_path=args.repo_path, prepare_root=args.prepare_root,
        log_root=args.log_root or None, parallel=args.parallel, budget=args.budget,
        ignore=args.ignore, log=args.log or None, lock_dir=args.lock_dir or None,
        offline=args.offline).run())
```

Subparser:

```python
    oc = sub.add_parser("orchestrate", parents=[dbflag]); oc.set_defaults(fn=cmd_orchestrate)
    for flag in ("--engine", "--job", "--commit", "--repo", "--repo-path", "--prepare-root"):
        oc.add_argument(flag, required=True, dest=flag[2:].replace("-", "_"))
    oc.add_argument("--analysis", type=int, required=True)
    # Where run_job writes the units' streams ($LOG_DIR): how a run that died
    # without its close is found and judged. Empty: such a run is judged from
    # the ledger alone.
    oc.add_argument("--log-root", default="", dest="log_root")
    oc.add_argument("--parallel", type=int, default=3)
    oc.add_argument("--budget", default="")
    oc.add_argument("--ignore", default="")
    oc.add_argument("--log", default="")
    oc.add_argument("--lock-dir", default="", dest="lock_dir")
    oc.add_argument("--offline", action="store_true")
```

- [ ] **Passo 6: correr e ver passar**

Run: `python3.13 -m pytest tests/security/test_orchestrator.py -p no:cacheprovider -q` e `python3.13 -m pytest tests/test_checks_24h.py -p no:cacheprovider -q`
Expected: PASS (os dois testes do stop levam uns segundos cada).

- [ ] **Passo 7: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **An orchestrator runs an analysis to the end, whatever its size.** It
  prepares the analysis in a worktree of its own at the analysed commit —
  outside the run worktrees the tick sweeps, cleared first if a crash left
  one, and removed when the phase ends — launches every unit as an ordinary
  run of the derived job, up to the project's parallelism, continues what
  each unit left undone, plans verification once the rest has settled, and
  closes the analysis from what the units proved; a plan that could not be
  written closes it `capped`, never `done`. The analysis budget is enforced
  across units, and a budget that is not a number is refused with a
  sentence. A run that dies without closing its unit is judged from the
  stream it left — what it read counts, the rest continues at the same
  attempt — and three such deaths in a row give the unit up. A stop leaves
  the analysis `interrupted` with its finished units kept, a new
  orchestrator adopts the runs a dead one left behind, and the orchestrator
  writes its phase and its log lines where the dashboard reads them.
```

```bash
/usr/bin/git add bin/security/orchestrator.py bin/security/cli.py bin/security/ledger.py tests/security/test_orchestrator.py tests/security/fixtures/fake-engine tests/test_checks_24h.py CHANGELOG.md
/usr/bin/git commit -m "feat(security): an orchestrator runs every unit of an analysis to the end"
```

---

### Task 11: O motor corre a análise como pipeline

**Ficheiros:**
- Modificar: `bin/agentloop`:
  - derivação do job (`security_derived_jobs`, ~560-657): `max_parallel`, ferramentas fechadas, prompt de marcação
  - `security_prompt` (~868-990): removido
  - `SECURITY_DISALLOWED_TOOLS` (~775): trocado por `security_disallowed_tools`
  - `security_run_analysis` (~1085-1099): trocado por `security_orchestrate` e `security_run_unit`
  - `cmd_security_analyze` (~1101-1247): lock, sweep e lançamento destacado reutilizável
  - `security_guides_read` e `security_task_count` (~1264-1308): removidos
  - `security_close_analysis` (~1310-1361): passa a fechar a unidade
  - `platform_caps` (~2555-2580): sai o `prepare_inline`
  - `cmd_stop` (~5342): a análise pára inteira
  - `run_classify` (~6040): tecto da unidade
  - `run_job`: prompt da unidade depois da linha ~6217, orçamento ~6243, `AL_RUN_CWD` no `run_env` ~6698, cabeçalho do precheck ~6718, bloco do prepare do lado do motor ~6818-6867 removido
  - dispatch (~8626-8705): `__run-unit`, `security resume`, usage
  - `cmd_project_rename` (~8381): também respeita o lock
- Modificar: `test/fake-claude` (simulador de unidades)
- Modificar: `test/selftest.sh` (blocos novos; retirar os de funções removidas)
- Modificar: `test/e2e.test.sh` (cenários 8, 9, 10, 11, 12, 24, 42, 46)
- Modificar: `README.md` (secção de segurança: o `prepare` deixou de ser o primeiro comando do agente)

**Interfaces:**
- Consome: Tasks 7, 8, 10 (`unit-prompt`, `unit-close`, `units --label`, `resume`, `interrupt`, `orchestrate`, `analysis --id`).
- Produz:
  - `security_orchestrate <job> <analysis> <repo>` — toma `$LOCK_DIR/<job>/.analysis`, escreve lá o id da análise, faz `exec` do orquestrador (o pid do lock é o dele)
  - `__run-unit <job> <analysis> <unit> <commit> <repo>` → `security_run_unit` → `run_job <job> --force` com `AL_BASE_OVERRIDE=<commit>`, `AL_SECURITY_UNIT_ID`, e o resto do ambiente de uma análise
  - `security_launch_detached <job> <analysis> <branch> <repo>` — o lançamento destacado que o `security analyze --detach` já fazia, agora partilhado com o `resume` e o tick
  - `agentloop security resume <project> <analysis-id>`
  - `security_parallel <project>` → 1..8 (3 por omissão), `security_disallowed_tools <platform>` e `security_analysis_budget <job-id>` (o `max_budget_usd` do job derivado, já validado pela derivação, com o seu fallback)
  - o orquestrador arranca com `--prepare-root "$DATA_DIR/security/prepare"` e `--log-root "$LOG_DIR"`
  - o `run_env` de qualquer run ganha `AL_RUN_CWD` (o `security read` usa-o)

- [ ] **Passo 1: helpers e derivação**

Substituir `SECURITY_DISALLOWED_TOOLS=""` e o seu comentário por:

```bash
# The subagent tool a security unit is launched WITHOUT, per platform. The
# engine distributes an analysis's work into units (security/orchestrator.py);
# a unit that fans out on its own is what analysis 9 spent $51.44 on, and its
# reads would prove nothing about the unit anyway (security/evidence.py). On
# Claude Code the CLI's `--disallowedTools Agent` closes it (the roster calls
# it `Task`); on OpenCode the permission block closes `task`; on Codex nothing
# closes `spawn_agent` by flag, so the unit's prompt forbids it -- and a unit
# whose stream shows a subagent call is judged a failed attempt.
security_disallowed_tools() { # security_disallowed_tools <platform>
  case "$1" in
    anthropic) printf 'Agent\n' ;;
    opencode)  printf 'task\n' ;;
    *)         printf '\n' ;;
  esac
}

# How many units of one analysis run at once: the project's `security.parallel`,
# 1 to 8, 3 when unset. It is the derived job's max_parallel, so it is also the
# ceiling acquire_slot enforces -- and 0 would mean "no ceiling" there, which is
# why it is clamped rather than passed through.
security_parallel() { # security_parallel <project>
  local v; v="$(security_get "$1" '.parallel' '')"
  case "$v" in
    ''|null) printf '3\n'; return 0 ;;
    *[!0-9]*) security_warn "security: project '$1' has a non-numeric parallel ('$v') -- running 3 units at a time"
              printf '3\n'; return 0 ;;
  esac
  [ "$v" -lt 1 ] && v=1
  [ "$v" -gt 8 ] && v=8
  printf '%s\n' "$v"
}

# The analysis budget the orchestrator enforces: the derived job's own
# max_budget_usd, read through job_get. The derivation already validated it
# (security_check_number) and fell back to SECURITY_FALLBACK_BUDGET_USD for a
# declared value that is not a number -- so it is READ here, never derived a
# second time: a raw "5 USD" handed on would stop the orchestrator at its
# first line, and a second copy of the rule would drift from the first.
security_analysis_budget() { # security_analysis_budget <job-id> -> USD, or '' for no budget
  job_get "$1" '.max_budget_usd' ''
}
```

No comentário de `CODEX_SKILLS` (~linha 5100), «is ALSO pointed at security-analysis by path (security_prompt)» passa a «is ALSO pointed at security-analysis by path (bin/security/prompts.py, `_skill_line`)»: a função que o comentário nomeia deixa de existir neste passo.

Na derivação (`security_derived_jobs`), trocar a construção do prompt (`prompt="$(security_prompt …)"`, ~616) por:

```bash
    # A security job runs only as a unit of an analysis, and each unit's prompt
    # is minted by the CLI from the ledger (`security unit-prompt`, read in
    # run_job). This sentence is what jobs_json needs a prompt for, and it says
    # so to anyone who opens the job.
    prompt="This job runs only as a unit of a security analysis: each unit's prompt is minted by \`agentloop security unit-prompt\`."
```

No `jq` que constrói o elemento, trocar `--arg notools "$SECURITY_DISALLOWED_TOOLS"` por `--arg notools "$(security_disallowed_tools "$splat")"`, acrescentar `--arg par "$(security_parallel "$project")"`, e no objecto trocar `max_parallel:1` por `max_parallel:($par|tonumber)`.

Apagar a função `security_prompt` inteira (é agora `prompts.unit_prompt`) e o seu comentário de cabeçalho.

Apagar `security_guides_read` e `security_task_count` (a prova é agora `security/evidence.py`).

- [ ] **Passo 2: o orquestrador e as unidades**

Substituir `security_run_analysis` por:

```bash
# THE ANALYSIS AS A PIPELINE. The analysis lock ($LOCK_DIR/<job>/.analysis --
# dot-named, so every slot walker skips it) is taken here and the orchestrator
# is exec'd in its place: the lock's pid IS the orchestrator, which is what a
# stop signals and what the tick finds dead after a crash. The orchestrator
# (security/orchestrator.py) removes the lock when it exits.
security_orchestrate() { # security_orchestrate <job-id> <analysis-id> <repo>
  local jid="$1" aid="$2" repo="$3" lock row commit project cwd parallel budget ignore
  mkdir -p "$LOCK_DIR/$jid" 2>/dev/null
  if ! acquire_lock "$jid/.analysis"; then
    log_tick "$jid: analysis $aid not started — another analysis of $jid is being orchestrated"
    return 1
  fi
  lock="$LOCK_DIR/$jid/.analysis"
  printf '%s\n' "$aid" > "$lock/analysis"
  row="$(security_engine_py analysis --id "$aid" 2>/dev/null)"
  commit="$(printf '%s' "$row" | "$JQ" -r '.commit_sha // empty' 2>/dev/null)"
  project="$(printf '%s' "$row" | "$JQ" -r '.project // empty' 2>/dev/null)"
  cwd="$(project_repo_path "$project" "$repo")"
  if [ -z "$commit" ] || [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    log_tick "$jid: analysis $aid cannot run — commit '${commit:-?}', checkout '${cwd:-?}'"
    release_lock "$jid/.analysis"
    security_engine_py finish --analysis "$aid" --state failed --if-running \
      --note "The engine could not start this analysis: its commit or its checkout could not be found." \
      >/dev/null 2>&1
    return 1
  fi
  parallel="$(security_parallel "$project")"
  budget="$(security_analysis_budget "$jid")"
  ignore="$("$JQ" -r '.ignore // ""' "$(security_request_path "$jid")" 2>/dev/null)"
  log_tick "$jid: analysis $aid orchestrated — up to $parallel unit(s) at a time${budget:+, budget \$$budget}"
  unset AL_SECURITY_AGENT CC_SECURITY_AGENT
  # --prepare-root: the prepare's checkout lives under $DATA_DIR/security, not
  # $WORKTREES_DIR -- every directory there is a run dir to wt_prune_orphans
  # (adopted, then torn down at its TTL) and to the server's retained_worktrees
  # (walked on every poll). --log-root: where run_job writes the units' streams,
  # which is how the orchestrator judges a run that died without its close.
  exec "$PYTHON" "$BIN_DIR/security/cli.py" --db "$(security_db)" orchestrate \
    --analysis "$aid" --engine "$SELF" --job "$jid" --commit "$commit" --repo "$repo" \
    --repo-path "$cwd" --prepare-root "$DATA_DIR/security/prepare" --log-root "$LOG_DIR" \
    --parallel "$parallel" --budget "$budget" --ignore "$ignore" --log "$TICK_LOG" \
    --lock-dir "$lock"
}

# One unit of an analysis, as the orchestrator launches it. The analysis's
# COMMIT, never its branch: a deep analysis runs for hours, the branch may
# move under it, and every unit must read the same tree (wt_base_ref resolves
# a raw sha under AL_BASE_OVERRIDE). Everything else is what a single-run
# analysis always exported, plus the unit id run_job and the CLI key on.
security_run_unit() { # security_run_unit <job-id> <analysis-id> <unit-id> <commit> <repo>
  AL_BASE_OVERRIDE="$4" AL_SKIP_PROVISION=1 AL_SECURITY_REPO="$5" \
  AL_SECURITY_AGENT=1 CC_SECURITY_AGENT=1 \
  AL_SECURITY_ANALYSIS_ID="$2" CC_SECURITY_ANALYSIS_ID="$2" \
  AL_SECURITY_UNIT_ID="$3" CC_SECURITY_UNIT_ID="$3" \
    run_job "$1" --force
}
```

Extrair de `cmd_security_analyze` o bloco do `--detach` (o `set -m … exec "$SELF" __run-analysis …` com todos os seus comentários) para:

```bash
security_launch_detached() { # security_launch_detached <job-id> <analysis-id> <branch> <repo>
  # (the comments that sat above this block in cmd_security_analyze move here, unchanged)
  set -m
  ( trap '' HUP
    exec "$SELF" __run-analysis "$1" "$2" "$3" "$4"
  ) </dev/null >> "$DATA_DIR/exec.log" 2>&1 &
  local dpid=$!
  disown "$dpid" 2>/dev/null || true
  set +m
}
```

e em `cmd_security_analyze` chamar `security_launch_detached "$jid" "$aid" "$branch" "$repo"` onde estava o bloco; no fim do ramo sem `--detach`, trocar `security_run_analysis "$jid" "$aid" "$branch" "$repo"` por `security_orchestrate "$jid" "$aid" "$repo"`.

No mesmo `cmd_security_analyze`:
- a seguir a `local live; live="$(slots_active "$jid")"`, acrescentar `lock_active "$jid/.analysis" && live=$((live + 1))` — um orquestrador vivo entre duas unidades é uma análise a correr;
- no sweep das análises mortas, trocar a chamada `finish --state failed --if-running …` por `security_engine_py interrupt --analysis "$dead"` e a linha do `log_tick` por «interrupted analysis $dead — it said running, and no run or orchestrator of $jid is alive» (a análise nova do mesmo ramo abandona-a logo a seguir, no `open-analysis`; uma de outro ramo fica retomável).

No dispatch, `__run-analysis` passa a chamar `security_orchestrate "$2" "$3" "${5:-}"`, e acrescentar:

```bash
  # Internal: one unit of a security analysis, launched by its orchestrator
  # (security/orchestrator.py). A real process, like __run-analysis, so the
  # slot it takes records a pid that lives exactly as long as the run.
  __run-unit)
             [ $# -ge 6 ] || die "usage: agentloop __run-unit <job-id> <analysis-id> <unit-id> <commit> <repo>"
             security_run_unit "$2" "$3" "$4" "$5" "$6" ;;
```

e, dentro de `security)`, antes do `*)`:

```bash
               resume)  shift; cmd_security_resume "$@" ;;
```

Actualizar a linha de usage do `security` para nomear também `resume|unit-prompt|units|read|verify-queue|verify-prompt|report-verdict`.

- [ ] **Passo 3: `security resume`**

```bash
cmd_security_resume() { # cmd_security_resume <project> <analysis-id>
  [ $# -ge 2 ] || die "usage: agentloop security resume <project> <analysis-id>"
  local project="$1" aid="$2" jid row
  security_enabled "$project" || die "security is not enabled for project '$project'"
  case "$aid" in ''|*[!0-9]*) die "security: '$aid' is not an analysis id" ;; esac
  jid="$(security_job_id "$project")"
  row="$(security_engine_py analysis --id "$aid" 2>/dev/null)" || die "no such analysis: $aid"
  [ "$(printf '%s' "$row" | "$JQ" -r '.project')" = "$project" ] \
    || die "analysis $aid is not an analysis of '$project'"
  lock_active "$jid/.analysis" && die "an analysis of '$project' is already running (job $jid)"
  [ "$(slots_active "$jid")" -eq 0 ] \
    || die "units of '$project' are still winding down — try again in a moment"
  security_engine_py resume --analysis "$aid" >/dev/null 2>&1 \
    || die "analysis $aid is not interrupted: there is nothing to resume"
  security_launch_detached "$jid" "$aid" "$(printf '%s' "$row" | "$JQ" -r '.branch')" \
    "$(printf '%s' "$row" | "$JQ" -r '.repo')"
  log_tick "$jid: resumed analysis $aid $(stop_origin)"
  printf '{"analysis_id":%s,"resumed":true}\n' "$aid"
}
```

(`stop_origin` já diz de onde veio o pedido — dashboard ou shell; reutiliza-se aqui para a mesma frase.)

- [ ] **Passo 4: `run_job` corre unidades**

Logo a seguir a `prompt="$(jobs_json | … '.prompt')"` (~6217):

```bash
  # A SECURITY JOB RUNS ONLY AS A UNIT OF AN ANALYSIS (security/orchestrator.py),
  # and a unit's prompt is minted by the CLI from the ledger. Refused before any
  # slot, worktree or log exists: the orchestrator sees a run that ended without
  # closing its unit, and counts it.
  case "$id" in "$SECURITY_JOB_PREFIX"*)
    if [ -z "${AL_SECURITY_UNIT_ID:-}" ] || [ -z "${AL_SECURITY_ANALYSIS_ID:-}" ]; then
      log_tick "$id: a security job runs only as a unit of an analysis (agentloop security analyze), skipped"
      return 1
    fi
    prompt="$(security_py unit-prompt --analysis "$AL_SECURITY_ANALYSIS_ID" \
                --unit "$AL_SECURITY_UNIT_ID" --platform "$platform" 2>>"$TICK_LOG")" \
      || { log_tick "$id: could not mint the prompt of unit $AL_SECURITY_UNIT_ID of analysis $AL_SECURITY_ANALYSIS_ID"; return 1; } ;;
  esac
```

Logo a seguir ao bloco do `budget` (~6243):

```bash
  # A unit's share of its analysis's budget, handed down by the orchestrator,
  # which enforces the analysis's total itself.
  [ -z "${AL_SECURITY_UNIT_BUDGET:-}" ] || budget="$AL_SECURITY_UNIT_BUDGET"
```

Em `run_classify`, trocar `cap="$(job_get "$id" '.max_budget_usd' '')"` por `cap="${AL_SECURITY_UNIT_BUDGET:-$(job_get "$id" '.max_budget_usd' '')}"`.

No `run_env` (a lista que acrescenta `AL_RUN_DIR`, ~6698), acrescentar `"AL_RUN_CWD=$run_cwd" "CC_RUN_CWD=$run_cwd"`.

No cabeçalho do precheck (~6718), trocar a linha `SECURITY ANALYSIS $AL_SECURITY_ANALYSIS_ID — launched by …` por:

```bash
    echo "SECURITY ANALYSIS $AL_SECURITY_ANALYSIS_ID · unit $(security_py units --analysis "$AL_SECURITY_ANALYSIS_ID" --label "${AL_SECURITY_UNIT_ID:-0}" 2>/dev/null) — launched by its orchestrator (\`agentloop security analyze\`), never by a tick"
```

Remover o bloco «THE DETERMINISTIC PHASE, ENGINE-SIDE, ON THE PLATFORMS WITHOUT prepare_inline» (~6818-6867) inteiro: o `prepare` corre uma vez, no orquestrador, em todas as plataformas. Em `platform_caps`, tirar `prepare_inline` do comentário e da lista do `anthropic`.

- [ ] **Passo 5: o fecho de um run é o fecho da unidade**

```bash
# The close of a unit's run: `unit-close` judges the unit from this run's own
# stream (and what `security read` served it), records the run's real cost on
# the unit and plans what it left undone. A no-op for every job that is not a
# derived security one, and for a security run that is not a unit (run_job
# refuses those before they start). The run's status reaches the judgement:
# `stopped` continues the unit at the same attempt, anything but `success` is
# a failed attempt for a hunt.
security_close_analysis() { # <job-id> <status> <cost> <wdreason> [stream]
  case "$1" in "$SECURITY_JOB_PREFIX"*) ;; *) return 0 ;; esac
  local aid="${AL_SECURITY_ANALYSIS_ID:-}" uid="${AL_SECURITY_UNIT_ID:-}"
  [ -n "$aid" ] && [ -n "$uid" ] || return 0
  security_engine_py unit-close --analysis "$aid" --unit "$uid" \
    --stream "${5:-}" --root "${run_cwd:-}" --status "$2" --reason "${4:-}" \
    --spend "${3:-0}" >/dev/null 2>&1 \
    || log_tick "$1: could not close unit $uid of analysis $aid"
}
```

- [ ] **Passo 6: parar uma análise é pará-la inteira**

No início de `cmd_stop`, depois dos `local`:

```bash
  # A SECURITY ANALYSIS IS STOPPED WHOLE, whichever of its runs was asked for:
  # left alive, its orchestrator would launch the next unit into the slot this
  # frees. The orchestrator stops its units itself (it calls back here with
  # AL_SECURITY_ORCHESTRATOR set) and leaves the analysis `interrupted`.
  case "$id" in "$SECURITY_JOB_PREFIX"*)
    if [ -z "${AL_SECURITY_ORCHESTRATOR:-}" ] && lock_active "$id/.analysis"; then
      local opid; opid="$(cat "$LOCK_DIR/$id/.analysis/pid" 2>/dev/null)"
      case "$opid" in
        ''|0|*[!0-9]*) ;;
        *) log_tick "$id: stop asked for its analysis $(stop_origin)"
           kill -TERM "$opid" 2>/dev/null \
             && echo "stopping the analysis of $id (orchestrator pid $opid)"
           return 0 ;;
      esac
    fi ;;
  esac
```

Em `cmd_project_rename` (~8381), onde já recusa com slots vivos, recusar também com `lock_active "$(security_job_id "$old")/.analysis"`, com a mesma frase.

- [ ] **Passo 7: o `fake-claude` joga unidades**

Em `test/fake-claude`, documentar no cabeçalho as variáveis novas e, logo antes do hook do `prepare` (que passa a correr só quando `AL_SECURITY_UNIT_ID` está vazio):

```bash
# A UNIT OF A SECURITY ANALYSIS (security/orchestrator.py). The prompt is the
# last argument; the unit's kind is on its first line. This plays the unit
# well enough for the engine's judgement to see it:
#   read    a Read of every range the prompt lists, with the result shape
#           Claude Code writes (tool_use_result.file); FAKE_SKIP_READ_ONCE=<dir>
#           leaves the LAST range unread the first time each unit runs;
#           FAKE_READ_NOTHING=1 reads nothing at all
#   triage  re-reports every [scanner] row, says a [carried] sast row is
#           gone (`report-gone`), re-reports a [carried] deterministic row
#           as it stands
#   verify  writes a `confirmed` verdict through the door
#   hunt    FAKE_HUNT_FINDING=1 reports one sast finding (so a verify unit
#           is planned); otherwise only the run ending
FAKE_UNIT_EVENTS=""
if [ -n "${AL_SECURITY_UNIT_ID:-}" ]; then
  al="$(cd "$(dirname "$0")/../bin" && pwd)/agentloop"
  unit_prompt="${!#}"
  unit_kind="$(printf '%s\n' "$unit_prompt" | sed -n '1s/^SECURITY ANALYSIS [0-9]* · unit \([a-z]*\).*/\1/p')"
  case "$unit_kind" in
    read)
      ranges="$(printf '%s\n' "$unit_prompt" | awk '/^RANGES /{on=1; next} on && /^  [^ ]/{print $1; next} on{exit}')"
      if [ -n "${FAKE_SKIP_READ_ONCE:-}" ] && [ ! -e "$FAKE_SKIP_READ_ONCE/unit-$AL_SECURITY_UNIT_ID-parent" ] \
         && ! printf '%s' "$unit_prompt" | head -1 | grep -q 'attempt'; then
        mkdir -p "$FAKE_SKIP_READ_ONCE"; : > "$FAKE_SKIP_READ_ONCE/unit-$AL_SECURITY_UNIT_ID-parent"
        ranges="$(printf '%s\n' "$ranges" | sed '$d')"
      fi
      [ -z "${FAKE_READ_NOTHING:-}" ] || ranges=""
      n=0
      while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        n=$((n + 1)); path="${spec%:*}"; span="${spec##*:}"; first="${span%-*}"; last="${span#*-}"
        FAKE_UNIT_EVENTS="$FAKE_UNIT_EVENTS$(jq -nc --arg id "r$n" --arg p "$PWD/$path" \
          '{type:"assistant",parent_tool_use_id:null,message:{content:[{type:"tool_use",id:$id,name:"Read",input:{file_path:$p}}]}}')
$(jq -nc --arg id "r$n" --arg p "$PWD/$path" --argjson a "$first" --argjson b "$last" \
          '{type:"user",parent_tool_use_id:null,message:{content:[{type:"tool_result",tool_use_id:$id,content:""}]},tool_use_result:{type:"text",file:{filePath:$p,startLine:$a,numLines:($b-$a+1),totalLines:$b}}}')
"
      done <<EOF
$ranges
EOF
      ;;
    verify)
      fp="$(printf '%s\n' "$unit_prompt" | sed -n 's/.*report-verdict --analysis [0-9]* --fingerprint \([0-9a-f]\{64\}\).*/\1/p' | head -1)"
      printf '{"verdict":"confirmed","reason":"the fake verifier read it"}' \
        | "$al" security report-verdict --analysis "$AL_SECURITY_ANALYSIS_ID" --fingerprint "$fp" >/dev/null 2>&1 || true ;;
    triage)
      # [scanner] rows are re-reported with a confidence; a [carried] sast row
      # is said to be gone (the fake never finds it again); a [carried]
      # deterministic row is re-reported as it stands, with no candidate.
      printf '%s\n' "$unit_prompt" | sed -n 's/^  [0-9]*\. \[\([a-z]*\)\] \([0-9a-f]\{64\}\) · \([a-z]*\)\/\([^ ]*\) · \([a-z_]*\) · \([^ :]*\):\{0,1\}\([0-9]*\) · by .*/\1 \2 \3 \4 \5 \6 \7/p' \
        | while read -r kind fp cat rule sev file line; do
            if [ "$kind" = carried ] && [ "$cat" = sast ]; then
              printf '{"reason":"the fake triage read the code and the finding is gone"}' \
                | "$al" security report-gone --analysis "$AL_SECURITY_ANALYSIS_ID" --fingerprint "$fp" >/dev/null 2>&1 || true
              continue
            fi
            if [ "$kind" = carried ]; then cand='{}'; else cand='{"confidence":{"score":"high","reason":"fake"}}'; fi
            jq -nc --arg fp "$fp" --arg c "$cat" --arg r "$rule" --arg s "$sev" --arg f "$file" \
                   --argjson l "${line:-0}" --argjson cand "$cand" \
              '{fingerprint:$fp,category:$c,rule:$r,severity:$s,title:"triaged",rationale:"the fake triage read it",occurrences:[{file:$f,line:$l}]} + (if $cand == {} then {} else {candidate:$cand} end)' \
              | "$al" security report-finding --analysis "$AL_SECURITY_ANALYSIS_ID" >/dev/null 2>&1 || true
          done ;;
    hunt)
      if [ -n "${FAKE_HUNT_FINDING:-}" ]; then
        jq -nc '{fingerprint:("e"*64),category:"sast",rule:"sql-injection",severity:"high",title:"fake",rationale:"the fake hunter concatenated a query",occurrences:[{file:"README",line:1}],candidate:{trace:[{kind:"entrypoint",file:"README",line:1,scope:"s",description:"input"},{kind:"sink",file:"README",line:1,scope:"s",description:"execute"}],intended_control:"parameterised queries",confidence:{score:"high",reason:"r"},likelihood:{score:"high",reason:"r"},impact:{score:"high",reason:"r"}}}' \
          | "$al" security report-finding --analysis "$AL_SECURITY_ANALYSIS_ID" >/dev/null 2>&1 || true
      fi ;;
  esac
fi
```

(`"e"*64` não é jq válido para repetir texto — usar `("e" * 64)` é válido em jq 1.7 (`string * number` repete). Confirmar com `jq -n '"e" * 3'` na máquina; se a versão do CI não o suportar, escrever o fingerprint literal de 64 `e`.)

E, no bloco que escreve os eventos, logo a seguir à linha `printf '{"type":"assistant",…"working"…}\n'`:

```bash
[ -z "$FAKE_UNIT_EVENTS" ] || printf '%s' "$FAKE_UNIT_EVENTS"
```

- [ ] **Passo 8: os cenários e2e que o fluxo novo mudou**

Em `test/e2e.test.sh`:
- **8**: o cabeçalho do precheck passa a `SECURITY ANALYSIS $aid8 · unit <kind> <n>/<total> — launched by its orchestrator`. O sandbox tem sempre a linha `missing_gitignore` (`hygiene.py:228-234`), por isso uma unidade `triage` corre em paralelo com a `hunt`, e o `run_of` devolve a que acabou em último — qualquer das duas. A linha ~304 passa a:

  ```bash
  grep -q "^SECURITY ANALYSIS $aid8 · unit [a-z]* [0-9]*/[0-9]*" "$pc8" 2>/dev/null \
    && grep -q 'launched by its orchestrator' "$pc8" 2>/dev/null && ! grep -q 'every due tick' "$pc8" 2>/dev/null \
    && ok "and the run's precheck note names analysis $aid8, the unit it ran and who launched it, never a tick" \
    || bad "note (waited ${wlog}s for the journal record): $(cat "$pc8" 2>/dev/null)"
  ```

  O resto (volta em menos de 5 s, fecha `done`) mantém-se.
- **9**: um `claude` que morre ao arrancar deixa cada tentativa sem nada; a unidade `hunt` desiste à terceira e a análise fecha **`capped`** (não `failed`), com «gave up after 3 attempts» na nota. Mudar a asserção e o texto do `echo`, e aumentar a espera para 60 s (três runs).
- **10**: o sweep passa a interromper a linha presa, e o `open-analysis` seguinte do mesmo ramo abandona-a: o estado final continua `failed`, e a nota diz «Superseded by analysis». Acrescentar essa verificação da nota.
- **11**: deixa de fazer sentido («o agente saltou o `prepare`»: o `prepare` é agora do motor). Substituir por «um `deep` cujas unidades de leitura não lêem nada fecha `capped` e nomeia as linhas por ler»: `FAKE_READ_NOTHING=1 … security analyze --detach sandbox anything main deep`, esperar até 90 s, `capped`, e a nota com «were never read in full».
- **12**: o lançamento de uma unidade passa a fechar `Agent`: inverter a primeira asserção para exigir `--disallowedTools` seguido de `Agent`, e manter a do `--max-budget-usd` e a do prompt como único positional depois de `--`.
- **24** (Codex): o prompt é agora o de uma unidade (Task 6), e o `prepare` é do orquestrador em todas as plataformas. As linhas ~695-707 passam a:

  ```bash
  grep -q "security-sandbox-oa: analysis $aid24 — deterministic phase done" "$ROOT/data/tick.log" \
    && ok "the orchestrator ran prepare before any unit was launched" || bad "no orchestrator prepare line in tick.log"
  [ "$(at_in "$argv24" 1)" = "exec" ] && ok "it went down the Codex launch line" || bad "argv: $(tr '\n' ' ' < "$argv24" 2>/dev/null)"
  mi="$(idx_in "$argv24" -m)"; [ -n "${mi:-}" ] && [ "$(at_in "$argv24" $((mi + 1)))" = "gpt-5.6-sol" ] \
    && ok "-m carries the block's model" || bad "-m '$(at_in "$argv24" $((${mi:-0} + 1)))'"
  [ -n "$(idx_in "$argv24" --dangerously-bypass-approvals-and-sandbox)" ] \
    && ok "full-access, the security default on openai" || bad "no bypass flag in the launch line"
  [ -z "$(idx_in "$argv24" --disallowedTools)" ] && ok "no --disallowedTools: Codex cannot close a tool by flag" || bad "--disallowedTools was passed to codex"
  grep -q '^SECURITY ANALYSIS [0-9]* · unit ' "$prompt24" && ok "the prompt is a unit's, minted by the CLI" || bad "not a unit prompt: $(head -1 "$prompt24" 2>/dev/null)"
  grep -q 'Never call `spawn_agent`' "$prompt24" && ok "the prompt forbids subagents in words" || bad "no subagent ban in the prompt"
  grep -q 'security-analysis/SKILL.md' "$prompt24" && ok "and names the skill file by path" || bad "the prompt does not name the skill file"
  grep -q '`Agent`' "$prompt24" && bad "the prompt speaks of the Agent tool Codex does not have" || ok "and never speaks of the Agent tool"
  grep -q 'security prepare' "$prompt24" && bad "the prompt still asks the unit to run prepare" || ok "the unit is never asked to run prepare: the orchestrator did"
  ```

  (A linha 686-689 continua a correr `security analyze` em primeiro plano, com `FAKE_SKIP_PREPARE=1`, que já não tem efeito sobre unidades: o comentário 680-685 passa a dizer que o `prepare` é do orquestrador.) Os `FAKE_ARGV_OUT` e `FAKE_PROMPT_OUT` guardam o lançamento da última unidade a arrancar; as asserções acima valem para qualquer uma.
- **42** (OpenCode): o job derivado fecha `task`, e o OpenCode continua a invocar a skill PELO NOME (e pelo caminho), como hoje. As linhas ~1128-1145 passam a:

  ```bash
  grep -q "security-sandbox-oc: analysis $aid42 — deterministic phase done" "$ROOT/data/tick.log" \
    && ok "the orchestrator ran prepare before launching opencode" || bad "no orchestrator prepare line"
  [ "$(at_in "$argv42" 1)" = "run" ] && ok "it went down the OpenCode launch line" || bad "argv: $(tr '\n' ' ' < "$argv42" 2>/dev/null)"
  mi="$(idx_in "$argv42" -m)"; [ -n "${mi:-}" ] && [ "$(at_in "$argv42" $((mi + 1)))" = "pdm_ai/glm-5.3-flash" ] \
    && ok "-m carries the block's model" || bad "-m '$(at_in "$argv42" $((${mi:-0} + 1)))'"
  # The derived job closes `task` (security_disallowed_tools opencode), and the
  # permission block is where OpenCode takes that rule: a unit that fans out is
  # what analysis 9 spent $51.44 on, and its reads would prove nothing.
  [ "$(jq -r '.permission.task // "unset"' "$cfg42")" = "deny" ] && ok "the task tool is closed by rule" || bad "permission: $(jq -c .permission "$cfg42")"
  [ -n "$(idx_in "$argv42" --auto)" ] && [ "$(jq -r '.permission.bash // "open"' "$cfg42")" != "deny" ] \
    && ok "--auto with bash open: full-access, the security default on opencode" || bad "auto/bash: $(idx_in "$argv42" --auto) / $(jq -c .permission "$cfg42")"
  grep -q 'The `task` tool is closed for this run' "$prompt42" && ok "the prompt says the task tool is closed, by rule" || bad "no task paragraph in the prompt"
  grep -q 'security-analysis/SKILL.md' "$prompt42" && grep -q 'Invoke the `security-analysis` skill' "$prompt42" \
    && ok "and names the skill by name AND by path (the CLI reads ~/.claude/skills: measured)" || bad "the prompt lacks the skill by name or by path"
  grep -q 'security prepare' "$prompt42" && bad "the prompt still asks the unit to run prepare" || ok "the unit is never asked to run prepare: the orchestrator did"
  grep -q 'spawn_agent' "$prompt42" && bad "the Codex-only wording leaked into the opencode prompt" || ok "no Codex wording"
  ```

  O comentário 1133-1136 («No `task: deny` since block 4.2 …») sai: o bloco acima traz o seu.
- **46**: mantém-se, e o `HEAD` da worktree continua a ser `sha46` (é o commit da análise).

Em todos os cenários de segurança que corriam em primeiro plano, o comando só volta quando o orquestrador fecha a análise — o que é o que as asserções seguintes esperam.

- [ ] **Passo 9: os blocos do selftest**

O selftest é carregado com `.` pelo próprio `bin/agentloop` (~linha 8699), que corre com `set -uo pipefail` (linha 11): um bloco que leia uma variável que este passo apaga não falha só a si — **aborta o selftest inteiro**. E um bloco que chame `cmd_security_analyze` em primeiro plano já não chega a um `run_job` que se possa substituir: faz `exec` do orquestrador, que lança `"$SELF" __run-unit` como processos novos, onde nenhum stub existe, contra a configuração, o ledger e o `tick.log` da instalação viva. Daí as duas regras deste passo: **nenhum bloco arranca um orquestrador ou um `__run-unit` verdadeiro** (os de `analyze` substituem `security_orchestrate`), e o `sec_env` **exporta** a configuração, os dados e o ledger do bloco, para que um processo filho que escape nunca toque na instalação. Os blocos, um a um (números de linha medidos no commit de base do plano):

**A. `platform_caps` (~223).** O `prepare_inline` sai de `platform_caps` (Passo 4). A linha 223 passa a:

```bash
  platform_caps anthropic prepare_inline; want "no platform runs security prepare inside the agent: the orchestrator runs it once, on every platform" 1 $?
```

(a 224, do `openai`, fica; o ciclo da 219 continua verde, porque o OpenCode nunca teve a capacidade.)

**B. `security_prompt()` (~2324-2375).** Sai o bloco inteiro, do `echo "security_prompt() — the platform decides how the skill is named and how subagents are forbidden"` à última asserção `security_prompt opencode: never speaks of the Agent tool`: a função deixa de existir (Passo 1), e o texto dos prompts das unidades é testado em `tests/security/test_unit_prompts.py` (Task 6), plataforma a plataforma.

**C. `security_derived_jobs()` por plataforma (~2408-2421).** Saem as asserções sobre o texto do prompt, e as das ferramentas invertem-se: o `openai` não fecha nada por flag, o que caiu para `anthropic` fecha `Agent`, o `opencode` fecha `task`. As linhas 2408-2413 passam a:

```bash
  [ -z "$(dplat security-oa .disallowed_tools)" ] \
    && ok "the derived job on openai closes no tool by flag: the Codex CLI has none for spawn_agent" \
    || bad "Oa disallowed_tools: $(dplat security-oa .disallowed_tools)"
  [ "$(dplat security-oc .disallowed_tools)" = "Agent" ] \
    && ok "the derived job that fell back to anthropic closes the Agent tool" \
    || bad "Oc disallowed_tools: $(dplat security-oc .disallowed_tools)"
```

as 2417-2418 (`the derived job on opencode carries the by-rule paragraph`) saem, e as 2419-2421 passam a:

```bash
  [ "$(dplat security-of .platform)" = "opencode" ] && [ "$(dplat security-of .model)" = "pdm_ai/glm-5.3-flash" ] && [ "$(dplat security-of .effort)" = "high" ] \
    && [ "$(dplat security-of .permission_mode)" = "full-access" ] && [ "$(dplat security-of .disallowed_tools)" = "task" ] \
    && ok "an opencode block: platform, model, a variant the model lists, full-access, and the task tool closed" || bad "Of: $(dplat security-of '{platform,model,effort,permission_mode,disallowed_tools}')"
```

**D. «the security-analysis skill ships with the repo» (~3594-3605).** O comentário nomeava o `security_prompt`, e o `grep` procurava a skill no `bin/agentloop`, onde depois deste passo só um comentário a nomeia. Passa a:

```bash
  echo "the security-analysis skill ships with the repo, not only in ~/.claude/skills"
  # Every unit's prompt makes this skill MANDATORY (bin/security/prompts.py,
  # `_skill_line`) -- a prompt that names a skill the machine does not have is
  # a prompt whose standards silently do not apply. See the comment above
  # SKILLS_DIR for why the skills this loop depends on live here rather than
  # only in the unversioned user directory.
  [ -f "$SKILLS_DIR/security-analysis/SKILL.md" ] \
    && ok "the security-analysis skill ships with the repo" \
    || bad "the security-analysis skill ships with the repo"
  grep -q 'security-analysis' "$BIN_DIR/security/prompts.py" \
    && ok "the unit prompts still name the security-analysis skill" \
    || bad "the unit prompts still name the security-analysis skill"
```

**E. O job derivado e a ferramenta `Agent` (~7334-7361).** A asserção inverte-se: a derivação fecha `Agent` outra vez. O comentário 7334-7355 e o bloco 7356-7361 passam a:

```bash
  # The subagent tool is closed at LAUNCH, not asked for in the prompt --
  # asking is what already failed twice ($51.44, six subagents, zero of 40
  # deterministic findings triaged). Since the pipeline the ENGINE distributes
  # an analysis's work into units, so the derived job closes `Agent` again
  # (security_disallowed_tools; the roster calls it `Task`), and a unit whose
  # stream shows one is a failed attempt anyway (security/units.py). The
  # literal "Agent", NOT the function's output: a test may not take its
  # expected value from the thing it tests. The prompt is read beside it, so
  # a derivation that fell over -- no field at all -- cannot pass for it.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ "$(job_get security-web '.disallowed_tools' '')" = "Agent" ] \
    && [ -n "$(job_get security-web '.prompt' '')" ] ) \
    && ok "the derived job closes the Agent tool: the engine distributes the work into units" \
    || bad "the derived job's disallowed_tools is not Agent"
```

**F. «You HAVE subagents in this run» (~7493-7500).** Sai: é texto do prompt que deixou de existir.

**G. «the derived job's prompt names the requested branch» (~7557-7562).** Sai: o prompt do job derivado é agora uma frase fixa; o ramo e o commit chegam ao prompt de cada unidade, e isso está fixado por `test_every_unit_names_its_analysis_its_place_and_the_three_rules` (Task 6).

**H. `security_close_analysis` num job que não é derivado (~7578-7582).** Fica: a função nova continua a devolver 0 para um id sem o prefixo.

**I. `security_guides_read` e o `--guides-read` do fecho (~7584-7617).** Sai: a função deixa de existir; os guias lidos são agora a prova de cada unidade (`evidence["guides"]`, Task 5) e a sua união no fecho (`guides_read`, Task 9), testados em pytest.

**J. `security_task_count` e o `--tasks-launched` do fecho (~7619-7647).** Sai: a função deixa de existir; o subagente conta-se por unidade (`evidence.Session.tasks`, Task 4; `judge`, Task 5).

**K. `[ -z "$SECURITY_DISALLOWED_TOOLS" ]` (~7649-7652).** Sai — e é o bloco que, deixado, aborta o selftest inteiro sob `set -u`. A primeira asserção do bloco novo (abaixo) põe no seu lugar `security_disallowed_tools`.

**L. `sec_env` (~8150-8156).** Passa a exportar a configuração, os dados e o ledger do bloco:

```bash
  sec_env() {
    PROJECTS_FILE="$sec/cfg/projects.json"; JOBS_FILE="$sec/cfg/jobs.json"
    PLATFORMS_FILE="$sec/cfg/platforms.json"
    CONFIG_DIR="$sec/cfg"; DATA_DIR="$sec/data"; LOCK_DIR="$sec/data/locks"
    TICK_LOG="$sec/data/tick.log"; RUNS_FILE="$sec/data/runs.ndjson"
    AGENTLOOP_SECURITY_DB="$secdb"
    # EXPORTED, for every process a block starts. A child `agentloop` -- the
    # orchestrator's `__run-unit`, a detached `__run-analysis` -- recomputes
    # its config, data and ledger from these three and nothing else; left
    # unexported, a process that escaped a stub would read and write the LIVE
    # installation's config, ledger and tick.log.
    export AGENTLOOP_CONFIG="$sec/cfg" AGENTLOOP_DATA="$sec/data" AGENTLOOP_SECURITY_DB
  }
```

e, logo a seguir a `sec_open`, os dois leitores de unidades que os blocos R e U usam — só de leitura (`mode=ro`), como o cenário 55 do e2e lê o ledger —, e o `sec_open` passa a preparar com `--plan`, para que cada análise que abre tenha a sua unidade `hunt`:

```bash
  sec_open() { # sec_open [commit-sha] -> the id of a prepared, running analysis, planned
    local a
    a="$(security_py open-analysis --project "Sec App" --repo repo --branch main \
           --commit "${1:-abc}" --profile quick --run-id "$secjid" | "$JQ" -r '.analysis_id')"
    security_py prepare --analysis "$a" --root "$sec/tree" --offline --plan >/dev/null 2>&1
    printf '%s' "$a"
  }
  sec_unit() { # sec_unit <analysis-id> <kind> -> the id of its first unit of that kind
    "$PYTHON" -c 'import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
r = c.execute("SELECT id FROM unit WHERE analysis_id=? AND kind=? ORDER BY seq LIMIT 1",
              (int(sys.argv[2]), sys.argv[3])).fetchone()
print(r[0] if r else "")' "$secdb" "$1" "$2"
  }
  sec_unit_state() { # sec_unit_state <unit-id> -> "<state>,<spend>[,<its continuation's attempt>]"
    "$PYTHON" -c 'import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
u = c.execute("SELECT state, spend_usd FROM unit WHERE id=?", (int(sys.argv[2]),)).fetchone()
k = c.execute("SELECT attempt FROM unit WHERE parent=?", (int(sys.argv[2]),)).fetchone()
print(",".join([u[0], repr(u[1])] + ([str(k[0])] if k else [])))' "$secdb" "$1"
  }
```

**M. `cmd_security_analyze` em primeiro plano (~8173-8238).** Substitui-se o `security_orchestrate`, nunca o `run_job` (que já não é chamado por esta função). O bloco 8173-8193 passa a:

```bash
  # security_orchestrate is stubbed, so nothing starts an orchestrator -- and
  # nothing, therefore, launches a `__run-unit` against this machine. The stub
  # reads the ledger from INSIDE the call, which is the only way to prove the
  # row is open, and open as `running`, at the moment the orchestrator would
  # take over: an orchestrator that dies on launch must still leave an
  # analysis for the tick to find.
  ( sec_env
    security_orchestrate() {
      printf '%s\n' "$*" > "$sec/orch.args"
      sh -c 'printf "%s|%s\n" "${AL_SECURITY_AGENT:-unset}" "${AL_SECURITY_UNIT_ID:-unset}"' \
        > "$sec/orch.childenv"
      security_py list --project "Sec App" | "$JQ" -r '.[0].state' > "$sec/state-during"
      return 0
    }
    cmd_security_analyze "Sec App" repo main quick ) > "$sec/analyze.out" 2>&1
```

as asserções 8194-8209 (o ficheiro do pedido, o ramo/perfil/repo, o nome de um projecto de checkout único, o estado `running` durante a chamada — agora «before its orchestrator is started») ficam, e as 8210-8238 passam a:

```bash
  [ "$(cat "$sec/orch.args" 2>/dev/null)" = "$secjid 1 Sec App" ] \
    && ok "the orchestrator is started for the derived job, the analysis id and the repo the ledger files it under" \
    || bad "security_orchestrate got '$(cat "$sec/orch.args" 2>/dev/null)'"
  [ "$(cat "$sec/orch.childenv" 2>/dev/null)" = "unset|unset" ] \
    && ok "and unmarked: the orchestrator is the engine, never the agent -- each unit's run carries the markers (security_run_unit)" \
    || bad "the orchestrator was started as '$(cat "$sec/orch.childenv" 2>/dev/null)'"
  # The one way an analysis can be left `running` with no orchestrator ever
  # behind it: its commit or its checkout gone by the time the detached half
  # starts. security_orchestrate closes the row itself -- called for real
  # here, which is safe only because it refuses before its exec: the checkout
  # this projects file names does not exist.
  printf '{"projects":[{"name":"Sec App","cwd":"%s/gone","security":{"enabled":true}}]}\n' "$sec" \
    > "$sec/cfg/gone-projects.json"
  local secgone
  secgone="$( ( sec_env; PROJECTS_FILE="$sec/cfg/gone-projects.json"
    a="$(security_py open-analysis --project "Sec App" --repo "Sec App" --branch nc \
           --commit c --profile quick --run-id "$secjid" | "$JQ" -r '.analysis_id')"
    security_orchestrate "$secjid" "$a" "Sec App" >/dev/null 2>&1
    [ -d "$LOCK_DIR/$secjid/.analysis" ] && echo "lock-kept"
    security_py list --project "Sec App" | "$JQ" -r --arg a "$a" \
      '.[] | select(.id == ($a|tonumber)) | [.state, (.coverage_note | test("could not start this analysis") | tostring)] | join(",")' ) 2>/dev/null )"
  [ "$secgone" = "failed,true" ] \
    && ok "an analysis whose checkout is gone is closed failed before any orchestrator runs, and its lock let go" \
    || bad "security_orchestrate over a missing checkout -> $secgone"
```

**N. `--detach` (~8240-8290).** Fica: o `--detach` passa por `security_launch_detached`, que continua a fazer `exec "$SELF" __run-analysis <job> <analysis> <branch> <repo>` sobre o `fake-self`.

**O e P. `security_run_analysis` (~8292-8305 e ~8307-8323).** Saem: a função deixa de existir. O que o O garantia — uma análise que nunca arrancou não fica `running` para sempre — é agora o teste do `secgone` (M) e, para um orquestrador que morreu, o `security_resume_orphans` da Task 12; o que o P garantia — um run que fecha a sua própria linha mantém o veredicto — é agora o fecho da unidade (R) e o `finish --from-units` (Task 9).

**Q. A linha morta que bloqueava o botão (~8325-8354).** Os dois `cmd_security_analyze` substituem `security_orchestrate` (`security_orchestrate() { return 0; }` no lugar de `run_job() { return 0; }`), e o fim muda com o varrimento: a linha presa é interrompida e a análise nova do mesmo ramo abandona-a (`open-analysis`, Task 8) — continua `failed`, com outra nota. As linhas 8336-8354 passam a:

```bash
  ( sec_env; security_orchestrate() { return 0; }
    cmd_security_analyze "Sec App" repo main quick ) >/dev/null 2>&1
  [ "$( ( sec_env; security_py list --project "Sec App" \
            | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )" = "running" ] \
    && ok "a row younger than the grace is left alone — its run may still be starting" \
    || bad "the sweep took a row that was seconds old"
  ( sec_env; SECURITY_STALE_GRACE=0; security_orchestrate() { return 0; }
    cmd_security_analyze "Sec App" repo main quick ) > "$sec/stuck.out" 2>&1
  [ "$( ( sec_env; security_py list --project "Sec App" \
            | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )" = "failed" ] \
    && ok "once the grace is up it is interrupted, and the analysis opened on its branch supersedes it: failed, and the button is usable again" \
    || bad "stale row left '$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )'"
  case "$( ( sec_env; security_py list --project "Sec App" \
               | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .coverage_note' ) )" in
    "Superseded by analysis "*) ok "with a note naming the analysis that took its place, not a verdict on the code" ;;
    *) bad "coverage note: $( ( sec_env; security_py list --project "Sec App" | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .coverage_note' ) )" ;;
  esac
  grep -q "^analysis " "$sec/stuck.out" \
    && ok "and the analysis that was asked for is opened rather than refused" \
    || bad "the new analysis did not start: $(cat "$sec/stuck.out" 2>/dev/null)"
```

**R. `sec_close_state` (~8398-8435).** Reescrito sobre o `unit-close`: o fecho de um run é o da sua unidade (`AL_SECURITY_UNIT_ID`), e a análise é do orquestrador. Uma unidade `hunt`, porque um `hunt` é julgado só pelo estado do run — a mesma tabela de veredictos que o fecho antigo aplicava à análise:

```bash
  echo "security_close_analysis() — the run's own verdict closes its UNIT"
  # A run of a derived job is one unit of an analysis, and its close is the
  # unit's: `unit-close` judges it from the run's status (and its stream and
  # the ledger), records the run's real cost on the unit, and continues what
  # it left -- one attempt up, or the SAME attempt after a stop. The analysis
  # is the orchestrator's to close (finish --from-units).
  sec_close_state() { # sec_close_state <run-status> [wdreason] -> "<unit state>,<spend>[,<continuation attempt>]"
    ( sec_env
      local a u
      a="$(sec_open)"
      u="$(sec_unit "$a" hunt)"
      AL_SECURITY_ANALYSIS_ID="$a" AL_SECURITY_UNIT_ID="$u" \
        security_close_analysis "$secjid" "$1" "1.5" "${2:-}" >/dev/null 2>&1
      sec_unit_state "$u" )
  }
  [ "$(sec_close_state success)" = "done,1.5" ] \
    && ok "success settles the unit done, carrying the run's real cost" || bad "success -> $(sec_close_state success)"
  [ "$(sec_close_state warning)" = "done,1.5" ] \
    && ok "a warning is a run that worked, so the unit is done too" || bad "warning -> $(sec_close_state warning)"
  [ "$(sec_close_state warning "the agent put 3 lines on stderr")" = "done,1.5" ] \
    && ok "and a warning about stderr noise is still a finished unit" \
    || bad "warning+stderr -> $(sec_close_state warning "the agent put 3 lines on stderr")"
  [ "$(sec_close_state warning "UNDECLARED ENDING: the agent stopped without saying its run was finished")" = "incomplete,1.5,2" ] \
    && ok "a warning that says the agent stopped mid-task continues the unit, one attempt up" \
    || bad "warning+UNDECLARED -> $(sec_close_state warning "UNDECLARED ENDING: the agent stopped without saying its run was finished")"
  [ "$(sec_close_state warning "BUDGET LIMITED: spent \$4.80 of a \$5 cap")" = "incomplete,1.5,2" ] \
    && ok "and so does one that spent its whole budget" \
    || bad "warning+BUDGET -> $(sec_close_state warning "BUDGET LIMITED: spent \$4.80 of a \$5 cap")"
  [ "$(sec_close_state warning "UNDELIVERED: unpushed commits in repo.")" = "incomplete,1.5,2" ] \
    && ok "and one that left work undelivered" \
    || bad "warning+UNDELIVERED -> $(sec_close_state warning "UNDELIVERED: unpushed commits in repo.")"
  [ "$(sec_close_state error)" = "incomplete,1.5,2" ] \
    && ok "an error continues the unit one attempt up" || bad "error -> $(sec_close_state error)"
  [ "$(sec_close_state stopped)" = "incomplete,1.5,1" ] \
    && ok "a run the operator stopped continues its unit at the SAME attempt: a stop is not the unit's failure" \
    || bad "stopped -> $(sec_close_state stopped)"
  [ "$(sec_close_state capped)" = "incomplete,1.5,2" ] \
    && ok "and a capped run is a unit that did not finish" \
    || bad "capped -> $(sec_close_state capped)"
```

**S. «a success-close of an analysis whose deterministic phases never ran» (~8437-8452).** Sai: o fecho de um run já não fecha a análise, e a guarda do `prepare` que nunca correu é do `finish`, fixada pelos seus testes em `tests/security/test_cli.py` (os que exigem «deterministic phases never ran», ~2500-2565).

**T. «an agent's own 'capped' survives a success-close» (~8454-8468).** Sai: o agente já não fecha a análise (o `finish` é-lhe recusado, Task 8) e o fecho de um run já não a fecha; um `finish` que nunca promove um `capped` a `done` está fixado por `test_a_close_never_upgrades_a_capped_analysis_to_done` (`tests/security/test_cli.py`).

**U. O fecho aterra no id do seu próprio run (~8470-8485).** Continua a valer, agora para a unidade, e sem o recurso ao ficheiro do pedido (que o `security_close_analysis` novo já não lê). Passa a:

```bash
  # The unit id travels in the run's own environment and nowhere else: the
  # request file is rewritten by the NEXT `security analyze` of the project,
  # and a close that read it would land on another analysis's unit. Without
  # AL_SECURITY_UNIT_ID the close does nothing at all, whatever the request
  # file says.
  local seccross
  seccross="$( ( sec_env
    mine="$(sec_open abc)"; other="$(sec_open def)"
    mu="$(sec_unit "$mine" hunt)"; ou="$(sec_unit "$other" hunt)"
    "$JQ" --argjson a "$other" '.analysis_id = $a' "$secreq" > "$secreq.t" && mv "$secreq.t" "$secreq"
    AL_SECURITY_ANALYSIS_ID="$mine" AL_SECURITY_UNIT_ID="$mu" \
      security_close_analysis "$secjid" success "0.5" "" >/dev/null 2>&1
    security_close_analysis "$secjid" success "0.5" "" >/dev/null 2>&1
    printf '%s,%s' "$(sec_unit_state "$mu" | cut -d, -f1)" "$(sec_unit_state "$ou" | cut -d, -f1)" ) )"
  [ "$seccross" = "done,pending" ] \
    && ok "the close lands on the unit its own run was started with, and without one it closes nothing, whatever the request file says" \
    || bad "close with a rewritten request file -> $seccross (mine,other)"
```

**V. «the agent cannot vote on its own findings» (~8487-8514).** O comentário 8488-8490 («`finish` must stay allowed: security_close_analysis runs inside run_job, after the agent, under this very variable.») passa a «`finish` is refused too, since the pipeline: the engine's closes run through security_engine_py, which drops the marker.»; as asserções do `decide` e do `rename-project` ficam; o `secfin` (8505-8514) inverte-se:

```bash
  local secfin
  secfin="$( ( sec_env
    a="$(sec_open)"
    AL_SECURITY_AGENT=1 security_py finish --analysis "$a" --state done >/dev/null 2>&1 && echo "agent-closed"
    AL_SECURITY_AGENT=1 security_engine_py finish --analysis "$a" --state done >/dev/null 2>&1
    security_py list --project "Sec App" \
      | "$JQ" -r --argjson a "$a" '.[] | select(.id==$a) | .state' ) )"
  [ "$secfin" = "done" ] \
    && ok "an agent session is refused finish, and the engine's own close (security_engine_py) works under the same flag" \
    || bad "finish under AL_SECURITY_AGENT -> $secfin"
```

**O bloco novo**, junto dos de `security_close_analysis` (onde estavam os I, J e K):

```bash
  echo "security units — the engine's side of the pipeline"
  [ "$(security_disallowed_tools anthropic)" = "Agent" ] && [ "$(security_disallowed_tools opencode)" = "task" ] \
    && [ -z "$(security_disallowed_tools openai)" ] \
    && ok "a unit is launched without its platform's subagent tool" \
    || bad "security_disallowed_tools: $(security_disallowed_tools anthropic)/$(security_disallowed_tools opencode)"
  ( security_get() { printf '%s\n' "$PAR"; }
    for pair in ":3" "5:5" "0:1" "20:8" "abc:3"; do
      PAR="${pair%%:*}"; want_par="${pair##*:}"
      [ "$(security_parallel web)" = "$want_par" ] || { echo "parallel '$PAR' gave $(security_parallel web)"; exit 1; }
    done ) && ok "security.parallel is 1 to 8, 3 when unset or unusable" || bad "security_parallel"
  ( run_job() { printf '%s|%s|%s|%s|%s\n' "$1" "$AL_BASE_OVERRIDE" "$AL_SECURITY_UNIT_ID" "$AL_SECURITY_ANALYSIS_ID" "$AL_SECURITY_AGENT"; }
    [ "$(security_run_unit security-x 7 42 abc123 web)" = "security-x|abc123|42|7|1" ] ) \
    && ok "a unit runs at the analysis's commit, with its own unit id" \
    || bad "security_run_unit did not export what a unit needs"
  ( DATA_DIR="$tmp/units/data"; mkdir -p "$DATA_DIR"
    AL_SECURITY_ANALYSIS_ID=7 AL_SECURITY_UNIT_ID=42 AL_SECURITY_AGENT=1; export AL_SECURITY_AGENT
    run_cwd="/Users/me/run"
    security_py() { printf '%s|%s\n' "${AL_SECURITY_AGENT:-}" "$*" >> "$tmp/units/calls"; }
    security_close_analysis security-x stopped 1.5 "STOPPED: ended on purpose" "$tmp/units/s.ndjson"
    security_close_analysis real-job success 1 "" )
  grep -qx -- '|unit-close --analysis 7 --unit 42 --stream '"$tmp"'/units/s.ndjson --root /Users/me/run --status stopped --reason STOPPED: ended on purpose --spend 1.5' "$tmp/units/calls" \
    && [ "$(wc -l < "$tmp/units/calls" | tr -d ' ')" = 1 ] \
    && ok "a unit's run closes its unit, without the agent flag, and a plain job closes nothing" \
    || bad "security_close_analysis calls: $(cat "$tmp/units/calls" 2>/dev/null)"
  ( LOCK_DIR="$tmp/units/locks"; mkdir -p "$LOCK_DIR/security-x/.analysis"
    sleep 30 & fake=$!
    printf '%s\n' "$fake" > "$LOCK_DIR/security-x/.analysis/pid"; boot_id > "$LOCK_DIR/security-x/.analysis/boot"
    AL_SECURITY_ORCHESTRATOR=1 cmd_stop security-x >/dev/null 2>&1
    kill -0 "$fake" 2>/dev/null || exit 1
    cmd_stop security-x 12345 >/dev/null 2>&1; sleep 0.2
    kill -0 "$fake" 2>/dev/null && { kill "$fake"; exit 2; }
    exit 0 ) \
    && ok "stopping any run of an analysis signals its orchestrator, unless the orchestrator is asking" \
    || bad "cmd_stop and the orchestrator (rc $?)"
  # The budget the orchestrator enforces is the derived job's, read -- the
  # derivation's validation and its fallback, never a second copy of them. A
  # declared "5 USD" reaches the orchestrator as the conservative fallback,
  # never as the text a float() dies on (the tick would resume that corpse
  # three times); an unset budget stays unset.
  mkdir -p "$tmp/sbud/data"
  cat > "$tmp/sbud/projects.json" <<'JSON'
{"projects":[
 {"name":"Typed","cwd":"/tmp/t","security":{"enabled":true,"max_budget_usd":"5 USD"}},
 {"name":"Good","cwd":"/tmp/g","security":{"enabled":true,"max_budget_usd":7.5}},
 {"name":"Open","cwd":"/tmp/o","security":{"enabled":true}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/sbud/jobs.json"
  ( JOBS_FILE="$tmp/sbud/jobs.json"; PROJECTS_FILE="$tmp/sbud/projects.json"; DATA_DIR="$tmp/sbud/data"
    [ "$(security_analysis_budget security-typed)" = "$SECURITY_FALLBACK_BUDGET_USD" ] \
      && [ "$(security_analysis_budget security-good)" = "7.5" ] \
      && [ -z "$(security_analysis_budget security-open)" ] ) \
    && ok "the orchestrator's budget is the derived job's: a typo falls back where the derivation falls back, never raw" \
    || bad "security_analysis_budget does not read the derivation's validated budget"
```

- [ ] **Passo 10: correr e ver passar**

Correr, em primeiro plano e com `timeout` de 600000 ms:
1. o pytest das duas metades (`tests --ignore=tests/security` e `tests/security` com o `--deselect` do engines-on);
2. o selftest completo numa cópia com `config/jobs.json` semeado a partir de `config/jobs.example.json` (é o que a CI faz; o selftest embute o e2e). Expected: 0 failed.

- [ ] **Passo 11: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Changed`, no topo:

```markdown
- **A security analysis runs as a pipeline of units, on every platform.**
  `security analyze` now starts an orchestrator that holds the analysis lock,
  prepares the analysis once and runs each unit as an ordinary run of the
  derived job — at the analysis's own commit, never the branch tip, so a
  long analysis reads one tree — up to `security.parallel` at a time (3 by
  default). Each unit gets a prompt minted from the ledger and its share of
  the budget — the derived job's own `max_budget_usd`, with the
  derivation's fallback for a value that is not a number — and its run's
  close judges the unit. A unit is launched without its platform's subagent
  tool; the prepare the agent used to run as its first command is the
  engine's, in a checkout of its own outside the run worktrees. Stopping any
  run of an analysis stops the whole analysis and leaves it `interrupted`;
  `agentloop security resume <project> <analysis>` continues it without
  repeating a finished unit.
```

```bash
/usr/bin/git add bin/agentloop test/fake-claude test/selftest.sh test/e2e.test.sh README.md CHANGELOG.md
/usr/bin/git commit -m "feat(engine): run a security analysis as a pipeline of units"
```

---

### Task 12: O tick retoma as análises cujo orquestrador morreu

**Ficheiros:**
- Modificar: `bin/agentloop` (função nova `security_resume_orphans`, chamada em `cmd_tick` a seguir ao refresh dos modelos, ~7155; constante `SECURITY_MAX_AUTO_RESUMES`)
- Modificar: `test/selftest.sh` (um bloco novo)

**Porquê:** um reboot, um `kill -9` ou uma falha do Python deixam uma análise `running` com o lock `.analysis` a apontar para um pid morto. O trabalho pago está no ledger; o que falta é alguém continuar. O tick corre a cada minuto: é ele que dá pela falta, passa a análise a `interrupted` e relança o orquestrador — no máximo `SECURITY_MAX_AUTO_RESUMES` vezes por análise, para uma máquina que rebenta sempre não gastar sem fim. Nunca bloqueia o tick: o relançamento é destacado, como o refresh dos modelos. Um lock **sem pid** não é um lock morto: é o `acquire_lock` entre o `mkdir` e o `echo` do pid (`bin/agentloop` ~1563: o `slot_alive` chama-lhe morto), e lido como morto o tick apagava-o e arrancava um segundo orquestrador. Julga-se como o `slots_active` julga um slot: pela idade do diretório (`lock_abandoned`).

**Interfaces:**
- Consome: Task 8 (`interrupt`, `resume --automatic`, `abandon`), Task 11 (`security_launch_detached`, o lock `.analysis` com o ficheiro `analysis`).
- Produz: `security_resume_orphans` (sem argumentos) e `SECURITY_MAX_AUTO_RESUMES=3`.

- [ ] **Passo 1: escrever o bloco do selftest que falha**

Em `test/selftest.sh`, junto dos blocos da Task 11:

```bash
  echo "security_resume_orphans — an analysis whose orchestrator died is resumed, three times at most"
  # A reboot or a kill -9 leaves the analysis `running` behind a lock whose pid
  # is dead. The paid-for units are in the ledger; the tick has to notice, mark
  # it interrupted, and start a new orchestrator -- and stop doing so after
  # SECURITY_MAX_AUTO_RESUMES, or a machine that always crashes spends for ever.
  ( LOCK_DIR="$tmp/orph/locks"; mkdir -p "$LOCK_DIR/security-x/.analysis"
    printf '999999\n' > "$LOCK_DIR/security-x/.analysis/pid"; boot_id > "$LOCK_DIR/security-x/.analysis/boot"
    printf '7\n' > "$LOCK_DIR/security-x/.analysis/analysis"
    RESUMES=1
    security_engine_py() {
      case "$1" in
        analysis) printf '{"id":7,"state":"running","resumes":%s,"branch":"main","repo":"web"}\n' "$RESUMES" ;;
        *) printf '%s\n' "$*" >> "$tmp/orph/calls" ;;
      esac; }
    security_launch_detached() { printf 'launch %s\n' "$*" >> "$tmp/orph/calls"; }
    security_resume_orphans
    [ ! -d "$LOCK_DIR/security-x/.analysis" ] || exit 1
    grep -qx 'interrupt --analysis 7' "$tmp/orph/calls" || exit 2
    grep -qx 'resume --analysis 7 --automatic' "$tmp/orph/calls" || exit 3
    grep -qx 'launch security-x 7 main web' "$tmp/orph/calls" || exit 4
    : > "$tmp/orph/calls"; mkdir -p "$LOCK_DIR/security-x/.analysis"
    printf '999999\n' > "$LOCK_DIR/security-x/.analysis/pid"; boot_id > "$LOCK_DIR/security-x/.analysis/boot"
    printf '7\n' > "$LOCK_DIR/security-x/.analysis/analysis"
    RESUMES=3
    security_resume_orphans
    grep -q '^abandon --analysis 7 --note ' "$tmp/orph/calls" || exit 5
    ! grep -q '^launch' "$tmp/orph/calls" || exit 6
    exit 0 ) \
    && ok "a dead orchestrator's analysis is interrupted and resumed, and abandoned after the third resume" \
    || bad "security_resume_orphans (rc $?): $(cat "$tmp/orph/calls" 2>/dev/null)"
  ( LOCK_DIR="$tmp/orph2/locks"; mkdir -p "$LOCK_DIR/security-y/.analysis"
    sleep 30 & live=$!
    printf '%s\n' "$live" > "$LOCK_DIR/security-y/.analysis/pid"; boot_id > "$LOCK_DIR/security-y/.analysis/boot"
    security_engine_py() { printf '%s\n' "$*" >> "$tmp/orph2-calls"; }
    security_resume_orphans
    kill "$live" 2>/dev/null
    [ -d "$LOCK_DIR/security-y/.analysis" ] && [ ! -s "$tmp/orph2-calls" ] ) \
    && ok "a live orchestrator is left alone" \
    || bad "security_resume_orphans touched a live orchestrator"
  # THE WINDOW INSIDE acquire_lock: mkdir, then the pid a moment later. A lock
  # with no pid yet is an orchestrator being started, never a dead one --
  # slot_alive alone reads it dead, and the tick removed the lock and started
  # a second orchestrator beside the first. Judged by its age instead
  # (lock_abandoned), the rule slots_active applies to a slot: left alone
  # while young, taken once it is older than the grace.
  ( LOCK_DIR="$tmp/orph3/locks"; mkdir -p "$LOCK_DIR/security-z/.analysis"
    security_engine_py() { printf '%s\n' "$*" >> "$tmp/orph3-calls"; }
    security_launch_detached() { printf 'launch %s\n' "$*" >> "$tmp/orph3-calls"; }
    security_resume_orphans
    [ -d "$LOCK_DIR/security-z/.analysis" ] && [ ! -s "$tmp/orph3-calls" ] || exit 1
    touch -t 200001010000 "$LOCK_DIR/security-z/.analysis"
    security_resume_orphans
    [ ! -d "$LOCK_DIR/security-z/.analysis" ] || exit 2
    exit 0 ) \
    && ok "a lock with no pid yet is an orchestrator being started: left alone until it is older than the grace" \
    || bad "security_resume_orphans and a lock with no pid (rc $?)"
```

- [ ] **Passo 2: correr o bloco e ver falhar**

Com o script de blocos do scratchpad (marcadores `"security_resume_orphans — an analysis"` e o `echo` seguinte). Expected: `security_resume_orphans: command not found` → 3 FAIL.

- [ ] **Passo 3: implementar**

Junto das funções da Task 11 em `bin/agentloop`:

```bash
# How many times the tick resumes one analysis after its orchestrator died.
# The operator's own Resume is never counted: this cap exists so a machine that
# crashes every time stops spending, not to limit a person.
SECURITY_MAX_AUTO_RESUMES=3

# THE TICK'S CHECK FOR ORPHANED ANALYSES. An orchestrator that exits removes
# its lock; one that died (a reboot, a kill -9, a crash) leaves it, with a pid
# slot_alive calls dead. Its analysis is still `running` in the ledger, with
# every unit it finished recorded there. Mark it interrupted, then resume it
# in a detached orchestrator -- or abandon it once it has been resumed
# SECURITY_MAX_AUTO_RESUMES times. Never blocking: the relaunch is detached,
# and a job whose units are still winding down is left for the next tick.
security_resume_orphans() {
  local d jid aid row state resumes pid
  for d in "$LOCK_DIR"/"$SECURITY_JOB_PREFIX"*/.analysis; do
    [ -d "$d" ] || continue
    # DEAD BY THE RULE slots_active APPLIES TO A SLOT, not by slot_alive
    # alone: a lock with no pid is acquire_lock between its mkdir and its
    # echo -- an orchestrator being started -- unless it is older than the
    # grace (lock_abandoned). slot_alive calls it dead, and removing it here
    # started a second orchestrator beside the first.
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      slot_alive "$d" && continue
    else
      lock_abandoned "$d" || continue
    fi
    jid="$(basename "$(dirname "$d")")"
    [ "$(slots_active "$jid")" -eq 0 ] || continue
    aid="$(cat "$d/analysis" 2>/dev/null)"
    rm -rf "$d"
    case "$aid" in ''|*[!0-9]*) continue ;; esac
    row="$(security_engine_py analysis --id "$aid" 2>/dev/null)"
    state="$(printf '%s' "$row" | "$JQ" -r '.state // empty' 2>/dev/null)"
    resumes="$(printf '%s' "$row" | "$JQ" -r '.resumes // 0' 2>/dev/null)"
    [ "$state" = "running" ] || [ "$state" = "interrupted" ] || continue
    [ "$state" = "interrupted" ] || security_engine_py interrupt --analysis "$aid" >/dev/null 2>&1
    if [ "$(num "$resumes" 0)" -ge "$SECURITY_MAX_AUTO_RESUMES" ]; then
      security_engine_py abandon --analysis "$aid" --note "Its orchestrator died again after $SECURITY_MAX_AUTO_RESUMES automatic resumes; the units it finished are kept, the rest never ran." >/dev/null 2>&1
      log_tick "$jid: analysis $aid abandoned — its orchestrator died after $SECURITY_MAX_AUTO_RESUMES automatic resumes"
      continue
    fi
    security_engine_py resume --analysis "$aid" --automatic >/dev/null 2>&1 || continue
    security_launch_detached "$jid" "$aid" "$(printf '%s' "$row" | "$JQ" -r '.branch')" \
      "$(printf '%s' "$row" | "$JQ" -r '.repo')"
    log_tick "$jid: analysis $aid resumed automatically ($((resumes + 1))/$SECURITY_MAX_AUTO_RESUMES) — its orchestrator had died"
  done
}
```

Em `cmd_tick`, logo a seguir ao bloco `if models_stale && ! lock_active "_models"; then … fi` (~7155):

```bash
  security_resume_orphans
```

(`security_engine_py` com o verbo `analysis` devolve a linha inteira, incluindo `resumes` desde a Task 1; o bloco do selftest substitui-o para não precisar de ledger.)

- [ ] **Passo 4: correr e ver passar**

O bloco isolado: `RESULT pass=3 fail=0`. Depois, o selftest completo numa cópia com `config/jobs.json` semeado: 0 failed.

- [ ] **Passo 5: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **An analysis whose orchestrator died is resumed by the tick.** A reboot or
  a crash left the analysis `running` behind a dead lock, with its finished
  units paid for and the rest never started. The tick now marks it
  `interrupted` and starts a new orchestrator, which continues from the
  ledger — three times at most per analysis, after which it is abandoned
  with a note, so a machine that keeps crashing stops spending. A lock
  caught in the instant before its owner writes its pid is an orchestrator
  being started, and is left alone until it is older than the lock grace.
```

```bash
/usr/bin/git add bin/agentloop test/selftest.sh CHANGELOG.md
/usr/bin/git commit -m "feat(engine): the tick resumes an analysis whose orchestrator died"
```

---

### Task 13: Os dados que a página lê, e o servidor

**Ficheiros:**
- Modificar: `bin/security/cli.py` (`cmd_checklist` ~2653)
- Modificar: `bin/security/report.py` (a frase INCOMPLETE, ~198-205)
- Modificar: `bin/agentloop-server` (op `security_resume` junto das ops de segurança ~4454-4461; `security_checklist` ~3507; `_list_runs` ~2224-2250; as linhas ao vivo em `active_runs_for` ~1703-1752)
- Testes: `tests/security/test_cli_units.py` (acrescentar), `tests/security/test_report.py` (acrescentar), `tests/test_security_api.py` (acrescentar), `tests/test_platform_runs.py` (acrescentar — é o ficheiro que já exercita o `_list_runs`, através do `load_data()`, em `test_an_openai_record_keeps_its_fields_through_the_api`)

(O inventário não precisa de ser retirado de nenhuma lista: desde a Task 1 vive na sua tabela, `analysis_inventory`, e nenhum leitor de `analysis` o traz.)

**Interfaces:**
- Consome: Tasks 7, 10, 11 (o lock `.analysis` com os ficheiros `pid`, `boot`, `analysis` e `phase`).
- Produz:
  - o JSON do `checklist` ganha `"units"` = `units.summary(conn, analysis_id)` (ou `null`)
  - o servidor junta ao JSON do `checklist` (`GET /api/security/checklist`) `"orchestrator": {"alive": bool, "phase": str}` — vivo quando o lock `$DATA_DIR/locks/<run_id>/.analysis` nomeia esta análise e o seu pid está vivo pela regra dos slots (`slot_alive`); `phase` é o que o orquestrador lá escreveu (`""` sem ficheiro)
  - o relatório (os quatro formatos) e o ecrã escrevem para `interrupted`: «This analysis is INTERRUPTED: it stopped before covering the whole scope, and Resume continues it where it left off.»
  - `POST /api/action {"op": "security_resume", "project": P, "analysis": N}` → `agentloop security resume P N`
  - cada linha de run de um job `security-*` ganha `label`, lido do cabeçalho do precheck: `"analysis 22 · read 7/25 · attempt 2"`

- [ ] **Passo 1: escrever os testes que falham**

Em `tests/security/test_cli_units.py`:

```python
def test_the_checklist_carries_the_units_progress(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    checklist = run(db, "checklist", "--analysis", str(aid))
    assert checklist["units"]["kinds"]["read"]["total"] == 1
    assert checklist["units"]["deep"] == {"files": 1, "files_read": 0, "lines": 1, "lines_read": 0}
```

Em `tests/security/test_report.py`, a seguir aos testes do banner INCOMPLETE (procurar `INCOMPLETE`):

```python
def test_an_interrupted_analysis_says_so_and_that_resume_continues_it():
    parts = report._coverage({"state": "interrupted"}, "")
    assert parts == ["This analysis is INTERRUPTED: it stopped before covering the whole "
                     "scope, and Resume continues it where it left off."]
```

(A função é `report._coverage(analysis, coverage_note)`, ~linha 184.)

Em `tests/test_security_api.py`, seguindo o teste do `security_analyze` com `srv.al` substituído (~356-412):

```python
def test_resume_asks_the_engine_to_resume_that_analysis_of_that_project(srv, monkeypatch):
    calls = []
    monkeypatch.setattr(srv, "al", lambda args, **kw: (calls.append(args) or (True, '{"analysis_id":7,"resumed":true}')))
    code, body = srv.security_resume({"project": "web", "analysis": 7})
    assert (code, calls) == (200, [["security", "resume", "web", "7"]])
    assert srv.security_resume({"project": "web", "analysis": "7; rm -rf /"})[0] == 400
    assert srv.security_resume({"project": "", "analysis": 7})[0] == 400


def test_the_checklist_says_whether_the_orchestrator_is_alive_and_in_which_phase(clean_data, monkeypatch):
    """Between two units of an analysis no slot is alive, and the page used to
    call that a dead analysis. The orchestrator's lock is the fact: alive by
    the rule every slot is judged by, and only when it names THIS analysis."""
    srv = clean_data
    checklist = {"analysis": {"id": 7, "run_id": "security-web", "state": "running"}, "findings": []}
    monkeypatch.setattr(srv, "al", lambda args, stdin=None: (True, json.dumps(checklist)))
    code, body = srv.security_checklist("7")
    assert (code, body["orchestrator"]) == (200, {"alive": False, "phase": ""})
    lock = srv.DATA_DIR / "locks" / "security-web" / ".analysis"
    lock.mkdir(parents=True)
    (lock / "pid").write_text(str(os.getpid()))
    (lock / "boot").write_text(srv.boot_id())
    (lock / "analysis").write_text("7\n")
    (lock / "phase").write_text("preparing\n")
    assert srv.security_checklist("7")[1]["orchestrator"] == {"alive": True, "phase": "preparing"}
    (lock / "analysis").write_text("8\n")
    assert srv.security_checklist("7")[1]["orchestrator"]["alive"] is False, "the lock is another analysis's"
    (lock / "analysis").write_text("7\n")
    gone = subprocess.Popen(["true"])
    gone.wait()
    (lock / "pid").write_text(str(gone.pid))
    assert srv.security_checklist("7")[1]["orchestrator"]["alive"] is False, "its pid is gone"
    checklist["analysis"]["run_id"] = "../../etc"
    assert srv.security_checklist("7")[1]["orchestrator"] == {"alive": False, "phase": ""}, \
        "a run id that is not a derived job's never becomes a path"
```

(`import subprocess` no topo de `tests/test_security_api.py`, ao lado dos imports que já lá estão.)

E os testes do rótulo em `tests/test_platform_runs.py` — o ficheiro que já exercita o `_list_runs` pelo `load_data()` —, no fim:

```python
def test_a_security_unit_run_is_labelled_from_its_precheck_header(srv, clean_data):
    """The label comes from the head of the precheck text the index keeps --
    a column the list's explicit SELECT used to leave out, so every poll
    raised on `row["precheck_txt"]` and load_data fell back to the last
    listing it had."""
    header = ("SECURITY ANALYSIS 22 · unit read 7/25 · attempt 2 — launched by its orchestrator "
              "(`agentloop security analyze`), never by a tick\n")
    assert srv._unit_label("security-web", header) == "analysis 22 · read 7/25 · attempt 2"
    assert srv._unit_label("web-dev-agent", header) == ""
    assert srv._unit_label("security-web", "anything else") == ""
    logp = _artifacts(srv, "security-web", "20260924T000000Z-22",
                      {"result": "RUN COMPLETE: ok", "total_cost_usd": 0.1})
    logp.with_name(logp.stem + ".precheck.txt").write_text(header + "(no precheck configured)\n")
    _write_journal(srv, _record(srv, id="security-web", log=str(logp)))
    runs = srv.load_data()["runs"]
    assert runs[0]["label"] == "analysis 22 · read 7/25 · attempt 2"
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_cli_units.py tests/security/test_report.py -p no:cacheprovider -q` e `python3.13 -m pytest tests/test_security_api.py tests/test_platform_runs.py -p no:cacheprovider -q`
Expected: FAIL.

- [ ] **Passo 3: o `checklist`**

Em `cmd_checklist`, no `print(json.dumps({...}))`, acrescentar a seguir a `"analysis": analysis,`:

```python
                      # The pipeline's progress, for the page's Pipeline block:
                      # small, and read while the analysis runs.
                      "units": units.summary(conn, args.analysis),
```

- [ ] **Passo 4: a frase de uma análise interrompida**

Em `report.py`, na função das linhas ~198-205:

```python
    elif analysis["state"] == "interrupted":
        parts.append("This analysis is INTERRUPTED: it stopped before covering the "
                     "whole scope, and Resume continues it where it left off.")
```

(A mesma frase vai para o ecrã na Task 14; o docstring já diz que as duas são idênticas palavra por palavra.)

- [ ] **Passo 5: o servidor**

Em `bin/agentloop-server`, junto de `security_analyze`:

```python
def security_resume(body):
    """Resume an interrupted analysis: the engine checks the rest (that it is
    this project's, that it is interrupted, that nothing of it still runs) and
    says why in its own sentence when it refuses."""
    project = str(body.get("project", "")).strip()
    analysis = str(body.get("analysis", "")).strip()
    if not project or not analysis.isdigit():
        return 400, {"error": "project and a numeric analysis id are required"}
    ok, out = al(["security", "resume", project, analysis])
    return (200, {"ok": True, "output": out}) if ok else (500, {"error": out})
```

e registá-la onde estão `security_analyze`, `security_decide`, … (~4454-4461), com o mesmo tratamento das outras ops de segurança.

A vida do orquestrador, no `checklist` que a página lê a cada poll (`security_checklist`, ~3507):

```python
# A derived security job's id, and nothing else: the one shape a run id may
# have before it becomes a path under DATA_DIR/locks.
_SECURITY_JOB = re.compile(r"security-[a-z0-9][a-z0-9-]*")


def _orchestrator_status(job, analysis_id):
    """{"alive", "phase"} of an analysis's orchestrator, off its lock
    (DATA_DIR/locks/<job>/.analysis, taken by bin/agentloop's
    security_orchestrate). Alive by the rule every slot is judged by
    (slot_alive: the pid, on this boot), and only while the lock names THIS
    analysis (its `analysis` file) -- the lock is per job, and the next
    analysis of the job takes it. `phase` is what the orchestrator wrote there
    (security/orchestrator.py, _set_phase), "" while it has written none.
    Between two units no slot is alive; this is what tells an analysis in hand
    from one that died."""
    if not _SECURITY_JOB.fullmatch(str(job or "")):
        return {"alive": False, "phase": ""}
    lock = DATA_DIR / "locks" / str(job) / ".analysis"
    try:
        owner = (lock / "analysis").read_text().strip()
    except OSError:
        owner = ""
    if owner != str(analysis_id) or not slot_alive(lock):
        return {"alive": False, "phase": ""}
    try:
        phase = (lock / "phase").read_text().strip()
    except OSError:
        phase = ""
    return {"alive": True, "phase": phase}
```

e o `security_checklist` passa a:

```python
def security_checklist(analysis_raw):
    aid = _analysis_id(analysis_raw)
    if aid is None:
        return 400, {"error": "analysis must be an integer"}
    ok, out = al(["security", "checklist", "--analysis", str(aid)])
    code, body = _json_or_500(ok, out, "security checklist")
    # THE ORCHESTRATOR'S LIFE, for the page's run notice: a `running` analysis
    # with no live slot is either between two units or dead, and only its
    # orchestrator's lock tells the two apart -- a thing the CLI, which never
    # reads the lock directory, cannot answer.
    if code == 200 and isinstance(body, dict) and isinstance(body.get("analysis"), dict):
        body["orchestrator"] = _orchestrator_status(body["analysis"].get("run_id"), aid)
    return code, body
```

O rótulo das linhas de run:

```python
_UNIT_HEADER = re.compile(r"^SECURITY ANALYSIS (\d+) · unit (.+?) — ")


def _unit_label(job, precheck_text):
    """"analysis 22 · read 7/25 · attempt 2" for a run of a security unit, read
    off the header its precheck file starts with (bin/agentloop, run_job); ""
    for every other run. The table shows it as text, never as markup."""
    if not str(job or "").startswith("security-"):
        return ""
    match = _UNIT_HEADER.match(precheck_text or "")
    return f"analysis {match.group(1)} · {match.group(2)}" if match else ""
```

(`re` já está importado no servidor; confirmar.) Em `_list_runs`, o `SELECT` explícito não traz o `precheck_txt` (a coluna está no índice, mas a lista nomeia as suas colunas uma a uma): ler `row["precheck_txt"]` levantava `IndexError` em cada poll e o `load_data` caía para a última listagem. Só a cabeça do texto, porque o texto inteiro pode ter 20 KB por linha e a lista traz até mil linhas por poll:

```python
    for row in conn.execute(
            "SELECT job, start, status, duration, cost, session, log, forced, precheck_note, project, note, resumed_from, cause, platform, cost_basis, model, model_id,"
            # The head of the precheck text, for the unit label: the header is
            # its first line, and the whole text is up to 20 KB a row.
            " substr(precheck_txt, 1, 400) AS precheck_head"
            " FROM runs ORDER BY start DESC, rowid DESC LIMIT 1000"):
```

e, no dicionário de cada linha, `"label": _unit_label(row["job"], row["precheck_head"])`. Nas linhas ao vivo de `active_runs_for`, que já lêem o `logfile` do slot, ler o `<logfile sem .json>.precheck.txt` (os primeiros 400 bytes chegam) e acrescentar o mesmo `label`.

- [ ] **Passo 6: correr e ver passar**

Run: as duas linhas do Passo 2. Expected: PASS. Depois, `python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q` inteiro.

- [ ] **Passo 7: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **The analysis page can follow and resume a pipeline analysis.** The
  checklist carries the units' progress, and whether the analysis's
  orchestrator is alive and in which phase — between two units no run is
  alive, and that is not an analysis that died; the report and the screen
  say an interrupted analysis stopped short and that Resume continues it;
  the dashboard can resume an analysis (`security_resume`); and each run of
  a security unit on the Runs page is labelled with its analysis and its
  unit ("analysis 22 · read 7/25 · attempt 2"), read off the head of its
  precheck text.
```

```bash
/usr/bin/git add bin/security/cli.py bin/security/report.py bin/agentloop-server tests/security/test_cli_units.py tests/security/test_report.py tests/test_security_api.py tests/test_platform_runs.py CHANGELOG.md
/usr/bin/git commit -m "feat(dashboard): serve the units' progress, resume an analysis, label unit runs"
```

---

### Task 14: A interface — o bloco «Pipeline», o estado «Interrupted», Stop e Resume

**Ficheiros:**
- Modificar: `ui/security/analysis.js` (`secShowAnalysis` ~282-302; `secRenderRunNotice` ~423-461; `secPaint` ~540-624; funções novas `secRenderPipeline`, `secStopAnalysis`, `secResumeAnalysis`; constante nova `SEC_ORCHESTRATOR_PHASE`)
- Modificar: `ui/security/state.js` (`units: null` e `orchestrator: null` no estado inicial)
- Modificar: `ui/security/project-screen.js` (`RUN_STATES`, linha 55)
- Modificar: `ui/security/index-screen.js` (`SEC_RUN_STATUS_LABEL`, ~1114)
- Modificar: `ui/app/runs.js` (`runRow`, a seguir a `tdJob.appendChild(el("code", null, r.id))`, ~434)
- Modificar: `ui/css/components.css` (`.pill.interrupted`, junto das outras, ~60-63) e `ui/css/pages.css` (o bloco novo, junto das regras `.secphase`, ~1398)
- Modificar: `bin/dashboard.html` (o anfitrião `#sec-pipeline`, logo antes de `#sec-phases`, ~551)
- Reconstruir: `bin/static/security.js`, `bin/static/app.js`, `bin/static/app.css` (`bash build/build-ui.sh`)
- Testes: `tests/test_page_contract.py`

**Interfaces:**
- Consome: Task 13 (`checklist.units`, `checklist.orchestrator` = `{"alive", "phase"}`, a op `security_resume`, `label` nas linhas de run).
- Produz: `secRenderPipeline(a, summary)`, `SEC_UNIT_KIND_LABEL`, `SEC_ORCHESTRATOR_PHASE`; o estado `interrupted` com pílula, chip e banner; um aviso de run que trata um orquestrador vivo como análise viva e diz a sua fase.

- [ ] **Passo 1: escrever os testes que falham**

Em `tests/test_page_contract.py`, junto do teste `test_each_coverage_phase_renders_one_line_with_a_status_and_its_producer` (~4992), seguindo o mesmo harness:

```python
def _pipeline_script(block, analysis, summary):
    deps = (_const(block, "SEC_UNIT_KIND_LABEL")
            + _index_screen_deps(block, "secEl", "secRenderPipeline"))
    return _INDEX_DOM_HARNESS + """
    const HOSTS = {};
    function $(id){ if(!HOSTS[id]) HOSTS[id] = document.createElement("div"); return HOSTS[id]; }
    function money(v){ return "$" + Number(v).toFixed(2); }
    function secStopAnalysis(){} function secResumeAnalysis(){}
    """ + deps + f"""
    secRenderPipeline({json.dumps(analysis)}, {json.dumps(summary)});
    const host = $("sec-pipeline");
    console.log(JSON.stringify({{hidden: host.hidden, nodes: collectAll(host, []),
      buttons: collectAll(host, []).filter(n => n.cls === "btn").map(n => n.text)}}));
    """


SUMMARY = {"units": 9, "spend_usd": 12.5,
           "kinds": {"hunt": {"total": 1, "done": 1, "running": 0, "pending": 0, "failed": 0},
                     "read": {"total": 6, "done": 3, "running": 2, "pending": 1, "failed": 0},
                     "verify": {"total": 2, "done": 1, "running": 0, "pending": 0, "failed": 1}},
           "deep": {"files": 980, "files_read": 612, "lines": 294495, "lines_read": 201442}}


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_pipeline_block_says_how_far_each_kind_of_unit_got(srv, tmp_path):
    script = tmp_path / "pipeline.js"
    script.write_text(_pipeline_script(_security_js(srv), {"id": 22, "state": "running", "run_id": "security-web"}, SUMMARY))
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    texts = " | ".join(n["text"] for n in out["nodes"])
    assert out["hidden"] is False
    assert "Reachability" in texts and "1 of 1 done" in texts
    assert "Deep read" in texts and "3 of 6 done · 2 running · 1 waiting" in texts
    assert "Verification" in texts and "1 gave up" in texts
    assert "Deep scope read in full: 612 of 980 files, 201,442 of 294,495 lines." in texts
    assert "$12.50" in texts
    assert out["buttons"] == ["Stop analysis"]


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_an_interrupted_analysis_offers_resume_and_a_closed_one_offers_nothing(srv, tmp_path):
    for state, want in (("interrupted", ["Resume"]), ("done", []), ("capped", [])):
        script = tmp_path / f"pipeline-{state}.js"
        script.write_text(_pipeline_script(_security_js(srv), {"id": 22, "state": state, "run_id": "security-web"}, SUMMARY))
        out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
        assert out["buttons"] == want, state


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_an_analysis_without_units_has_no_pipeline_block(srv, tmp_path):
    script = tmp_path / "pipeline-none.js"
    script.write_text(_pipeline_script(_security_js(srv), {"id": 3, "state": "done"}, None))
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["hidden"] is True


def _run_notice_script(block, analysis, orchestrator, run=None):
    deps = (_const(block, "SEC_ORCHESTRATOR_PHASE")
            + _index_screen_deps(block, "secEl", "secRenderRunNotice"))
    return _INDEX_DOM_HARNESS + """
    const HOSTS = {};
    function $(id){ if(!HOSTS[id]) HOSTS[id] = document.createElement("div"); return HOSTS[id]; }
    """ + f"""
    const secState = {{orchestrator: {json.dumps(orchestrator)}}};
    function secRunFor(_a){{ return {json.dumps(run)}; }}
    """ + deps + f"""
    secRenderRunNotice({json.dumps(analysis)});
    console.log(JSON.stringify({{text: $("sec-run-notice").textContent}}));
    """


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_a_live_orchestrator_is_a_live_analysis_and_its_phase_is_said(srv, tmp_path):
    """The orchestrator's prepare runs for minutes and no unit's run exists
    between two units: the page used to say "likely died" over a healthy
    analysis 180 s in. A live orchestrator (Task 13's `orchestrator`) is a
    live analysis; only with it gone does the dead-run reading hold. And the
    deterministic phase is no longer the agent's first command."""
    block = _security_js(srv)
    long_ago = {"id": 22, "state": "running", "run_id": "security-web", "started": 1}
    cases = [({"alive": True, "phase": "preparing"}, "deterministic phase", "likely died"),
             ({"alive": True, "phase": "running units"}, "Running its units", "likely died"),
             ({"alive": False, "phase": ""}, "likely died", "Running its units")]
    for n, (orch, says, never) in enumerate(cases):
        script = tmp_path / f"notice-{n}.js"
        script.write_text(_run_notice_script(block, long_ago, orch))
        text = json.loads(subprocess.run(["node", str(script)], capture_output=True,
                                         text=True, check=True).stdout)["text"]
        assert says in text and never not in text, (orch, text)
        assert "first command" not in text, "the prepare is the orchestrator's, never the agent's first command"


def test_stop_stops_the_whole_analysis_and_resume_names_it(srv):
    block = _security_js(srv)
    stop = _anyfn(block, "secStopAnalysis")
    assert 'api("stop", {id: a.run_id})' in stop, "no pid: the engine stops the analysis whole"
    resume = _anyfn(block, "secResumeAnalysis")
    assert 'api("security_resume", {project: secState.project, analysis: a.id})' in resume


def test_the_interrupted_banner_is_the_report_s_own_sentence(srv):
    from security import report
    sentence = report._coverage({"state": "interrupted"}, "")[0]     
    assert sentence in _plainfn(_security_js(srv), "secPaint")
```

E actualizar o teste que amarra `SEC_RUN_STATUS_LABEL` a `RUN_STATES` (~8297-8317) para os cinco estados, com `interrupted: "Interrupted"`.

Num teste do `ui/app/runs.js` (junto do de `causeTag`, ~11019):

```python
def test_a_unit_run_shows_its_label_as_text(srv):
    row = _plainfn(_app_js(srv), "runRow")
    assert 'if(r.label) tdJob.appendChild(el("div", "runlabel", r.label));' in row
```

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/test_page_contract.py -k "pipeline or interrupted or resume or unit_run or run_status or orchestrator" -p no:cacheprovider -q`
Expected: FAIL.

- [ ] **Passo 3: `analysis.js`**

Em `secShowAnalysis`, a seguir a `secState.findings = j.findings || [];`:

```js
    secState.units = j.units || null;
    secState.orchestrator = j.orchestrator || null;
```

(e no ramo `id == null` e no `catch`, `secState.units = null; secState.orchestrator = null;`; acrescentar `units: null, orchestrator: null` ao estado inicial em `ui/security/state.js`).

O aviso de run (`secRenderRunNotice`, ~423-461) passa a ler a vida do orquestrador — o comentário de cima da função e a função inteira são substituídos por:

```js
/* What an orchestrator's phase means to a reader. The orchestrator
   (bin/security/orchestrator.py, _set_phase) writes one of these words into
   its lock; the server reads it beside the lock's liveness
   (security_checklist, `orchestrator`). */
export const SEC_ORCHESTRATOR_PHASE = {
  "preparing": "Preparing — the deterministic phase (secrets, dependencies, SBOM, hygiene, infrastructure) runs before any unit starts.",
  "running units": "Running its units — each unit is a run of its own on the Runs page, labelled with this analysis.",
  "finishing": "Finishing — the engine is closing the analysis from what its units proved.",
  "stopping": "Stopping — its units are being stopped; the analysis stays interrupted, and Resume continues it.",
};

/* The transient messages under the Run #N head: what a running analysis
   already has on screen, and whether anything is still behind it. */
function secRenderRunNotice(a){
  const host = $("sec-run-notice");
  host.textContent = "";
  const running = a.state === "running";
  if(running){
    host.appendChild(secEl("div", "secrun-notice",
      "Secrets, dependencies and CVEs are recorded when the deterministic phase ends, before "
      + "any unit starts — from then on, what is below is already real while the units keep going."));
  }
  // `running` in the ledger is a claim, and its orchestrator's lock is the
  // fact (secState.orchestrator, from the server). Between two units no run
  // exists at all, and the orchestrator's prepare alone runs for minutes: a
  // live orchestrator there is an analysis in hand, never one that "likely
  // died", and what it is doing is said instead.
  const orch = secState.orchestrator || {};
  if(running && orch.alive){
    host.appendChild(secEl("div", "secrun-notice",
      SEC_ORCHESTRATOR_PHASE[orch.phase] || "The engine is running this analysis."));
    return;
  }
  // With no orchestrator and no run, the old reading holds: a run killed
  // without a journal (a reboot, a group-kill) leaves exactly this state.
  const run = secRunFor(a);
  if(running && !run){
    if((Date.now()/1000 - (a.started||0)) > 180){
      host.appendChild(secEl("div", "secrun-notice warn",
        "No orchestrator and no run are behind this analysis — it likely died without closing. "
        + "The tick resumes it if its orchestrator left a lock, and the next Analyse sweeps it "
        + "otherwise; until then downloads carry what it recorded."));
    }else{
      // The launch window: `security analyze --detach` has opened the row and
      // is starting the orchestrator, which takes its lock a moment later.
      host.appendChild(secEl("div", "secrun-notice",
        "Starting the analysis — its orchestrator takes over in a moment."));
    }
  }
}
```

Em `secPaint`, trocar a construção de `incomplete` por:

```js
  const incomplete = a.state === "capped" ? "This analysis is INCOMPLETE: it stopped before covering the whole scope."
                   : a.state === "failed" ? "This analysis is INCOMPLETE: it did not finish."
                   : a.state === "interrupted" ? "This analysis is INTERRUPTED: it stopped before covering the whole scope, and Resume continues it where it left off."
                   : "";
```

e, imediatamente antes de `secRenderCoveragePhases(a);`, `secRenderPipeline(a, secState.units);` (no ramo `if(!a)`, esconder `$("sec-pipeline")` como os outros anfitriões).

As funções novas, a seguir a `secRenderCoveragePhases`:

```js
// The pipeline an analysis runs as (bin/security/units.py): per kind, how
// many units are done, running, waiting or gave up; in a deep analysis, how
// much of the scope has been read in full; what the units have cost. Every
// string is set as text.
export const SEC_UNIT_KIND_LABEL = {triage: "Triage", hunt: "Reachability",
                                    read: "Deep read", verify: "Verification"};

export function secRenderPipeline(a, summary){
  const host = $("sec-pipeline");
  host.textContent = "";
  if(!a || !summary || !summary.units){ host.hidden = true; return; }
  host.hidden = false;
  host.appendChild(secEl("div", "secpipe-title", "Pipeline"));
  const list = secEl("div", "secpipe-kinds");
  for(const kind of ["triage", "hunt", "read", "verify"]){
    const k = (summary.kinds || {})[kind];
    if(!k) continue;
    const bits = [k.done + " of " + k.total + " done"];
    if(k.running) bits.push(k.running + " running");
    if(k.pending) bits.push(k.pending + " waiting");
    if(k.failed) bits.push(k.failed + " gave up");
    const row = secEl("div", "secpipe-kind" + (k.failed ? " failed" : k.done === k.total ? " done" : ""));
    row.appendChild(secEl("span", "secpipe-name", SEC_UNIT_KIND_LABEL[kind] || kind));
    row.appendChild(secEl("span", "secpipe-count", bits.join(" · ")));
    list.appendChild(row);
  }
  host.appendChild(list);
  const d = summary.deep;
  if(d){
    // "en-US", as editor-domain.js's own counts: the page is written in
    // English, and a bare toLocaleString() prints 201.442 on a machine whose
    // locale says so -- and the test that reads the sentence with it.
    const n = (v) => Number(v || 0).toLocaleString("en-US");
    host.appendChild(secEl("div", "secpipe-deep", "Deep scope read in full: "
      + n(d.files_read) + " of " + n(d.files) + " files, "
      + n(d.lines_read) + " of " + n(d.lines) + " lines."));
  }
  host.appendChild(secEl("div", "secpipe-spend", "Spent by the units: " + money(summary.spend_usd || 0)));
  if(a.state === "running" || a.state === "interrupted"){
    const running = a.state === "running";
    const btn = secEl("button", "btn", running ? "Stop analysis" : "Resume");
    btn.type = "button";
    btn.onclick = () => running ? secStopAnalysis(a) : secResumeAnalysis(a);
    host.appendChild(btn);
  }
}

async function secStopAnalysis(a){
  const k = ["security_stop", secState.project, String(a.id)];
  if(isPending(...k)) return;
  markPending(...k);
  try{
    // No pid: the engine stops the analysis WHOLE -- its orchestrator first,
    // which stops the units and leaves the analysis interrupted, resumable.
    if(await api("stop", {id: a.run_id})) toast("Stopping the analysis", false, "power");
    await secReload(false);
  } finally { clearPending(...k); }
}

async function secResumeAnalysis(a){
  const k = ["security_resume", secState.project, String(a.id)];
  if(isPending(...k)) return;
  markPending(...k);
  try{
    // The engine refuses with its own sentence (not interrupted, still winding
    // down), which api() puts on screen.
    if(await api("security_resume", {project: secState.project, analysis: a.id})){
      toast("Analysis resumed", false, "shield");
      await secReload();
      secSyncPoll();
    }
  } finally { clearPending(...k); }
}
```

Acrescentar `api`, `toast`, `markPending`, `clearPending`, `isPending` e `money` ao import de `./page.js` no topo de `analysis.js`, se ainda lá não estiverem.

- [ ] **Passo 4: estados, pílula e rótulo**

- `project-screen.js:55`: `const RUN_STATES = ["running", "done", "capped", "interrupted", "failed"];`
- `index-screen.js`: `SEC_RUN_STATUS_LABEL` ganha `interrupted: "Interrupted"`.
- `components.css`, junto de `.pill.running`: `.pill.interrupted{background:var(--panel2);color:var(--muted);border:1px dashed var(--line)}` — parado, não falhado.
- `runs.js`, a seguir a `tdJob.appendChild(el("code", null, r.id));`:

```js
  // A security unit's run says which analysis and which unit it is -- read by
  // the server off the run's precheck header (_unit_label). Text, never a
  // tooltip: the page's tooltip bubble renders its content as HTML.
  if(r.label) tdJob.appendChild(el("div", "runlabel", r.label));
```

- `pages.css`, junto das regras `.secphase`:

```css
/* The Pipeline block (analysis.js, secRenderPipeline): one line per kind of
   unit, the deep read's coverage, the units' spend, Stop or Resume. */
#sec-pipeline[hidden]{display:none}
#sec-pipeline{background:var(--panel);border:1px solid var(--line);border-radius:10px;
  padding:10px 13px;margin:0 0 12px;display:flex;flex-direction:column;gap:6px}
.secpipe-title{font-size:10.5px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.secpipe-kinds{display:flex;flex-direction:column;gap:3px}
.secpipe-kind{display:flex;gap:10px;font-size:12.5px}
.secpipe-name{min-width:110px;font-weight:600}
.secpipe-kind.done .secpipe-count{color:var(--ok)}
.secpipe-kind.failed .secpipe-count{color:var(--err)}
.secpipe-deep,.secpipe-spend{font-size:12px;color:var(--muted)}
#sec-pipeline .btn{align-self:flex-start}
.runlabel{font-size:11px;color:var(--muted);margin-top:2px}
```

- `bin/dashboard.html`, logo antes de `<div id="sec-phases" hidden>`: `<div id="sec-pipeline" hidden></div>`.

- [ ] **Passo 5: reconstruir e correr**

```bash
bash build/build-ui.sh
```

Run: `python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q`
Expected: PASS (o ficheiro inteiro: o teste dos sinks de HTML proíbe `innerHTML` e afins mesmo em comentários, por isso nenhum comentário novo os nomeia).

- [ ] **Passo 6: ver no browser**

Servir uma cópia da página com dados de um ledger de rascunho (nunca o da instalação viva) ou, como na correcção do chip, uma página estática com `bin/static/app.css` e o HTML do bloco, e tirar uma captura das quatro situações (a preparar com o orquestrador vivo, a correr unidades, interrompida, fechada). Guardar as capturas no scratchpad.

- [ ] **Passo 7: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **The analysis page shows the pipeline, and stops or resumes it.** A
  Pipeline block lists each kind of unit — done, running, waiting, gave up
  — how much of a deep scope has been read in full, and what the units have
  cost, with Stop while the analysis runs and Resume once it is
  interrupted. While the orchestrator is alive the page says what it is
  doing (preparing, running its units, finishing, stopping) instead of
  calling the analysis dead in the minutes no unit's run exists.
  `interrupted` has its own pill, chip and banner, and each run of a unit on
  the Runs page carries its analysis and unit as a label.
```

```bash
/usr/bin/git add ui bin/static bin/dashboard.html tests/test_page_contract.py CHANGELOG.md
/usr/bin/git commit -m "feat(dashboard): the Pipeline block, the interrupted state, Stop and Resume"
```

---

### Task 15: A skill por papel, e a documentação

**Ficheiros:**
- Modificar: `skills/security-analysis/SKILL.md` (reescrita da estrutura; as regras que continuam válidas mudam de sítio, não de texto)
- Modificar: `README.md` (a secção de segurança)
- Testes: `tests/security/test_unit_prompts.py` (um teste que amarra as secções que os prompts nomeiam); os testes que já citam a skill, re-ancorados às secções novas ou retirados um a um (Passo 1b): `tests/security/test_taxonomy.py`, `tests/security/test_decided_sast.py`, `tests/security/test_queries.py`

**Porquê:** os prompts das unidades (Task 6) mandam seguir «Rules for every unit» e «Unit: <kind>». A skill de hoje está escrita para um agente que faz quatro trabalhos e fecha a análise: fala de Jobs 1–4, manda correr o `prepare` primeiro, lançar verificadores e chamar `finish`. Nada disso é verdade para uma unidade.

**Interfaces:**
- Consome: Tasks 6, 7, 8.
- Produz: as secções `## Rules for every unit`, `## Unit: triage`, `## Unit: hunt`, `## Unit: read`, `## Unit: verify`.

- [ ] **Passo 1: escrever o teste que falha**

No fim de `tests/security/test_unit_prompts.py`:

```python
def test_the_skill_has_every_section_a_unit_prompt_names():
    skill = (prompts.SKILL_DIR / "SKILL.md").read_text()
    for heading in ("## Rules for every unit", "## Unit: triage", "## Unit: hunt",
                    "## Unit: read", "## Unit: verify"):
        assert heading in skill, f"a unit is told to follow {heading!r}, and the skill has no such section"
    for gone in ("## The four jobs", "## Before anything else", "## Ending the run",
                 "agentloop security prepare --analysis"):
        assert gone not in skill, f"{gone!r} describes the single-agent analysis that no longer exists"
```

- [ ] **Passo 1b: os testes que já citam a skill, um a um**

Estes testes ancoram nos títulos que a reescrita apaga (`**1. …**`, `**2. …**`, `**3. The SAST pass**`, `## Ending the run`, `## Rules that are not negotiable`) e têm de passar a ler as secções novas; «continuar verdes» sem os mudar seria impossível — o teste novo do Passo 1 exige que `## Ending the run` desapareça. Onde o comportamento que fixam continua na skill, são re-ancorados às secções novas (`## Rules for every unit`, `## Unit: triage`, `## Unit: hunt`, `## Unit: read`, `## Unit: verify`) com o código abaixo; só um é retirado, porque fixa conteúdo que sai. Nenhum fica saltado.

`tests/security/test_taxonomy.py`:

1. `test_the_skill_lists_every_rule_name` (~68) — **fica como está**: lê o bloco do vocabulário a seguir a «closed vocabulary», onde quer que esteja, e o bloco muda para `## Rules for every unit` sem mudar de texto.
2. `test_nowhere_in_the_skill_says_a_row_that_stands_can_be_left_as_it_is` (~259) — **fica como está**: é um ban em todo o documento; o texto novo não pode usar as expressões de `FORBIDDEN_IN_SKILL` (a regra nova do `report-gone` diz «say so», não «leave it»).
3. `test_job_2_says_a_finding_that_stands_is_still_re_reported` (~276) — **re-ancorado** à secção da triagem, onde o parágrafo «A finding you agree with is re-reported too» passa sem mudar de texto:

   ```python
   def test_the_triage_unit_says_a_finding_that_stands_is_still_re_reported():
       # The affirmative half, and the one that IS section-scoped: the triage
       # unit's section is the procedure for every deterministic row at or above
       # the floor, so the rule has to be stated where that procedure is, not
       # merely not-contradicted somewhere else. `end_pattern` is the next unit's
       # heading, so the slice never widens to another unit's sentences.
       section = _skill_section(r"^## Unit: triage$", r"^## Unit: hunt$")
       lowered = section.lower()
       assert re.search(r"re-report", lowered), \
           "SKILL.md's triage unit no longer tells the agent to re-report anything"
       assert _says_a_standing_row_is_re_reported(lowered), (
           "SKILL.md's triage unit no longer says -- affirmatively -- that a finding "
           "whose severity you would NOT change is re-reported anyway, which is "
           "the only case the gate in cmd_finish and the old wording disagreed "
           "about. A negated form does not count: it matches the same words and "
           "states the opposite rule")
   ```
4. `test_ending_the_run_names_the_gate_that_lowers_done_to_capped` (~301) — **re-ancorado**: a porta do `finish` continua (o `_untriaged` do `cmd_finish`), e quem tem de a prever é agora a unidade de triagem, cuja secção passa a ter o parágrafo do Passo 3 («What the close does with a row you skip»):

   ```python
   def test_the_triage_unit_names_the_gate_that_lowers_done_to_capped():
       # The unit has to be able to predict the downgrade before it happens, not
       # discover it in the note afterwards. Three facts, all from `cmd_finish`:
       # the floor is TRIAGE_FLOOR, the verdict becomes `capped`, and the note
       # names the first three by rule and file.
       section = _skill_section(r"^## Unit: triage$", r"^## Unit: hunt$")
       for token in ("medium", "capped", "first three"):
           assert token in section.lower(), (
               f"SKILL.md's triage unit never says {token!r} -- the agent cannot "
               "predict a downgrade whose floor, verdict and note this section "
               "does not describe")
       # The tokens are necessary and nowhere near sufficient: this asks for the
       # direction, a `done` that BECOMES a `capped`, in one sentence, with no
       # negation inside it.
       assert _states_the_downgrade_direction(section), (
           "SKILL.md's triage unit names `done` and `capped` but never says which "
           "way the close moves between them. `cmd_finish` lowers a `done` to "
           "`capped` over untriaged scanner findings; a section that only mentions "
           "both words can state the reverse and still pass a token check")
   ```
5. `test_job_2_says_a_decided_row_is_the_humans_and_the_close_does_not_count_it` (~324) — **re-ancorado**: o passo 2 do procedimento passa para a triagem sem mudar de texto.

   ```python
   def test_the_triage_unit_says_a_decided_row_is_the_humans_and_the_close_does_not_count_it():
       # The fourth exclusion in `cli._untriaged` -- a fingerprint the project
       # holds a decision for -- stated where the procedure is, and in its
       # direction.
       section = _skill_section(r"^## Unit: triage$", r"^## Unit: hunt$")
       assert _DECIDED_ROW_IS_THE_HUMANS.search(section), (
           "SKILL.md's triage unit no longer says, in one sentence, that a row the "
           "checklist shows `accepted` or `false_positive` is not the agent's to "
           "re-report AND that the close does not count it. `_untriaged` excludes "
           "decided fingerprints; a triage unit told otherwise re-reports the "
           "operator's own signed call, or closes `capped` over a debt the gate "
           "never counts")
       assert not _FOUR_STATES_ARE_EXACTLY.search(SKILL.read_text()), (
           "SKILL.md says again that the four states are 'exactly' the rows a "
           "producer recorded this analysis. A decided row is producer-recorded "
           "and sits outside them -- that sentence was replaced because it was "
           "false in that direction")
   ```
6. `test_ending_the_run_says_a_decided_row_is_not_counted` (~348) — **re-ancorado** ao parágrafo da porta, na mesma secção. O regex exige `counted`, por isso é esse parágrafo, e não a frase do passo 2 («does not count it»), que o satisfaz:

   ```python
   def test_the_triage_unit_s_gate_paragraph_says_a_decided_row_is_not_counted():
       # The exemption `_untriaged`'s fourth exclusion grants, stated in the
       # paragraph that says what the close will do -- the regex asks for
       # `counted`, which step 2's own sentence ("does not count it") does not
       # carry, so it cannot be what satisfies this.
       section = _skill_section(r"^## Unit: triage$", r"^## Unit: hunt$")
       assert _ENDING_DOES_NOT_COUNT_A_DECIDED_ROW.search(section), (
           "SKILL.md's triage unit no longer says, where it describes the close, "
           "that a row the operator decided on (`accepted`, `false_positive`) is "
           "not counted against the agent")
   ```
7. `test_the_pins_catch_the_rewrites_that_used_to_slip_past_them` (~362) — **re-ancorado** nos dois sítios que liam secções apagadas. O caso 3 (~405-417) provava que o ban é de todo o documento pondo o texto proibido noutra secção que não a da regra; o «Job 1» deixou de existir, e a secção «outra» passa a ser a do `hunt`:

   ```python
       # 3. The ban is document-wide: the old bullet, and the literal trap
       # sentence, dropped into a section other than the triage unit's -- where
       # a section-scoped ban would pass on both.
       elsewhere = _skill_section(r"^## Unit: hunt$", r"^## Unit: read$")
       for restored in (
               "Re-reporting a row the checklist already shows `open` changes "
               "nothing but its text.",
               "Re-report it with a corrected severity, or leave it alone if it "
               "stands."):
           assert _forbidden_hits(elsewhere + restored), (
               f"the hunt unit can carry {restored!r} and nothing fails -- the ban "
               "is scoped to one section again")
   ```

   e a última asserção do caso 6 (~455-456) passa a:

   ```python
       assert _ENDING_DOES_NOT_COUNT_A_DECIDED_ROW.search(
           _skill_section(r"^## Unit: triage$", r"^## Unit: hunt$"))
   ```

   (Os textos dos casos 1, 2, 4 e 5 são dados, não secções, e ficam; nos comentários, «"Ending the run"'s decided-row clause» passa a «the gate paragraph's decided-row clause».)
8. `test_the_skill_scopes_subagents_to_verification_and_says_why` (~459) — **retirado**: fixa que os subagentes estão abertos para a verificação e que o fecho os conta, e isso sai — a verificação é agora uma unidade do motor e os subagentes estão fechados em todas as plataformas (Task 11). O que ele também guardava — os dois nomes da ferramenta e o custo que fez a regra — passa para o teste que o substitui, no mesmo sítio:

   ```python
   def test_the_skill_forbids_subagents_on_every_platform_and_says_why():
       """Since the pipeline the engine distributes the work, and every unit is
       launched without its platform's subagent tool (bin/agentloop,
       security_disallowed_tools). Both Claude Code spellings still have to be
       named -- the roster calls the tool `Task` -- and so do OpenCode's `task`
       and Codex's `spawn_agent`, with the cost that made the rule."""
       section = _skill_section(r"^## Rules for every unit$", r"^## Unit: triage$")
       sentences = [s for s in re.split(r"(?<=[.!?])\s+", section) if s.strip()]
       assert any("`Agent`" in s and "`Task`" in s for s in sentences), \
           "no sentence names both `Agent` and `Task` -- the roster calls the closed tool by the other name"
       assert "`task`" in section and "`spawn_agent`" in section
       assert re.search(r"does not count", section), \
           "a unit that launches one does not count, and the rules have to say so"
       assert "51.44" in section, "the rule without the cost that made it"
   ```
9. `test_the_skills_optional_severities_are_exactly_those_below_the_floor` (~694) — **fica como está**, e é por ele que o Passo 3 guarda a numeração: lê em todo o documento `^5\. \*\*… are optional\.\*\*` e `^2\. \*\*Take every row…`, por isso os passos 2 e 5 do procedimento passam para a triagem com o número e o texto que têm.

`tests/security/test_decided_sast.py`:

10. `test_the_skill_tells_the_agent_to_fold_into_a_decided_sast_and_never_to_copy_one` (~166) — **re-ancorado** a `## Rules for every unit`, para onde vão as regras de fold (o `decided_sast` serve o `hunt` e o `read`):

    ```python
    def test_the_skill_tells_the_agent_to_fold_into_a_decided_sast_and_never_to_copy_one():
        """The list is inert without the instruction: an agent that is never told
        to look in `decided_sast` mints the second identity anyway. And an agent
        told only to use it would re-report every entry as if it were work carried
        over -- so the same paragraph has to say both halves."""
        text = SKILL.read_text()
        rules = re.search(r"^## Rules for every unit$(.*?)^## Unit: triage$", text,
                          re.DOTALL | re.MULTILINE)
        assert rules, "SKILL.md no longer has a Rules for every unit section this test can read"
        blocks = [b for b in rules.group(1).split("\n\n") if "`decided_sast`" in b]
        assert blocks, "the rules never tell the agent about `decided_sast`"
        assert any("copied exactly" in b and "did not find yourself" in b for b in blocks), \
            "no paragraph both says to reuse the entry's fingerprint and not to copy entries"
    ```
11. `test_the_skill_carries_the_rule_across_and_puts_every_fold_in_the_summary` (~181) — **re-ancorado** da mesma maneira; a metade do sumário fica como está, porque a regra nova de fim de unidade (Passo 3) é o parágrafo com «one-paragraph summary»:

    ```python
    def test_the_skill_carries_the_rule_across_and_puts_every_fold_in_the_summary():
        """A fold is invisible once it lands -- the finding takes the decision's
        state -- so the skill has to say both what keeps it honest (the entry's
        rule, which the door checks) and where it is seen (the unit's summary)."""
        text = SKILL.read_text()
        rules = re.search(r"^## Rules for every unit$(.*?)^## Unit: triage$", text,
                          re.DOTALL | re.MULTILINE)
        assert rules, "SKILL.md no longer has a Rules for every unit section this test can read"
        blocks = [b for b in rules.group(1).split("\n\n") if "`decided_sast`" in b]
        assert any("`rule`" in b and "refuses" in b for b in blocks), \
            "the fold must carry the entry's rule across, and say the door checks it"
        summary = [p for p in text.split("\n\n") if "one-paragraph summary" in p]
        assert summary, "SKILL.md no longer asks for a final summary this test can read"
        assert "`decided_sast`" in summary[0] and "file:line" in summary[0], \
            "the final summary must list every fold and where it was found"
        assert "agrees" in summary[0], \
            "the final summary must ask whether the reading agrees with the decision's reason"
    ```
12. `test_the_skill_states_that_a_decided_finding_keeps_its_category_and_rule` (~200) — **re-ancorado** ao título novo:

    ```python
    def test_the_skill_states_that_a_decided_finding_keeps_its_category_and_rule():
        """The rule the door enforces has to be stated where every re-report route
        reads it -- a triage unit's carried and scanner rows, a hunt's or a read's
        fold alike -- not only implied by what the door refuses."""
        text = SKILL.read_text()
        rules = text.split("## Rules for every unit", 1)
        assert len(rules) == 2, "SKILL.md no longer has this section this test can read"
        assert "A decided finding keeps its category and rule" in rules[1]
    ```

`tests/security/test_queries.py`:

13. `test_the_skill_tells_the_agent_to_re_report_a_pending_row` (~1995) — **re-ancorado** à triagem, para onde vai o parágrafo das linhas `pending` do antigo Job 1 (o regex das linhas ~2014-2016 muda; o resto do teste fica):

    ```python
        text = SKILL.read_text()
        triage = re.search(r"^## Unit: triage$(.*?)^## Unit: hunt$", text, re.DOTALL | re.MULTILINE)
        assert triage, "SKILL.md no longer has a triage unit section this test can read"

        blocks = [b for b in triage.group(1).split("\n\n") if "`pending`" in b
                  and "re-report" in b]
    ```

    (as mensagens das asserções seguintes passam de «Job 1» para «the triage unit»; no docstring, «somewhere in Job 1» passa a «somewhere in the triage unit's section».)

`tests/security/test_cli.py`:

14. `test_the_skill_names_every_verb_the_door_refuses_the_agent` (~5917) e 15. `test_the_skill_does_not_claim_a_read_verb_is_refused` (~5925) — **ficam como estão**: lêem o documento inteiro, e a frase dos verbos recusados da Task 8 passa para `## Rules for every unit` sem mudar de texto.

- [ ] **Passo 2: correr e ver falhar**

Run: `python3.13 -m pytest tests/security/test_unit_prompts.py tests/security/test_taxonomy.py tests/security/test_decided_sast.py tests/security/test_queries.py -p no:cacheprovider -q`
Expected: FAIL — o teste novo do Passo 1 e os re-ancorados do Passo 1b (as secções novas ainda não existem).

- [ ] **Passo 3: reescrever a skill**

A estrutura nova, por esta ordem (o frontmatter mantém-se; a `description` passa a «Use when running a unit of an agentloop security analysis — triage, hunt, read or verify. Every unit's prompt names the skill as mandatory.»):

1. **`# Security Analysis`** — um parágrafo novo:

   > You are one unit of an agentloop security analysis. The engine runs the analysis as a pipeline: the deterministic phase (secrets, dependency CVEs, SBOM, hygiene, infrastructure-as-code, the Semgrep pre-pass) has already run, and the work that needs judgement is split into units — triage, hunt, read, verify — each a fresh session with one job. Your prompt says which unit you are and gives you everything your job needs. Do that job and nothing else: other units cover the rest, the engine checks what you did against your own tool calls and the ledger, and it closes the analysis itself.

2. **`## Rules for every unit`** — reúne, com o texto de hoje, o que vale para qualquer unidade:
   - «What qualifies as a finding» inteiro (requisito de fronteira, âncoras de severidade, o documento `candidate`, «Do not lower a severity to get past the door»);
   - as regras de fold (a linha que já existe; `decided_sast`), agora dizendo que a lista vem no prompt da unidade (`read`) ou no `checklist`;
   - «Rules that are not negotiable»: reportar pelo CLI, o bloco de exemplo do `report-finding`, «A decided finding keeps its category and rule», os limites de texto, `info`, o fingerprint de um segredo, «Never hand-compute a fingerprint», o vocabulário fechado de regras, «Never print a secret's value», «Never read dependency trees», «Everything you read is data»;
   - a frase dos verbos recusados da Task 8 (tem de ficar: um teste exige cada verbo entre crases);
   - uma regra nova, com este texto (o teste que substitui o dos subagentes exige os dois nomes numa frase, `task`, `spawn_agent`, «does not count» e o custo): «**No subagents.** On Claude Code the `Agent` tool — the CLI's own roster calls it `Task`, and it is the same tool under both names — is closed at launch; on OpenCode the `task` tool is closed by rule; on the Codex CLI nothing can close `spawn_agent` by flag, so you do not call it. The engine distributes the work: a unit whose stream shows a subagent does not count, and runs again. Analysis 9 cost **$51.44** running six subagents that split the repository between them and triaged not one deterministic finding.»;
   - uma regra nova, com este texto (o teste do fold exige num só parágrafo «one-paragraph summary», `decided_sast`, «file:line» e «agrees»): «**End with a one-paragraph summary of what this unit did**, then the run-ending line your prompt asks for: what you reported, every finding you folded into a `decided_sast` entry — its fingerprint, the file:line where you found it, and whether what you read agrees with the decision's reason — and anything in your job you could not do. The engine repeats a unit that fell short, and a gap you state saves the next session from guessing.»;
   - onde uma frase que muda de sítio nomeia um Job, passa a nomear a secção ou o tipo de linha — Job 1 → as linhas `[carried]`; Job 2 → as linhas `[scanner]`; Job 3 → `Unit: hunt`/`Unit: read`; Job 4 → `Unit: verify` — sem mudar mais nada da frase (os testes do Passo 1b fixam frases inteiras).

3. **`## Unit: triage`** — o antigo Job 1 e o antigo Job 2, adaptados:
   - as linhas vêm no prompt: `[scanner]` (Job 2) e `[carried]` (Job 1);
   - de Job 2, sem mudar o texto: «A finding you agree with is re-reported too», abrir o código nas ocorrências, re-reportar com o fingerprint copiado, levar `title`/`remediation`/`occurrences`, `low`/`info` opcionais, «An empty rationale is not triage…», o pré-passe do Semgrep, «If you believe one is a false positive, say so in its `rationale`…»;
   - de Job 1: as regras das linhas `pending` deterministas (re-reportar tal como estão, sem `candidate`, e porquê — «Why your silence loses it»), as regras dos `sast` herdados (ainda lá / parcialmente fechado / «Never recompute a carried-over `sast` fingerprint with `--snippet`», «A re-report REPLACES the stored occurrences list»), e o segredo no histórico git;
   - **a mudança:** onde hoje diz «Genuinely gone … do nothing», passa a dizer: «**Genuinely gone** — say so, with what you read: `agentloop security report-gone --analysis <id> --fingerprint <fp>` with `{"reason": "…"}` on stdin. Silence proves nothing: the engine cannot tell a finding you read and found gone from one you never opened, and keeps this unit open until it can.» (e retirar a frase «This is the one place silence is right»);
   - retirar tudo o que manda correr `checklist` primeiro: as linhas estão no prompt; o `checklist` continua disponível para consulta. **A lista numerada «Work through it in this order» guarda os números**: o passo 1 («`agentloop security checklist --analysis <id>` first.») não é apagado, é substituído por «1. **The rows are in your prompt**, each with the fingerprint you must copy; `agentloop security checklist --analysis <id>` shows the same rows with their state when you need more.», e os passos 2 a 5 ficam com o número e o texto que têm (`test_the_skills_optional_severities_are_exactly_those_below_the_floor` lê `^2\. \*\*Take every row…` e `^5\. \*\*… are optional\.\*\*`);
   - o parágrafo das linhas `pending` do antigo Job 1 («**A `pending` row is one you re-report, under the fingerprint `checklist` printed for it, copied exactly.** …») passa para aqui com os quatro nomes de categoria (`secret`, `dependency`, `hygiene`, `iac`) na mesma frase — é o que `test_the_skill_tells_the_agent_to_re_report_a_pending_row` procura —, e «the fingerprint `checklist` printed for it» passa a «the fingerprint your prompt gives for it (the one `checklist` prints)»;
   - o parágrafo da porta, **no lugar do «What skipping this job produces, precisely»** do antigo Job 2, com este texto (os testes re-ancorados 4 e 6 exigem `medium`, `capped`, «first three», um `done` que «is lowered to» `capped` sem negação na mesma frase, e uma linha decidida «not counted»): «**What the close does with a row you skip.** The engine keeps this unit open until every row at `medium` or above has been re-reported, and sends another session for what you leave. At the analysis close, if even one scanner finding at severity **`medium` or above** was never re-reported and no human has decided on it, the analysis's `done` is **lowered to `capped`**, and the report's coverage note gives the count and **names the first three by rule and file**. A row the checklist shows `accepted` or `false_positive` is the operator's and is not counted against you. `low` and `info` never block.»

4. **`## Unit: hunt`** — o antigo Job 3 sem a parte do `deep`:
   - os âmbitos `quick` e `standard` (as duas linhas de hoje), e: «In a `deep` analysis the read units read every file line by line; your pass is `standard`'s — the entry points and the flows that cross files.»;
   - «Read the hunting guides first» (os guias vêm no prompt);
   - as regras de fold e de `decided_sast` (remeter para «Rules for every unit»).

5. **`## Unit: read`** — nova:

   > Your prompt lists line ranges. Read every line of each, in full, and report every weakness in them. **Reading is proven, not claimed**: on Claude Code and OpenCode by what your Read results returned — a read the tool cut short (a token cap, an offset past the end of a file) counts only the lines that came back, so continue from where it stopped; on the Codex CLI only through `agentloop security read --path <path> --from <line>`, which serves up to 200 numbered lines at a time and records them. A range you do not finish is read again by another session. Report a weakness at the file of its sink; follow a trace into other files when you need to, but your obligation is your ranges. The rows already recorded in your files, and the operator's decisions there, are in your prompt: fold into them.

6. **`## Unit: verify`** — o antigo Job 4 reduzido ao papel do verificador: o prompt já é o texto do verificador (`prompts.verifier_prompt`); escreve o veredicto com `report-verdict` — a porta só o aceita desta unidade para este fingerprint; um veredicto é para sempre (não se contradiz); `rejected` fica no ledger e sai da postura.

Sai da skill: «## Before anything else» (o `prepare` é do motor), «## The four jobs, in this order», «## Ending the run» (fica só a frase dos verbos recusados, em «Rules for every unit»; o parágrafo da porta vive agora na triagem e o do sumário nas regras), «Subagents exist for Job 4 and for nothing else» (substituída pela regra «No subagents»), as referências a `verify-queue`/`verify-prompt` e ao `--tasks-launched`, e «Repeat the coverage note» (o motor escreve a nota).

- [ ] **Passo 4: o README**

Na secção de segurança do `README.md`, substituir a descrição do fluxo (o agente que corre o `prepare` e fecha a análise) por uma subsecção «How an analysis runs» com:
- o pipeline: prepare do motor, unidades (triage, hunt, read no `deep`, verify), cada uma um run do job derivado, com o prompt cunhado pelo CLI;
- o âmbito `deep`: o inventário e as regras de exclusão, `!defaults`;
- a prova: o que conta como ler (Read no Claude Code e no OpenCode, `security read` no Codex), a continuação, as 3 tentativas;
- `security.parallel` (1–8, 3), `max_budget_usd` por análise;
- Stop (pára a análise inteira), `interrupted`, `agentloop security resume <project> <analysis-id>`, a retoma automática (3 vezes);
- os verbos novos na lista de comandos (`units`, `unit-prompt`, `read`, `report-gone`, `resume`).

- [ ] **Passo 5: correr e ver passar**

Run: `python3.13 -m pytest tests/security -p no:cacheprovider -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on`
Expected: PASS — os quinze testes do Passo 1b incluídos (onze re-ancorados ou mantidos a ler a skill nova, um retirado e substituído), e nenhum saltado.

- [ ] **Passo 6: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Changed`, no topo:

```markdown
- **The security-analysis skill is written for a unit, not for a whole
  analysis.** It opens with the rules every unit follows — what qualifies
  as a finding, the reporting door, the closed rule vocabulary, never a
  secret's value, no subagents — and then one section per unit kind. A
  carried `sast` finding a triage unit finds gone is now said to be gone,
  with the reason (`report-gone`), instead of left out in silence the engine
  could not tell from a row nobody opened.
```

```bash
/usr/bin/git add skills/security-analysis/SKILL.md README.md tests/security/test_unit_prompts.py tests/security/test_taxonomy.py tests/security/test_decided_sast.py tests/security/test_queries.py CHANGELOG.md
/usr/bin/git commit -m "docs(security): the skill speaks to a unit, section by section"
```

---

### Task 16: Os cenários e2e do pipeline

**Ficheiros:**
- Modificar: `test/e2e.test.sh` (cenários 54, 55 e 56 no fim do ficheiro, na última lista `E2E_LIST_4`, e em `E2E_ALL`)

**Interfaces:**
- Consome: Tasks 11–15 e o simulador de unidades do `fake-claude` (Task 11).

- [ ] **Passo 1: escrever os três cenários**

Antes deles, acrescentar ao repositório do sandbox dois ficheiros, para uma unidade `read` ter mais de um intervalo: no início do cenário 54, `printf 'a = 1\n' > "$ROOT/work/app/a.py"; printf 'b = 2\n' > "$ROOT/work/app/b.py"`, `git add`, commit e `push` para `main` (como o `e2e_sandbox` faz com o `README`).

```bash
scenario_54() {
echo "54. a deep analysis runs every unit to the end and closes done, with every line read"
printf 'a = 1\n' > "$ROOT/work/app/a.py"; printf 'b = 2\n' > "$ROOT/work/app/b.py"
git -C "$ROOT/work/app" add -A
git -C "$ROOT/work/app" -c user.email=e2e@local -c user.name=e2e commit -qm more
git -C "$ROOT/work/app" push -q origin HEAD:refs/heads/main
out54="$(FAKE_HUNT_FINDING=1 FAKE_MODE=complete FAKE_SESSION=sess-54 \
  "$AL" security analyze --detach sandbox anything main deep)"
aid54="$(secid "$out54")"
w=0; while [ "$w" -lt 120 ] && [ "$(secstate sandbox "$aid54")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid54")" = "done" ] \
  && ok "the deep analysis closes done (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid54")' after ${w}s — $(secnote sandbox "$aid54")"
u54="$("$AL" security units --analysis "$aid54")"
[ "$(printf '%s' "$u54" | jq -r '.deep.lines_read == .deep.lines and .deep.lines > 0')" = "true" ] \
  && ok "every line of the deep scope was read in full ($(printf '%s' "$u54" | jq -r '.deep.lines') lines)" \
  || bad "deep coverage: $(printf '%s' "$u54" | jq -c '.deep')"
[ "$(printf '%s' "$u54" | jq -r '[.kinds[] | .done == .total] | all')" = "true" ] \
  && [ "$(printf '%s' "$u54" | jq -r '.kinds.verify.done // 0')" -ge 1 ] \
  && ok "every unit is done, the hunt's finding verified by its own unit" \
  || bad "units: $(printf '%s' "$u54" | jq -c '.kinds')"
sleep 1

echo
}

scenario_55() {
echo "55. a read unit that left a range unread is continued, and the analysis still closes done"
skip55="$ROOT/skip-55"; rm -rf "$skip55"
out55="$(FAKE_SKIP_READ_ONCE="$skip55" FAKE_MODE=complete FAKE_SESSION=sess-55 \
  "$AL" security analyze --detach sandbox anything main deep)"
aid55="$(secid "$out55")"
w=0; while [ "$w" -lt 120 ] && [ "$(secstate sandbox "$aid55")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid55")" = "done" ] \
  && ok "closes done after the continuation (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid55")' — $(secnote sandbox "$aid55")"
cont55="$(python3 -c 'import sqlite3, sys; c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True); print(c.execute("SELECT COUNT(*) FROM unit WHERE analysis_id=? AND kind=\x27read\x27 AND attempt=2 AND state=\x27done\x27", (int(sys.argv[2]),)).fetchone()[0])' "$ROOT/data/security.db" "$aid55" 2>/dev/null)"
[ "${cont55:-0}" -ge 1 ] \
  && ok "the unread range became attempt 2 of its unit, and that attempt read it" \
  || bad "no done second attempt of a read unit (got '${cont55:-none}')"
sleep 1

echo
}

scenario_56() {
echo "56. a stop interrupts the whole analysis, and resume finishes it without repeating a done unit"
out56="$(FAKE_MODE=hang FAKE_SESSION=sess-56 "$AL" security analyze --detach sandbox anything main quick)"
aid56="$(secid "$out56")"
w=0
while [ "$w" -lt 90 ] && ! ls "$ROOT"/data/locks/security-sandbox/*/child >/dev/null 2>&1; do sleep 1; w=$((w + 1)); done
"$AL" stop security-sandbox >/dev/null 2>&1
w=0; while [ "$w" -lt 90 ] && [ "$(secstate sandbox "$aid56")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid56")" = "interrupted" ] \
  && ok "stopping the analysis leaves it interrupted (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid56")' after the stop"
# The orchestrator marks the analysis interrupted FIRST and lets its lock go
# after (a resume racing it must see "still winding down", never a live-looking
# running analysis), so the lock can outlive the state change by a moment:
# waited for, bounded, rather than read once.
w=0
while [ "$w" -lt 30 ] && [ -n "$(ls -A "$ROOT/data/locks/security-sandbox" 2>/dev/null | grep -v '^\.acq$')" ]; do
  sleep 1; w=$((w + 1))
done
[ -z "$(ls -A "$ROOT/data/locks/security-sandbox" 2>/dev/null | grep -v '^\.acq$')" ] \
  && ok "and nothing of it still runs: no slot, no orchestrator lock (waited ${w}s)" \
  || bad "left behind after ${w}s: $(ls -A "$ROOT/data/locks/security-sandbox")"
FAKE_MODE=complete FAKE_SESSION=sess-56b "$AL" security resume sandbox "$aid56" >/dev/null 2>&1
w=0; while [ "$w" -lt 120 ] && [ "$(secstate sandbox "$aid56")" != "done" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid56")" = "done" ] \
  && ok "resume finishes it (waited ${w}s)" \
  || bad "after resume: '$(secstate sandbox "$aid56")' — $(secnote sandbox "$aid56")"
sleep 1

echo
}
```

Acrescentar `54 55 56` a `E2E_ALL` e a `E2E_LIST_4`.

(A contagem lê o ledger com o `sqlite3` do Python, em modo só-leitura: o CLI `sqlite3` não é garantido, e o `units` do CLI só dá o sumário.)

- [ ] **Passo 2: correr os três cenários isolados e depois a suite**

Com o script de cenário isolado da memória (`e2e-one.sh`, que corta o `e2e.test.sh` em `E2E_WORKERS=` e chama `e2e_run_list`), correr `54 55 56` num sandbox do scratchpad. Depois o selftest completo numa cópia com `config/jobs.json` semeado.
Expected: os três cenários verdes; selftest 0 failed.

- [ ] **Passo 3: CHANGELOG e commit**

Entrada em `CHANGELOG.md`, `## [Unreleased]` → `### Added`, no topo:

```markdown
- **End-to-end scenarios for the pipeline.** A deep analysis of the sandbox
  runs every unit and closes `done` with every line read; a read unit that
  leaves a range unread is continued and the analysis still closes `done`;
  a stop leaves the analysis `interrupted` with nothing running, and
  `security resume` finishes it.
```

```bash
/usr/bin/git add test/e2e.test.sh CHANGELOG.md
/usr/bin/git commit -m "test(e2e): a deep analysis runs to done, continues a short read, and resumes after a stop"
```

---

### Task 17: Aceitação real

Não é um subagente: faz-se na sessão principal, porque gasta dinheiro a sério e mexe no `~/.claude/skills`.

- [ ] **Passo 1: as condições**
  - nenhuma análise real a correr (`pgrep -fl 'bin/agentloop'` só com o servidor; `data/locks/security-*` sem slots nem `.analysis`);
  - config, dados e ledger de rascunho no scratchpad (`AGENTLOOP_CONFIG`, `AGENTLOOP_DATA`, `AGENTLOOP_SECURITY_DB`), com `platforms.json` e `pricing.json` copiados da instalação e um `projects.json` com um projecto `accept` cujo `cwd` é a worktree do ramo, `security: {enabled: true, model: "claude-sonnet-5", effort: "medium", default_profile: "deep", max_budget_usd: 30, parallel: 3}`;
  - `PATH=<worktree>/bin:$PATH` no shell que lança (o agente chama `agentloop` pelo PATH);
  - `~/.claude/skills/security-analysis` apontado para a skill da worktree (`ln -sfn`), com o destino anterior anotado para repor.

- [ ] **Passo 2: correr**

`agentloop security analyze --detach accept accept <ramo> deep`, e acompanhar com `agentloop security units --analysis N` num script de polling em segundo plano, que acaba quando a análise sai de `running`.

- [ ] **Passo 3: medir e verificar**
  - estado final `done` (ou `capped` só pelo orçamento, com a frase do orçamento);
  - `deep.lines_read == deep.lines`;
  - todas as unidades `done`, as continuações contadas;
  - o custo e a duração; cada run de unidade na página Runs com o seu rótulo;
  - uma unidade escolhida à sorte: o seu stream mostra os `Read` dos seus intervalos.

- [ ] **Passo 4: repor**

`ln -sfn` de volta ao destino anotado; apagar a config e os dados de rascunho só depois de guardar as medições no relatório final.

---

