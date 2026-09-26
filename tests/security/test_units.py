# tests/security/test_units.py
"""The pipeline's units: what the plan holds, what runs next, and how a unit is judged."""
import sqlite3
from pathlib import Path

import pytest

from security import cli as security_cli
from security import evidence, ledger, queries, units

ENGINE = Path(__file__).resolve().parent.parent.parent / "bin" / "agentloop"
# The subagent launch of a real captured Claude Code stream (test_evidence.py's fixture).
LAUNCH = next(line for line in (Path(__file__).parent / "fixtures" / "streams" / "claude-reads.ndjson")
              .read_text().splitlines() if '"name":"Agent"' in line)


def _quiet(tmp_path):
    """A stream that proves a session ran and launched nothing: its init
    event alone. A close judges nothing without a stream (units.close)."""
    stream = tmp_path / "quiet.stream.ndjson"
    stream.write_text('{"type":"system","subtype":"init","cwd":"/Users/me/run"}\n')
    return str(stream)


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


def _agent(conn, aid, fp, severity="medium", unit=0, rationale="the agent read it"):
    ledger.record_finding(conn, aid, {
        "fingerprint": fp, "category": "sast", "rule": "xss", "severity": severity,
        "title": "t", "rationale": rationale, "producer": "agent", "unit": unit,
        "occurrences": [{"file": "a.py", "line": 3}]})


def _verdict(conn, fp):
    return tuple(conn.execute("SELECT verdict, verified_by FROM finding WHERE fingerprint=?",
                              (fp,)).fetchone())


def _inventory(conn, aid, files):
    ledger.set_inventory(conn, aid, {"files": files, "excluded": {}, "git": True,
                                     "totals": {"files": len(files), "lines": 0, "bytes": 0}})


def _file(path, *ranges):
    return {"path": path, "lines": ranges[-1][1], "bytes": sum(r[2] for r in ranges),
            "ranges": [list(r) for r in ranges]}


def test_the_triage_floor_is_the_close_s_own():
    assert units.BLOCKING == security_cli.TRIAGE_BLOCKING


def test_a_carried_sast_finding_reported_gone_is_settled_and_a_deterministic_one_is_not(conn):
    """Fix 3: a `sast` gone claim also needs its file read (here, `a.py`,
    the occurrence `_agent` records) -- a `dependency` one is never settled
    by `report-gone` at all, whatever it reads."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"},
        {"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    ledger.record_gone(conn, uid, "d" * 64, "not how a dependency row is settled")
    done, remaining, ev, note = units.judge(
        conn, ledger.get_unit(conn, uid), _session({"a.py": [(1, 5)]}), "success")
    assert remaining == {"items": [{"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]}


def test_a_gone_claim_on_a_row_another_unit_re_reported_is_owed_and_named_for_it(conn):
    """The carried row was re-reported into this analysis by ANOTHER unit
    while this one said it is gone: owed, and the note says so -- it used to
    read "has no recorded location to verify", about a row that has one."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}]})
    other = ledger.add_unit(conn, aid, "read", {"ranges": []})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    _agent(conn, aid, "c" * 64, unit=other, rationale="the read unit found it still there")
    done, _remaining, _ev, note = units.judge(
        conn, ledger.get_unit(conn, uid), _session({"a.py": [(1, 5)]}), "success")
    assert done is False
    assert f"reported gone, but another unit re-reported it into this analysis ({'c' * 64})" in note
    assert "no recorded location" not in note


def test_triage_owes_every_open_scanner_row_and_every_agent_finding_left_open(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "low")
    _scanner(conn, aid, "b" * 64, "critical")
    items = units.triage_items(conn, aid)
    assert [(i["fingerprint"][0], i["kind"]) for i in items] == [("b", "scanner"), ("c", "carried"), ("a", "scanner")]


def test_a_carried_finding_from_before_the_producer_column_is_still_owed(conn):
    """A row written before `producer` existed carries ''. Left out of the
    triage, nobody re-checked it -- and a `sast` row nobody can name the
    producer of closes `fixed` on the analysis's `done` (diff._proven), the
    very silence the carried items exist to break."""
    prev = _analysis(conn, commit="c0")
    ledger.record_finding(conn, prev, {
        "fingerprint": "e" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "t", "rationale": "an older engine's reading", "producer": "",
        "occurrences": [{"file": "a.py", "line": 1}]})
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    assert [(i["fingerprint"], i["kind"]) for i in units.triage_items(conn, aid)] == [("e" * 64, "carried")]


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
    assert ledger.units_of(conn, aid)[0]["payload"]["items"][0] == \
        {"fingerprint": "a" * 64, "kind": "scanner", "category": "sast", "severity": "high"}, \
        "each item keeps the severity its scanner filed: the triage floor is judged by it too"
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


def test_two_plans_of_one_analysis_racing_leave_exactly_one_plan(tmp_path):
    """I1. "No units yet" is asked INSIDE the transaction that writes the
    plan (ledger.add_units' guard). Asked before it, a second caller that
    planned the analysis whole between that check and this write left two
    plans: every slice read twice, every row triaged twice."""
    first, other = ledger.connect(tmp_path / "security.db"), ledger.connect(tmp_path / "security.db")
    aid = _analysis(first)
    _inventory(first, aid, [_file("a.py", (1, 10, 100))])
    raced = []

    def guides_while_another_plan_lands(ranges):
        if not raced:
            raced.append(units.plan(other, aid))
        return ["ATTACK-CLASSES"]
    try:
        assert units.plan(first, aid, slice_guides=guides_while_another_plan_lands) == []
        assert len(raced[0]) == 2, "the other caller planned it: a hunt and a read"
        assert [u["kind"] for u in ledger.units_of(first, aid)] == ["hunt", "read"]
    finally:
        first.close()
        other.close()


def test_a_deep_analysis_is_never_planned_without_its_inventory(conn):
    """I3. `inventory_of` reads a missing row and one that does not decode as
    {} -- to a planner, an empty repository: a deep plan with no read unit,
    and a debt (`owed`) of nothing. Refused instead, and the refusal writes
    nothing, so `prepare --plan` fails loudly."""
    aid = _analysis(conn)
    with pytest.raises(ValueError, match="no inventory"):
        units.plan(conn, aid)
    assert ledger.units_of(conn, aid) == []
    _inventory(conn, aid, [_file("a.py", (1, 10, 100))])
    conn.execute("UPDATE analysis_inventory SET doc='{not json' WHERE analysis_id=?", (aid,))
    conn.commit()
    with pytest.raises(ValueError, match="no inventory"):
        units.plan(conn, aid)
    assert ledger.units_of(conn, aid) == []


def test_a_deep_analysis_whose_inventory_lists_no_file_is_planned_without_reads(conn):
    """The nearest case the refusal above must not swallow: an inventory
    that was listed and holds no file is a scope, not a missing one."""
    aid = _analysis(conn)
    _inventory(conn, aid, [])
    units.plan(conn, aid)
    assert [u["kind"] for u in ledger.units_of(conn, aid)] == ["hunt"]


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


def test_two_verification_plans_racing_write_one_verify_unit_per_finding(tmp_path, monkeypatch):
    """I1. Which findings already have a verify unit is asked inside the
    transaction that writes the new ones. Read before the queue, a second
    caller that planned in between doubled every verification."""
    first, other = ledger.connect(tmp_path / "security.db"), ledger.connect(tmp_path / "security.db")
    aid = _analysis(first)
    _agent(first, aid, "a" * 64, "high")
    _agent(first, aid, "b" * 64, "medium")
    real, raced = queries.verify_queue, []

    def queue_while_another_plan_lands(c, analysis_id):
        if not raced:
            raced.append(None)
            raced.append(units.plan_verification(other, analysis_id))
        return real(c, analysis_id)
    monkeypatch.setattr(queries, "verify_queue", queue_while_another_plan_lands)
    try:
        assert units.plan_verification(first, aid) == []
        assert len(raced[1]) == 2, "the other caller planned both"
        fps = [u["payload"]["fingerprint"] for u in ledger.units_of(first, aid) if u["kind"] == "verify"]
        assert sorted(fps) == ["a" * 64, "b" * 64]
    finally:
        first.close()
        other.close()


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
    _agent(conn, aid, "a" * 64, "high", unit=uid)   # this unit's re-report marks the scanner row triaged
    _agent(conn, aid, "c" * 64, unit=uid)           # this unit re-checks the carried finding here
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


@pytest.mark.parametrize("writer", ["another unit", "operator", "subagent"])
def test_a_verify_unit_is_not_done_by_a_verdict_it_did_not_write(conn, writer):
    """C1. The hunter that minted the finding verifying it itself, the
    operator, a verifier from before the pipeline: a verdict on the row is
    this unit's work only when it carries this unit's id."""
    aid = _analysis(conn)
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    _agent(conn, aid, "a" * 64, "high", unit=hunt)
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    by = {"another unit": f"unit:{hunt}", "operator": "operator", "subagent": "subagent"}[writer]
    ledger.record_verdict(conn, aid, "a" * 64, "rejected", "not this unit's reading", by=by)
    done, remaining, ev, note = units.judge(conn, ledger.get_unit(conn, uid), _session(), "success")
    assert (done, ev["verdict"]) == (False, "")
    assert by in note, "the note says whose verdict it is, never that none was recorded"


def _fanned_out(conn, uid, tmp_path):
    """Close attempt `uid` as its engine would after a session that launched
    a subagent, and return the continuation it left."""
    stream = tmp_path / f"stream-{uid}.ndjson"
    stream.write_text(LAUNCH + "\n")
    out = units.close(conn, ledger.get_unit(conn, uid), stream=str(stream), root=str(tmp_path),
                      status="success")
    assert out["state"] == "incomplete"
    return ledger.get_unit(conn, out["continuation"])


def test_the_verdict_of_an_attempt_that_launched_a_subagent_is_cleared_at_its_close(conn, tmp_path):
    """C1. A verdict is written once (record_verdict's `verdict=''`), so the
    disqualified attempt's -- the subagent's, for all anyone can prove --
    left standing would close its continuation with no work done, and a
    `rejected` one would drop the finding from the exposure for good. Its
    close clears it; the continuation is done on the verdict IT writes."""
    aid = _analysis(conn)
    _agent(conn, aid, "a" * 64, "high")
    first = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    ledger.start_unit(conn, first)
    ledger.record_verdict(conn, aid, "a" * 64, "rejected", "a subagent's reading", by=f"unit:{first}")
    second = _fanned_out(conn, first, tmp_path)
    row = conn.execute("SELECT verdict, verdict_reason, verified_by FROM finding WHERE fingerprint=?",
                       ("a" * 64,)).fetchone()
    assert tuple(row) == ("", "", ""), "a verdict nobody can prove this unit reasoned does not stand"
    assert units.judge(conn, second, _session(), "success")[0] is False
    assert ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it", by=f"unit:{second['id']}")
    assert units.judge(conn, second, _session(), "success")[0] is True


@pytest.mark.parametrize("kind", ["scanner", "carried"])
def test_a_re_report_an_attempt_with_a_subagent_wrote_does_not_count_for_its_continuation(conn, tmp_path, kind):
    """C1. A re-report carries the unit whose session wrote it
    (`finding.unit`), and a unit is credited only with what carries its own
    id: what attempt 1 wrote while a subagent ran in its session leaves
    attempt 2 owing the row, until attempt 2 re-reports it itself."""
    if kind == "carried":
        prev = _analysis(conn, commit="c0")
        _agent(conn, prev, "a" * 64, "high")
        ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    if kind == "scanner":
        _scanner(conn, aid, "a" * 64, "high")
    item = {"fingerprint": "a" * 64, "kind": kind, "category": "sast"}
    first = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.start_unit(conn, first)
    _agent(conn, aid, "a" * 64, "high", unit=first)
    second = _fanned_out(conn, first, tmp_path)
    assert units.judge(conn, second, _session(), "success")[:2] == (False, {"items": [item]})
    _agent(conn, aid, "a" * 64, "high", unit=second["id"], rationale="attempt 2 read the handler itself")
    assert units.judge(conn, second, _session(), "success")[:2] == (True, None)


def test_a_severity_an_attempt_with_a_subagent_lowered_below_the_floor_settles_nothing(conn, tmp_path):
    """C1's neighbour. A scanner row below the floor needs no reading -- at
    the severity its SCANNER gave it, which the plan keeps in the item, as
    well as at the one it holds now. Attempt 1 re-reporting a `high` as
    `low` is a reading like any other, and letting it through the floor
    would credit attempt 2 with it. (The row the scanner itself filed low,
    and nobody touched, stays settled: see the triage test above.)"""
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "high")
    item = {"fingerprint": "a" * 64, "kind": "scanner", "category": "sast", "severity": "high"}
    first = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.start_unit(conn, first)
    _agent(conn, aid, "a" * 64, "low", unit=first)
    second = _fanned_out(conn, first, tmp_path)
    assert units.judge(conn, second, _session(), "success")[:2] == (False, {"items": [item]}), \
        "owed, and the continuation's item still carries the scanner's severity"
    _agent(conn, aid, "a" * 64, "low", unit=second["id"], rationale="attempt 2 read the handler itself")
    assert units.judge(conn, second, _session(), "success")[:2] == (True, None), \
        "its own re-report at `low` settles it"


@pytest.mark.parametrize("folded, owed", [("low", False), ("high", True)],
                         ids=["left below the floor", "raised into it"])
def test_a_scanner_row_another_unit_folded_into_is_owed_only_at_the_floor_or_above(
        conn, tmp_path, folded, owed):
    """I1 (round 2). A read unit folds what it finds into a known
    fingerprint, as its prompt tells it to. Judged by `triaged` alone, that
    made the `low` row the triage unit skipped -- as ITS prompt allows --
    that unit's debt, and the lineage ran again for a row nothing blocks
    on. Below the floor at BOTH severities -- the one its scanner filed
    (kept in the item) and the one it holds now -- a row needs nobody's
    reading, whoever wrote on it; raised into the floor, it is owed."""
    aid = _analysis(conn)
    _inventory(conn, aid, [_file("a.py", (1, 10, 100))])
    _scanner(conn, aid, "a" * 64, "high")
    _scanner(conn, aid, "b" * 64, "low")
    units.plan(conn, aid)
    by_kind = {u["kind"]: u for u in ledger.units_of(conn, aid)}
    triage, read = by_kind["triage"], by_kind["read"]
    ledger.start_unit(conn, triage["id"])
    ledger.start_unit(conn, read["id"])
    _agent(conn, aid, "a" * 64, "high", unit=triage["id"], rationale="the triage unit read it")
    _agent(conn, aid, "b" * 64, folded, unit=read["id"], rationale="the read unit folded its finding here")
    out = units.close(conn, ledger.get_unit(conn, triage["id"]), stream=_quiet(tmp_path),
                      root=str(tmp_path), status="success")
    if not owed:
        assert out == {"state": "done", "continuation": None}
        return
    assert out["state"] == "incomplete"
    assert ledger.get_unit(conn, out["continuation"])["payload"] == {"items": [
        {"fingerprint": "b" * 64, "kind": "scanner", "category": "sast", "severity": "low"}]}


def test_an_item_planned_without_its_scanner_s_severity_keeps_the_rule_it_had(conn):
    """The item's severity is what lets the floor look past who wrote on a
    row. An item without one -- built by hand, or planned before the plan
    kept it -- cannot tell the scanner's severity from an agent's, so it
    keeps the committed rule: the floor holds only while no re-report has
    written over the row (`triaged`)."""
    aid = _analysis(conn)
    _scanner(conn, aid, "c" * 64, "low")
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    _agent(conn, aid, "c" * 64, "low", unit=hunt, rationale="the hunt came across it")
    item = {"fingerprint": "c" * 64, "kind": "scanner", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    assert units.judge(conn, ledger.get_unit(conn, uid), _session(), "success")[:2] == (False, {"items": [item]})


def test_a_continuation_cannot_hand_back_the_sentence_its_disqualified_attempt_left(conn, tmp_path):
    """M2. The rubber-stamp gate armed only when `triaged` went 0 -> 1, so
    once a disqualified attempt had marked the row, its continuation could
    re-report it with that attempt's rationale -- its subagent's, for all
    anyone can prove -- byte for byte, and be credited: `finding.unit` then
    named the continuation. A write that moves a scanner's row to another
    unit is gated like a first one."""
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "high")
    item = {"fingerprint": "a" * 64, "kind": "scanner", "category": "sast", "severity": "high"}
    first = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.start_unit(conn, first)
    _agent(conn, aid, "a" * 64, "high", unit=first, rationale="the subagent's reading of it")
    second = _fanned_out(conn, first, tmp_path)
    with pytest.raises(ValueError, match="another session left on this row, handed back byte for byte"):
        _agent(conn, aid, "a" * 64, "high", unit=second["id"], rationale="the subagent's reading of it")
    assert units.judge(conn, second, _session(), "success")[:2] == (False, {"items": [item]}), \
        "the echo recorded nothing, so the row is still owed"
    _agent(conn, aid, "a" * 64, "high", unit=second["id"], rationale="attempt 2 read the handler itself")
    assert units.judge(conn, second, _session(), "success")[:2] == (True, None)


def test_a_report_gone_an_attempt_with_a_subagent_made_does_not_count_for_its_continuation(conn, tmp_path):
    """C1. `report-gone` is kept per unit (`unit_gone`), and the judge reads
    this unit's alone (ledger.gone_by): attempt 1's word is not attempt 2's."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    first = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.start_unit(conn, first)
    ledger.record_gone(conn, first, "c" * 64, "a subagent said so")
    second = _fanned_out(conn, first, tmp_path)
    assert units.judge(conn, second, _session(), "success")[:2] == (False, {"items": [item]})
    ledger.record_gone(conn, second["id"], "c" * 64, "the handler was deleted in this commit")
    assert units.judge(conn, second, _session({"a.py": [(1, 5)]}), "success")[:2] == (True, None), \
        "Fix 3: attempt 2's own claim is credited once attempt 2 also reads the file"


def test_a_gone_claim_is_owed_until_its_file_is_read_and_the_note_names_it(conn):
    """Fix 3. `report-gone` used to be credited on any non-empty reason, so a
    triage unit could mark a carried vulnerability `fixed` without ever
    reading the file it was in -- the one non-conservative triage outcome
    this tool has. Now the claim needs the file too: unread, with no
    checkout known (`root=""`, the judge's default), it stays owed and the
    note names the file; read by the session, it settles."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    unit = ledger.get_unit(conn, uid)
    done, remaining, ev, note = units.judge(conn, unit, _session(), "success")
    assert (done, remaining) == (False, {"items": [item]})
    assert "reported gone without reading a.py" in note
    done, remaining, ev, note = units.judge(conn, unit, _session({"a.py": [(1, 5)]}), "success")
    assert (done, remaining) == (True, None)


def test_a_gone_claim_is_settled_by_the_file_s_absence_only_when_the_checkout_is_known(conn, tmp_path):
    """The other half of the rule: a file gone from `root` needs no reading.
    But `root=""` -- the judge's default, "no checkout known" -- cannot tell
    absence from anything else, so it never settles a claim on its own: the
    same empty `tmp_path`, where `a.py` truly does not exist, settles the
    claim only once it is actually given as `root`."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    unit = ledger.get_unit(conn, uid)
    assert units.judge(conn, unit, _session(), "success")[:2] == (False, {"items": [item]}), \
        "no root given: absence cannot be checked"
    assert units.judge(conn, unit, _session(), "success", root=str(tmp_path))[:2] == (True, None), \
        "a.py does not exist in this checkout"


def test_a_close_against_a_checkout_that_is_gone_proves_no_absence(conn, tmp_path):
    """A unit's checkout is torn down when its run ends (run_cleanup, the
    orchestrator's sweep). A close handed a root that is no longer on disk
    -- the orchestrator judging a dead run by its stream's `cwd` -- must not
    read every claimed-gone file as absent from it: the claim stays owed, as
    with no checkout known, and a read still settles it."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.start_unit(conn, uid)
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    gone = tmp_path / "torn-down-checkout"
    out = units.close(conn, ledger.get_unit(conn, uid), stream=_quiet(tmp_path), root=str(gone),
                      status="success")
    assert out["state"] != "done", "a checkout that is gone proved a.py absent"
    assert "reported gone without reading a.py" in ledger.get_unit(conn, uid)["note"]


def test_a_gone_claim_for_a_finding_in_two_files_is_owed_until_both_are_accounted_for(conn, tmp_path):
    prev = _analysis(conn, commit="c0")
    ledger.record_finding(conn, prev, {
        "fingerprint": "c" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "t", "rationale": "the agent read it", "producer": "agent",
        "occurrences": [{"file": "a.py", "line": 3}, {"file": "b.py", "line": 9}]})
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "both handlers were deleted")
    unit = ledger.get_unit(conn, uid)
    (tmp_path / "b.py").write_text("x")   # exists: needs its own reading, unlike a.py below
    done, remaining, ev, note = units.judge(
        conn, unit, _session({"a.py": [(1, 5)]}), "success", root=str(tmp_path))
    assert (done, remaining) == (False, {"items": [item]})
    assert "reported gone without reading b.py" in note
    done, remaining, ev, note = units.judge(
        conn, unit, _session({"a.py": [(1, 5)], "b.py": [(1, 1)]}), "success", root=str(tmp_path))
    assert (done, remaining) == (True, None)


def test_a_gone_claim_s_occurrence_outside_the_checkout_is_never_settled_by_absence(conn, tmp_path):
    """An occurrence's `file` is unvalidated data from a previous analysis --
    nothing upstream refuses a `..` escape or an absolute path when it is
    written. Such a path is not "gone from the checkout": were it joined
    onto `root` raw, a path built to exist nowhere would settle the claim by
    an absence that never checked this repository at all. `_unread_files`
    reuses `evidence.relative_path`'s own containment rule instead, so the
    claim stays owed -- exactly as if `root` were unknown."""
    prev = _analysis(conn, commit="c0")
    ledger.record_finding(conn, prev, {
        "fingerprint": "c" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "t", "rationale": "the agent read it", "producer": "agent",
        "occurrences": [{"file": "../../../../nonexistent-outside-the-checkout-xyz", "line": 1}]})
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    unit = ledger.get_unit(conn, uid)
    done, remaining, ev, note = units.judge(conn, unit, _session(), "success", root=str(tmp_path))
    assert (done, remaining) == (False, {"items": [item]}), \
        "an escaping path is not 'gone from the checkout' -- it is unaccounted for"


def test_a_gone_claim_on_a_finding_with_no_stored_occurrence_stays_owed(conn):
    """Fix 4. Nothing to check is not a passed check -- the same fail-closed
    rule `_unread_files` already applies to a race between two units (see
    its own docstring). A carried `sast` row with ZERO stored occurrences
    (planted here by raw SQL: `ledger.record_finding` itself now refuses to
    write one, round 4's other half of this fix -- so the only way such a
    row still exists is a row written before that door existed) settled a
    `gone` claim VACUOUSLY before this fix: `_unread_files([], ...)` returns
    `[]`, indistinguishable from a finding whose every file WAS read or IS
    gone. Now it stays owed, with a note that says there was nothing to
    verify -- absence of evidence is not evidence of absence."""
    prev = _analysis(conn, commit="c0")
    with conn:
        conn.execute(
            "INSERT INTO finding (analysis_id, fingerprint, category, rule, severity, title,"
            " rationale, producer) VALUES (?,?,?,?,?,?,?,?)",
            (prev, "c" * 64, "sast", "xss", "medium", "t", "the agent read it", "agent"))
    ledger.finish_analysis(conn, prev, "done")
    assert ledger.findings_of(conn, prev)[0]["occurrences"] == [], \
        "the planted row really has no stored occurrence"
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "vacuous reason, nothing to read")
    unit = ledger.get_unit(conn, uid)
    # No session read could ever settle this claim -- there is no file to
    # read in the first place -- so even a session that "read everything"
    # must leave it owed.
    done, remaining, ev, note = units.judge(
        conn, unit, _session({"a.py": [(1, 999)], "b.py": [(1, 999)]}), "success")
    assert (done, remaining) == (False, {"items": [item]})
    assert "no recorded location to verify" in note


def test_a_gone_claim_s_read_check_normalises_an_absolute_occurrence_path(conn, tmp_path):
    """Minor 3. `session.reads`'s keys are canonical -- relative to `root`,
    the same normal form `evidence.relative_path` produces (see `security
    read`, which is what populates them). A stored occurrence's own `file`
    is unvalidated data from a PREVIOUS analysis and may be absolute; an
    absolute occurrence path INSIDE `root` that THIS unit actually did read
    must still count as read, not stay owed because the raw string never
    matched the canonical key."""
    prev = _analysis(conn, commit="c0")
    root = tmp_path / "repo"
    root.mkdir()
    (root / "a.py").write_text("x = 1\n")
    ledger.record_finding(conn, prev, {
        "fingerprint": "c" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "t", "rationale": "the agent read it", "producer": "agent",
        "occurrences": [{"file": str(root / "a.py"), "line": 3}]})
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    item = {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}
    uid = ledger.add_unit(conn, aid, "triage", {"items": [item]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    unit = ledger.get_unit(conn, uid)
    # `session.reads` carries the CANONICAL key ("a.py"), the way `security
    # read` records it -- never the absolute path the stored occurrence
    # happens to carry.
    done, remaining, ev, note = units.judge(
        conn, unit, _session({"a.py": [(1, 5)]}), "success", root=str(root))
    assert (done, remaining) == (True, None), \
        "an absolute occurrence path inside root, once read, must count as read"


def test_a_gone_claim_s_file_served_by_security_read_counts_like_a_stream_read(conn, tmp_path):
    """`security read`'s own record (`ledger.unit_reads`, joined onto the
    session by `with_served` before `close` ever judges) is the only proof
    of reading on a platform whose shell reads cannot be proven from the
    stream (Codex) -- a gone claim is provable from it exactly as from a
    Read tool call."""
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}]})
    ledger.start_unit(conn, uid)
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    ledger.record_unit_read(conn, uid, "a.py", 1, 3)      # what `security read` served it
    out = units.close(conn, ledger.get_unit(conn, uid), stream=_quiet(tmp_path), status="success")
    assert out == {"state": "done", "continuation": None}


@pytest.mark.parametrize("status, reason, done", [
    ("success", "", True),
    ("warning", "stderr had 3 bytes", True),
    ("warning", "UNDECLARED ENDING: no run-ending line", False),
    ("warning", "BUDGET LIMITED: spent $1 of a $1 cap", False),
    ("warning", "UNDELIVERED: the run made changes that exist on no remote", False),
    ("error", "", False),
    ("stopped", "", False),
])
def test_a_hunt_is_done_when_its_run_worked(conn, status, reason, done):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    assert units.judge(conn, ledger.get_unit(conn, uid), _session(), status, reason)[0] is done


def test_every_mark_that_truncates_a_hunt_is_one_the_engine_writes_into_its_reason():
    """`_TRUNCATED` mirrors the `wdreason` strings `run_classify` (bin/agentloop)
    writes when a run ended without finishing -- BUDGET LIMITED, UNDECLARED
    ENDING -- and `wt_undelivered_work`'s UNDELIVERED. That reason is what
    `unit-close --reason` passes on, unread by the engine itself since Task
    11 removed its own case pattern over it: `judge` (bin/security/units.py,
    `_judge_hunt`) is the only reader left, matching `mark in reason`. A mark
    renamed on the engine's side and not here -- or vice versa -- would let a
    truncated hunt's warning read as a pass, so the suite pins each mark to
    the exact prefix the engine writes."""
    engine = ENGINE.read_text()
    for mark in units._TRUNCATED:
        assert f"{mark}: " in engine, f"{mark!r} is not a reason prefix the engine writes"


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


def test_a_second_conclude_of_one_unit_plans_no_second_continuation(conn):
    """I2. Two closes of one unit -- its engine's and the orchestrator's --
    used to settle it once and continue it twice: the settle's own guard
    refused the second, and nobody read what it said."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    unit = ledger.get_unit(conn, uid)
    first = units.conclude(conn, unit, done=False, evidence={}, note="n", spend_usd=0)
    again = units.conclude(conn, unit, done=False, evidence={}, note="n", spend_usd=0)
    assert first["state"] == "incomplete" and first["continuation"]
    assert again == {"state": "incomplete", "continuation": None}
    assert len(ledger.units_of(conn, aid)) == 2, "the unit and ONE continuation"


def test_a_conclude_over_a_unit_settled_elsewhere_reports_what_the_ledger_holds(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    unit = ledger.get_unit(conn, uid)
    ledger.settle_unit(conn, uid, "done", 0, {}, "settled by another close")
    assert units.conclude(conn, unit, done=False, evidence={}, note="n", spend_usd=0) == \
        {"state": "done", "continuation": None}
    assert [u["id"] for u in ledger.units_of(conn, aid)] == [uid], "nothing planned over a done unit"


def test_a_unit_is_settled_and_its_continuation_planned_together_or_not_at_all(conn):
    """I2. Two commits used to do it: a kill between them left the unit
    `incomplete` with no continuation -- nothing relaunched it and no gap
    named it. One transaction now: a continuation that cannot be written
    (here, a payload JSON cannot encode) leaves the unit as it was."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 9, "bytes": 1}]})
    ledger.start_unit(conn, uid)

    class NotJson:
        pass
    with pytest.raises(TypeError):
        units.conclude(conn, ledger.get_unit(conn, uid), done=False, evidence={}, note="n",
                       spend_usd=1.0, remaining={"ranges": NotJson()})
    unit = ledger.get_unit(conn, uid)
    assert (unit["state"], unit["spend_usd"]) == ("running", 0.0), "the settle rolled back with it"
    assert [u["id"] for u in ledger.units_of(conn, aid)] == [uid]


def test_the_label_names_the_kind_its_place_and_the_attempt(conn):
    aid = _analysis(conn)
    first = ledger.add_unit(conn, aid, "read", {"ranges": []})
    ledger.add_unit(conn, aid, "read", {"ranges": []})
    cont = ledger.add_unit(conn, aid, "read", {"ranges": []}, attempt=2, parent=first)
    assert units.label(conn, ledger.get_unit(conn, first)) == "read 1/2"
    assert units.label(conn, ledger.get_unit(conn, cont)) == "read 1/2 · attempt 2"


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
    assert s["deep"] == {"files": 2, "files_read": 1, "files_empty": 0, "lines": 15, "lines_read": 10}
    assert (s["spend_usd"], s["units"]) == (1.5, 3)


def test_the_summary_never_counts_an_empty_file_as_read_before_any_unit_ran(conn):
    """An empty file is listed with no `ranges` (inventory.py `build`), so
    `owed` never names it missing anything -- it must not count towards
    `files`/`files_read` either, or the page would say files were "read in
    full" before a single read unit ran. It is reported apart, as
    `files_empty`, so the two totals still add up to the inventory's own
    file count."""
    empty = {"path": "empty.py", "lines": 0, "bytes": 0, "ranges": []}
    ledger.set_inventory(conn, aid := _analysis(conn),
                         {"files": [_file("a.py", (1, 10, 100)), empty],
                          "excluded": {}, "git": True,
                          "totals": {"files": 2, "lines": 10, "bytes": 100}})
    s = units.summary(conn, aid)
    assert s["deep"] == {"files": 1, "files_read": 0, "files_empty": 1, "lines": 10, "lines_read": 0}


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


def test_unit_reads_since_keeps_only_rows_recorded_at_or_after_it(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 9, "bytes": 1}]})
    conn.execute("INSERT INTO unit_read (unit_id, path, first, last, at) VALUES (?,?,?,?,?)",
                 (uid, "a.py", 1, 3, 100))
    conn.execute("INSERT INTO unit_read (unit_id, path, first, last, at) VALUES (?,?,?,?,?)",
                 (uid, "a.py", 4, 9, 200))
    conn.commit()
    assert ledger.unit_reads(conn, uid) == [("a.py", 1, 3), ("a.py", 4, 9)]
    assert ledger.unit_reads(conn, uid, since=200) == [("a.py", 4, 9)]
    assert ledger.unit_reads(conn, uid, since=150) == [("a.py", 4, 9)]


def test_close_counts_only_reads_recorded_since_this_run_started(conn, tmp_path):
    """Minor 1. `reset_unit` sends a unit whose run died back to `pending`
    without clearing its id or its `started` -- so a chunk `security read`
    recorded for that dead run is still on `unit_read` under the same unit
    id once it is relaunched. `close` must credit only what was served
    since THIS run's own `started`, set fresh by `start_unit` on every
    launch."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 9, "bytes": 1}]})
    conn.execute("INSERT INTO unit_read (unit_id, path, first, last, at) VALUES (?,?,?,?,?)",
                 (uid, "a.py", 1, 3, 100))                  # served to the run that died
    conn.execute("UPDATE unit SET state='running', started=200 WHERE id=?", (uid,))   # relaunched
    conn.execute("INSERT INTO unit_read (unit_id, path, first, last, at) VALUES (?,?,?,?,?)",
                 (uid, "a.py", 4, 9, 250))                  # what THIS run actually served
    conn.commit()
    out = units.close(conn, ledger.get_unit(conn, uid), stream=_quiet(tmp_path), status="success")
    assert out["state"] == "incomplete", "lines 1-3 are still owed, not credited to this run"
    assert ledger.get_unit(conn, uid)["evidence"]["covered"] == {"a.py": [[4, 9]]}, \
        "lines 1-3 were served to the run that died, not to this one"
    cont = ledger.get_unit(conn, out["continuation"])
    assert cont["payload"]["ranges"] == [{"path": "a.py", "first": 1, "last": 3, "bytes": 0}]


def test_close_judges_a_run_and_settles_its_unit_once(conn, tmp_path):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 3, "bytes": 9}]})
    ledger.start_unit(conn, uid)
    ledger.record_unit_read(conn, uid, "a.py", 1, 3)       # what `security read` served it
    out = units.close(conn, ledger.get_unit(conn, uid), stream=_quiet(tmp_path), status="success",
                      spend_usd=0.5)
    assert out == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["evidence"]["covered"] == {"a.py": [[1, 3]]}
    again = units.close(conn, ledger.get_unit(conn, uid), status="error", spend_usd=9)
    assert again == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["spend_usd"] == 0.5, "a settled unit is never closed twice"


def test_a_close_over_a_unit_settled_elsewhere_touches_nothing_not_even_its_verdict(conn, tmp_path):
    """The nearest case the clearing of a disqualified verdict must not
    reach: a close holding an old copy of a unit another close already
    settled `done`. It reports what the ledger holds, and the verdict that
    unit was credited with stays."""
    aid = _analysis(conn)
    _agent(conn, aid, "a" * 64, "high")
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    ledger.start_unit(conn, uid)
    stale = ledger.get_unit(conn, uid)
    ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it", by=f"unit:{uid}")
    ledger.settle_unit(conn, uid, "done", 0, {"verdict": "confirmed"}, "Verdict: confirmed.")
    stream = tmp_path / "late.ndjson"
    stream.write_text(LAUNCH + "\n")
    out = units.close(conn, stale, stream=str(stream), root=str(tmp_path), status="success")
    assert out == {"state": "done", "continuation": None}
    assert tuple(conn.execute("SELECT verdict, verified_by FROM finding WHERE fingerprint=?",
                              ("a" * 64,)).fetchone()) == ("confirmed", f"unit:{uid}")
    assert [u["id"] for u in ledger.units_of(conn, aid)] == [uid]


@pytest.mark.parametrize("lands", ["before this close judges", "after this close judged"])
def test_two_closes_of_one_verify_unit_interleaved_never_leave_it_done_without_its_verdict(
        tmp_path, monkeypatch, lands):
    """M1. The close of a session that launched a subagent clears the
    verdict its unit wrote -- and it used to clear it on its own, before the
    settle. A second close of the same unit whose stream shows no subagent
    (a copy that lost the launch) settled it `done` on that verdict in between, and the first
    then took the verdict away: a `done` verify unit with no verdict. The
    clear now lands inside the settle's transaction, and only if the settle
    takes effect: the first close finds the unit settled and touches
    nothing. (A close that lands whole first is the sequential case the
    tests above cover: `incomplete`, the verdict cleared, a continuation.)"""
    db = tmp_path / "security.db"
    mine, other = ledger.connect(db), ledger.connect(db)
    aid = _analysis(mine)
    _agent(mine, aid, "a" * 64, "high")
    uid = ledger.add_unit(mine, aid, "verify", {"fingerprint": "a" * 64})
    ledger.start_unit(mine, uid)
    ledger.record_verdict(mine, aid, "a" * 64, "rejected", "a subagent's reading", by=f"unit:{uid}")
    stream = tmp_path / "fanned.ndjson"
    stream.write_text(LAUNCH + "\n")
    theirs = []

    def the_other_close_lands():
        # A stream that shows no subagent -- a close that sees none.
        theirs.append(units.close(other, ledger.get_unit(other, uid), stream=_quiet(tmp_path),
                                  root=str(tmp_path), status="success"))

    if lands == "before this close judges":
        real_read, started = evidence.read_session, []

        def read_session(path, root):
            if not started and path:
                started.append(True)                # the other close reads a stream too
                the_other_close_lands()
            return real_read(path, root)
        monkeypatch.setattr(evidence, "read_session", read_session)
    else:
        real_judge, landed = units.judge, []

        def judge(*args, **kwargs):
            judged = real_judge(*args, **kwargs)
            if not landed:
                landed.append(True)
                the_other_close_lands()
            return judged
        monkeypatch.setattr(units, "judge", judge)
    try:
        ours = units.close(mine, ledger.get_unit(mine, uid), stream=str(stream), root=str(tmp_path),
                           status="success")
        assert theirs == [{"state": "done", "continuation": None}], "the close whose stream shows no subagent"
        assert ours == {"state": "done", "continuation": None}, "and this one found the unit settled"
        assert _verdict(mine, "a" * 64) == ("rejected", f"unit:{uid}"), \
            "a verify unit settled `done` keeps the verdict it was credited with"
        assert [u["id"] for u in ledger.units_of(mine, aid)] == [uid]
    finally:
        mine.close()
        other.close()


def test_a_close_cut_short_inside_its_settle_takes_the_clear_back_with_it(conn, tmp_path):
    """M1, and the kill-safety clearing first used to buy. The clear and the
    settle are one transaction now, so a close cut short anywhere in it --
    here, at the insert of the continuation -- leaves both undone: the unit
    still running, its verdict as it was. Never a unit settled while its
    disqualified verdict still stands (a continuation the write-once guard
    would lock out), never a verdict cleared under a unit that stays
    unsettled. The next close does both."""
    aid = _analysis(conn)
    _agent(conn, aid, "a" * 64, "high")
    uid = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    ledger.start_unit(conn, uid)
    ledger.record_verdict(conn, aid, "a" * 64, "rejected", "a subagent's reading", by=f"unit:{uid}")
    stream = tmp_path / "fanned.ndjson"
    stream.write_text(LAUNCH + "\n")
    conn.execute("CREATE TEMP TRIGGER cut_short BEFORE INSERT ON unit"
                 " BEGIN SELECT RAISE(ABORT, 'killed mid-close'); END")
    with pytest.raises(sqlite3.IntegrityError, match="killed mid-close"):
        units.close(conn, ledger.get_unit(conn, uid), stream=str(stream), root=str(tmp_path), status="success")
    conn.execute("DROP TRIGGER cut_short")
    assert ledger.get_unit(conn, uid)["state"] == "running"
    assert _verdict(conn, "a" * 64) == ("rejected", f"unit:{uid}"), "the clear rolled back with the settle"
    assert [u["id"] for u in ledger.units_of(conn, aid)] == [uid]
    out = units.close(conn, ledger.get_unit(conn, uid), stream=str(stream), root=str(tmp_path), status="success")
    assert (out["state"], _verdict(conn, "a" * 64)) == ("incomplete", ("", ""))
    cont = ledger.get_unit(conn, out["continuation"])
    assert ledger.record_verdict(conn, aid, "a" * 64, "confirmed", "read it", by=f"unit:{cont['id']}")
    assert units.judge(conn, cont, _session(), "success")[0] is True


def _read_tool_stream(tmp_path, path, first, count):
    """A Read tool result proving lines first..first+count-1 of `path`."""
    import json
    events = [{"type": "system", "subtype": "init", "cwd": str(tmp_path)},
              {"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
                  {"type": "tool_use", "id": "t1", "name": "Read",
                   "input": {"file_path": str(tmp_path / path)}}]}},
              {"type": "user", "parent_tool_use_id": None,
               "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": ""}]},
               "tool_use_result": {"type": "text", "file": {"filePath": str(tmp_path / path),
                                                            "startLine": first, "numLines": count,
                                                            "totalLines": first + count - 1}}}]
    stream = tmp_path / "read.stream.ndjson"
    stream.write_text("".join(json.dumps(e) + "\n" for e in events))
    return str(stream)


def test_a_line_the_read_tool_cuts_is_not_proven_read_by_its_result(conn, tmp_path):
    """I5. A Read result counts a line past 2,000 characters among its
    `numLines` while showing only its head. Under `!defaults` the inventory
    names such lines (`wide`), and a Read result never proves them: only
    `security read`, which shows a line whole or not at all, does."""
    aid = _analysis(conn)
    entry = _file("a.py", (1, 3, 5000))
    entry["wide"] = [2]
    _inventory(conn, aid, [entry])
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 3,
                                                          "bytes": 5000}]})
    ledger.start_unit(conn, uid)
    stream = _read_tool_stream(tmp_path, "a.py", 1, 3)
    out = units.close(conn, ledger.get_unit(conn, uid), stream=stream, root=str(tmp_path),
                      status="success")
    assert out["state"] == "incomplete"
    assert ledger.get_unit(conn, uid)["evidence"]["covered"] == {"a.py": [[1, 1], [3, 3]]}
    cont = ledger.get_unit(conn, out["continuation"])
    assert cont["payload"]["ranges"] == [{"path": "a.py", "first": 2, "last": 2, "bytes": 0}]
    # The continuation reads the wide line through `security read`: proven.
    ledger.start_unit(conn, cont["id"])
    ledger.record_unit_read(conn, cont["id"], "a.py", 2, 2)
    again = units.close(conn, ledger.get_unit(conn, cont["id"]), stream=stream, root=str(tmp_path),
                        status="success")
    assert again == {"state": "done", "continuation": None}


def test_without_lines_cuts_named_lines_out_of_every_span():
    session = evidence.Session(reads={"a.py": [(1, 10)], "b.py": [(1, 2)]})
    out = evidence.without_lines(session, {"a.py": [1, 5, 10, 99]})
    assert out.reads == {"a.py": [(2, 4), (6, 9)], "b.py": [(1, 2)]}
    assert evidence.without_lines(session, {}) is session


def test_a_run_whose_agent_never_started_keeps_its_attempt_and_names_the_error(conn):
    """Analysis 12 (2026-09-26): OpenCode failed every boot of the project,
    and each run spent one of its unit's three attempts. Nothing ran, so
    nothing is the unit's fault: the close keeps the attempt, as it does for
    a provider outage, and the unit's note carries the agent's own words."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    out = units.close(conn, ledger.get_unit(conn, uid), status="error", cause=units.START_FAILED,
                      reason="START FAILED: BadResource: FileSystem.access (/gone/repo)")
    assert out["state"] == "incomplete"
    unit = ledger.get_unit(conn, uid)
    assert unit["evidence"]["cause"] == "start_failed"
    assert unit["evidence"]["error"] == "BadResource: FileSystem.access (/gone/repo)"
    assert unit["note"] == ("The agent could not start (BadResource: FileSystem.access (/gone/repo)); "
                            "nothing ran, so the attempt is kept.")
    assert ledger.get_unit(conn, out["continuation"])["attempt"] == 1


def test_a_run_killed_with_no_stream_still_spends_its_attempt(conn):
    """The control: only the causes that are nobody's fault keep it."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    out = units.close(conn, ledger.get_unit(conn, uid), status="error", cause="killed")
    assert ledger.get_unit(conn, out["continuation"])["attempt"] == 2
    assert "cause" not in ledger.get_unit(conn, uid)["evidence"]


def test_the_start_error_is_the_agents_words_without_the_engines_prefix():
    assert units.start_error("START FAILED: BadResource: x") == "BadResource: x"
    assert units.start_error("BadResource: x") == "BadResource: x"
    assert units.start_error("") == "no reason given"
    assert len(units.start_error("START FAILED: " + "y" * 900)) == 300


def _failed_hunt(conn, aid):
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    ledger.settle_unit(conn, uid, "failed", 0, {}, "The engine could not run this unit.")
    return uid


def test_a_retry_is_for_the_newest_closed_analysis_of_its_branch_with_a_lineage_that_gave_up(conn):
    aid = _analysis(conn)
    uid = _failed_hunt(conn, aid)
    assert units.retry_refusal(conn, aid) == "is running: only a capped or failed analysis is retried"
    ledger.finish_analysis(conn, aid, "capped")
    assert units.retry_refusal(conn, aid) == ""
    assert units.retryable(conn, aid) == 1
    assert [u["id"] for u in units.failed_lineages(conn, aid)] == [uid]
    ledger.start_analysis(conn, "web", "web", "feature", "c2", "deep", "security-web")
    assert units.retry_refusal(conn, aid) == "", "another branch does not supersede it"
    newer = _analysis(conn)
    assert units.retry_refusal(conn, aid) == (f"was superseded by analysis {newer} of the same branch: "
                                              "run Analyse again instead")
    assert units.retryable(conn, aid) == 0


def test_a_closed_analysis_where_nothing_gave_up_has_nothing_to_retry(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    ledger.settle_unit(conn, uid, "done", 0, {}, "ok")
    ledger.finish_analysis(conn, aid, "capped")
    assert units.retry_refusal(conn, aid) == "has no unit that gave up: there is nothing to retry"
    assert units.retryable(conn, aid) == 0
    done = ledger.start_analysis(conn, "web", "web", "other", "c3", "deep", "security-web")
    _failed_hunt(conn, done)
    ledger.finish_analysis(conn, done, "done")
    assert units.retry_refusal(conn, done) == "is done: only a capped or failed analysis is retried"


def test_a_lineage_retried_is_judged_by_its_new_last_unit(conn):
    """The close judges a lineage by its last unit (units._lineages): once a
    child hangs off the failed leaf, the leaf is history, not a gap."""
    aid = _analysis(conn)
    uid = _failed_hunt(conn, aid)
    ledger.finish_analysis(conn, aid, "capped")
    assert ledger.reopen_analysis(conn, aid, units.failed_lineages(conn, aid), "n") is True
    assert units.failed_lineages(conn, aid) == []
    assert not [g for g in units.gaps(conn, aid) if "gave up" in g]
    assert ledger.get_unit(conn, uid)["state"] == "failed", "the leaf stays what it was"


def test_the_retry_sentence_says_when_and_how_many():
    assert units.retry_sentence(1, day="2026-09-27") == (
        "Retried on 2026-09-27: 1 unit that had given up was run again.")
    assert units.retry_sentence(231, day="2026-09-27") == (
        "Retried on 2026-09-27: 231 units that had given up were run again.")


def test_the_close_part_starts_at_the_units_sentence(conn):
    aid = _analysis(conn)
    _failed_hunt(conn, aid)
    head = "Scope and secrets as prepare wrote them."
    closed = f"{head} {units.coverage_sentence(conn, aid)} {' '.join(units.gaps(conn, aid))}".strip()
    assert closed[:units.close_part_start(conn, aid, closed)].strip() == head
    assert units.close_part_start(conn, aid, head) == len(head), "nothing of a close in it: all kept"
