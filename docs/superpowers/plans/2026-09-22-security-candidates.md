# Bloco 4.1 — Candidatos — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectivo:** um achado `sast` do agente passa a carregar um documento `candidate` (trace, intended_control, confidence, likelihood, impact, conditions) validado à porta e guardado canónico; o `prepare` escolhe os guias de caça da Cloudflare pela stack do repositório; o fecho regista, a partir do stream do run, que guias foram lidos; relatórios e dashboard mostram tudo isto.

**Arquitectura:** um módulo novo `bin/security/candidate.py` valida/codifica/descodifica o documento (Python puro, sem `jsonschema`); `ledger.py` ganha duas colunas aditivas (`finding.candidate`, `analysis.guides`); `cli.py` decide à porta o que é obrigatório pela categoria, severidade e pela existência de uma linha de scanner nesta análise; `bin/security/guides.py` escolhe guias por sinais determinísticos; `bin/agentloop` lê o stream no fecho e passa `--guides-read` ao `finish`; `report.py`, `queries.py`, o servidor e `ui/security/` mostram e filtram. A spec é [docs/superpowers/specs/2026-09-22-security-candidates-design.md](../specs/2026-09-22-security-candidates-design.md).

**Tech stack:** Python 3.13 (stdlib: `json`, `sqlite3`, `fnmatch`), bash 3.2 + jq (engine), ES modules empacotados por esbuild 0.25 (`build/build-ui.sh`), pytest 9.

## Restrições globais

- **Trabalhar num worktree**, nunca no checkout `/Users/lfmoura/Projects/agentloop` em que o launchd corre o tick e o servidor (o `bin/agentloop` é lido a cada invocação). Branch: `feat/security-candidates` (já existe, com a spec). Todos os comandos abaixo assumem `cd <WT>` onde `<WT>` é o caminho do worktree.
- **Testes em primeiro plano**, `timeout` 600000, nunca em background. `pytest` só existe em `python3.13`: `python3.13 -m pytest … -p no:cacheprovider`. O `tests/security` precisa de `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true` e, para caber em 10 min, `--deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on`.
- **Ler ficheiros com `Read`, correr comandos exactos com `rtk proxy …`** — o hook rtk trunca `cat`/`grep` sem aviso.
- **`agentloop selftest` só no checkout real** (um worktree não tem `config/jobs.json`); no worktree, copiar `config/jobs.json` do checkout antes de o correr, ou aceitar exactamente essa falha.
- **Nunca correr o engine contra `data/` real.** Aceitação real só com `AGENTLOOP_CONFIG`/`AGENTLOOP_DATA`/`AGENTLOOP_SECURITY_DB` de rascunho.
- **`CHANGELOG.md` por commit**, entrada sob `## [Unreleased]` (`### Added` / `### Changed`), a dizer o que mudou e o que custava não ter.
- **`bash build/build-ui.sh` na mesma commit** de qualquer alteração sob `ui/`, seguido de `node --check bin/static/security.js`.
- Prosa de código, docstrings, commits, README e CHANGELOG **em inglês**; mensagens de commit terminam com `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Recusas à porta **nunca citam o valor** de um campo — só o caminho e a regra.

## Estrutura de ficheiros

| ficheiro | responsabilidade |
|---|---|
| `bin/security/candidate.py` (novo) | vocabulários, `validate`, `within_ceiling`, `texts`, `search_text`, `encode`, `decode`, `confidence_of` |
| `bin/security/guides.py` (novo) | `GUIDES`, `NAMES`, `ALWAYS`, `signals`, `select`, `recommend` |
| `bin/security/ledger.py` | colunas `finding.candidate` e `analysis.guides`; `record_finding` grava `candidate`; `findings_of` descodifica; `set_guides`/`guides_of` |
| `bin/security/cli.py` | a porta (`_candidate_requirements` + validação em `cmd_report_finding`); `guides` em `prepare`/`checklist`; `--guides-read` em `finish`; `--confidence` em `findings-page` |
| `bin/security/queries.py` | `confidence` em `SORTABLE`, filtro, ordenação com `''` no fim; `q` sobre `search_text`; `guides` descodificado em `checklist` |
| `bin/security/report.py` | o bloco candidate nos três formatos e no consolidado |
| `bin/agentloop` | `security_guides_read`, `security_close_analysis` passa `--guides-read`, `security_prompt` nomeia `references/` |
| `bin/agentloop-server` | `confidence` em `/api/security/findings`, `FINDINGS_SORT` |
| `skills/security-analysis/references/*` (novos) | os onze guias + `UPSTREAM.md` |
| `skills/security-analysis/SKILL.md` | secção "What qualifies as a finding", guias no Job 3, `candidate` no exemplo, regras dos Jobs 1 e 2 |
| `ui/security/candidate.js` (novo) | `secConfidenceChip`, `secCandidateBlock`, `SEC_CONFIDENCE` |
| `ui/security/analysis.js`, `ui/security/findings-screen.js`, `ui/css/pages.css` | montagem do bloco, coluna/filtro/ordenação, larguras |
| `test/selftest.sh` | blocos para `security_guides_read` e o prompt |
| `tests/security/test_candidate.py`, `test_guides.py` (novos), `test_ledger.py`, `test_cli.py`, `test_report.py`, `test_queries.py`, `tests/test_security_api.py`, `tests/test_page_contract.py` | os testes |
| `README.md`, `CHANGELOG.md` | documentação entregue |

**Correcções à spec, decididas ao planear (portar para a spec na Task 0):** (1) `queries.finding_rows` filtra em Python depois do `checklist()`, não em SQL — não há `json_extract`, logo não há dependência de JSON1 nem verificação no selftest; o filtro `confidence` é um `r.get("confidence")` sobre a chave que `ledger.findings_of` deriva. (2) Só um módulo desenha um achado por inteiro hoje (`analysis.js`, `secFindingRow`); o Findings mostra uma linha truncada. O bloco monta-se aí; o Findings ganha o chip/coluna. (3) Os sinais de IaC vêm de padrões de caminho em `guides.py`, não do resultado da fase IaC — mesmo efeito, sem acoplar ao Trivy.

---

### Task 0: worktree, spec corrigida

**Files:**
- Modify: `docs/superpowers/specs/2026-09-22-security-candidates-design.md`

- [ ] **Step 1: criar o worktree sobre a branch existente**

```bash
cd /Users/lfmoura/Projects/agentloop && git worktree add /Users/lfmoura/Projects/agentloop-wt-candidates feat/security-candidates
```

Expected: `Preparing worktree (checking out 'feat/security-candidates')`. Daqui em diante `<WT>` = `/Users/lfmoura/Projects/agentloop-wt-candidates`.

- [ ] **Step 2: portar as três correcções para a spec**

Na secção 4 da spec substituir a frase do `json_extract` por: "em `queries.py` é mais um ramo do filtro em Python que `finding_rows` já aplica depois do `checklist()` — a chave `confidence` é derivada por `ledger.findings_of`, e nenhum ecrã lê dentro do documento". Remover da tabela de ficheiros a verificação de `json_extract` no `selftest` e o risco 3 (substituí-lo por: "3. **Os sinais de IaC são padrões de caminho**, não o resultado da fase IaC — um Dockerfile num caminho ignorado não recomenda o guia, coerente com a regra do scope"). Na secção 4 trocar "hoje `findings-screen.js`, `analysis.js` e `index-screen.js` são os módulos que desenham `rationale`" por "hoje só `analysis.js` (`secFindingRow`) desenha um achado por inteiro; o Findings mostra o rationale truncado a uma linha e ganha o chip".

- [ ] **Step 3: commit**

```bash
cd <WT> && git add docs/superpowers/specs/2026-09-22-security-candidates-design.md && git commit -m "docs(security): block 4.1 spec — three corrections found while planning

Filtering is Python-side after checklist(), so there is no json_extract and no
SQLite JSON1 check to add; only analysis.js draws a finding in full today; the
IaC signals for the guides are path patterns, not the IaC phase's result.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 1: `candidate.py` — o documento, validado e canónico

**Files:**
- Create: `bin/security/candidate.py`
- Test: `tests/security/test_candidate.py`

**Interfaces:**
- Produces: `validate(doc, *, required=(), trace_allowed=True) -> dict` (levanta `CandidateError(path, message)`), `within_ceiling(severity, doc) -> bool`, `texts(doc) -> list[(path, text)]`, `search_text(doc) -> str`, `encode(doc) -> str`, `decode(stored) -> dict|None`, `confidence_of(doc) -> str`; constantes `TRACE_KINDS`, `CONFIDENCE_SCORES`, `SEVERITY_SCORES`, `CONDITION_KINDS`, `KEYS`, `MAX_STEPS`, `MAX_TEXT`, `MAX_BYTES`.

- [ ] **Step 1: escrever os testes**

```python
# tests/security/test_candidate.py
"""The `candidate` document: validated at the door, stored canonical, decoded
for every reader. `decode` never raises; every refusal names a path and never
a value."""
import json

import pytest

from security import candidate


def _doc(**over):
    doc = {
        "trace": [
            {"kind": "entrypoint", "file": "app/api.py", "line": 42,
             "scope": "handle_upload", "description": "filename read from the request"},
            {"kind": "sink", "file": "app/storage.py", "line": 19,
             "scope": "save", "description": "open() on the joined path"}],
        "intended_control": "uploads stay under the upload root",
        "confidence": {"score": "high", "reason": "the join is unconditional"},
        "likelihood": {"score": "high", "reason": "any tenant can upload"},
        "impact": {"score": "high", "reason": "arbitrary file write"},
        "conditions": [{"kind": "authentication_level", "description": "a tenant session"}],
    }
    doc.update(over)
    return doc


def test_a_full_document_validates_and_round_trips():
    doc = candidate.validate(_doc(), required=candidate.KEYS)
    assert candidate.decode(candidate.encode(doc)) == doc


def test_encoding_is_independent_of_key_order():
    a = candidate.encode(candidate.validate(_doc()))
    reordered = dict(reversed(list(_doc().items())))
    b = candidate.encode(candidate.validate(reordered))
    assert a == b
    assert "\n" not in a and ": " not in a


@pytest.mark.parametrize("over, path, rule", [
    ({"trace": []}, "trace", "at least one step"),
    ({"trace": "x"}, "trace", "at least one step"),
    ({"trace": [{"kind": "leak", "file": "a", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].kind", "must be one of"),
    ({"trace": [{"kind": "sink", "file": "/etc/passwd", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].file", "repository-relative"),
    ({"trace": [{"kind": "sink", "file": "a/../b", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].file", "repository-relative"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 0, "scope": "s", "description": "d"}]},
     "trace[0].line", "1 or more"),
    ({"trace": [{"kind": "sink", "file": "a", "line": True, "scope": "s", "description": "d"}]},
     "trace[0].line", "1 or more"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 1, "scope": "", "description": "d"}]},
     "trace[0].scope", "non-empty string"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 1, "scope": "s", "description": "d", "x": 1}]},
     "trace[0]", "does not know: x"),
    ({"confidence": {"score": "sure", "reason": "r"}}, "confidence.score", "must be one of"),
    ({"confidence": {"score": "high"}}, "confidence.reason", "non-empty string"),
    ({"impact": {"score": "critical", "reason": "r", "extra": 1}}, "impact", "does not know: extra"),
    ({"likelihood": "high"}, "likelihood", "must be an object"),
    ({"conditions": [{"kind": "moon_phase", "description": "d"}]}, "conditions[0].kind", "must be one of"),
    ({"conditions": {"kind": "data_state"}}, "conditions", "must be a list"),
    ({"intended_control": ""}, "intended_control", "non-empty string"),
    ({"payloads": ["x"]}, "", "does not know: payloads"),
])
def test_every_refusal_names_the_path_and_the_rule(over, path, rule):
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(**over))
    assert exc.value.path == path
    assert rule in exc.value.message


def test_a_repeated_step_is_refused():
    doc = _doc()
    doc["trace"].append(dict(doc["trace"][0]))
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(doc)
    assert exc.value.path == "trace[2]"
    assert "repeats" in exc.value.message


def test_more_than_fifty_steps_are_refused():
    steps = [{"kind": "propagation", "file": "a.py", "line": i + 1, "scope": "f",
              "description": "d"} for i in range(51)]
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(trace=steps))
    assert exc.value.path == "trace"
    assert "51" in exc.value.message


def test_a_text_over_the_cap_is_refused_by_path():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(intended_control="x" * (candidate.MAX_TEXT + 1)))
    assert exc.value.path == "intended_control"
    assert str(candidate.MAX_TEXT) in exc.value.message


def test_a_document_over_the_byte_cap_is_refused():
    steps = [{"kind": "propagation", "file": "a.py", "line": i + 1, "scope": "f",
              "description": "d" * candidate.MAX_TEXT} for i in range(7)]
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(trace=steps))
    assert exc.value.path == ""
    assert "bytes" in exc.value.message


def test_required_keys_are_held_to_and_named():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate({"confidence": {"score": "low", "reason": "r"}},
                           required=("trace", "intended_control", "confidence"))
    assert exc.value.path == ""
    assert "missing required key(s): trace, intended_control" in exc.value.message


def test_a_trace_is_refused_where_the_category_has_no_data_flow():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(), trace_allowed=False)
    assert exc.value.path == "trace"
    assert "not accepted" in exc.value.message


def test_a_refusal_never_quotes_the_value():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(confidence={"score": "AKIAQYLPMN5HNXMEFRTG", "reason": "r"}))
    assert "AKIA" not in str(exc.value)


def test_the_ceiling_rule():
    assert candidate.within_ceiling("high", {"impact": {"score": "high", "reason": "r"}})
    assert candidate.within_ceiling("low", {"impact": {"score": "critical", "reason": "r"}})
    assert not candidate.within_ceiling("critical", {"impact": {"score": "high", "reason": "r"}})
    assert candidate.within_ceiling("critical", {})
    assert candidate.within_ceiling("critical", None)


def test_texts_names_every_free_text_field_by_path():
    paths = [p for p, _ in candidate.texts(candidate.validate(_doc()))]
    assert paths == ["trace[0].scope", "trace[0].description", "trace[1].scope",
                     "trace[1].description", "intended_control", "confidence.reason",
                     "likelihood.reason", "impact.reason", "conditions[0].description"]
    assert "open() on the joined path" in candidate.search_text(_doc())
    assert candidate.search_text(None) == ""


def test_decode_never_raises_and_confidence_is_derived():
    assert candidate.decode("") is None
    assert candidate.decode(None) is None
    assert candidate.decode("{") is None
    assert candidate.decode("[1]") is None
    assert candidate.confidence_of(None) == ""
    assert candidate.confidence_of({"confidence": {"score": "low", "reason": "r"}}) == "low"
    assert candidate.confidence_of({"confidence": "low"}) == ""
```

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_candidate.py -q -p no:cacheprovider
```

Expected: `ModuleNotFoundError: No module named 'security.candidate'`.

- [ ] **Step 3: escrever o módulo**

```python
# bin/security/candidate.py
"""The `candidate` document a finding carries -- validated at the door,
stored canonical, decoded for every reader.

WHAT IT IS. A `sast` finding used to be a paragraph: `rationale` said why,
`occurrences` said where, and nothing between them was a claim a machine
could hold the writer to. `candidate` is the same claim in parts a reader --
and, in the next block, a verifier that did not write it -- can check:

    trace             entrypoint -> propagation -> sink, each step a file, a
                      line, a scope and a sentence
    intended_control  the control that should have held and did not
    confidence        how sure the writer is, and why
    likelihood        one half of the severity, with its reason
    impact            the other half, with its reason
    conditions        what has to be true for the hole to be reachable

NOT IDENTITY. Nothing here enters the fingerprint or the diff: a candidate
describes a finding the ledger already identifies by category, rule, path
and code. A re-report replaces it whole, the way it replaces the row.

ONE VALIDATOR, PLAIN PYTHON. Installing agentloop needs jq, python3 and
curl; a jsonschema dependency for one document is not worth a fourth. Every
refusal names the PATH of the field (`trace[2].description`) and a rule, and
never the value -- the door scans these texts for credentials after they
are validated, and a refusal that echoed a value would be the leak the scan
exists to prevent.

`decode` NEVER RAISES, for the reason `coverage.decode` never does: the
column is additive, '' is what every row written before it carries, and a
report is not the place to discover a corrupted document.
"""

import json

TRACE_KINDS = ("entrypoint", "propagation", "sink")
CONFIDENCE_SCORES = ("low", "medium", "high")
# Least severe FIRST, so `index()` orders the ceiling rule below. The same
# five words `report.SEVERITIES` spells worst first; a tuple of its own
# because ledger imports this module and report imports ledger through
# queries -- importing report here would cycle.
SEVERITY_SCORES = ("info", "low", "medium", "high", "critical")
CONDITION_KINDS = ("authentication_level", "authorization_role", "user_interaction",
                   "system_configuration", "network_routing", "environmental_dependency",
                   "data_state", "timing_dependency", "third_party_dependency")
KEYS = ("trace", "intended_control", "confidence", "likelihood", "impact", "conditions")
SCORED = ("confidence", "likelihood", "impact")
MAX_STEPS = 50
MAX_TEXT = 10000          # the same cap cli.MAX_TEXT puts on every other free text
MAX_BYTES = 64 * 1024     # the whole document, after canonical encoding


class CandidateError(ValueError):
    """A refusal: `path` names the field (dotted, indexed; '' for the document
    itself), `message` the rule. Neither ever carries a value."""

    def __init__(self, path, message):
        super().__init__(f"{path}: {message}" if path else message)
        self.path = path
        self.message = message


def _text(path, value):
    if not isinstance(value, str) or not value.strip():
        raise CandidateError(path, "must be a non-empty string")
    if len(value) > MAX_TEXT:
        raise CandidateError(path, f"is {len(value)} characters and the limit is {MAX_TEXT}")
    return value


def _unknown(path, obj, allowed):
    extra = sorted(set(obj) - set(allowed))
    if extra:
        raise CandidateError(path, "has keys this ledger does not know: " + ", ".join(extra))


def _scored(path, value, scores):
    if not isinstance(value, dict):
        raise CandidateError(path, "must be an object with `score` and `reason`")
    _unknown(path, value, ("score", "reason"))
    if value.get("score") not in scores:
        raise CandidateError(f"{path}.score", "must be one of " + ", ".join(scores))
    return {"score": value["score"], "reason": _text(f"{path}.reason", value.get("reason"))}


def _relative(path, value):
    file = _text(path, value)
    if file.startswith("/") or ".." in file.split("/"):
        raise CandidateError(path, "must be a repository-relative path: no leading `/`, no `..` segment")
    return file


def _trace(steps):
    if not isinstance(steps, list) or not steps:
        raise CandidateError("trace", "must be a list of at least one step")
    if len(steps) > MAX_STEPS:
        raise CandidateError("trace", f"has {len(steps)} steps and the limit is {MAX_STEPS}")
    out, seen = [], set()
    for i, step in enumerate(steps):
        p = f"trace[{i}]"
        if not isinstance(step, dict):
            raise CandidateError(p, "must be an object")
        _unknown(p, step, ("kind", "file", "line", "scope", "description"))
        if step.get("kind") not in TRACE_KINDS:
            raise CandidateError(f"{p}.kind", "must be one of " + ", ".join(TRACE_KINDS))
        line = step.get("line")
        # `bool` is an int in Python; `true` is not a line number.
        if isinstance(line, bool) or not isinstance(line, int) or line < 1:
            raise CandidateError(f"{p}.line", "must be an integer of 1 or more")
        row = {"kind": step["kind"], "file": _relative(f"{p}.file", step.get("file")),
               "line": line, "scope": _text(f"{p}.scope", step.get("scope")),
               "description": _text(f"{p}.description", step.get("description"))}
        key = tuple(row[k] for k in ("kind", "file", "line", "scope", "description"))
        if key in seen:
            raise CandidateError(p, "repeats an earlier step")
        seen.add(key)
        out.append(row)
    return out


def _conditions(items):
    if not isinstance(items, list):
        raise CandidateError("conditions", "must be a list")
    out = []
    for i, item in enumerate(items):
        p = f"conditions[{i}]"
        if not isinstance(item, dict):
            raise CandidateError(p, "must be an object")
        _unknown(p, item, ("kind", "description"))
        if item.get("kind") not in CONDITION_KINDS:
            raise CandidateError(f"{p}.kind", "must be one of " + ", ".join(CONDITION_KINDS))
        out.append({"kind": item["kind"],
                    "description": _text(f"{p}.description", item.get("description"))})
    return out


def validate(doc, *, required=(), trace_allowed=True) -> dict:
    """The document, normalised, or a CandidateError.

    `required` names the keys that must be present for THIS finding -- the
    door decides them from the category, the severity and whether the row is
    a triage (see cli._candidate_requirements); this function only holds the
    document to them. `trace_allowed` is False for the categories a trace
    makes no sense on (a secret has no data flow), and a trace sent there is
    REFUSED rather than dropped: a field the ledger would not read is a field
    a reader would take for a measurement.
    """
    if not isinstance(doc, dict):
        raise CandidateError("", "must be an object")
    _unknown("", doc, KEYS)
    missing = [k for k in required if k not in doc]
    if missing:
        raise CandidateError("", "is missing required key(s): " + ", ".join(missing))
    out = {}
    if "trace" in doc:
        if not trace_allowed:
            raise CandidateError("trace", "is not accepted on this category: a secret, a "
                                 "hygiene or an infrastructure finding has no data flow to trace")
        out["trace"] = _trace(doc["trace"])
    if "intended_control" in doc:
        out["intended_control"] = _text("intended_control", doc["intended_control"])
    if "confidence" in doc:
        out["confidence"] = _scored("confidence", doc["confidence"], CONFIDENCE_SCORES)
    for key in ("likelihood", "impact"):
        if key in doc:
            out[key] = _scored(key, doc[key], SEVERITY_SCORES)
    if "conditions" in doc:
        out["conditions"] = _conditions(doc["conditions"])
    size = len(encode(out).encode("utf-8"))
    if size > MAX_BYTES:
        raise CandidateError("", f"is {size} bytes and the limit is {MAX_BYTES}")
    return out


def within_ceiling(severity, doc) -> bool:
    """`severity` may not exceed `impact.score` -- the one coherence rule:
    the ceiling of a severity is its impact. True whenever there is no
    impact to hold it to."""
    impact = (doc or {}).get("impact")
    if not isinstance(impact, dict):
        return True
    if severity not in SEVERITY_SCORES or impact.get("score") not in SEVERITY_SCORES:
        return True
    return SEVERITY_SCORES.index(severity) <= SEVERITY_SCORES.index(impact["score"])


def texts(doc):
    """Every free-text field as (path, text): what the door's credential scan
    reads, and what `search_text` joins for the findings browser."""
    out = []
    for i, step in enumerate(doc.get("trace") or []):
        out.append((f"trace[{i}].scope", step["scope"]))
        out.append((f"trace[{i}].description", step["description"]))
    if doc.get("intended_control"):
        out.append(("intended_control", doc["intended_control"]))
    for key in SCORED:
        if isinstance(doc.get(key), dict):
            out.append((f"{key}.reason", doc[key].get("reason", "")))
    for i, cond in enumerate(doc.get("conditions") or []):
        out.append((f"conditions[{i}].description", cond["description"]))
    return out


def search_text(doc) -> str:
    """The document's prose in one string, for a free-text search."""
    if not isinstance(doc, dict):
        return ""
    return " ".join(t for _, t in texts(doc))


def encode(doc) -> str:
    """Canonical: sorted keys, no whitespace, unicode kept -- two reports of
    one finding are byte-identical whatever order the agent typed."""
    return json.dumps(doc, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def decode(stored):
    """The document, or None for '' and for anything unreadable. Never raises."""
    if not stored:
        return None
    try:
        doc = json.loads(stored)
    except (TypeError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def confidence_of(doc) -> str:
    """The confidence score or '' -- the one value the findings browser
    filters and sorts on, derived here so no screen reads inside the document."""
    conf = (doc or {}).get("confidence") if isinstance(doc, dict) else None
    return conf.get("score", "") if isinstance(conf, dict) else ""
```

- [ ] **Step 4: correr e ver passar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_candidate.py -q -p no:cacheprovider
```

Expected: `16 passed` (13 casos parametrizados contam individualmente — o número exacto é o que o pytest imprimir; nenhum `failed`).

- [ ] **Step 5: CHANGELOG + commit**

Em `CHANGELOG.md`, sob `## [Unreleased]`, `### Added` (criar a subsecção se não existir acima de `### Changed`):

```markdown
- **A `sast` finding can carry a `candidate` document** — trace (entrypoint →
  propagation → sink), the control that should have held, confidence,
  likelihood and impact each with a reason, and the conditions the hole
  depends on — validated by `bin/security/candidate.py` in plain Python and
  stored canonical. Until now a finding was a paragraph: nothing between
  "why" and "where" was a claim anybody could hold the agent to, and the
  verifier the next block adds would have had to parse prose.
```

```bash
cd <WT> && git add bin/security/candidate.py tests/security/test_candidate.py CHANGELOG.md && git commit -m "feat(security): the candidate document — validated at the door, stored canonical

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: ledger — as duas colunas, o documento gravado e descodificado, `guides`

**Files:**
- Modify: `bin/security/ledger.py` (`_ANALYSIS_COLUMNS`, `_FINDING_COLUMNS`, `record_finding`, `findings_of`, novas `set_guides`/`guides_of`)
- Test: `tests/security/test_ledger.py`

**Interfaces:**
- Consumes: `candidate.decode`, `candidate.confidence_of`.
- Produces: em cada dict de `findings_of` as chaves `candidate` (objecto ou `None`) e `confidence` (`''`/`low`/`medium`/`high`); `set_guides(conn, analysis_id, recommended=None, read=None)`, `guides_of(row) -> dict` (`{"recommended": [...], "read": [...]}`, `read` ausente quando nada o disse, `{}` para linhas antigas).

- [ ] **Step 1: testes**

Acrescentar no fim de `tests/security/test_ledger.py`:

```python
# ------------------------------------- the candidate document and the guides

def _sast(fp, **over):
    row = {"fingerprint": fp, "category": "sast", "rule": "path-traversal",
           "severity": "high", "title": "t", "rationale": "r", "producer": "agent",
           "occurrences": [{"file": "app.py", "line": 1}]}
    row.update(over)
    return row


def test_the_candidate_and_guides_columns_are_added_to_tables_that_predate_them(tmp_path):
    path = tmp_path / "old.db"
    raw = sqlite3.connect(str(path))
    raw.executescript(
        "CREATE TABLE analysis (id INTEGER PRIMARY KEY AUTOINCREMENT, project TEXT NOT NULL,"
        " repo TEXT NOT NULL, branch TEXT NOT NULL, commit_sha TEXT NOT NULL,"
        " profile TEXT NOT NULL, started INTEGER NOT NULL, ended INTEGER,"
        " state TEXT NOT NULL, spend_usd REAL NOT NULL DEFAULT 0);"
        "INSERT INTO analysis (project, repo, branch, commit_sha, profile, started, state)"
        " VALUES ('p', 'r', 'main', 'abc', 'quick', 1, 'done');"
        "CREATE TABLE finding (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " analysis_id INTEGER NOT NULL, fingerprint TEXT NOT NULL,"
        " category TEXT NOT NULL, rule TEXT NOT NULL, severity TEXT NOT NULL,"
        " title TEXT NOT NULL, UNIQUE(analysis_id, fingerprint));"
        "INSERT INTO finding (analysis_id, fingerprint, category, rule, severity, title)"
        " VALUES (1, 'old', 'sast', 'xss', 'high', 't');")
    raw.commit()
    raw.close()

    c = ledger.connect(path)
    assert "candidate" in {r["name"] for r in c.execute("PRAGMA table_info(finding)")}
    assert "guides" in {r["name"] for r in c.execute("PRAGMA table_info(analysis)")}
    old = ledger.findings_of(c, 1)[0]
    assert old["candidate"] is None
    assert old["confidence"] == ""
    assert ledger.guides_of(c.execute("SELECT * FROM analysis WHERE id=1").fetchone()) == {}


def test_a_candidate_is_stored_canonical_and_read_back_decoded(tmp_path):
    c = ledger.connect(tmp_path / "s.db")
    aid = ledger.start_analysis(c, "p", "r", "main", "abc", "quick", "run")
    doc = {"confidence": {"score": "medium", "reason": "r"},
           "trace": [{"kind": "sink", "file": "app.py", "line": 3, "scope": "f", "description": "d"}]}
    ledger.record_finding(c, aid, _sast("a" * 64, candidate=candidate_mod.encode(doc)))
    row = ledger.findings_of(c, aid)[0]
    assert row["candidate"] == doc
    assert row["confidence"] == "medium"
    stored = c.execute("SELECT candidate FROM finding WHERE fingerprint=?", ("a" * 64,)).fetchone()
    assert stored["candidate"] == candidate_mod.encode(doc)


def test_a_re_report_replaces_the_document_and_an_absent_one_clears_it(tmp_path):
    c = ledger.connect(tmp_path / "s.db")
    aid = ledger.start_analysis(c, "p", "r", "main", "abc", "quick", "run")
    first = candidate_mod.encode({"confidence": {"score": "low", "reason": "a"}})
    second = candidate_mod.encode({"confidence": {"score": "high", "reason": "b"}})
    ledger.record_finding(c, aid, _sast("a" * 64, candidate=first))
    ledger.record_finding(c, aid, _sast("a" * 64, candidate=second))
    assert ledger.findings_of(c, aid)[0]["confidence"] == "high"
    ledger.record_finding(c, aid, _sast("a" * 64))
    assert ledger.findings_of(c, aid)[0]["candidate"] is None


def test_set_guides_merges_the_two_halves(tmp_path):
    c = ledger.connect(tmp_path / "s.db")
    aid = ledger.start_analysis(c, "p", "r", "main", "abc", "quick", "run")
    row = lambda: c.execute("SELECT * FROM analysis WHERE id=?", (aid,)).fetchone()
    assert ledger.guides_of(row()) == {}
    ledger.set_guides(c, aid, recommended=["ATTACK-CLASSES", "AI-AND-LLM"])
    assert ledger.guides_of(row()) == {"recommended": ["ATTACK-CLASSES", "AI-AND-LLM"]}
    ledger.set_guides(c, aid, read=["AI-AND-LLM"])
    assert ledger.guides_of(row()) == {"recommended": ["ATTACK-CLASSES", "AI-AND-LLM"],
                                       "read": ["AI-AND-LLM"]}
    ledger.set_guides(c, aid, read=[])
    assert ledger.guides_of(row())["read"] == []
```

No topo do ficheiro, junto aos imports existentes de `security`, acrescentar `from security import candidate as candidate_mod` (ver como `ledger`/`fp_mod` já são importados e seguir o mesmo estilo).

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_ledger.py -q -p no:cacheprovider -k "candidate or guides"
```

Expected: 4 falhas (`no such column`, `AttributeError: set_guides`…).

- [ ] **Step 3: implementar**

Em `bin/security/ledger.py`:

1. Import: `from . import candidate` ao lado de `from .diff import AGENT`.
2. `_ANALYSIS_COLUMNS`, último elemento:

```python
    # The hunting guides `prepare` recommended and, once the engine has read
    # the run's stream, the ones the agent opened -- `{"recommended": [...],
    # "read": [...]}`, see `set_guides`/`guides_of`. '' for every analysis
    # from before the column; nothing derives a state from it.
    ("guides", "TEXT NOT NULL DEFAULT ''"),
```

3. `_FINDING_COLUMNS`, último elemento:

```python
    # The `candidate` document (security/candidate.py), canonical JSON or ''.
    # Additive as the columns above are: never a fingerprint input, never read
    # by `diff`, and '' -- what every row from before the column carries --
    # decodes to None, which every renderer draws as nothing.
    ("candidate", "TEXT NOT NULL DEFAULT ''"),
```

4. `record_finding`, o `UPDATE`:

```python
            conn.execute(
                "UPDATE finding SET category=?, rule=?, severity=?, title=?,"
                " rationale=?, remediation=?, partial_note=?, cwe=?, owasp=?,"
                " candidate=?, triaged=MAX(triaged, ?)"
                " WHERE id=?",
                (finding["category"], finding["rule"], finding["severity"], finding["title"],
                 finding.get("rationale", ""), finding.get("remediation", ""),
                 finding.get("partial_note", ""), finding.get("cwe", ""),
                 finding.get("owasp", ""), finding.get("candidate", ""), triaged, fid))
```

e o `INSERT`:

```python
            cur = conn.execute(
                "INSERT INTO finding (analysis_id, fingerprint, category, rule, severity,"
                " title, rationale, remediation, partial_note, cwe, owasp, producer,"
                " scope, candidate)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (analysis_id, finding["fingerprint"], finding["category"], finding["rule"],
                 finding["severity"], finding["title"], finding.get("rationale", ""),
                 finding.get("remediation", ""), finding.get("partial_note", ""),
                 finding.get("cwe", ""), finding.get("owasp", ""),
                 finding.get("producer", ""), finding.get("scope", ""),
                 finding.get("candidate", "")))
```

Acrescentar ao docstring de `record_finding`, antes do bloco `with conn:`, um parágrafo: `candidate` é a terceira coluna que a re-report escreve por inteiro — "A re-report REPLACES the document as it replaces the row: a payload with no `candidate` (where the door allows one) writes '' — the agent said nothing under it, and a stored document that outlived the claim it described would be the stale-row failure `occurrences` already avoids."

5. `findings_of`:

```python
def findings_of(conn, analysis_id) -> list:
    rows = conn.execute(
        "SELECT * FROM finding WHERE analysis_id=? ORDER BY id", (analysis_id,)).fetchall()
    out = []
    for r in rows:
        occ = conn.execute(
            "SELECT file, line, snippet_hash FROM occurrence WHERE finding_id=? ORDER BY id",
            (r["id"],)).fetchall()
        d = dict(r)
        d["occurrences"] = [dict(o) for o in occ]
        # DECODED HERE, ONCE, for every reader -- the checklist, the reports,
        # the findings browser and the verifier all get an object or None,
        # never the column's text; `confidence` is the one value screens
        # filter and sort on, derived so none of them reads inside.
        d["candidate"] = candidate.decode(d.get("candidate"))
        d["confidence"] = candidate.confidence_of(d["candidate"])
        out.append(d)
    return out
```

6. Depois de `finish_analysis`:

```python
def set_guides(conn, analysis_id, recommended=None, read=None) -> None:
    """Merge into the `guides` document. A half not passed keeps what is
    stored: `prepare` writes `recommended` before the agent starts and the
    engine's close writes `read` after it ends, and neither knows the other's
    half."""
    row = conn.execute("SELECT guides FROM analysis WHERE id=?", (analysis_id,)).fetchone()
    doc = guides_of(row) if row is not None else {}
    if recommended is not None:
        doc["recommended"] = [str(g) for g in recommended]
    if read is not None:
        doc["read"] = [str(g) for g in read]
    with conn:
        conn.execute("UPDATE analysis SET guides=? WHERE id=?",
                     (json.dumps(doc, sort_keys=True), analysis_id))


def guides_of(row) -> dict:
    """`{"recommended": [...], "read": [...]}` -- `read` absent while nothing
    has said what was read, `{}` for a row from before the column or a
    document this module cannot read. Never raises, for the reason
    `coverage.decode` never does."""
    try:
        stored = row["guides"]
    except (KeyError, IndexError, TypeError):
        return {}
    if not stored:
        return {}
    try:
        doc = json.loads(stored)
    except (TypeError, ValueError):
        return {}
    if not isinstance(doc, dict):
        return {}
    return {k: [str(g) for g in doc[k]] for k in ("recommended", "read")
            if isinstance(doc.get(k), list)}
```

- [ ] **Step 4: correr e ver passar; correr o ficheiro inteiro**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_ledger.py -q -p no:cacheprovider
```

Expected: tudo verde (nenhum `failed`).

- [ ] **Step 5: CHANGELOG + commit**

`### Added`:

```markdown
- **`finding.candidate` and `analysis.guides` columns**, additive, '' on every
  row from before them; `findings_of` hands every reader the candidate as an
  object (or `None`) and a derived `confidence`, so no screen or report ever
  parses the column itself.
```

```bash
cd <WT> && git add bin/security/ledger.py tests/security/test_ledger.py CHANGELOG.md && git commit -m "feat(security): the ledger stores the candidate document and the guides of an analysis

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: a porta — `report-finding` decide o que é obrigatório e valida

**Files:**
- Modify: `bin/security/cli.py` (`cmd_report_finding`, nova `_candidate_requirements`, import)
- Test: `tests/security/test_cli.py`

**Interfaces:**
- Consumes: `candidate.validate/within_ceiling/texts/encode`, `TRIAGE_BLOCKING` (as severidades ≥ medium), `diff.AGENT`.
- Produces: o payload que chega a `record_finding` traz `candidate` como string canónica ou `''`.

- [ ] **Step 1: o helper de teste e a matriz**

No topo de `tests/security/test_cli.py`, depois de `AS_AGENT`:

```python
# A complete, valid candidate -- what every `sast` finding at medium or above
# has to carry through the door since block 4.1. Tests about OTHER rules of
# the door attach it so they keep testing the rule they name.
SAST_CANDIDATE = {
    "trace": [
        {"kind": "entrypoint", "file": "app/api.py", "line": 42, "scope": "handle",
         "description": "the filename comes from the request"},
        {"kind": "sink", "file": "app/db.py", "line": 12, "scope": "query",
         "description": "the string reaches execute()"}],
    "intended_control": "queries are parameterised",
    "confidence": {"score": "high", "reason": "the concatenation is unconditional"},
    "likelihood": {"score": "high", "reason": "the endpoint is unauthenticated"},
    "impact": {"score": "critical", "reason": "full read of the database"},
}
```

Depois de `test_the_agent_cannot_send_something_that_is_not_json`, os testes da porta:

```python
# ------------------------------------------------ the candidate at the door

def _scanner_row(db, aid, fp, category, rule, severity="high"):
    """A row a SCANNER minted in this analysis -- what makes an agent's
    re-report of it a triage. Written through the ledger, as `prepare` does,
    because no scanner mints on demand."""
    conn = security_ledger.connect(db)
    security_ledger.record_finding(conn, aid, {
        "fingerprint": fp, "category": category, "rule": rule, "severity": severity,
        "title": "scanner's title", "rationale": "scanner's sentence",
        "remediation": "scanner's fix", "producer": "semgrep" if category == "sast" else "trivy",
        "occurrences": [{"file": "app/db.py", "line": 12}]})
    conn.close()


def _payload(fp, category="sast", rule="sql-injection", severity="high", **over):
    p = {"fingerprint": fp, "category": category, "rule": rule, "severity": severity,
         "title": "t", "rationale": "my own reading", "remediation": "m",
         "occurrences": [{"file": "app/db.py", "line": 12, "snippet_hash": "h"}]}
    p.update(over)
    return p


def _without(*keys):
    return {k: v for k, v in SAST_CANDIDATE.items() if k not in keys}


@pytest.mark.parametrize("severity, candidate, refused", [
    ("high", SAST_CANDIDATE, ""),
    ("medium", _without("likelihood", "impact"), ""),
    ("low", {"confidence": SAST_CANDIDATE["confidence"]}, ""),
    ("info", {"confidence": SAST_CANDIDATE["confidence"]}, ""),
    ("high", None, "candidate is required"),
    ("high", _without("trace"), "missing required key(s): trace"),
    ("high", _without("intended_control"), "intended_control"),
    ("high", _without("confidence"), "confidence"),
    ("high", _without("likelihood", "impact"), "likelihood, impact"),
    ("critical", _without("likelihood", "impact"), "likelihood, impact"),
    ("medium", _without("trace", "likelihood", "impact"), "trace"),
    ("low", None, "candidate is required"),
    ("low", {}, "confidence"),
])
def test_what_a_sast_finding_has_to_carry_depends_on_its_severity(tmp_path, severity, candidate, refused):
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    payload = _payload("b" * 64, severity=severity)
    if candidate is not None:
        payload["candidate"] = candidate
    out = fails(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(payload))
    if refused:
        assert out.returncode != 0, out.stderr
        assert refused in out.stderr
        assert "Nothing was recorded" in out.stderr
        assert _finding_row(db, aid) is None
    else:
        assert out.returncode == 0, out.stderr


def test_a_triage_of_a_scanner_row_needs_a_confidence_and_a_secret_takes_no_trace(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    fp = secret_fingerprint("aws-access-token", "prod.env")
    _scanner_row(db, aid, fp, "secret", "aws-access-token")
    base = _payload(fp, category="secret", rule="aws-access-token",
                    occurrences=[{"file": "prod.env", "line": 3}])
    out = fails(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(base))
    assert out.returncode != 0 and "confidence" in out.stderr
    out = fails(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(
        dict(base, candidate={"confidence": SAST_CANDIDATE["confidence"],
                              "trace": SAST_CANDIDATE["trace"]})))
    assert out.returncode != 0 and "candidate.trace" in out.stderr and "not accepted" in out.stderr
    run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(
        dict(base, candidate={"confidence": SAST_CANDIDATE["confidence"]})))


def test_a_dependency_triage_may_carry_a_trace_for_reachability(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    _scanner_row(db, aid, "d" * 64, "dependency", "CVE-2024-1")
    run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(_payload(
        "d" * 64, category="dependency", rule="CVE-2024-1",
        candidate={"confidence": SAST_CANDIDATE["confidence"], "trace": SAST_CANDIDATE["trace"]})))
    assert _finding_row(db, aid)["candidate"] != ""


def test_a_verbatim_echo_of_a_pending_deterministic_row_needs_no_candidate(tmp_path):
    """Job 1: the row is NOT in this analysis (nobody re-found it), so the
    door sees no scanner row and asks for nothing -- echoing it with a
    confidence would claim a verification that did not happen."""
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(_payload(
        "c" * 64, category="dependency", rule="CVE-2024-1")))
    run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(_payload(
        "e" * 64, category="hygiene", rule="committed_env_file")))


def test_severity_above_the_candidates_impact_is_refused(tmp_path):
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    doc = dict(SAST_CANDIDATE, impact={"score": "medium", "reason": "one row of one table"})
    out = fails(db, "report-finding", "--analysis", str(aid),
                stdin=json.dumps(_payload("b" * 64, severity="high", candidate=doc)))
    assert out.returncode != 0
    assert "above the candidate's impact" in out.stderr
    assert _finding_row(db, aid) is None


def test_a_candidate_that_is_not_an_object_or_has_unknown_keys_is_refused(tmp_path):
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    out = fails(db, "report-finding", "--analysis", str(aid),
                stdin=json.dumps(_payload("b" * 64, candidate="high")))
    assert out.returncode != 0 and "candidate must be an object" in out.stderr
    out = fails(db, "report-finding", "--analysis", str(aid),
                stdin=json.dumps(_payload("b" * 64, candidate=dict(SAST_CANDIDATE, payloads=["x"]))))
    assert out.returncode != 0 and "does not know: payloads" in out.stderr


def test_a_credential_inside_the_candidate_is_refused_by_path_and_never_echoed(tmp_path):
    """The adversarial test, extended to the document: the same shaped
    patterns `rationale` goes through, applied to every free-text field of
    the candidate; the refusal names the FIELD by its path and the rule, and
    the key's text appears nowhere -- not on stdout, not on stderr, not in
    the ledger."""
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    doc = json.loads(json.dumps(SAST_CANDIDATE))
    doc["trace"][1]["description"] = f"execute() is reached with {AWS} in the query"
    out = fails(db, "report-finding", "--analysis", str(aid),
                stdin=json.dumps(_payload("b" * 64, candidate=doc)))
    assert out.returncode != 0
    assert "candidate.trace[1].description" in out.stderr
    assert "aws_access_key" in out.stderr
    assert AWS not in out.stdout and AWS not in out.stderr
    assert _finding_row(db, aid) is None
    conn = sqlite3.connect(str(db))
    assert AWS not in "".join(str(r) for r in conn.execute("SELECT * FROM finding"))


def test_the_stored_candidate_is_canonical_and_comes_back_decoded(tmp_path):
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    run(db, "report-finding", "--analysis", str(aid),
        stdin=json.dumps(_payload("b" * 64, candidate=SAST_CANDIDATE)))
    row = _finding_row(db, aid)
    assert row["candidate"] == security_candidate.encode(security_candidate.validate(SAST_CANDIDATE))
    found = run(db, "findings", "--analysis", str(aid))[0]
    assert found["candidate"]["confidence"]["score"] == "high"
    assert found["confidence"] == "high"
    listed = run(db, "checklist", "--analysis", str(aid))["findings"][0]
    assert listed["candidate"]["intended_control"] == "queries are parameterised"
```

Junto aos imports: `from security import candidate as security_candidate`. Confirmar que `_finding_row(db, aid)` existe no ficheiro (é usado nos testes existentes) e devolve `None` sem linha — se devolver outra coisa, ajustar as asserções `is None` ao que ele devolve.

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_cli.py -q -p no:cacheprovider -k "candidate or carry or triage_of_a_scanner or reachability or verbatim_echo or ceiling or impact"
```

Expected: as recusas não acontecem ainda (`returncode == 0` onde se esperava recusa).

- [ ] **Step 3: a porta**

Em `bin/security/cli.py`:

1. Import: acrescentar `candidate` à linha `from security import adapters, coverage, ...` (ordem alfabética: depois de `adapters`).

2. Antes de `cmd_report_finding`:

```python
def _candidate_requirements(conn, analysis_id, payload):
    """(required keys, trace_allowed) for THIS finding -- decided from data
    the ledger already has, never from a flag the agent sends.

    A row of this fingerprint already in this analysis and minted by a
    SCANNER means the re-report is a triage (Job 2): somebody is judging a
    scanner's finding, and a judgement carries a confidence. No such row means
    a new finding (Job 3) or the verbatim echo of a row nobody re-found (Job
    1), which carries nothing -- a confidence there would be the verification
    Job 1 says did not happen. `sast` is held by severity alone, whoever
    minted it: at medium or above the writer asserts a real weakness and has
    to show the chain and the control; at high and critical, both halves of
    the severity as well. A trace is allowed on `sast` and on `dependency`
    (the CVE's reachability) and refused on the three categories that have
    no data flow.
    """
    category, severity = payload["category"], payload["severity"]
    existing = conn.execute(
        "SELECT producer FROM finding WHERE analysis_id=? AND fingerprint=?",
        (analysis_id, payload["fingerprint"])).fetchone()
    triage = existing is not None and (existing["producer"] or "") not in ("", diff.AGENT)
    if category == "sast":
        if severity in TRIAGE_BLOCKING:
            required = ["trace", "intended_control", "confidence"]
            if severity in ("high", "critical"):
                required += ["likelihood", "impact"]
        else:
            required = ["confidence"]
        return required, True
    return (["confidence"] if triage else []), category == "dependency"
```

3. Em `cmd_report_finding`, substituir o bloco que começa em `payload["producer"] = diff.AGENT` até ao fim da função por:

```python
    conn = _conn(args)
    _running(conn, args.analysis)
    # THE CANDIDATE, after every text field above has been through the same
    # gates -- so a rationale that quotes a key is still refused as
    # `rationale`, never as a missing candidate -- and before the producer is
    # stamped, because the requirements read the row the ledger already holds.
    required, trace_allowed = _candidate_requirements(conn, args.analysis, payload)
    doc = payload.pop("candidate", None)
    if doc is None:
        if required:
            sys.exit("report-finding: candidate is required here — a "
                     f"{payload['category']} finding at {payload['severity']} "
                     f"has to carry: {', '.join(required)}. A medium+ weakness "
                     "without a trace is one you have not read; go read it rather "
                     "than lowering the severity. Nothing was recorded")
        payload["candidate"] = ""
    else:
        if not isinstance(doc, dict):
            sys.exit("report-finding: candidate must be an object. Nothing was recorded")
        try:
            doc = candidate.validate(doc, required=required, trace_allowed=trace_allowed)
        except candidate.CandidateError as exc:
            where = f"candidate.{exc.path}" if exc.path else "candidate"
            sys.exit(f"report-finding: {where} {exc.message}. Nothing was recorded")
        if not candidate.within_ceiling(payload["severity"], doc):
            sys.exit(f"report-finding: severity {payload['severity']} is above the "
                     "candidate's impact — the ceiling of a severity is its impact; "
                     "lower the severity or raise the impact with a reason. Nothing "
                     "was recorded")
        # The same scanner every other free-text field went through, over
        # every free-text field of the document, by path. See
        # `_refuse_if_secret` for why the message names the field and never
        # the text.
        for path, text in candidate.texts(doc):
            _refuse_if_secret(f"report-finding: candidate.{path}", text)
        payload["candidate"] = candidate.encode(doc)
    # NEVER read from the payload -- `producer` is not an agent-writable
    # field, it is this door's own record of who arrived through it. An agent
    # able to send its own would be able to claim a deterministic producer for
    # a finding it invented, and `diff._proven` reads that column to decide
    # what absence proves. On a RE-REPORT this is discarded anyway
    # (`record_finding` leaves the column alone for a fingerprint the analysis
    # already holds), so it only ever lands on a finding the agent genuinely
    # minted -- which is exactly what `diff.AGENT` is proven by: the analysis
    # closing `done`.
    payload["producer"] = diff.AGENT
    try:
        ledger.record_finding(conn, args.analysis, payload)
    # OverflowError is here for the same reason ValueError is: it comes out of
    # `int(occ["line"])` on a number too large to be one (`1e999` parses as
    # JSON infinity), and it is not a ValueError -- the agent got a traceback
    # and no sentence saying what was wrong with its finding.
    except (ValueError, TypeError, OverflowError, sqlite3.Error) as exc:
        # record_finding wraps the finding and its occurrences in one
        # transaction, so a rejected line number rolls the whole thing back --
        # the agent has to be told, or it moves on believing it reported.
        sys.exit(f"report-finding: could not record it: {exc}")
```

(As duas linhas `conn = _conn(args)` / `_running(conn, args.analysis)` que estavam depois de `payload["producer"]` desaparecem — passam a estar antes.)

- [ ] **Step 4: correr os novos testes; depois o ficheiro inteiro, e emendar os testes antigos**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_cli.py -q -p no:cacheprovider -k "candidate or carry or triage_of_a_scanner or reachability or verbatim_echo or ceiling or impact"
```

Expected: verde. Depois:

```bash
cd <WT> && TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests/security/test_cli.py tests/security/test_export_findings.py tests/security/test_fixed_elsewhere.py tests/security/test_fixed_elsewhere_rows.py -q -p no:cacheprovider 2>&1 | tail -40
```

Expected: várias falhas com `candidate is required`. Para **cada** teste que falha assim, abrir o payload e acrescentar `"candidate": SAST_CANDIDATE` (ou `candidate=SAST_CANDIDATE` no helper local). Regras: **não** baixar severidades para fugir à porta; nos ficheiros fora de `test_cli.py`, copiar a constante `SAST_CANDIDATE` para o topo do ficheiro (não importar de outro teste). Um teste que assere um `stderr` de outra regra (rationale/title/remediation com credencial) não precisa do candidate — essas recusas vêm antes. Repetir até:

Expected: `0 failed`.

- [ ] **Step 5: CHANGELOG + commit**

`### Changed`:

```markdown
- **`report-finding` holds a `sast` finding to its severity.** At medium or
  above it has to carry a trace, the control that should have held and a
  confidence; at high and critical, likelihood and impact with reasons too;
  the severity may never exceed the impact; a re-report onto a scanner's row
  carries a confidence; a trace is refused on a secret, a hygiene or an
  infrastructure finding; every free-text field of the document goes through
  the same credential scan as `rationale`, and a refusal names the field by
  path and never the text. A finding that fails any of this is refused whole
  — nothing recorded — which is what stops a paragraph from standing in for a
  chain of code nobody read.
```

```bash
cd <WT> && git add bin/security/cli.py tests/security/ CHANGELOG.md && git commit -m "feat(security): report-finding decides what a candidate must carry and validates it

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: relatórios — o bloco nos três formatos e no consolidado

**Files:**
- Modify: `bin/security/report.py`
- Test: `tests/security/test_report.py`

**Interfaces:**
- Consumes: `f["candidate"]` (objecto ou `None`) como `findings_of` o entrega.
- Produces: `_candidate_md(f) -> list[str]`, `_candidate_html(f) -> str`; `as_json` garante a chave `candidate` (objecto ou `null`); `_consolidated_finding_json` leva `candidate`.

- [ ] **Step 1: testes**

Acrescentar a `tests/security/test_report.py`:

```python
CANDIDATE = {
    "trace": [
        {"kind": "entrypoint", "file": "app/api.py", "line": 42, "scope": "handle_upload",
         "description": "filename read | from the request <b>"},
        {"kind": "sink", "file": "app/storage.py", "line": 19, "scope": "save",
         "description": "open() on the joined path"}],
    "intended_control": "uploads stay under the upload root",
    "confidence": {"score": "high", "reason": "the join is unconditional"},
    "likelihood": {"score": "high", "reason": "any tenant can upload"},
    "impact": {"score": "high", "reason": "arbitrary file write"},
    "conditions": [{"kind": "authentication_level", "description": "a tenant session"}],
}

WITH_CANDIDATE = [dict(FINDINGS[1], candidate=CANDIDATE, confidence="high", state="new")]
WITHOUT = [dict(FINDINGS[1], candidate=None, confidence="", state="new")]


def test_the_candidate_block_is_rendered_in_every_format_and_only_when_present():
    md = report.as_markdown(ANALYSIS, WITH_CANDIDATE, "")
    assert "**Trace:**" in md
    assert "entrypoint · `app/api.py:42` · handle_upload — filename read \\| from the request <b>" in md
    assert "**Intended control:** uploads stay under the upload root" in md
    assert "authentication_level: a tenant session" in md
    assert "**Confidence:** high — the join is unconditional" in md
    assert "**Likelihood:** high — any tenant can upload" in md
    assert "**Impact:** high — arbitrary file write" in md
    html_out = report.as_html(ANALYSIS, WITH_CANDIDATE, "")
    assert "<b>" not in html_out and "&lt;b&gt;" in html_out
    assert 'class="cand"' in html_out
    doc = json.loads(report.as_json(ANALYSIS, WITH_CANDIDATE, ""))
    assert doc["findings"][0]["candidate"]["confidence"]["score"] == "high"
    for text in (report.as_markdown(ANALYSIS, WITHOUT, ""), report.as_html(ANALYSIS, WITHOUT, "")):
        assert "Trace" not in text and "Confidence" not in text
    assert json.loads(report.as_json(ANALYSIS, WITHOUT, ""))["findings"][0]["candidate"] is None


def test_a_report_without_candidates_is_byte_identical_to_before():
    """The golden: a finding that carries no document -- every row from
    before the column, every deterministic row -- renders exactly as it did.
    `FINDINGS` has no `candidate` key at all (a caller assembling findings
    some other way) and must render the same as one carrying None."""
    plain = [dict(f) for f in FINDINGS]
    with_none = [dict(f, candidate=None) for f in FINDINGS]
    assert report.as_markdown(ANALYSIS, plain, "") == report.as_markdown(ANALYSIS, with_none, "")
    assert report.as_html(ANALYSIS, plain, "") == report.as_html(ANALYSIS, with_none, "")
    assert "Trace" not in report.as_markdown(ANALYSIS, plain, "")


def test_the_consolidated_report_carries_the_block_too():
    groups = [{"branch": "main", "analysis": dict(ANALYSIS),
               "open": [dict(WITH_CANDIDATE[0], first_seen=1)], "resolved": []}]
    md = report.consolidated_as_markdown("web", groups, {"at": 1})
    assert "**Trace:**" in md and "**Confidence:** high" in md
    html_out = report.consolidated_as_html("web", groups, {"at": 1})
    assert 'class="cand"' in html_out and "&lt;b&gt;" in html_out
    doc = json.loads(report.consolidated_as_json("web", groups, {"at": 1}))
    assert doc["branches"][0]["open"][0]["candidate"]["impact"]["score"] == "high"
```

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_report.py -q -p no:cacheprovider -k "candidate or byte_identical or consolidated_report_carries"
```

Expected: `AssertionError` (o bloco não existe).

- [ ] **Step 3: implementar**

Em `bin/security/report.py`, depois de `_scope_label`:

```python
# The candidate document (security/candidate.py) under a finding: the chain,
# the control, the conditions, and the three scored fields. Drawn ONLY when
# the finding carries one -- every deterministic row and every row from
# before the column carries None, and for those the report is byte-identical
# to what it was, the same contract `_phase_rows` keeps for `coverage`. All
# of it is the agent's text: escaped for HTML, `|` escaped in Markdown.
_SCORED_LABELS = (("confidence", "Confidence"), ("likelihood", "Likelihood"), ("impact", "Impact"))


def _md_cell(text: str) -> str:
    return str(text).replace("|", "\\|")


def _candidate_md(f) -> list:
    c = f.get("candidate")
    if not isinstance(c, dict):
        return []
    out = []
    if c.get("trace"):
        out.append("**Trace:**")
        out += [f"- {s['kind']} · `{s['file']}:{s['line']}` · {_md_cell(s['scope'])}"
                f" — {_md_cell(s['description'])}" for s in c["trace"]]
    if c.get("intended_control"):
        out.append(f"**Intended control:** {_md_cell(c['intended_control'])}")
    if c.get("conditions"):
        out.append("**Conditions:**")
        out += [f"- {x['kind']}: {_md_cell(x['description'])}" for x in c["conditions"]]
    scored = [f"**{label}:** {c[key]['score']} — {_md_cell(c[key]['reason'])}"
              for key, label in _SCORED_LABELS if isinstance(c.get(key), dict)]
    if scored:
        out.append(" · ".join(scored))
    return out


def _candidate_html(f) -> str:
    c = f.get("candidate")
    if not isinstance(c, dict):
        return ""
    e = html.escape
    parts = ['<div class="cand">']
    if c.get("trace"):
        parts.append("<p><strong>Trace:</strong></p><ol>")
        parts += [f"<li>{e(s['kind'])} · <code>{e(s['file'])}:{int(s['line'])}</code> · "
                  f"{e(s['scope'])} — {e(s['description'])}</li>" for s in c["trace"]]
        parts.append("</ol>")
    if c.get("intended_control"):
        parts.append(f"<p><strong>Intended control:</strong> {e(c['intended_control'])}</p>")
    if c.get("conditions"):
        parts.append("<p><strong>Conditions:</strong></p><ul>")
        parts += [f"<li>{e(x['kind'])}: {e(x['description'])}</li>" for x in c["conditions"]]
        parts.append("</ul>")
    scored = [f"<strong>{label}:</strong> {e(c[key]['score'])} — {e(c[key]['reason'])}"
              for key, label in _SCORED_LABELS if isinstance(c.get(key), dict)]
    if scored:
        parts.append("<p>" + " · ".join(scored) + "</p>")
    parts.append("</div>")
    return "".join(parts)
```

Montagem:

- `as_json`: junto a `row.setdefault("scope", "")` acrescentar `row.setdefault("candidate", None)`.
- `as_markdown`, no loop dos achados, substituir `out += ["", f["rationale"], "", f"**Remediation:** {f['remediation']}", ""]` por:

```python
        out += ["", f["rationale"], ""]
        block = _candidate_md(f)
        if block:
            out += block + [""]
        out += [f"**Remediation:** {f['remediation']}", ""]
```

- `as_html`, no loop: substituir `f"<ul>{locs}</ul><p>{e(f['rationale'])}</p>"` por `f"<ul>{locs}</ul><p>{e(f['rationale'])}</p>{_candidate_html(f)}"`.
- `_consolidated_finding_md`: depois de `if f.get("rationale"): out += ["", f["rationale"]]` acrescentar:

```python
    block = _candidate_md(f)
    if block:
        out += [""] + block
```

- `_consolidated_finding_json`: acrescentar `"candidate": f.get("candidate"),` antes de `"first_seen"`.
- `consolidated_as_html`: depois de `+ (f"<p>{e(f['rationale'])}</p>" if f.get("rationale") else "")` acrescentar `+ _candidate_html(f)`.
- `_CSS`: acrescentar `.cand{margin:.5rem 0;padding:.5rem .75rem;border-left:3px solid #d4d4d8;background:#fafafa}.cand ol,.cand ul{margin:.25rem 0 .5rem 1.25rem}`.

- [ ] **Step 4: correr e ver passar; ficheiro inteiro + consolidado**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_report.py tests/security/test_consolidated_report.py tests/security/test_export_findings.py -q -p no:cacheprovider
```

Expected: verde.

- [ ] **Step 5: CHANGELOG + commit**

`### Added`:

```markdown
- **Reports render the candidate** — trace, intended control, conditions and
  the three scored fields — under a finding that carries one, in Markdown,
  HTML and the consolidated document, and as an object in JSON; a finding
  without one renders byte for byte as before.
```

```bash
cd <WT> && git add bin/security/report.py tests/security/test_report.py CHANGELOG.md && git commit -m "feat(security): the reports render the candidate block

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `confidence` no findings-page, no servidor e na pesquisa

**Files:**
- Modify: `bin/security/queries.py` (`SORTABLE`, `finding_rows`, `checklist`), `bin/security/cli.py` (`findings-page`), `bin/agentloop-server` (`FINDINGS_SORT`, `security_findings`)
- Test: `tests/security/test_queries.py`, `tests/security/test_cli.py`, `tests/test_security_api.py`

**Interfaces:**
- Produces: `filters["confidence"]` (lista), `sort="confidence"`; `/api/security/findings?confidence=high,medium&sort=confidence`; `checklist()` devolve `analysis["guides"]` descodificado.

- [ ] **Step 1: testes de queries**

Ver como `tests/security/test_queries.py` constrói uma base com achados (há um helper que abre análises e grava com `ledger.record_finding` e fecha `done`; usar o mesmo). Acrescentar:

```python
def test_findings_can_be_filtered_sorted_and_searched_by_confidence(tmp_path):
    db = tmp_path / "s.db"
    conn = ledger.connect(db)
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "quick", "r1")
    ledger.mark_prepared(conn, aid, ["hygiene"])
    for fp, conf, text in (("a" * 64, "high", "the join is unconditional"),
                           ("b" * 64, "low", "maybe guarded upstream"),
                           ("c" * 64, "", "")):
        doc = {"confidence": {"score": conf, "reason": text}} if conf else None
        ledger.record_finding(conn, aid, {
            "fingerprint": fp, "category": "sast", "rule": "xss", "severity": "medium",
            "title": "t", "rationale": "r", "producer": "agent",
            "occurrences": [{"file": "a.py", "line": 1}],
            "candidate": candidate.encode(doc) if doc else ""})
    ledger.finish_analysis(conn, aid, "done")
    ro = queries.read_only(db)

    rows = queries.finding_rows(ro, "web", {"confidence": ["high"]})["rows"]
    assert [r["fingerprint"][0] for r in rows] == ["a"]
    rows = queries.finding_rows(ro, "web", {"confidence": ["high", "low"]})["rows"]
    assert {r["fingerprint"][0] for r in rows} == {"a", "b"}

    rows = queries.finding_rows(ro, "web", {}, sort="confidence", direction="desc")["rows"]
    assert [r["fingerprint"][0] for r in rows] == ["a", "b", "c"]
    rows = queries.finding_rows(ro, "web", {}, sort="confidence", direction="asc")["rows"]
    assert [r["fingerprint"][0] for r in rows] == ["b", "a", "c"]

    rows = queries.finding_rows(ro, "web", {"q": "guarded upstream"})["rows"]
    assert [r["fingerprint"][0] for r in rows] == ["b"]


def test_checklist_hands_the_guides_over_decoded(tmp_path):
    db = tmp_path / "s.db"
    conn = ledger.connect(db)
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "quick", "r1")
    ledger.set_guides(conn, aid, recommended=["ATTACK-CLASSES"])
    analysis, _ = queries.checklist(conn, aid)
    assert analysis["guides"] == {"recommended": ["ATTACK-CLASSES"]}
```

(`from security import candidate` no topo, ao lado de `ledger`/`queries`.)

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_queries.py -q -p no:cacheprovider -k "confidence or guides_over"
```

Expected: `ValueError: sort must be one of` / filtro ignorado.

- [ ] **Step 3: implementar**

`bin/security/queries.py`:

1. `SORTABLE = ("severity", "title", "category", "branch", "first_seen", "state", "confidence")`, e por baixo `_CONF_RANK = {"high": 0, "medium": 1, "low": 2}`.
2. Em `checklist`, logo depois de `analysis = dict(row)`: `analysis["guides"] = ledger.guides_of(row)`.
3. Em `finding_rows`, o loop `for key in ("severity", "state", "category", "branch"):` passa a `for key in ("severity", "state", "category", "branch", "confidence"):`.
4. O filtro `q`: acrescentar `candidate.search_text(r.get("candidate"))` à lista dentro do `" ".join([...])` (import `from . import candidate, diff, ledger`).
5. A ordenação, substituir o `if sort == "severity": ... else: ...` + `rows.sort(...)` por:

```python
    if sort == "severity":
        keyf = lambda r: _SEV_RANK.get(r["severity"], 9)
        # Rank 0 is "critical", the most severe -- ascending rank order
        # already puts critical first, which is what `desc` (most severe
        # first) means for this column. So `desc` maps to reverse=False
        # here, the opposite of every other sortable column below.
        reverse = direction != "desc"
    elif sort == "confidence":
        # The same rank-order trick as severity: `desc` is "most confident
        # first". A row with no document has no rank at all -- it is not
        # "less confident than low", it is unmeasured -- so those rows are
        # PARTITIONED to the end below, whichever direction was asked for.
        keyf = lambda r: _CONF_RANK.get(r.get("confidence", ""), 9)
        reverse = direction != "desc"
    else:
        keyf = lambda r: r.get(sort, "")
        reverse = direction == "desc"
    rows.sort(key=keyf, reverse=reverse)
    if sort == "confidence":
        rows = [r for r in rows if r.get("confidence")] + [r for r in rows if not r.get("confidence")]
```

(Manter o comentário original do ramo `else` sobre `.get(sort, "")`.)

`bin/security/cli.py`, no parser de `findings-page`, depois de `--category`:

```python
    fpg.add_argument("--confidence", action="append", default=None,
                     choices=candidate.CONFIDENCE_SCORES)
```

e em `cmd_findings_page` o dict `filters` ganha `"confidence": args.confidence or [],`. No docstring, a lista de chaves ganha `confidence`.

`bin/agentloop-server`:

- `FINDINGS_SORT = ("severity", "title", "category", "branch", "first_seen", "state", "confidence")`.
- Depois de `FINDING_CATEGORIES = (...)`: `FINDING_CONFIDENCE = ("low", "medium", "high")` com o mesmo comentário de duplicação deliberada que as vizinhas têm.
- Em `security_findings`, depois do bloco de `category`:

```python
    confidence, err = _checked_list(params, "confidence", FINDING_CONFIDENCE)
    if err:
        return 400, err
```

e na construção de `args`, depois do loop de `category`: `for s in confidence: args += ["--confidence", s]`.

- [ ] **Step 4: teste da rota**

Em `tests/test_security_api.py`, ver como uma rota de findings é chamada com parâmetros (há testes que capturam o argv passado a `al(...)`); acrescentar um que passa `confidence=high,low&sort=confidence` e assere que o argv contém `--confidence high --confidence low` e `--sort confidence`, e outro que `confidence=maybe` responde 400. Correr:

```bash
cd <WT> && python3.13 -m pytest tests/security/test_queries.py tests/test_security_api.py -q -p no:cacheprovider
```

Expected: verde.

- [ ] **Step 5: CHANGELOG + commit**

`### Added`:

```markdown
- **The findings browser filters, sorts and searches by confidence** —
  `findings-page --confidence`, `/api/security/findings?confidence=`,
  `sort=confidence` with unmeasured rows last whichever way you sort, and the
  free-text search reads the candidate's prose too.
```

```bash
cd <WT> && git add bin/security/queries.py bin/security/cli.py bin/agentloop-server tests/security/test_queries.py tests/test_security_api.py CHANGELOG.md && git commit -m "feat(security): confidence as a filter, a sort and a search term on the findings browser

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: os guias — vendorizar, escolher no `prepare`, imprimir no `checklist`

**Files:**
- Create: `skills/security-analysis/references/{ATTACK-CLASSES,AI-AND-LLM,CLIENT-SIDE,CLOUD-AND-DEPLOYMENT,DATA-ISOLATION-AND-LIFECYCLE,DESKTOP-MOBILE-AND-LOCAL-IPC,MEMORY-SAFETY-AND-BINARY,PROTOCOLS-RPC-AND-MESSAGING,RESOURCE-EXHAUSTION-AND-AVAILABILITY,SUPPLY-CHAIN-AND-RELEASE,WEB-PROTOCOL-AND-AUTH}.md`, `skills/security-analysis/references/UPSTREAM.md`, `bin/security/guides.py`
- Modify: `bin/security/cli.py` (`cmd_prepare`)
- Test: `tests/security/test_guides.py`, `tests/security/test_cli.py`

**Interfaces:**
- Produces: `guides.NAMES` (os onze, pela ordem da tabela), `guides.ALWAYS = "ATTACK-CLASSES"`, `guides.signals(root, ignore, components) -> dict`, `guides.select(sig, profile) -> list[str]`, `guides.recommend(root, ignore, components, profile) -> (list[str], note)`; `prepare` imprime `"guides": {"recommended": [...]}` e grava via `ledger.set_guides`; `checklist` já devolve `analysis["guides"]` (Task 5).

- [ ] **Step 1: vendorizar ao SHA**

```bash
cd <WT> && SHA=$(curl -s https://api.github.com/repos/cloudflare/security-audit-skill/commits/main | jq -r .sha) && echo "$SHA" && mkdir -p skills/security-analysis/references && for n in ATTACK-CLASSES AI-AND-LLM CLIENT-SIDE CLOUD-AND-DEPLOYMENT DATA-ISOLATION-AND-LIFECYCLE DESKTOP-MOBILE-AND-LOCAL-IPC MEMORY-SAFETY-AND-BINARY PROTOCOLS-RPC-AND-MESSAGING RESOURCE-EXHAUSTION-AND-AVAILABILITY SUPPLY-CHAIN-AND-RELEASE WEB-PROTOCOL-AND-AUTH; do curl -sfL "https://raw.githubusercontent.com/cloudflare/security-audit-skill/$SHA/skills/security-audit/$n.md" -o "skills/security-analysis/references/$n.md" || echo "FAILED $n"; done && curl -sfL "https://raw.githubusercontent.com/cloudflare/security-audit-skill/$SHA/LICENSE" -o /tmp/cf-license.txt && wc -c skills/security-analysis/references/*.md
```

Expected: onze ficheiros, tamanhos entre 7 KB e 16 KB, nenhum `FAILED`. Confirmar com `Read` que `WEB-PROTOCOL-AND-AUTH.md` começa por `# HTTP-Protocol and Authentication Hunting`.

Escrever `skills/security-analysis/references/UPSTREAM.md`:

```markdown
# Upstream

These eleven guides are vendored byte for byte from
https://github.com/cloudflare/security-audit-skill
(`skills/security-audit/*.md`), at commit `<SHA>` on 2026-09-22.

They are hunting material, not process: the audit skill's own SKILL.md,
HUNTING.md, RECONNAISSANCE.md and VALIDATION-AND-REPORTING.md describe a
workflow (hunters, verifiers, findings.json) that competes with
`skills/security-analysis/SKILL.md` and are deliberately NOT vendored.

## Rule

Never edit a guide in place. To update: fetch every file again at one new
commit, replace the set whole, and change the SHA and date above in the same
commit. `tests/security/test_guides.py` refuses a table that names a guide
this directory does not hold, and a SHA that is not 40 hex characters.

## Licence

MIT — copyright (c) Cloudflare, Inc. Full text below, as required.

<the contents of /tmp/cf-license.txt, verbatim>
```

- [ ] **Step 2: testes de `guides.py`**

```python
# tests/security/test_guides.py
"""Which hunting guides `prepare` recommends: a table of signals, a rank, a
profile ceiling -- and never a failure of the deterministic phase."""
import re
from pathlib import Path

import pytest

from security import guides

REPO = Path(__file__).resolve().parent.parent.parent
REFERENCES = REPO / "skills" / "security-analysis" / "references"


def _tree(tmp_path, *files):
    root = tmp_path / "repo"
    for rel in files:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x\n")
    return root


def _components(*names):
    return [{"ecosystem": "npm", "name": n, "version": "1.0.0", "source": "package-lock.json",
             "scope": "runtime"} for n in names]


def test_every_guide_the_table_names_is_vendored_and_upstream_is_pinned():
    for name in guides.NAMES:
        assert (REFERENCES / f"{name}.md").is_file(), name
    upstream = (REFERENCES / "UPSTREAM.md").read_text()
    assert re.search(r"at commit `[0-9a-f]{40}`", upstream)
    assert "MIT" in upstream
    vendored = {p.stem for p in REFERENCES.glob("*.md")} - {"UPSTREAM"}
    assert vendored == set(guides.NAMES)


def test_attack_classes_is_always_recommended_even_on_an_empty_tree(tmp_path):
    root = _tree(tmp_path)
    for profile in ("quick", "standard"):
        assert guides.select(guides.signals(root, [], []), profile) == [guides.ALWAYS]
    assert guides.select(guides.signals(root, [], []), "deep") == list(guides.NAMES)


def test_signals_are_read_off_dependencies_and_paths(tmp_path):
    root = _tree(tmp_path, "src/App.jsx", "CLAUDE.md", ".github/workflows/ci.yml",
                 "Dockerfile", "db/migrate/001.rb")
    sig = guides.signals(root, [], _components("express", "@anthropic-ai/sdk", "pg"))
    chosen = guides.select(sig, "standard")
    assert chosen[0] == guides.ALWAYS
    assert set(chosen) == {"ATTACK-CLASSES", "WEB-PROTOCOL-AND-AUTH", "CLIENT-SIDE",
                           "CLOUD-AND-DEPLOYMENT", "SUPPLY-CHAIN-AND-RELEASE", "AI-AND-LLM",
                           "DATA-ISOLATION-AND-LIFECYCLE", "RESOURCE-EXHAUSTION-AND-AVAILABILITY"}


def test_quick_reads_attack_classes_and_the_single_best_match(tmp_path):
    root = _tree(tmp_path, "CLAUDE.md", "AGENTS.md", ".claude/settings.json", "skills/x/SKILL.md")
    sig = guides.signals(root, [], _components("express"))
    assert guides.select(sig, "quick") == ["ATTACK-CLASSES", "AI-AND-LLM"]


def test_ties_break_by_table_order_and_prefix_names_match(tmp_path):
    root = _tree(tmp_path)
    sig = guides.signals(root, [], _components("langchain-core", "@grpc/grpc-js"))
    assert guides.select(sig, "quick") == ["ATTACK-CLASSES", "AI-AND-LLM"]
    assert "PROTOCOLS-RPC-AND-MESSAGING" in guides.select(sig, "standard")
    assert "RESOURCE-EXHAUSTION-AND-AVAILABILITY" in guides.select(sig, "standard")


def test_ignored_paths_give_no_signal(tmp_path):
    root = _tree(tmp_path, ".github/workflows/ci.yml")
    assert "SUPPLY-CHAIN-AND-RELEASE" in guides.select(guides.signals(root, [], []), "standard")
    assert "SUPPLY-CHAIN-AND-RELEASE" not in guides.select(
        guides.signals(root, [".github/**"], []), "standard")


def test_supply_chain_follows_a_non_empty_inventory(tmp_path):
    root = _tree(tmp_path)
    assert "SUPPLY-CHAIN-AND-RELEASE" in guides.select(
        guides.signals(root, [], _components("left-pad")), "standard")


def test_recommend_never_raises(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("disk on fire")
    monkeypatch.setattr(guides, "signals", boom)
    chosen, note = guides.recommend(tmp_path, [], [], "standard")
    assert chosen == [guides.ALWAYS]
    assert "did not run" in note and "disk on fire" in note
    chosen, note = guides.recommend(_tree(tmp_path, "a.rs"), [], [], "standard")
    assert note == "" and "MEMORY-SAFETY-AND-BINARY" in chosen
```

- [ ] **Step 3: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_guides.py -q -p no:cacheprovider
```

Expected: `ModuleNotFoundError: security.guides`.

- [ ] **Step 4: `guides.py`**

```python
# bin/security/guides.py
"""Which of the vendored hunting guides an analysis should read.

Eleven guides (skills/security-analysis/references/, vendored from
cloudflare/security-audit-skill -- see UPSTREAM.md there) add up to ~130 KB,
about 35k tokens: read whole on every run they would eat a `quick` profile's
budget before the agent opened a file of the repository. So `prepare`
chooses, from signals it has in hand already -- the dependency inventory's
names and the paths of the tree, under the same `ignore_paths` every other
phase obeys -- and the profile puts a ceiling on how many.

DETERMINISTIC AND RECORDED. The agent could pick its own guides after a
look at the tree; then the cost per run would be the model's mood and nothing
would say what it read. Here the list is data, it is stored on the analysis
(`ledger.set_guides`) and the close records what was actually opened off the
run's stream (see `security_guides_read` in bin/agentloop).

NEVER A FAILURE OF `prepare`. Guides are advice. `recommend` catches
everything, answers ATTACK-CLASSES alone and a note the coverage paragraph
carries; the deterministic phases do not fall over for want of a reading
list.
"""

from fnmatch import fnmatchcase
from pathlib import Path

from . import ignores, secrets

ALWAYS = "ATTACK-CLASSES"

# name -> signals. `deps` are lowercase package names, a trailing `*` a prefix;
# `paths` are fnmatch patterns over the repository-relative path, and `*`
# crosses `/` in fnmatch, so `.claude/*` reaches `.claude/agents/x.md` and
# `*migrations/*` reaches `app/migrations/0001.py`. `follows` names guides
# whose match implies this one. `inventory` matches any non-empty inventory.
GUIDES = (
    (ALWAYS, {"always": True}),
    ("WEB-PROTOCOL-AND-AUTH", {"deps": (
        "express", "koa", "fastify", "hapi", "@hapi/hapi", "@nestjs/core", "next", "nuxt",
        "flask", "django", "fastapi", "starlette", "tornado", "rails", "sinatra",
        "laravel/framework", "symfony/symfony", "slim/slim", "spring-boot",
        "github.com/gin-gonic/gin", "github.com/labstack/echo*", "github.com/go-chi/chi*",
        "github.com/gofiber/fiber*", "actix-web", "axum", "rocket")}),
    ("CLIENT-SIDE", {"paths": ("*.html", "*.jsx", "*.tsx", "*.vue", "*.svelte"),
                     "deps": ("react", "vue", "svelte", "@angular/core", "jquery")}),
    ("CLOUD-AND-DEPLOYMENT", {"paths": (
        "Dockerfile*", "*/Dockerfile*", "*.Dockerfile", "docker-compose*.yml",
        "docker-compose*.yaml", "*.tf", "Chart.yaml", "*/Chart.yaml", "k8s/*",
        "kubernetes/*", "manifests/*", "*cloudformation*", ".github/workflows/*",
        "serverless.yml", "wrangler.toml", "fly.toml", "Procfile")}),
    ("SUPPLY-CHAIN-AND-RELEASE", {"inventory": True, "paths": (
        ".github/workflows/*", ".gitlab-ci.yml", "bitbucket-pipelines.yml", "Jenkinsfile",
        ".circleci/*")}),
    ("AI-AND-LLM", {"deps": (
        "openai", "anthropic", "@anthropic-ai/sdk", "langchain*", "@langchain/*",
        "llamaindex", "llama-index*", "mcp", "@modelcontextprotocol/*", "ai", "transformers"),
        "paths": ("CLAUDE.md", "AGENTS.md", ".claude/*", "SKILL.md", "*/SKILL.md",
                  ".mcp.json", "mcp.json", ".cursorrules")}),
    ("MEMORY-SAFETY-AND-BINARY", {"paths": (
        "*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "*.rs", "*.zig", "Cargo.lock")}),
    ("PROTOCOLS-RPC-AND-MESSAGING", {"paths": ("*.proto",), "deps": (
        "grpc*", "@grpc/*", "grpcio", "amqplib", "pika", "kafkajs", "kafka-python",
        "confluent-kafka", "paho-mqtt", "mqtt", "ws", "socket.io", "websockets", "nats")}),
    ("DATA-ISOLATION-AND-LIFECYCLE", {"deps": (
        "sqlalchemy", "prisma", "@prisma/client", "sequelize", "typeorm", "knex", "drizzle-orm",
        "gorm.io/gorm", "diesel", "mongoose", "pg", "mysql2", "psycopg2*", "psycopg", "asyncpg",
        "pymongo"), "paths": ("*migrations/*", "*db/migrate/*", "*alembic/*")}),
    ("DESKTOP-MOBILE-AND-LOCAL-IPC", {"deps": ("electron", "@tauri-apps/api", "react-native", "expo"),
                                      "paths": ("*.swift", "*.kt", "*.m", "android/*", "ios/*",
                                                "*.xcodeproj/*")}),
    ("RESOURCE-EXHAUSTION-AND-AVAILABILITY", {"follows": ("WEB-PROTOCOL-AND-AUTH",
                                                          "PROTOCOLS-RPC-AND-MESSAGING")}),
)
NAMES = tuple(name for name, _ in GUIDES)
PROFILES = ("quick", "standard", "deep")


def signals(root, ignore, components) -> dict:
    """What the tree and the inventory say: lowercase dependency names, and
    every repository-relative path the other phases would read -- the same
    `secrets.skipped` and `ignores.ignored` predicates, so an ignored
    `.github/**` gives no signal, exactly as it gives no finding."""
    root = Path(root)
    deps = {str(c.get("name", "")).lower() for c in (components or []) if c.get("name")}
    paths = []
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.is_symlink():
            continue
        rel = str(p.relative_to(root))
        if secrets.skipped(rel) or ignores.ignored(rel, ignore):
            continue
        paths.append(rel)
    return {"deps": deps, "paths": paths, "inventory": bool(deps)}


def _dep_hit(pattern, deps) -> bool:
    if pattern.endswith("*"):
        prefix = pattern[:-1]
        return any(d.startswith(prefix) for d in deps)
    return pattern in deps


def _hits(spec, sig, matched) -> int:
    n = 0
    n += sum(1 for pat in spec.get("deps", ()) if _dep_hit(pat, sig["deps"]))
    n += sum(1 for pat in spec.get("paths", ())
             if any(fnmatchcase(rel, pat) for rel in sig["paths"]))
    if spec.get("inventory") and sig.get("inventory"):
        n += 1
    n += sum(1 for other in spec.get("follows", ()) if other in matched)
    return n


def select(sig, profile) -> list:
    """ATTACK-CLASSES first, then the matched guides by number of signals
    (ties by table order), cut by the profile: `quick` keeps one, `standard`
    all that matched, `deep` reads all eleven whether they matched or not."""
    if profile == "deep":
        return list(NAMES)
    matched = {}
    for name, spec in GUIDES:
        if spec.get("always"):
            continue
        n = _hits(spec, sig, matched)
        if n:
            matched[name] = n
    order = {name: i for i, name in enumerate(NAMES)}
    ranked = sorted(matched, key=lambda name: (-matched[name], order[name]))
    if profile == "quick":
        ranked = ranked[:1]
    return [ALWAYS] + ranked


SELECTION_FAILED_NOTE = ("The hunting-guide selection did not run ({reason}); only "
                         "ATTACK-CLASSES was recommended to the agent.")


def recommend(root, ignore, components, profile):
    """(guides, note). Never raises -- see the module docstring."""
    try:
        return select(signals(root, ignore, components), profile), ""
    except Exception as exc:  # noqa: BLE001 -- advice must not fail the phase
        reason = f"{type(exc).__name__}: {exc}"
        return [ALWAYS], SELECTION_FAILED_NOTE.format(reason=reason)
```

- [ ] **Step 5: correr e ver passar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_guides.py -q -p no:cacheprovider
```

Expected: verde.

- [ ] **Step 6: `prepare` recomenda, grava e imprime**

Teste em `tests/security/test_cli.py`:

```python
def test_prepare_recommends_guides_by_the_profile_and_checklist_prints_them(tmp_path):
    root = tmp_path / "repo"
    (root / ".github" / "workflows").mkdir(parents=True)
    (root / ".github" / "workflows" / "ci.yml").write_text("on: push\n")
    (root / "CLAUDE.md").write_text("# rules\n")
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick")
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    assert out["guides"] == {"recommended": ["ATTACK-CLASSES", "AI-AND-LLM"]}
    listed = run(db, "checklist", "--analysis", str(aid))
    assert listed["analysis"]["guides"] == {"recommended": ["ATTACK-CLASSES", "AI-AND-LLM"]}
    aid = open_analysis(db, profile="deep", commit="b", run_id="r2")
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    assert len(out["guides"]["recommended"]) == 11


def test_a_failing_guide_selection_does_not_fail_prepare(tmp_path, monkeypatch):
    """Advice never costs the deterministic phase. Exercised in-process, the
    way the ledger-write-failure tests near the bottom of this file are,
    because a subprocess cannot be monkeypatched."""
    root = tmp_path / "repo"
    root.mkdir()
    db = tmp_path / "security.db"
    aid = open_analysis(db)
    from security import guides as security_guides
    monkeypatch.setattr(security_guides, "signals", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no")))
    monkeypatch.setattr(sys, "argv", ["cli", "prepare", "--analysis", str(aid), "--root",
                                      str(root), "--offline", "--db", str(db)])
    security_cli.main()
    listed = run(db, "checklist", "--analysis", str(aid))
    assert listed["analysis"]["guides"] == {"recommended": ["ATTACK-CLASSES"]}
    assert "hunting-guide selection did not run" in listed["analysis"]["coverage_note"]
```

(Confirmar como os testes in-process existentes no fim de `test_cli.py` chamam `security_cli.main()` — se passam `argv` como argumento em vez de `sys.argv`, seguir esse padrão. `security_cli.main()` pode terminar com `SystemExit(0)`? `prepare` faz `print` e retorna — se levantar `SystemExit`, envolver em `pytest.raises(SystemExit)` e asserir `code in (0, None)`.)

Em `cmd_prepare`, imports: acrescentar `guides` à linha `from security import ...`. Depois de `unknown_switch = ...` e do seu `if`, acrescentar:

```python
    # THE HUNTING GUIDES, chosen here and not by the agent -- see
    # security/guides.py. Filed under `scope` when the selection failed, since
    # that is the row about what this analysis was set up to read.
    recommended, guides_note = guides.recommend(root, ignore, components, row["profile"])
    if guides_note:
        notes.append(guides_note)
        scope_notes.append(guides_note)
        print(f"prepare: {guides_note}", file=sys.stderr)
```

Antes de `ledger.mark_prepared(conn, aid, produced)`: `ledger.set_guides(conn, aid, recommended=recommended)`. E o `print` final:

```python
    print(json.dumps({"coverage_note": note, "findings": len(findings),
                      "guides": {"recommended": recommended}}))
```

Correr:

```bash
cd <WT> && TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests/security/test_cli.py -q -p no:cacheprovider -k "guides or prose_is_a_substring"
```

Expected: verde — incluindo `test_every_phases_prose_is_a_substring_of_the_paragraph`, porque a frase entrou em `notes` e em `scope_notes` na mesma ordem.

- [ ] **Step 7: CHANGELOG + commit**

`### Added`:

```markdown
- **Cloudflare's hunting guides, vendored and chosen per repository.**
  `skills/security-analysis/references/` carries ATTACK-CLASSES and the ten
  domain guides of cloudflare/security-audit-skill (MIT, pinned to a commit in
  UPSTREAM.md); `prepare` recommends the ones the stack calls for — from the
  dependency inventory and the tree's paths, under the same ignore globs —
  capped by the profile (quick: one; standard: what matched; deep: all), and
  prints and stores the list. Read whole, the eleven cost ~35k tokens per
  run, which is a `quick` profile's whole budget.
```

```bash
cd <WT> && git add skills/security-analysis/references bin/security/guides.py bin/security/cli.py tests/security/test_guides.py tests/security/test_cli.py CHANGELOG.md && git commit -m "feat(security): vendor the hunting guides and let prepare choose them by the stack

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `finish --guides-read` e a frase de cobertura

**Files:**
- Modify: `bin/security/cli.py` (`cmd_finish`, parser)
- Test: `tests/security/test_cli.py`

**Interfaces:**
- Produces: `finish --guides-read <a,b|''|unknown>`; a frase `Guides read: …` na nota da linha `sast` e no `coverage_note`; `analysis.guides.read`.

- [ ] **Step 1: testes**

```python
def _sast_note(db, aid):
    analysis = run(db, "checklist", "--analysis", str(aid))["analysis"]
    phases = json.loads(analysis["coverage"])["phases"]
    return next(p["note"] for p in phases if p["name"] == "sast"), analysis


@pytest.mark.parametrize("flag, sentence, read", [
    ("AI-AND-LLM,ATTACK-CLASSES", "Guides read: ATTACK-CLASSES, AI-AND-LLM. Recommended but not read: CLIENT-SIDE.", ["ATTACK-CLASSES", "AI-AND-LLM"]),
    ("", "Guides read: none of the 3 recommended.", []),
    ("unknown", "Guides read: unknown (run stream unavailable).", None),
])
def test_the_engines_close_records_what_was_read_off_the_stream(tmp_path, flag, sentence, read):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    conn = security_ledger.connect(db)
    security_ledger.set_guides(conn, aid, recommended=["ATTACK-CLASSES", "AI-AND-LLM", "CLIENT-SIDE"])
    conn.close()
    run(db, "finish", "--analysis", str(aid), "--state", "done")
    note, analysis = _sast_note(db, aid)
    assert "Guides read" not in note, "the agent's own close knows nothing about the stream"
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--guides-read", flag)
    note, analysis = _sast_note(db, aid)
    assert sentence in note
    assert sentence in analysis["coverage_note"]
    assert analysis["guides"].get("read") == read
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--guides-read", flag)
    assert _sast_note(db, aid)[1]["coverage_note"].count("Guides read") == 1


def test_guides_read_that_were_never_recommended_are_still_listed(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--guides-read", "WEB-PROTOCOL-AND-AUTH,bogus")
    note, analysis = _sast_note(db, aid)
    assert "Guides read: WEB-PROTOCOL-AND-AUTH." in note
    assert "bogus" not in note
```

(A recomendação de `prepared_analysis` sobre uma árvore vazia é `["ATTACK-CLASSES"]`, logo o segundo teste vê "Recommended but not read: ATTACK-CLASSES." — ajustar a asserção para `"Guides read: WEB-PROTOCOL-AND-AUTH. Recommended but not read: ATTACK-CLASSES."`.)

- [ ] **Step 2: correr e ver falhar**

```bash
cd <WT> && python3.13 -m pytest tests/security/test_cli.py -q -p no:cacheprovider -k "guides_read or off_the_stream"
```

Expected: `unrecognized arguments: --guides-read`.

- [ ] **Step 3: implementar**

Parser de `finish`: `fn.add_argument("--guides-read", default=None, dest="guides_read")`.

Antes de `cmd_finish`:

```python
GUIDES_UNKNOWN = "unknown"


def _guides_sentence(recommended, read) -> str:
    """One of three forms; `read` is None when the stream could not be read."""
    if read is None:
        return "Guides read: unknown (run stream unavailable)."
    if not read:
        return (f"Guides read: none of the {len(recommended)} recommended."
                if recommended else "Guides read: none.")
    ordered = [g for g in guides.NAMES if g in read]
    missed = [g for g in recommended if g not in read]
    out = "Guides read: " + ", ".join(ordered) + "."
    if missed:
        out += " Recommended but not read: " + ", ".join(missed) + "."
    return out
```

Em `cmd_finish`, depois de `row = _analysis(conn, args.analysis)` e do `--if-running`:

```python
    # WHAT THE AGENT READ, from the ENGINE's close only -- the flag is absent
    # on the agent's own close, which knows nothing about its stream, so no
    # sentence is written then; the engine's close writes the one true
    # sentence and `guides.read`. `unknown` is a value, not an absence: the
    # stream could not be read, and the report says so rather than "none".
    guides_note = ""
    if args.guides_read is not None:
        stored_guides = ledger.guides_of(row)
        recommended = stored_guides.get("recommended", [])
        if args.guides_read.strip() == GUIDES_UNKNOWN:
            read = None
        else:
            read = [g for g in args.guides_read.split(",") if g in guides.NAMES]
            ledger.set_guides(conn, args.analysis, read=read)
        guides_note = _guides_sentence(recommended, read)
```

Na construção da nota, o tuplo `for part in (stored, args.note or "", unprepared_note, untriaged_note, decided_note):` ganha `guides_note` no fim. A linha `sast` no ramo `else` (analysis preparada):

```python
        sast_note = (args.note or "").strip() or prior_sast
        if guides_note and guides_note not in sast_note:
            sast_note = f"{sast_note} {guides_note}".strip()
        sast_phase = coverage.phase(
            coverage.SAST_AGENT,
            coverage.RAN if state == "done" else coverage.WARNING,
            diff.AGENT, sast_note)
```

- [ ] **Step 4: correr e ver passar; a suite de cli inteira**

```bash
cd <WT> && TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests/security/test_cli.py -q -p no:cacheprovider
```

Expected: verde.

- [ ] **Step 5: CHANGELOG + commit**

`### Added`:

```markdown
- **`finish --guides-read` records which guides the run opened** — a list,
  none, or `unknown` when the stream could not be read — in the `sast` row of
  the coverage table and in the paragraph, as one of three sentences; the
  agent's own close writes none of them, because the run's stream is the
  engine's to read, never the agent's word.
```

```bash
cd <WT> && git add bin/security/cli.py tests/security/test_cli.py CHANGELOG.md && git commit -m "feat(security): finish records the guides a run read, from the engine's close only

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: o engine — ler o stream no fecho, nomear `references/` no prompt

**Files:**
- Modify: `bin/agentloop` (`security_guides_read` nova, `security_close_analysis`, a chamada em `run_job`, `security_prompt`)
- Test: `test/selftest.sh`

**Interfaces:**
- Produces: `security_guides_read <stream>` → lista separada por vírgulas, vazio, ou `unknown`; `security_close_analysis <job> <status> <cost> <wdreason> [stream]`.

- [ ] **Step 1: blocos no selftest**

No `test/selftest.sh`, a seguir ao bloco `security_close_analysis must ignore every job that is not a derived one` (procurar a frase):

```bash
  # What a run read, off its own stream: `Read` on Claude Code (file_path),
  # `read` on OpenCode (filePath, already canonicalised to Read by the
  # normaliser) and a `cat` through Bash on Codex all land in `input`, so the
  # input is matched as ONE string, with no per-platform key map.
  mkdir -p "$tmp/guides"
  cat > "$tmp/guides/stream.ndjson" <<'JSON'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Read","input":{"file_path":"/Users/x/.claude/skills/security-analysis/references/ATTACK-CLASSES.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"2","name":"Read","input":{"filePath":"/Users/x/.claude/skills/security-analysis/references/AI-AND-LLM.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"3","name":"Bash","input":{"command":"cat /Users/x/.claude/skills/security-analysis/references/AI-AND-LLM.md | head"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reading references/CLIENT-SIDE.md is not a tool call"}]}}
{"type":"result","subtype":"success"}
JSON
  [ "$(security_guides_read "$tmp/guides/stream.ndjson")" = "AI-AND-LLM,ATTACK-CLASSES" ] \
    && ok "security_guides_read: the guides a run opened, once each, off Read/read/Bash alike" \
    || bad "security_guides_read: got '$(security_guides_read "$tmp/guides/stream.ndjson")'"
  printf '{"type":"result"}\n' > "$tmp/guides/none.ndjson"
  [ -z "$(security_guides_read "$tmp/guides/none.ndjson")" ] \
    && ok "security_guides_read: a run that opened no guide answers an empty list, not unknown" \
    || bad "security_guides_read on a guide-less stream: '$(security_guides_read "$tmp/guides/none.ndjson")'"
  [ "$(security_guides_read "$tmp/guides/missing.ndjson")" = "unknown" ] \
    && [ "$(security_guides_read "")" = "unknown" ] \
    && ok "security_guides_read: a missing or unnamed stream answers unknown, never none" \
    || bad "security_guides_read on a missing stream: '$(security_guides_read "$tmp/guides/missing.ndjson")'"
  # The close hands the answer to `finish` as --guides-read, and `unknown`
  # when it has no stream to read.
  ( DATA_DIR="$tmp/derived/data"; AL_SECURITY_ANALYSIS_ID=7
    security_py() { printf '%s\n' "$*" >> "$tmp/guides/calls"; }
    security_close_analysis "security-x" success 1 "" "$tmp/guides/stream.ndjson"
    security_close_analysis "security-x" success 1 "" )
  grep -q -- '--guides-read AI-AND-LLM,ATTACK-CLASSES' "$tmp/guides/calls" \
    && grep -q -- '--guides-read unknown' "$tmp/guides/calls" \
    && ok "security_close_analysis passes what was read to finish, and unknown without a stream" \
    || bad "security_close_analysis calls: $(cat "$tmp/guides/calls")"
```

E no bloco de `security_prompt()` (linha `echo "security_prompt() — ..."`), acrescentar:

```bash
  printf '%s\n' "$_pa" | grep -q 'security-analysis/references/' \
    && printf '%s\n' "$_po" | grep -q 'security-analysis/references/' \
    && printf '%s\n' "$_pc" | grep -q 'security-analysis/references/' \
    && ok "security_prompt: every platform is told where the hunting guides are" \
    || bad "security_prompt: a platform's prompt does not name references/"
```

- [ ] **Step 2: correr o selftest no worktree e ver as falhas novas**

```bash
cd <WT> && cp /Users/lfmoura/Projects/agentloop/config/jobs.json config/jobs.json 2>/dev/null; bin/agentloop selftest 2>&1 | tail -15
```

Expected: `security_guides_read: command not found` nos blocos novos (e nada mais a vermelho — se o `config/jobs.json` faltar, uma falha conhecida sobre ele).

- [ ] **Step 3: implementar**

Em `bin/agentloop`, antes de `security_close_analysis`:

```bash
# The hunting guides a run actually opened, read off the run's own stream --
# never off the agent's word. Every platform's stream is normalised to Claude's
# shape (bin/platforms/*_stream.py), so a `Read` on Claude Code, a `read` on
# OpenCode and a `cat` through `Bash` on Codex all carry the path somewhere
# in `input`; the input is matched as ONE string, so there is no per-platform
# key map to keep in step. Names only, sorted, once each. `unknown` -- not an
# empty list -- when there is no stream to read or jq could not read it: "the
# agent read nothing" and "nobody could tell" are different facts, and
# `finish` prints a different sentence for each.
security_guides_read() { # security_guides_read <stream.ndjson> -> a,b | '' | unknown
  local f="${1:-}" out
  if [ -z "$f" ] || [ ! -r "$f" ]; then printf 'unknown\n'; return 0; fi
  out="$("$JQ" -R -r 'fromjson? | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use") | (.input | tostring)
      | match("security-analysis/references/([A-Z][A-Z-]*)\\.md"; "g")
      | .captures[0].string' "$f" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  printf '%s\n' "$out" | grep -v '^$' | sort -u | paste -s -d, -
}
```

`security_close_analysis`: assinatura passa a `# <job-id> <status> <cost> <wdreason> [stream]`; a chamada final passa a:

```bash
  security_py finish --analysis "$aid" --state "$state" --spend "${3:-0}" \
    --guides-read "$(security_guides_read "${5:-}")" \
    >/dev/null 2>&1 || log_tick "$1: could not close analysis $aid"
```

Em `run_job`, a chamada `security_close_analysis "$id" "$status" "${cost:-0}" "$wdreason"` passa a `security_close_analysis "$id" "$status" "${cost:-0}" "$wdreason" "$streamfile"`.

`security_prompt`: no heredoc, depois do parágrafo `$agents_para` e antes de `Do not read code under node_modules/`:

```
The hunting guides \`prepare\` recommends for this repository are listed as
\`guides.recommended\` in its output and in \`checklist\`'s; the files are under
\`$SKILLS_DIR/security-analysis/references/\`. Read ATTACK-CLASSES.md and then
each recommended guide, in that order, before your own SAST pass.
```

- [ ] **Step 4: correr o selftest**

```bash
cd <WT> && bin/agentloop selftest 2>&1 | tail -8
```

Expected: os quatro blocos novos `ok`; contagem `failed=0` (ou só a falha conhecida do `config/jobs.json` se não foi copiado). Correr também `bash -n bin/agentloop` — e, porque a função usa `paste`/`sort`, correr o selftest com `bash` explicitamente (é o que `bin/agentloop` já faz; o shell da sessão é zsh).

- [ ] **Step 5: CHANGELOG + commit**

`### Added`:

```markdown
- **The engine's close reads the run's stream for the guides the agent
  opened** (`security_guides_read`) and hands them to `finish --guides-read`;
  every platform's prompt now says where the guides are. A stream that cannot
  be read answers `unknown`, never "none".
```

```bash
cd <WT> && git add bin/agentloop test/selftest.sh CHANGELOG.md && git commit -m "feat(engine): the close reads which guides a run opened off its stream

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: a UI — o bloco, o chip, a coluna, o filtro

**Files:**
- Create: `ui/security/candidate.js`
- Modify: `ui/security/analysis.js` (`secFindingRow`), `ui/security/findings-screen.js` (constantes, filtros, query, linha, cabeçalho), `ui/css/pages.css` (larguras, `.secconf`, `.seccand`), `bin/static/security.js` + `bin/static/app.css` (rebuild)
- Test: `tests/test_page_contract.py`

**Interfaces:**
- Produces: `secConfidenceChip(f) -> Element|null`, `secCandidateBlock(f) -> Element|null`, `SEC_CONFIDENCE = ["high", "medium", "low"]`.

- [ ] **Step 1: `candidate.js`**

```js
// ui/security/candidate.js
/* The candidate document (bin/security/candidate.py) as the screens draw it:
   a confidence chip wherever a finding is listed, and the full block --
   trace, intended control, conditions, the three scored fields -- wherever
   a finding is shown whole (analysis.js's secFindingRow). One module, so the
   two cannot drift from each other or from the report the same document
   renders into.

   textContent only, everywhere: every string here is the agent's prose about
   analysed code, and a repository must never be able to script this page. */
import { secEl } from "./dom.js";

export const SEC_CONFIDENCE = ["high", "medium", "low"];
const SCORED = [["confidence", "Confidence"], ["likelihood", "Likelihood"], ["impact", "Impact"]];

function _doc(f){
  const c = f && f.candidate;
  return c && typeof c === "object" ? c : null;
}

export function secConfidenceChip(f){
  const c = _doc(f);
  const score = (f && f.confidence) || (c && c.confidence && c.confidence.score) || "";
  if(!score) return null;
  const chip = secEl("span", "secconf " + score, score);
  if(c && c.confidence && c.confidence.reason) chip.title = c.confidence.reason;
  return chip;
}

export function secCandidateBlock(f){
  const c = _doc(f);
  if(!c) return null;
  const box = secEl("div", "seccand");
  if(Array.isArray(c.trace) && c.trace.length){
    box.appendChild(secEl("div", "seccand-label", "Trace"));
    const ol = document.createElement("ol");
    c.trace.forEach(s => {
      const li = document.createElement("li");
      li.appendChild(secEl("span", "seccand-kind", s.kind || ""));
      li.appendChild(secEl("code", null, (s.file || "") + (s.line ? ":" + s.line : "")));
      li.appendChild(secEl("span", "seccand-scope", s.scope || ""));
      li.appendChild(secEl("span", null, s.description || ""));
      ol.appendChild(li);
    });
    box.appendChild(ol);
  }
  if(c.intended_control){
    box.appendChild(secEl("p", null, "Intended control: " + c.intended_control));
  }
  if(Array.isArray(c.conditions) && c.conditions.length){
    box.appendChild(secEl("div", "seccand-label", "Conditions"));
    const ul = document.createElement("ul");
    c.conditions.forEach(x => ul.appendChild(secEl("li", null, (x.kind || "") + ": " + (x.description || ""))));
    box.appendChild(ul);
  }
  const scored = SCORED.filter(([k]) => c[k] && typeof c[k] === "object")
    .map(([k, label]) => label + ": " + (c[k].score || "") + " — " + (c[k].reason || ""));
  if(scored.length) box.appendChild(secEl("p", "seccand-scored", scored.join(" · ")));
  return box;
}
```

- [ ] **Step 2: montar em `analysis.js`**

Import: `import { secConfidenceChip, secCandidateBlock } from "./candidate.js";`. Em `secFindingRow`, depois de `h.appendChild(st);`:

```js
  const chip = secConfidenceChip(f);
  if(chip) h.appendChild(chip);
```

e depois da linha do `rationale` (`if((f.rationale || "").trim()) row.appendChild(...)`):

```js
  const cand = secCandidateBlock(f);
  if(cand) row.appendChild(cand);
```

- [ ] **Step 3: `findings-screen.js`**

1. Import: `import { SEC_CONFIDENCE, secConfidenceChip } from "./candidate.js";`
2. `FIND_SORT_COLUMNS`:

```js
const FIND_SORT_COLUMNS = [
  ["severity", "Severity"], ["title", "Title"], ["category", "Category"],
  ["confidence", "Confidence"], ["branch", "Branch"], ["state", "Status"],
  ["first_seen", "First seen"],
];
```

3. `SEC_FIND_TABLE_COLS`:

```js
const SEC_FIND_TABLE_COLS = [
  ["severity", "Severity"], ["title", "Title"], [null, "Location"],
  ["category", "Category"], ["confidence", "Confidence"], [null, "Analysis run"],
  ["branch", "Branch"], ["state", "Status"], ["first_seen", "First seen"], [null, "Actions"],
];
```

4. `_defaultFilters` ganha `confidence: [],` depois de `category: []`.
5. `secFindQuery`: `if(f.confidence.length) p.set("confidence", f.confidence.join(","));` depois da linha de `category`.
6. `secFindActiveFilterCount`: `if(f.confidence.length) n++;`.
7. `secFindCurrentQuery`: `confidence: f.confidence,` ao lado de `category`.
8. `secFindApplyQuery`: `confidence: Array.isArray(query.confidence) ? query.confidence.slice() : [],`.
9. `secFindFilterBar`, `row2`, antes do `toggleField`:

```js
  row2.appendChild(secFindMultiPicker("Confidence",
    SEC_CONFIDENCE.map(c => ({v: c, label: _secCap(c)})),
    fs.filters.confidence,
    (v) => { secFindToggleIn(fs.filters.confidence, v); fs.page = 1; secFindRefresh(fs); }));
```

e o `searchInput.title` passa a `"Search title / rule / rationale / file / candidate"`.

10. `secFindRow`, depois de `tr.appendChild(tdCat);`:

```js
  // CONFIDENCE: the candidate's own score, a chip; empty for a finding that
  // carries no document -- unmeasured, not "low".
  const tdConf = document.createElement("td");
  const chip = secConfidenceChip(f);
  if(chip) tdConf.appendChild(chip);
  tr.appendChild(tdConf);
```

11. `secFindTableSection`: `const INSERT_AFTER = {title: "Location", confidence: "Analysis run"};` e o comentário "Nine header cells" passa a "Ten header cells … Seven are sortable".

- [ ] **Step 4: CSS**

Em `ui/css/pages.css`, as larguras da `.secfind-table` passam a dez:

```css
.secfind-table th:nth-child(1){width:8%}    /* Severity     */
.secfind-table th:nth-child(2){width:17%}   /* Title        */
.secfind-table th:nth-child(3){width:15%}   /* Location     */
.secfind-table th:nth-child(4){width:8%}    /* Category     */
.secfind-table th:nth-child(5){width:7%}    /* Confidence   */
.secfind-table th:nth-child(6){width:11%}   /* Analysis run */
.secfind-table th:nth-child(7){width:8%}    /* Branch       */
.secfind-table th:nth-child(8){width:8%}    /* Status       */
.secfind-table th:nth-child(9){width:9%}    /* First seen   */
.secfind-table th:nth-child(10){width:9%}   /* Actions      */
```

Depois das regras `.secstate.*`:

```css
/* The confidence chip: the candidate's own score. Quieter than a state pill
   (it qualifies a finding, it does not classify it); high borrows the ok
   tone, low the warn tone, medium stays neutral. */
.secconf{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;
  border-radius:20px;padding:1px 8px;background:var(--panel2);color:var(--muted);
  border:1px solid var(--line);white-space:nowrap}
.secconf.high{background:var(--ok-soft);color:var(--ok);border-color:transparent}
.secconf.low{background:var(--warn-soft);color:var(--warn);border-color:transparent}
.seccand{margin:9px 0 0;padding:8px 10px;border-left:3px solid var(--line);background:var(--panel2);
  font-size:12px;line-height:1.55}
.seccand-label{font-weight:700;text-transform:uppercase;font-size:10.5px;letter-spacing:.04em;color:var(--muted)}
.seccand ol,.seccand ul{margin:4px 0 6px 18px;padding:0}
.seccand li{margin:2px 0}
.seccand li>*{margin-right:6px}
.seccand-kind{font-weight:700;color:var(--muted)}
.seccand-scope{font-style:italic;color:var(--muted)}
.seccand p{margin:6px 0 0}
.seccand-scored{color:var(--muted)}
```

- [ ] **Step 5: build e testes de contrato**

```bash
cd <WT> && bash build/build-ui.sh && node --check bin/static/security.js && node --check bin/static/app.js && python3.13 -m pytest tests/test_page_contract.py -q -p no:cacheprovider 2>&1 | tail -15
```

Expected: verde. Se `test_the_jobs_projects_and_runs_tables_declare_a_width_for_every_column` falhar, a soma das larguras não é 100 — corrigir o CSS. Acrescentar a `tests/test_page_contract.py` um teste que extrai `_defaultFilters` (com o harness `_FIND_MOUNT_DEPS` já existente, ver como os vizinhos o usam) e assere `confidence: []` no objecto, e que `FIND_SORT_COLUMNS` contém `["confidence", "Confidence"]`.

- [ ] **Step 6: CHANGELOG + commit**

`### Added`:

```markdown
- **The dashboard shows the candidate**: a confidence chip on every finding
  row and in the analysis drill-down, the full block (trace, intended control,
  conditions, the scored fields) under a finding's rationale, and a
  Confidence column, filter and sort on the findings browser — saved filters
  keep the new key, and an old one without it means "no filter".
```

```bash
cd <WT> && git add ui/security/candidate.js ui/security/analysis.js ui/security/findings-screen.js ui/css/pages.css bin/static/security.js bin/static/app.css tests/test_page_contract.py CHANGELOG.md && git commit -m "feat(dashboard): the candidate block, the confidence chip, column and filter

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: a skill e o README

**Files:**
- Modify: `skills/security-analysis/SKILL.md`, `README.md`

- [ ] **Step 1: SKILL.md**

1. Antes de `**3. The SAST pass**`, a secção nova:

```markdown
## What qualifies as a finding

A `sast` candidate at `medium` or above has to name **the lower-trust principal, the input or action it controls, the control that should have held, the boundary crossed, the resource or principal affected, and the observable result**. A generic crash, a missing best practice or an absent defence in depth is not a vulnerability: it is a *hardening note*, and it is filed at `info` — the severity this ledger already keeps for advice rather than exposure.

Severity anchors, replacing whatever you would otherwise reach for:

- `critical` — unauthenticated code execution, full data access, or account takeover
- `high` — an explicit control fully defeated, with a real consequence
- `medium` — a real boundary crossed, with a limited blast radius
- `low` — disclosure or minimal gain
- `info` — confirmed, no impact

An unsure finding is still a finding, at the severity it would have if it were real — but the doubt now has a field, `confidence`, and the door requires it.

**The `candidate` document is how the door holds you to this.** Every `sast` finding at `medium` or above carries `trace` (the chain `entrypoint → propagation → sink`, each step a file, a line, a scope and a sentence), `intended_control` and `confidence`; at `high` and `critical`, `likelihood` and `impact` with reasons as well, and the severity may never exceed the impact. Every re-report of a scanner's row (Job 2) carries `confidence`. A `dependency` re-report may carry a `trace` — the path from an entry point to the vulnerable call is the CVE's reachability. A `secret`, `hygiene` or `iac` row takes no trace. `conditions` (what has to be true for the hole to be reachable) is always optional. The same rule that governs `rationale` governs every text in the document: **never a credential's value**, and the door refuses by field path if one appears.

**Do not lower a severity to get past the door.** A medium+ weakness without a trace is one you have not read; go read it. The next block's verifier re-checks `low` findings whose impact reads high.

The same ruler applies to Job 2: Semgrep's MD5-in-a-cache-key fails the boundary requirement and goes to `info` with the reason written — which is what already happens in practice, now with a criterion by name.
```

2. No Job 3, antes de `**Before you report a weakness, check whether a row you already have lists it**`, o parágrafo dos guias:

```markdown
**Read the hunting guides first.** `prepare` printed `guides.recommended` (on the Codex CLI and OpenCode read it off `checklist`, which prints the same object); the files are under `references/` beside this file. Read `ATTACK-CLASSES.md` and then each recommended guide, in that order, before you open the repository's code. The guides are hunting material, not process: where a guide talks about reporting, validating, hunters or a findings file, this file wins. What you read is recorded off the run's stream at the close, never off your word.
```

3. O exemplo de `report-finding` passa a incluir um `candidate` (o JSON da secção 2 da spec, abreviado a dois passos de trace, `intended_control`, `confidence`, `likelihood`, `impact`).

4. Job 2, depois de `**A finding you agree with is re-reported too.**`: uma frase — "Every such re-report carries a `candidate.confidence` with its reason; it is the field that says how sure you are, and the door requires it on a triage."

5. Job 1, no parágrafo `For a deterministic row (…) that is the whole instruction: echo the row back`: acrescentar "— and with no `candidate`: a confidence on a row nobody re-checked would be the verification this job says did not happen." E no bullet *Still present, as reported* dos `sast`: "with the full `candidate` (you read the code to say so)".

6. Confirmar que o `description:` do frontmatter continua válido e que o ficheiro abre com `Read` sem erros.

- [ ] **Step 2: README**

Na secção `## Security analysis`, depois do parágrafo que termina em "the history that produces the checklist cannot be only as trustworthy as the last JSON it happened to type." acrescentar:

```markdown
### What a finding has to carry

A `sast` finding at `medium` or above is not a paragraph any more. It carries a
**`candidate` document**: the `trace` from entry point to sink, each step a
file, a line, a scope and a sentence; the `intended_control` that should have
held; a `confidence` with its reason; at `high` and `critical`, `likelihood`
and `impact` with their reasons — and the severity may never exceed the
impact, which is the one coherence rule the door enforces. `conditions` say
what has to be true for the hole to be reachable. A re-report of a scanner's
row carries a `confidence`; a `dependency` one may carry a `trace` (the CVE's
reachability); a secret, hygiene or infrastructure row takes no trace. Every
text in the document goes through the same credential scan as `rationale`,
and a refusal names the field by path and never the text. None of this
enters the fingerprint or the checklist's states: a candidate describes a
finding, it does not identify it, and a re-report replaces it whole.

The reports render it under the finding; the findings browser filters,
sorts and searches by confidence, with unmeasured rows last whichever way
you sort. A finding without a document — every deterministic row, every row
from before the column — renders exactly as it did.

The criterion behind it is the boundary requirement of
[cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill):
a finding names the lower-trust principal, the input, the control that should
have held, the boundary crossed, what is affected and the observable result;
a missing best practice is a hardening note at `info`, not a vulnerability.

### Hunting guides

`skills/security-analysis/references/` carries `ATTACK-CLASSES.md` and ten
domain guides from the same project (MIT; `UPSTREAM.md` names the commit).
Read whole they cost ~35k tokens per run, so `prepare` chooses: from the
dependency inventory's names and the tree's paths — under the same
`ignore_paths` every phase obeys — it recommends the guides the stack calls
for, capped by the profile (`quick` reads ATTACK-CLASSES and the best match,
`standard` all that matched, `deep` all eleven), and prints and stores the
list. **What was read is taken off the run's stream at the close**, never
off the agent's word, and the `sast` row of the coverage table says
`Guides read: …`, `none of the N recommended`, or `unknown (run stream
unavailable)`. It is a note, not a gate.
```

- [ ] **Step 3: CHANGELOG + commit**

`### Changed`:

```markdown
- **The security-analysis skill has a criterion for what qualifies as a
  finding** — Cloudflare's boundary requirement and five severity anchors —
  and tells the agent to read the recommended hunting guides before its own
  SAST pass; the README's *Security analysis* section documents the
  candidate document and the guides.
```

```bash
cd <WT> && git add skills/security-analysis/SKILL.md README.md CHANGELOG.md && git commit -m "docs(security): the skill's finding criterion, the guides, and the README section

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: suites completas e aceitação real

- [ ] **Step 1: as suites Python**

```bash
cd <WT> && TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests -q -p no:cacheprovider --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on 2>&1 | tail -5
```

Expected: `0 failed`. (Primeiro plano, `timeout` 600000.)

- [ ] **Step 2: selftest e e2e**

```bash
cd <WT> && bin/agentloop selftest 2>&1 | tail -4
```

Expected: `failed=0` (com `config/jobs.json` copiado). Depois `bash test/suites.sh e2e` se existir esse alvo (ver `test/suites.sh`), ou `bash test/e2e.test.sh`, em primeiro plano.

- [ ] **Step 3: aceitação real — uma análise `quick` deste repositório**

Pré-condições: nenhuma análise `running` no ledger real (`bin/agentloop security list --project <p>` para cada projecto, ou `sqlite3 data/security.db "select id,state from analysis where state='running'"` — vazio) e nenhum run vivo (`pgrep -fl 'bin/agentloop'` só mostra o servidor). Então:

1. Config de rascunho: `SCRATCH=<scratchpad>/accept`; `mkdir -p $SCRATCH/config $SCRATCH/data`; `projects.json` com um projecto `agentloop-wt` (`cwd` = `<WT>`, `security.enabled=true`, `platform=anthropic`, `model=opus`, `max_budget_usd=3`, `default_profile=quick`); `jobs.json` = `{"jobs":[]}`; copiar `config/platforms.json` e `config/pricing.json` do checkout real.
2. **Apontar temporariamente a skill para o worktree**: `ln -sfn <WT>/skills/security-analysis ~/.claude/skills/security-analysis` — e anotar que tem de ser reposto para `/Users/lfmoura/Projects/agentloop/skills/security-analysis` no fim, aconteça o que acontecer.
3. `AGENTLOOP_CONFIG=$SCRATCH/config AGENTLOOP_DATA=$SCRATCH/data AGENTLOOP_SECURITY_DB=$SCRATCH/data/security.db <WT>/bin/agentloop security analyze --detach agentloop-wt agentloop-wt feat/security-candidates quick` e esperar pelo fecho com um script de polling (`security list` + jq, `run_in_background`, dispara quando a linha deixa `running`).
4. Verificar: `security checklist --analysis <id>` → `analysis.guides.recommended` inclui `AI-AND-LLM`, `SUPPLY-CHAIN-AND-RELEASE` e `CLIENT-SIDE` (para `quick`, só o primeiro casado — anotar qual); `analysis.guides.read` não vazio e a frase `Guides read:` na linha `sast`; pelo menos um achado `sast` com `candidate.trace`; `security render --format md|html|json` com o bloco; o ecrã do dashboard do worktree (`<WT>/bin/agentloop-server` numa porta ≠ 8787, com as mesmas variáveis de ambiente) a mostrar o chip e o bloco. Registar o custo real do run.
5. **Repor a skill**: `ln -sfn /Users/lfmoura/Projects/agentloop/skills/security-analysis ~/.claude/skills/security-analysis` e confirmar com `ls -l ~/.claude/skills/security-analysis`.

Se um passo da aceitação revelar um defeito, corrigir com o seu teste, no commit que lhe pertence (ver Task correspondente), e repetir.

- [ ] **Step 4: o pacote final**

`git log --oneline main..HEAD` mostra os dez commits; `git diff main..HEAD --stat` sem `bin/static` a aparecer como o maior; PR contra `main` (nunca contra outra branch) com o resumo da spec e os números de aceitação, terminado em `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
