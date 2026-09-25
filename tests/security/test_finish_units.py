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
