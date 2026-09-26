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


@pytest.mark.parametrize("verb", ["finish", "unit-close", "orchestrate", "interrupt", "resume", "abandon",
                                  "prepare"])
def test_the_engine_s_verbs_are_refused_to_an_agent_session(verb):
    assert verb in security_cli.AGENT_FORBIDDEN


def test_prepare_is_refused_under_the_agent_flag(tmp_path):
    """The orchestrator runs the deterministic phase once, engine-side, with
    the flag stripped; a unit's session that ran it again would re-run the
    scanners over the analysis mid-pipeline."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick", commit="c1")
    (tmp_path / "tree").mkdir()
    out = fails(db, "prepare", "--analysis", str(aid), "--root", str(tmp_path / "tree"), "--offline",
                env=AS_AGENT)
    assert out.returncode != 0 and "refused inside a security analysis" in out.stderr
    row = run(db, "analysis", "--id", str(aid))
    assert not row["prepared"]


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
    ledger.start_unit(conn, uid)
    _sast(db, aid, "b" * 64, env=_agent_in_unit(aid, uid))
    assert conn.execute("SELECT unit FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()[0] == uid


@pytest.mark.parametrize("case", ["pending", "settled", "another analysis's", "missing"])
def test_a_finding_is_refused_for_a_unit_that_is_not_running_in_this_analysis(tmp_path, case):
    """`finding.unit` is what the judge credits a unit with, so the door
    asks what `report-verdict`, `report-gone` and `read` ask: a running unit
    of THIS analysis. An orphan of a run already judged, or a session naming
    another analysis's unit, writes nothing."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    conn = _conn(db)
    if case == "another analysis's":
        other = prepared_analysis(db, tmp_path)
        uid = ledger.add_unit(conn, other, "hunt", {})
        ledger.start_unit(conn, uid)
    elif case == "missing":
        uid = 999
    else:
        uid = ledger.add_unit(conn, aid, "hunt", {})
        if case == "settled":
            ledger.start_unit(conn, uid)
            ledger.settle_unit(conn, uid, "done", 0, {}, "judged")
    out = fails(db, "report-finding", "--analysis", str(aid), env=_agent_in_unit(aid, uid),
                stdin=json.dumps({"fingerprint": "b" * 64, "category": "hygiene", "rule": "r",
                                  "severity": "high", "title": "t", "rationale": "seen",
                                  "occurrences": [{"file": "a.py", "line": 1}]}))
    assert out.returncode != 0 and f"unit {uid} is not a running unit of analysis {aid}" in out.stderr
    assert conn.execute("SELECT COUNT(*) FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()[0] == 0


def test_a_finding_ignores_a_unit_the_payload_itself_tries_to_set(tmp_path):
    """`unit` is stamped from the RUN's own environment (`_session_unit()`),
    never read from the payload -- the same rule `producer` follows, and
    for the same reason: a session able to claim another unit's id in its
    own payload could hand a disqualified attempt's rows to whichever unit
    it liked, or credit a unit that never wrote anything at all. The
    payload's own `unit` key, whatever it names, must be silently
    overwritten, not merely ignored as an extra key that happens not to
    reach the column."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    conn = _conn(db)
    real = ledger.add_unit(conn, aid, "hunt", {})
    claimed = ledger.add_unit(conn, aid, "hunt", {})
    ledger.start_unit(conn, real)
    run(db, "report-finding", "--analysis", str(aid), env=_agent_in_unit(aid, real), stdin=json.dumps({
        "fingerprint": "b" * 64, "category": "sast", "rule": "sql-injection", "severity": "high",
        "title": "t", "rationale": "the query is concatenated",
        "occurrences": [{"file": "app/db.py", "line": 12}], "unit": claimed,
        "candidate": {"trace": [{"kind": "entrypoint", "file": "app/api.py", "line": 4, "scope": "s",
                                 "description": "input"},
                                {"kind": "sink", "file": "app/db.py", "line": 12, "scope": "f",
                                 "description": "execute"}],
                      "intended_control": "parameterised queries",
                      "confidence": {"score": "high", "reason": "r"},
                      "likelihood": {"score": "high", "reason": "r"},
                      "impact": {"score": "high", "reason": "r"}}}))
    stored = conn.execute("SELECT unit FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()[0]
    assert stored == real, "the session's own unit, never the one the payload asked for"
    assert stored != claimed


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


def test_a_verdict_is_refused_for_the_right_unit_while_it_is_still_pending(tmp_path):
    """The door's combined `if` names five ways a session is not this
    finding's verifier -- no unit, the wrong kind, the wrong analysis, the
    wrong fingerprint, and `unit["state"] != "running"` -- and the sibling
    test above exercises the first two of the five (`None`, a `hunt` unit)
    plus the fingerprint mismatch (`wrong`), but never sends the RIGHT
    unit, for the RIGHT finding, before the engine has started it: a plan
    leaves every unit `pending`, and `report-verdict` must refuse a session
    that has not actually been launched for it yet, the same as a wrong
    unit entirely."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    _sast(db, aid, "b" * 64)
    conn = _conn(db)
    right = ledger.add_unit(conn, aid, "verify", {"fingerprint": "b" * 64})   # never started: still pending
    out = fails(db, "report-verdict", "--analysis", str(aid), "--fingerprint", "b" * 64,
               stdin=json.dumps({"verdict": "confirmed", "reason": "read app/db.py:12"}),
               env=_agent_in_unit(aid, right))
    assert out.returncode != 0 and "verify unit" in out.stderr
    assert conn.execute("SELECT verdict FROM finding WHERE fingerprint=?", ("b" * 64,)).fetchone()[0] == ""


def test_a_verdict_is_refused_for_a_verify_unit_of_another_analysis_with_the_same_fingerprint(tmp_path):
    """`unit["analysis_id"] != args.analysis` is its own condition in the
    door's combined `if`, untested on its own: a verify unit that IS
    running, and IS a `verify` unit, and DOES carry the right fingerprint
    -- but was launched for a DIFFERENT analysis that happens to carry a
    finding under the same fingerprint text -- must not be able to write a
    verdict onto the analysis named by `--analysis` either. Two analyses of
    the same fingerprint is ordinary: a carried finding keeps its
    fingerprint across analyses, and two independently reported findings
    can collide on one by chance."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    _sast(db, aid, "b" * 64)
    other_aid = prepared_analysis(db, tmp_path)
    _sast(db, other_aid, "b" * 64)
    conn = _conn(db)
    other_unit = ledger.add_unit(conn, other_aid, "verify", {"fingerprint": "b" * 64})
    ledger.start_unit(conn, other_unit)
    # The session env names THIS analysis (`aid`) as the one it is writing
    # into, but the unit id is the OTHER analysis's own verify unit.
    env = {**AS_AGENT, "AL_SECURITY_ANALYSIS_ID": str(aid), "AL_SECURITY_UNIT_ID": str(other_unit)}
    out = fails(db, "report-verdict", "--analysis", str(aid), "--fingerprint", "b" * 64,
               stdin=json.dumps({"verdict": "confirmed", "reason": "read app/db.py:12"}), env=env)
    assert out.returncode != 0 and "verify unit" in out.stderr
    assert conn.execute("SELECT verdict FROM finding WHERE analysis_id=? AND fingerprint=?",
                        (aid, "b" * 64)).fetchone()[0] == ""


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
    """Scoped by `project`, `branch` AND `repo` alike -- the supersede
    query's own `WHERE` names all three -- so an interrupted analysis of a
    different branch OR a different repo of the same project/branch stays
    interrupted; only the exact same (project, repo, branch) is superseded.
    `list` is scoped by `--project` alone, so `other_repo`'s row -- a
    different repo of the SAME project -- still shows up in it."""
    db = tmp_path / "security.db"
    old = open_analysis(db)
    other_branch = open_analysis(db, branch="develop")
    other_repo = open_analysis(db, repo="web-other")
    run(db, "interrupt", "--analysis", str(old))
    run(db, "interrupt", "--analysis", str(other_branch))
    run(db, "interrupt", "--analysis", str(other_repo))
    new = open_analysis(db)
    rows = {r["id"]: r for r in run(db, "list", "--project", "web")}
    assert rows[old]["state"] == "failed"
    assert f"Superseded by analysis {new}" in rows[old]["coverage_note"]
    assert rows[other_branch]["state"] == "interrupted"
    assert rows[other_repo]["state"] == "interrupted"


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


def test_the_engine_s_usage_line_names_every_verb_the_door_accepts():
    """bin/agentloop's `security` usage message says it names every verb
    the door accepts; it had fallen behind the pipeline's (read, units,
    unit-close, interrupt, export-findings, ...) and kept one that is gone."""
    import re
    from pathlib import Path
    root = Path(security_cli.__file__).resolve().parents[2]
    usage = re.search(r'die "usage: agentloop security <([^>]+)>',
                      (root / "bin" / "agentloop").read_text()).group(1).split("|")
    source = (root / "bin" / "security" / "cli.py").read_text()
    verbs = set(re.findall(r'\bsub\.add_parser\(\s*"([a-z-]+)"', source))
    assert "migrate-rules" in verbs and "verify-prompt" not in verbs
    # `analyze` and `retry` are the engine's own (cmd_security_analyze,
    # cmd_security_retry, which calls the ledger's `reopen`); `resume` both.
    own = {"analyze", "retry"}
    assert set(usage) == verbs | own, (set(usage) ^ (verbs | own))


# ---- `finish --if-running` decides in the write, not only in a read before it

def test_a_close_if_running_never_settles_a_row_interrupted_while_it_was_closing(tmp_path, monkeypatch):
    """The check at the top of `cmd_finish` reads the row; a stop or the
    next Analyse's sweep can interrupt it before the UPDATE. The write is
    conditional too, so the interruption stands -- the resume's to continue."""
    db = tmp_path / "security.db"
    aid = prepared_analysis(db, tmp_path)
    real_gaps = security_cli.units.gaps

    def gaps_while_a_stop_lands(conn, analysis_id):
        ledger.interrupt_analysis(ledger.connect(db), analysis_id)
        return real_gaps(conn, analysis_id)
    monkeypatch.setattr(security_cli.units, "gaps", gaps_while_a_stop_lands)
    security_cli.main(["--db", str(db), "finish", "--analysis", str(aid), "--state", "done",
                       "--from-units", "--if-running"])
    row = run(db, "analysis", "--id", str(aid))
    assert (row["state"], row["ended"]) == ("interrupted", None)


def test_finish_analysis_only_if_running_leaves_any_other_row_alone(tmp_path):
    conn = _conn(tmp_path / "security.db")
    aid = open_analysis(tmp_path / "security.db", profile="quick", commit="c1")
    assert ledger.interrupt_analysis(conn, aid)
    assert ledger.finish_analysis(conn, aid, "done", only_if_running=True) is False
    assert conn.execute("SELECT state FROM analysis WHERE id=?", (aid,)).fetchone()[0] == "interrupted"
    assert ledger.finish_analysis(conn, aid, "failed") is True
