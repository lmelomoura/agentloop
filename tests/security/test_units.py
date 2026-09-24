# tests/security/test_units.py
"""The pipeline's units: what the plan holds, what runs next, and how a unit is judged."""
import pytest

from security import cli as security_cli
from security import evidence, ledger, units


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


def _agent(conn, aid, fp, severity="medium", unit=0):
    ledger.record_finding(conn, aid, {
        "fingerprint": fp, "category": "sast", "rule": "xss", "severity": severity,
        "title": "t", "rationale": "the agent read it", "producer": "agent", "unit": unit,
        "occurrences": [{"file": "a.py", "line": 3}]})


def _inventory(conn, aid, files):
    ledger.set_inventory(conn, aid, {"files": files, "excluded": {}, "git": True,
                                     "totals": {"files": len(files), "lines": 0, "bytes": 0}})


def _file(path, *ranges):
    return {"path": path, "lines": ranges[-1][1], "bytes": sum(r[2] for r in ranges),
            "ranges": [list(r) for r in ranges]}


def test_the_triage_floor_is_the_close_s_own():
    assert units.BLOCKING == security_cli.TRIAGE_BLOCKING


def test_a_carried_sast_finding_reported_gone_is_settled_and_a_deterministic_one_is_not(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"},
        {"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]})
    ledger.record_gone(conn, uid, "c" * 64, "the handler was deleted")
    ledger.record_gone(conn, uid, "d" * 64, "not how a dependency row is settled")
    done, remaining, ev, note = units.judge(conn, ledger.get_unit(conn, uid), _session(), "success")
    assert remaining == {"items": [{"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]}


def test_triage_owes_every_open_scanner_row_and_every_agent_finding_left_open(conn):
    prev = _analysis(conn, commit="c0")
    _agent(conn, prev, "c" * 64)
    ledger.finish_analysis(conn, prev, "done")
    aid = _analysis(conn)
    _scanner(conn, aid, "a" * 64, "low")
    _scanner(conn, aid, "b" * 64, "critical")
    items = units.triage_items(conn, aid)
    assert [(i["fingerprint"][0], i["kind"]) for i in items] == [("b", "scanner"), ("c", "carried"), ("a", "scanner")]


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
    _agent(conn, aid, "a" * 64, "high")   # the agent's re-report marks the scanner row triaged
    _agent(conn, aid, "c" * 64)           # the carried finding is re-checked in this analysis
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


@pytest.mark.parametrize("status, reason, done", [
    ("success", "", True),
    ("warning", "stderr had 3 bytes", True),
    ("warning", "UNDECLARED ENDING: no run-ending line", False),
    ("warning", "BUDGET LIMITED: spent $1 of a $1 cap", False),
    ("error", "", False),
    ("stopped", "", False),
])
def test_a_hunt_is_done_when_its_run_worked(conn, status, reason, done):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    assert units.judge(conn, ledger.get_unit(conn, uid), _session(), status, reason)[0] is done


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
    assert s["deep"] == {"files": 2, "files_read": 1, "lines": 15, "lines_read": 10}
    assert (s["spend_usd"], s["units"]) == (1.5, 3)


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


def test_close_judges_a_run_and_settles_its_unit_once(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 3, "bytes": 9}]})
    ledger.start_unit(conn, uid)
    ledger.record_unit_read(conn, uid, "a.py", 1, 3)       # what `security read` served it
    out = units.close(conn, ledger.get_unit(conn, uid), status="success", spend_usd=0.5)
    assert out == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["evidence"]["covered"] == {"a.py": [[1, 3]]}
    again = units.close(conn, ledger.get_unit(conn, uid), status="error", spend_usd=9)
    assert again == {"state": "done", "continuation": None}
    assert ledger.get_unit(conn, uid)["spend_usd"] == 0.5, "a settled unit is never closed twice"
