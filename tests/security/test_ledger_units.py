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


def test_what_a_unit_reported_gone_is_known_by_that_unit_alone(conn):
    """The judge's question (security/units.py): what did THIS unit say is
    gone -- never what some unit of the analysis said."""
    aid = _analysis(conn)
    said, silent = ledger.add_unit(conn, aid, "triage", {"items": []}), ledger.add_unit(conn, aid, "triage", {"items": []})
    ledger.record_gone(conn, said, "c" * 64, "the handler was deleted")
    assert (ledger.gone_by(conn, said), ledger.gone_by(conn, silent)) == ({"c" * 64}, set())


def _finding(fp, **extra):
    return {"fingerprint": fp, "category": "sast", "rule": "xss", "severity": "medium",
            "title": "t", "rationale": "r", "producer": "agent",
            "occurrences": [{"file": "a.py", "line": 1}], **extra}


@pytest.mark.parametrize("occurrences", [[], [{"line": 3}], [{"file": "", "line": 3}]])
def test_the_ledger_refuses_a_sast_finding_with_no_location_on_its_own(conn, occurrences):
    """The ledger's own copy of the door's lock (report-finding refuses the
    same payload with its own message): a scanner producer or a test calls
    record_finding directly, and a `sast` row with no location can be
    neither fixed nor verified -- nothing is written."""
    aid = _analysis(conn)
    with pytest.raises(ValueError, match="a sast finding needs at least one occurrence naming a file"):
        ledger.record_finding(conn, aid, _finding("a" * 64, occurrences=occurrences))
    assert conn.execute("SELECT COUNT(*) FROM finding").fetchone()[0] == 0


def test_the_door_refuses_a_sast_finding_with_no_location_in_its_own_words(tmp_path):
    import json
    from test_cli import fails, open_analysis
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick", commit="c1")
    out = fails(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(
        {"fingerprint": "a" * 64, "category": "sast", "rule": "xss", "severity": "low",
         "title": "t", "rationale": "r", "occurrences": []}))
    assert out.returncode != 0
    assert ("report-finding: a sast finding needs at least one occurrence naming a file. A "
            "weakness with no location can be neither fixed nor verified, by this analysis or "
            "the next one's report-gone") in out.stderr


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


def _verdict(conn, fp):
    return tuple(conn.execute("SELECT verdict, verdict_reason, verified_by FROM finding"
                              " WHERE fingerprint=?", (fp,)).fetchone())


def test_a_verdict_is_cleared_with_its_unit_s_settle_and_only_by_the_writer_it_names(conn):
    """The close of a verify unit disqualified for a subagent takes the
    verdict off its row IN THE SETTLE'S TRANSACTION (`conclude_unit`'s
    `clear_verdict`): never someone else's verdict -- another unit's, the
    operator's, a verifier's from before the pipeline -- and never when the
    settle does not take effect, so a unit another close already settled
    keeps what it was credited with."""
    aid = _analysis(conn)
    ledger.record_finding(conn, aid, _finding("a" * 64))
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    mine = f"unit:{uid}"
    ledger.record_verdict(conn, aid, "a" * 64, "rejected", "a subagent's reading", by=mine)
    for other in ("unit:99", "operator", "subagent", ""):
        attempt = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
        assert ledger.conclude_unit(conn, attempt, "incomplete", clear_verdict=(aid, "a" * 64, other))[0] is True
    assert _verdict(conn, "a" * 64) == ("rejected", "a subagent's reading", mine), "nobody else's is cleared"
    settled = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    ledger.settle_unit(conn, settled, "done")
    assert ledger.conclude_unit(conn, settled, "incomplete", clear_verdict=(aid, "a" * 64, mine)) == (False, None)
    assert _verdict(conn, "a" * 64) == ("rejected", "a subagent's reading", mine), \
        "a settle that does not take effect clears nothing"
    with pytest.raises(ValueError, match="keeps its verdict"):
        ledger.conclude_unit(conn, uid, "done", clear_verdict=(aid, "a" * 64, mine))
    assert (ledger.get_unit(conn, uid)["state"], _verdict(conn, "a" * 64)[0]) == ("pending", "rejected"), \
        "never a unit settled done by the call that clears its verdict"
    took, cid = ledger.conclude_unit(conn, uid, "incomplete", clear_verdict=(aid, "a" * 64, mine),
                                     continuation=("verify", {"fingerprint": "a" * 64}, 2, uid))
    assert (took, _verdict(conn, "a" * 64)) == (True, ("", "", ""))
    assert ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it", by=f"unit:{cid}") is True, \
        "and the row takes the continuation's verdict"


def test_a_clear_and_its_settle_land_together_or_not_at_all(conn):
    """One transaction: a continuation that cannot be written (here, a
    payload JSON cannot encode) rolls back the settle AND the clear -- the
    unit still pending, the verdict still on its row."""
    aid = _analysis(conn)
    ledger.record_finding(conn, aid, _finding("a" * 64))
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    ledger.record_verdict(conn, aid, "a" * 64, "rejected", "a subagent's reading", by=f"unit:{uid}")

    class NotJson:
        pass
    with pytest.raises(TypeError, match="JSON serializable"):
        ledger.conclude_unit(conn, uid, "incomplete", clear_verdict=(aid, "a" * 64, f"unit:{uid}"),
                             continuation=("verify", {"fingerprint": NotJson()}, 2, uid))
    assert ledger.get_unit(conn, uid)["state"] == "pending"
    assert _verdict(conn, "a" * 64) == ("rejected", "a subagent's reading", f"unit:{uid}")
    assert [u["id"] for u in ledger.units_of(conn, aid)] == [uid]


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


def test_a_guard_decides_inside_the_transaction_what_is_written(conn):
    """The check and the write of a plan in ONE transaction: the guard runs
    after BEGIN IMMEDIATE, so no other writer can land between what it saw
    and what is written, and only what it returns is written."""
    aid = _analysis(conn)
    seen = []

    def no_hunt(c, specs):
        seen.append(c.in_transaction)
        return [s for s in specs if s[0] != "hunt"]
    ids = ledger.add_units(conn, aid, [("hunt", {}), ("read", {"ranges": []})], guard=no_hunt)
    assert seen == [True]
    assert [ledger.get_unit(conn, i)["kind"] for i in ids] == ["read"]
    assert ledger.add_units(conn, aid, [("hunt", {})], guard=lambda c, specs: []) == []
    with pytest.raises(ValueError):
        ledger.add_units(conn, aid, [("hunt", {})], guard=lambda c, specs: [("explore", {})])
    assert [u["kind"] for u in ledger.units_of(conn, aid)] == ["read"], \
        "a guard's empty answer writes nothing, and a kind it hands back is checked like any other"


def test_concluding_settles_a_unit_and_adds_its_continuation_together_and_only_once(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": []})
    ledger.start_unit(conn, uid)
    settled, cid = ledger.conclude_unit(conn, uid, "incomplete", 0.5, {"missing": [1]}, "short",
                                        continuation=("read", {"ranges": [1]}, 2, uid))
    assert settled is True
    unit, cont = ledger.get_unit(conn, uid), ledger.get_unit(conn, cid)
    assert (unit["state"], unit["spend_usd"], unit["evidence"], unit["note"]) == \
        ("incomplete", 0.5, {"missing": [1]}, "short")
    assert (cont["state"], cont["kind"], cont["payload"], cont["attempt"], cont["parent"], cont["seq"]) == \
        ("pending", "read", {"ranges": [1]}, 2, uid, 2)
    assert ledger.conclude_unit(conn, uid, "done", continuation=("read", {}, 3, uid)) == (False, None)
    assert len(ledger.units_of(conn, aid)) == 2, "a settled unit is not continued again"
    assert ledger.conclude_unit(conn, cid, "done") == (True, None)
    with pytest.raises(ValueError):
        ledger.conclude_unit(conn, uid, "running")
