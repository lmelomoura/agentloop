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
    conf = doc.get("confidence") if isinstance(doc, dict) else None
    return conf.get("score", "") if isinstance(conf, dict) else ""
