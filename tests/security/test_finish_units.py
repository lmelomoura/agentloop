# tests/security/test_finish_units.py
"""The close the engine makes: done only with every unit's proof, capped with each gap named."""
import json
import os

from test_cli import fails, run

from security import cli as security_cli
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
    """One row, attempt 1: the lineage never ran a second time and never
    advanced an attempt, so the sentence must say "1 run (1 attempt)" -- not
    MAX_ATTEMPTS, which this lineage never reached."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    ledger.start_unit(conn, read)
    ledger.settle_unit(conn, read, "failed", 0.5,
                       {"missing": [{"path": "a.py", "first": 6, "last": 10, "bytes": 0}],
                        "covered": {"a.py": [[1, 5]]}},
                       "1 of 1 range(s) not read in full.")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "1 unit gave up after 1 run (1 attempt): read 1/1" in row["coverage_note"]
    assert "5 of 10 lines in the deep scope (1 of 1 files) were never read in full" in row["coverage_note"]
    assert "a.py:6-10" in row["coverage_note"]


def test_a_lineage_struck_out_by_the_orchestrator_gave_up_at_attempt_one_after_three_runs(tmp_path):
    """Three rows, all attempt 1: the orchestrator's own strike-out (three
    runs that died without closing, orchestrator.STRUCK_OUT_NOTE) never
    advances the attempt column, so `gaps` must report the runs it actually
    took -- "3 runs (1 attempt)" -- never MAX_ATTEMPTS' "3 attempts"."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    root = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    second = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=1, parent=root)
    third = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=1, parent=second)
    ledger.start_unit(conn, third)
    ledger.settle_unit(conn, third, "failed", 0, {},
                       "The engine could not run this unit: 3 runs ended without a close "
                       "(see tick.log).")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "1 unit gave up after 3 runs (1 attempt): read 1/1" in row["coverage_note"]


def test_a_lineage_that_gave_up_after_max_attempts_names_three_runs_and_three_attempts(tmp_path):
    """Three rows, attempts 1, 2 and 3: the ordinary MAX_ATTEMPTS path, where
    every continuation also advanced the attempt -- runs and attempts agree
    here, both at 3."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    root = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    second = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=2, parent=root)
    third = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=3, parent=second)
    ledger.start_unit(conn, third)
    ledger.settle_unit(conn, third, "failed", 0,
                       {"missing": [], "covered": {}},
                       "1 of 1 range(s) not read in full. Gave up after 3 attempts.")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "1 unit gave up after 3 runs (3 attempts): read 1/1" in row["coverage_note"]


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


def test_a_deep_analysis_with_no_inventory_is_capped_and_named(tmp_path):
    """A `deep` analysis whose scope was never listed, or could not be read
    (`inventory_of` returns {}), used to close `done` when every planned unit
    happened to finish -- `owed` reads an empty inventory as an empty
    repository and names nothing. The close must say so itself instead of
    trusting a debt it cannot compute."""
    db = tmp_path / "security.db"
    conn = _conn(db)
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "deep", "security-web")
    ledger.mark_prepared(conn, aid, ["secrets"])   # no set_inventory: the scope was never listed
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    _done(conn, hunt, 1.0, ["ATTACK-CLASSES"])
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "capped"
    assert "deep scope was never listed" in row["coverage_note"]


def test_a_quick_analysis_with_no_inventory_names_no_deep_gap(tmp_path):
    """A `quick` profile has no deep scope to begin with -- an empty
    inventory is simply the truth for it, not a missing one, so `gaps` must
    not name it."""
    db = tmp_path / "security.db"
    conn = _conn(db)
    aid = ledger.start_analysis(conn, "web", "web", "main", "abc", "quick", "security-web")
    ledger.mark_prepared(conn, aid, ["secrets"])
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "quick"})
    _done(conn, hunt, 1.0, ["ATTACK-CLASSES"])
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    row = _analysis(db, aid)
    assert row["state"] == "done"
    assert "deep scope" not in row["coverage_note"]


def test_from_units_keeps_the_passed_spend_when_summary_is_none(tmp_path, monkeypatch):
    """`units.summary` returns None for a ledger that predates the unit table
    (a read-only connection that never migrates, security/queries.py).
    `--spend` carries the run's own real cost; overwriting it with 0 in that
    case throws away the one number `finish` is bound never to lose."""
    db = tmp_path / "security.db"
    aid, conn = _deep(db, tmp_path)
    ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    monkeypatch.setattr(security_cli.units, "summary", lambda *a, **kw: None)
    security_cli.main(["finish", "--analysis", str(aid), "--state", "capped",
                       "--from-units", "--spend", "4.25", "--db", str(db)])
    row = _analysis(db, aid)
    assert row["spend_usd"] == 4.25


def _gave_up(db, tmp_path):
    """A deep analysis closed from its units with one lineage given up: the
    read proved its lines, the hunt never ran."""
    aid, conn = _deep(db, tmp_path)
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    _done(conn, read, 1.5, ["ATTACK-CLASSES"], covered={"a.py": [[1, 10]]})
    ledger.start_unit(conn, hunt)
    ledger.settle_unit(conn, hunt, "failed", 0, {}, "The engine could not run this unit.")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    return aid, conn, hunt, read


def test_a_retry_reopens_only_what_gave_up_and_the_next_close_drops_the_old_gaps(tmp_path):
    db = tmp_path / "security.db"
    aid, conn, hunt, read = _gave_up(db, tmp_path)
    before = _analysis(db, aid)
    assert before["state"] == "capped" and "gave up" in before["coverage_note"]
    assert run(db, "checklist", "--analysis", str(aid))["retryable"] == 1
    assert run(db, "reopen", "--analysis", str(aid)) == {"state": "interrupted", "units": 1}
    child = [u for u in ledger.units_of(conn, aid) if u["parent"] == hunt]
    assert [(c["kind"], c["state"], c["attempt"]) for c in child] == [("hunt", "pending", 1)]
    assert ledger.get_unit(conn, read)["state"] == "done", "what was done stays done"
    reopened = _analysis(db, aid)
    assert "gave up" not in reopened["coverage_note"], "the old close's gaps are cut"
    assert "1 unit that had given up was run again." in reopened["coverage_note"]
    ledger.resume_analysis(conn, aid)
    _done(conn, child[0]["id"], 0.5, ["ATTACK-CLASSES"])
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    after = _analysis(db, aid)
    assert after["state"] == "done", after["coverage_note"]
    assert "gave up" not in after["coverage_note"]
    assert "1 unit that had given up was run again." in after["coverage_note"]
    assert run(db, "checklist", "--analysis", str(aid))["retryable"] == 0


def test_reopen_refuses_with_the_reason_and_never_inside_an_agent_session(tmp_path):
    db = tmp_path / "security.db"
    aid, conn, _hunt, _read = _gave_up(db, tmp_path)
    agent = fails(db, "reopen", "--analysis", str(aid), env={**os.environ, "AL_SECURITY_AGENT": "1"})
    assert agent.returncode != 0, "a unit's session never reopens an analysis"
    assert _analysis(db, aid)["state"] == "capped"
    run(db, "reopen", "--analysis", str(aid))
    again = fails(db, "reopen", "--analysis", str(aid))
    assert again.returncode != 0
    assert f"analysis {aid} is interrupted: only a capped or failed analysis is retried" in again.stderr
