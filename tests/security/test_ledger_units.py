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
    assert {"unit", "unit_read", "unit_gone"} <= tables
    analysis = {r["name"] for r in conn.execute("PRAGMA table_info(analysis)")}
    assert {"inventory", "resumes"} <= analysis
    finding = {r["name"] for r in conn.execute("PRAGMA table_info(finding)")}
    assert "unit" in finding


def test_a_ledger_from_before_the_columns_gains_them_on_connect(tmp_path):
    path = tmp_path / "old.db"
    ledger.connect(path).close()
    raw = sqlite3.connect(path)
    raw.execute("ALTER TABLE analysis DROP COLUMN inventory")
    raw.execute("ALTER TABLE analysis DROP COLUMN resumes")
    raw.execute("ALTER TABLE finding DROP COLUMN unit")
    raw.commit()
    raw.close()
    conn = ledger.connect(path)
    assert {"inventory", "resumes"} <= {r["name"] for r in conn.execute("PRAGMA table_info(analysis)")}
    assert "unit" in {r["name"] for r in conn.execute("PRAGMA table_info(finding)")}


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


def test_the_inventory_round_trips_and_a_missing_or_broken_one_reads_empty(conn):
    aid = _analysis(conn)
    row = conn.execute("SELECT * FROM analysis WHERE id=?", (aid,)).fetchone()
    assert ledger.inventory_of(row) == {}
    ledger.set_inventory(conn, aid, {"totals": {"files": 2}, "files": []})
    row = conn.execute("SELECT * FROM analysis WHERE id=?", (aid,)).fetchone()
    assert ledger.inventory_of(row)["totals"] == {"files": 2}
    conn.execute("UPDATE analysis SET inventory='{not json' WHERE id=?", (aid,))
    assert ledger.inventory_of(conn.execute("SELECT * FROM analysis WHERE id=?", (aid,)).fetchone()) == {}
    assert ledger.inventory_of({}) == {}


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
