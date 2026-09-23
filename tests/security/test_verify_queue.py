# tests/security/test_verify_queue.py
"""Which findings go to a verifier, and in what order. The scope lives in
`queries.verify_queue` and nowhere else -- a filter the model applies from
prose is the kind of instruction this module has already watched fail."""
import pytest

from security import candidate, ledger, queries


def _finding(fp, *, severity="high", category="sast", producer="agent",
             impact=None, rule="sql-injection"):
    doc = {"confidence": {"score": "high", "reason": "r"}}
    if impact:
        doc["impact"] = {"score": impact, "reason": "r"}
    return {"fingerprint": fp, "category": category, "rule": rule,
            "severity": severity, "title": f"t-{fp[0]}", "rationale": "r",
            "producer": producer, "occurrences": [{"file": "a.py", "line": 1}],
            "candidate": candidate.encode(doc)}


@pytest.fixture
def seeded(tmp_path):
    conn = ledger.connect(tmp_path / "s.db")
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "standard", "r1")
    ledger.mark_prepared(conn, aid, ["semgrep"])
    rows = [
        _finding("a" * 64, severity="critical"),                  # in
        _finding("b" * 64, severity="medium"),                    # in
        _finding("c" * 64, severity="low"),                       # out: low, no impact
        _finding("d" * 64, severity="low", impact="critical"),    # in: the evasion route
        _finding("e" * 64, severity="info", impact="high"),       # in: same route
        _finding("f" * 64, severity="high", producer="semgrep"),  # out: not the agent's
        _finding("g" * 64, severity="high", category="hygiene",
                 rule="committed_env_file", producer="hygiene"),  # out: not sast
    ]
    for row in rows:
        ledger.record_finding(conn, aid, row)
    return conn, aid


def test_the_queue_is_the_scope_and_nothing_else(seeded):
    conn, aid = seeded
    assert sorted(f["fingerprint"][0] for f in queries.verify_queue(conn, aid)) == \
        ["a", "b", "d", "e"]


def test_the_queue_is_worst_first_by_the_worse_of_severity_and_impact(seeded):
    """Worst first, where "worst" is the worse of the declared severity and
    the candidate's impact. Ordering by severity alone would put the evasion
    route -- a `low` claiming a `critical` impact -- at the END of the queue,
    which is the one place a budget that runs out never reaches. `d` is low
    with a critical impact and `e` is info with a high one; both are verified
    before the honest `medium`."""
    conn, aid = seeded
    out = queries.verify_queue(conn, aid)
    assert [f["fingerprint"][0] for f in out] == ["a", "d", "e", "b"]
    assert [f["severity"] for f in out] == ["critical", "low", "info", "medium"]


def test_a_finding_already_verified_leaves_the_queue(seeded):
    conn, aid = seeded
    ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it")
    assert sorted(f["fingerprint"][0] for f in queries.verify_queue(conn, aid)) == \
        ["b", "d", "e"]


def test_the_queue_carries_what_the_prompt_needs(seeded):
    conn, aid = seeded
    first = queries.verify_queue(conn, aid)[0]
    assert first["candidate"]["confidence"]["score"] == "high"
    assert first["occurrences"] == [{"file": "a.py", "line": 1, "snippet_hash": ""}]
    assert first["rule"] == "sql-injection" and first["title"]


def test_in_verify_scope_is_the_one_predicate():
    assert queries.in_verify_scope(
        {"category": "sast", "producer": "agent", "verdict": "", "state": "new",
         "severity": "medium", "candidate": None})
    assert not queries.in_verify_scope(
        {"category": "sast", "producer": "agent", "verdict": "", "state": "fixed",
         "severity": "critical", "candidate": None}), "a fixed finding is not exposure to verify"
