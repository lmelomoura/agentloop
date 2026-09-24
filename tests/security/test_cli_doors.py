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


# ---- controller decision: `migrate-rules` refuses while an analysis is
# `interrupted`, not only `running` -- a resumed analysis's triage units carry
# fingerprints in their own payloads (security/units.py), and a rename in
# between orphans them and the rows they were to carry.

def test_migrate_rules_is_refused_while_an_analysis_is_interrupted_too(tmp_path):
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    run(db, "interrupt", "--analysis", str(aid))
    out = fails(db, "migrate-rules")
    assert out.returncode != 0
    assert f"analysis {aid}" in out.stderr and "interrupted" in out.stderr
    assert "nothing was migrated" in out.stderr.lower()


def test_migrate_rules_is_not_refused_once_the_interrupted_analysis_is_abandoned(tmp_path):
    """Containment probe: the guard is about a PAUSED analysis whose units may
    still resume, not about an analysis that once existed -- `abandon` ends
    that, and the ledger is free to migrate again."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    run(db, "interrupt", "--analysis", str(aid))
    run(db, "abandon", "--analysis", str(aid), "--note", "giving up on it")
    assert run(db, "migrate-rules") == {"renamed": [], "findings": 0}
