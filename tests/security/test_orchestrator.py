# tests/security/test_orchestrator.py
"""The orchestrator: every unit run to the end, continued when it falls short, and the analysis closed from the proof."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
from test_cli import open_analysis, run

from security import ledger, orchestrator

FAKE = Path(__file__).parent / "fixtures" / "fake-engine"
GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


@pytest.fixture
def world(tmp_path, monkeypatch):
    """A git repository, an open deep analysis of it, and the fake engine's environment."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True, env=GIT_ENV)
    (repo / "src").mkdir()
    (repo / "src" / "a.py").write_text("".join(f"x{n} = {n}\n" for n in range(40)))
    (repo / "src" / "b.py").write_text("y = 1\n")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True,
                         text=True, check=True).stdout.strip()
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep", commit=sha)
    monkeypatch.setenv("FAKE_ENGINE_DB", str(db))
    monkeypatch.setenv("FAKE_ENGINE_STOP", str(tmp_path / "stop-marker"))
    monkeypatch.setenv("FAKE_ENGINE_LOG_ROOT", str(tmp_path / "logs"))
    monkeypatch.setenv("TMPDIR", str(tmp_path))
    return {"db": db, "aid": aid, "repo": repo, "sha": sha, "tmp": tmp_path}


def _kwargs(world, **kw):
    base = dict(engine=str(FAKE), job="security-web", commit=world["sha"], repo="web",
                repo_path=str(world["repo"]), prepare_root=str(world["tmp"] / "prepare"),
                log_root=str(world["tmp"] / "logs"), poll=0.05, offline=True)
    base.update(kw)
    return base


def _orchestrator(world, **kw):
    return orchestrator.Orchestrator(world["db"], world["aid"], **_kwargs(world, **kw))


def _spawn(world, **kw):
    """The orchestrator in a process of its own, as the engine runs it -- so a
    test can send it the signal a stop sends."""
    code = (f"import sys; sys.path.insert(0, {str(Path(orchestrator.__file__).parents[1])!r});"
            "from security import orchestrator as o;"
            f"sys.exit(o.Orchestrator({str(world['db'])!r}, {world['aid']}, "
            f"**{_kwargs(world, **kw)!r}).run())")
    return subprocess.Popen([sys.executable, "-c", code], env=os.environ.copy())


def _row(world):
    return next(r for r in run(world["db"], "list", "--project", "web") if r["id"] == world["aid"])


def _units(world):
    return ledger.units_of(ledger.connect(world["db"]), world["aid"])


def _last_attempts(world):
    """{lineage root id: its last unit} -- how a lineage ended."""
    all_units = _units(world)
    children = {}
    for u in all_units:
        if u["parent"]:
            children.setdefault(u["parent"], []).append(u)
    out = {}
    for root in (u for u in all_units if not u["parent"]):
        last = root
        while children.get(last["id"]):
            last = max(children[last["id"]], key=lambda c: c["seq"])
        out[root["id"]] = last
    return out


def _read_events(ranges, root="/Users/me/run"):
    """A stream reading every range, in the shape the fake engine writes."""
    events = [{"type": "system", "subtype": "init", "cwd": root}]
    for n, r in enumerate(ranges):
        path = f"{root}/{r['path']}"
        events.append({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
            {"type": "tool_use", "id": f"t{n}", "name": "Read", "input": {"file_path": path}}]}})
        events.append({"type": "user", "parent_tool_use_id": None,
                       "message": {"content": [{"type": "tool_result", "tool_use_id": f"t{n}", "content": ""}]},
                       "tool_use_result": {"type": "text", "file": {
                           "filePath": path, "startLine": r["first"],
                           "numLines": r["last"] - r["first"] + 1, "totalLines": r["last"]}}})
    return "".join(json.dumps(e) + "\n" for e in events)


def test_it_prepares_runs_every_unit_verifies_what_was_found_and_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_FIND", "1")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    kinds = sorted(u["kind"] for u in _units(world))
    assert "hunt" in kinds and "read" in kinds and "verify" in kinds
    assert all(u["state"] == "done" for u in _units(world))
    assert row["state"] == "done", row["coverage_note"]
    assert row["spend_usd"] == pytest.approx(0.1 * len(_units(world)))
    assert not (world["tmp"] / "prepare" / f"security-web-{world['aid']}").exists()


def test_the_prepare_worktree_is_its_own_and_a_leftover_is_cleared_first(world):
    """OUTSIDE the run worktrees, which the tick's orphan sweep adopts and tears
    down and the dashboard walks on every poll. A leftover a dead prepare left
    at the path is cleared before the checkout is cut, and nothing -- neither
    the directory nor git's registration of it -- outlives the phase."""
    leftover = world["tmp"] / "prepare" / f"security-web-{world['aid']}"
    leftover.mkdir(parents=True)
    (leftover / "stale.txt").write_text("from a prepare that died\n")
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]
    assert not leftover.exists()
    listed = subprocess.run(["git", "-C", str(world["repo"]), "worktree", "list", "--porcelain"],
                            capture_output=True, text=True, check=True).stdout
    assert listed.count("worktree ") == 1, f"only the repository's own checkout is registered: {listed}"


def test_a_read_that_fell_short_is_continued_and_the_analysis_still_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "skip-first")
    _orchestrator(world).run()
    reads = [u for u in _units(world) if u["kind"] == "read"]
    assert any(u["attempt"] == 2 and u["state"] == "done" for u in reads)
    assert _row(world)["state"] == "done"


def test_units_whose_runs_never_close_are_struck_out_and_their_reads_are_owed(world, monkeypatch):
    """A run that dies without its close is judged from what it left (here:
    nothing) and continued at the SAME attempt -- a crash is not the unit's
    failure -- until three runs of the lineage have died, which is the engine
    saying it cannot run it. The read unit covered nothing, so its whole slice
    is owed and the close names it: the crash scenario, where nothing was read."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash")
    _orchestrator(world).run()
    last = _last_attempts(world).values()
    struck = [u for u in last if u["kind"] in ("hunt", "read")]
    assert struck and all(u["state"] == "failed" for u in struck)
    assert all(u["attempt"] == 1 for u in _units(world)), "no attempt is spent on a run that died"
    row = _row(world)
    assert row["state"] == "capped"
    assert "could not run this unit" in row["coverage_note"]
    assert "were never read in full" in row["coverage_note"]
    assert "src/a.py:1-40" in row["coverage_note"]


def test_a_dead_runs_spend_is_estimated_from_its_stream_not_lost_as_zero(world, monkeypatch, tmp_path):
    """_judge_orphan used to hand units.close spend_usd=0.0 unconditionally
    for a run that died before its own close ran -- a run that had genuinely
    spent several minutes of real tokens settled at $0.00 regardless. Priced
    from config/pricing.json (bin/platforms/costing.py, deduplicated by
    message id), the same table run_job's own salvage path reads, the
    estimate must be the non-zero figure the stream's usage prices to."""
    pricing = tmp_path / "pricing.json"
    pricing.write_text(json.dumps({"anthropic": {"claude-opus-5-5": {
        "input": 4.0, "cached_input": 0.2, "output": 20.0, "cache_write": 0.0}}}))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-with-usage")
    assert _orchestrator(world, pricing_file=str(pricing)).run() == 0
    # Every attempt that actually ran (LAUNCH_STRIKES of them, per lineage)
    # gets the estimate; the final row -- the lineage given up, never
    # launched -- has nothing to estimate from and stays at 0.0, as before.
    ran = [u for u in _units(world) if u["kind"] in ("hunt", "read") and u["spend_usd"] > 0]
    assert len(ran) == 2 * orchestrator.LAUNCH_STRIKES, "not every dead run's attempt was priced"
    # (5*4 + 2500*0.2 + 1000*0 + 50*20) / 1e6, from the deduplicated usage of
    # write_stream_with_usage's two turns.
    assert all(u["spend_usd"] == pytest.approx(0.00152) for u in ran)


def test_a_dead_run_with_no_pricing_file_settles_at_zero_as_before(world, monkeypatch):
    """No --pricing given (an install with no table, or one not yet
    refreshed): a dead run's judgement must not raise, and it settles at
    0.0 exactly as it always has -- the estimate is a bonus, never a
    requirement for the orchestrator to keep working."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-with-usage")
    assert _orchestrator(world).run() == 0
    struck = [u for u in _units(world) if u["kind"] in ("hunt", "read")]
    assert struck and all(u["spend_usd"] == 0.0 for u in struck)


def test_a_read_whose_run_died_after_reading_everything_is_done_not_run_again(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-after-read")
    _orchestrator(world).run()
    reads = [u for u in _units(world) if u["kind"] == "read"]
    assert [(u["state"], u["attempt"], u["parent"]) for u in reads] == [("done", 1, None)]
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_verify_unit_whose_run_died_with_no_stream_keeps_no_verdict(world, monkeypatch):
    """No stream, no proof: the stream is the only thing that shows whether
    the session launched a subagent, so a run that left none is judged as a
    disqualified one -- nothing it did counts, and the verdict it wrote goes
    with the attempt (units.conclude's clear, in the settle's transaction).
    The continuation keeps the SAME attempt: a crash is not the unit's failure."""
    monkeypatch.setenv("FAKE_ENGINE_FIND", "1")
    monkeypatch.setenv("FAKE_ENGINE_MODE", "verify-dies")
    assert _orchestrator(world).run() == 0
    verifies = [u for u in _units(world) if u["kind"] == "verify"]
    assert all(u["attempt"] == 1 for u in verifies)
    # Three runs died, each continued at the same attempt; the third's
    # continuation is the one given up, never launched.
    assert [u["state"] for u in verifies] == ["incomplete"] * orchestrator.LAUNCH_STRIKES + ["failed"]
    assert all(u["evidence"].get("stream") == "none" for u in verifies[:-1])
    conn = ledger.connect(world["db"])
    row = conn.execute("SELECT verdict, verified_by FROM finding WHERE analysis_id=? AND fingerprint=?",
                       (world["aid"], "e" * 64)).fetchone()
    assert (row["verdict"], row["verified_by"]) == ("", ""), "a verdict nobody can prove stands for nothing"
    assert _row(world)["state"] == "capped"


def test_a_run_that_closes_with_no_stream_is_credited_with_nothing(world, monkeypatch):
    """The rule is the close's, not only this loop's: a hunt run whose own
    `unit-close` hands no stream is not `done` on its word, and after three
    attempts that proved nothing the lineage is given up by name."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "no-stream-close")
    assert _orchestrator(world).run() == 0
    hunts = [u for u in _units(world) if u["kind"] == "hunt"]
    assert [u["attempt"] for u in hunts] == [1, 2, 3]
    assert all(u["evidence"].get("stream") == "none" for u in hunts)
    assert hunts[-1]["state"] == "failed"
    row = _row(world)
    assert row["state"] == "capped" and "left no stream" in row["coverage_note"]


def test_a_close_that_raises_is_retried_and_the_unit_is_never_reset(world, monkeypatch, tmp_path):
    """A unit whose run started an agent is never sent back to `pending` under
    the same id: an orphan agent's reads would be credited to the relaunch.
    The close is retried on a later poll instead."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-after-read")
    real_close = orchestrator.units.close
    calls = []

    def flaky(conn, unit, **kw):
        calls.append(unit["id"])
        if len(calls) == 1:
            raise RuntimeError("database is locked")
        return real_close(conn, unit, **kw)
    monkeypatch.setattr(orchestrator.units, "close", flaky)
    resets = []
    monkeypatch.setattr(orchestrator.ledger, "reset_unit", lambda *a, **k: resets.append(a) or True)
    log = tmp_path / "tick.log"
    assert _orchestrator(world, log=str(log)).run() == 0
    assert resets == []
    reads = [u for u in _units(world) if u["kind"] == "read"]
    assert [(u["state"], u["attempt"], u["parent"]) for u in reads] == [("done", 1, None)]
    assert calls.count(reads[0]["id"]) == 2
    assert "could not judge unit" in log.read_text()
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_judgement_that_keeps_failing_is_given_up_and_the_close_names_the_unit(world, monkeypatch,
                                                                                  tmp_path):
    """JUDGE_TRIES judgements of a dead run that all raise: the unit is left
    `running` -- never reset, never judged on nothing -- verification is not
    planned over it, and the close names it among the units that never
    finished, for a resume to judge again."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash-after-read")
    real_close = orchestrator.units.close
    tries = []

    def broken_for_reads(conn, unit, **kw):
        if unit["kind"] == "read":
            tries.append(unit["id"])
            raise RuntimeError("database is locked")
        return real_close(conn, unit, **kw)
    monkeypatch.setattr(orchestrator.units, "close", broken_for_reads)
    log = tmp_path / "tick.log"
    assert _orchestrator(world, log=str(log)).run() == 0
    read = next(u for u in _units(world) if u["kind"] == "read")
    assert len(tries) == orchestrator.JUDGE_TRIES and set(tries) == {read["id"]}
    assert (read["state"], read["attempt"], read["parent"]) == ("running", 1, None)
    text = log.read_text()
    assert text.count("— trying again") == orchestrator.JUDGE_TRIES - 1
    assert orchestrator.JUDGE_GAVE_UP_LOG.format(
        uid=read["id"], why="RuntimeError: database is locked", tries=orchestrator.JUDGE_TRIES) in text
    row = _row(world)
    assert row["state"] == "capped"
    assert "1 unit never finished: read 1/1" in row["coverage_note"]


def test_a_launch_that_failed_before_any_agent_ran_is_reset_then_struck_out(world):
    """An engine that cannot even be started: no agent ran, so the unit goes
    back to `pending` under the same id (nothing of it can be in the ledger),
    and after three such launches it is given up with the reason."""
    _orchestrator(world, engine=str(world["tmp"] / "no-such-engine")).run()
    everything = _units(world)
    assert everything and all(u["state"] == "failed" and u["attempt"] == 1 and not u["parent"]
                              for u in everything)
    row = _row(world)
    assert row["state"] == "capped"
    assert "could not run this unit" in row["coverage_note"]


def test_a_resume_judges_a_unit_whose_run_died_with_the_orchestrator(world):
    """The unit a dead orchestrator left `running`, its run gone: judged from
    the stream it left -- found by the name run_job gives it, <stamp>-<pid> --
    and, having read everything, done; never run a second time."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    conn = ledger.connect(world["db"])
    read = next(u for u in ledger.units_of(conn, world["aid"]) if u["kind"] == "read")
    gone = subprocess.Popen(["true"])
    gone.wait()
    ledger.start_unit(conn, read["id"], f"security-web/{gone.pid}")
    logs = world["tmp"] / "logs" / "security-web"
    logs.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    (logs / f"{stamp}-{gone.pid}.stream.ndjson").write_text(_read_events(read["payload"]["ranges"]))
    assert _orchestrator(world).run() == 0
    after = ledger.get_unit(conn, read["id"])
    assert (after["state"], after["attempt"]) == ("done", 1)
    assert not [u for u in ledger.units_of(conn, world["aid"]) if u["parent"] == read["id"]]
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_the_budget_stops_the_launches_and_the_close_says_so(world):
    """0.05: below the floor one unit is given, so NOTHING starts -- the floor
    is never a way over the budget -- and the close says why."""
    _orchestrator(world, budget=0.05, parallel=1).run()
    row = _row(world)
    assert row["state"] == "capped"
    assert ("The analysis budget of $0.05 had $0.05 left -- less than the $0.50 one unit is "
            "given -- before every unit ran.") in row["coverage_note"]
    assert all(u["state"] == "pending" for u in _units(world))


def test_what_a_unit_leaves_under_the_floor_stops_the_next_launch(world, monkeypatch):
    """$0.60 at one unit at a time: the first is handed all of it and spends
    $0.30; the $0.30 left is under the floor, so the next never starts."""
    monkeypatch.setenv("FAKE_ENGINE_SPEND", "0.3")
    budgets = world["tmp"] / "budgets"
    monkeypatch.setenv("FAKE_ENGINE_BUDGETS", str(budgets))
    _orchestrator(world, budget=0.6, parallel=1).run()
    assert budgets.read_text().split() == ["0.60"]
    assert "had $0.30 left -- less than the $0.50 one unit is given" in _row(world)["coverage_note"]


def test_a_budget_the_last_unit_spends_to_the_cent_is_not_a_gap(world, monkeypatch):
    """The sentence says units were left unrun; with none left it would be a
    false statement in the report."""
    monkeypatch.setenv("FAKE_ENGINE_SPEND", "0.5")
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    planned = len(_units(world))
    _orchestrator(world, budget=round(0.5 * planned, 2), parallel=1).run()
    row = _row(world)
    assert row["state"] == "done", row["coverage_note"]
    assert "budget" not in row["coverage_note"]


class _HeldRun:
    """A unit's run that never ends while the test looks at the launches."""
    pids = iter(range(900_001, 999_999))

    def __init__(self, argv, env=None, **_kw):
        self.argv, self.env, self.pid = argv, env or {}, next(self.pids)

    def poll(self):
        return None


class _OnePass(Exception):
    pass


@pytest.mark.parametrize("parallel, budget", [(3, 3.0), (8, 4.0), (8, 3.0), (3, 1.2)])
def test_the_caps_in_flight_never_add_up_to_more_than_the_budget(world, monkeypatch, parallel, budget):
    """ONE PASS with every run still in flight: the caps handed out are
    reserved, so their sum never exceeds the budget. Off the spend alone
    (units that closed) a pass handed out B, B/2, B/3 ... -- 1.83 B at P=3,
    2.72 B at P=8 -- and the floor raised the rest. Here the floor fills what
    it can and stops: at P=8 and $3 six units get $0.50 and two wait."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    conn = ledger.connect(world["db"])
    ledger.add_units(conn, world["aid"], [("hunt", {"profile": "deep"})] * 10)
    launched = []
    real_popen = subprocess.Popen

    def held(argv, **kw):
        if "__run-unit" not in argv:
            return real_popen(argv, **kw)              # `ps`, and the like
        proc = _HeldRun(argv, **kw)
        launched.append(proc)
        return proc

    class one_pass_clock:
        """`time` as the orchestrator module sees it, whose `sleep` ends the
        pass. NOT `time.sleep` itself: that is the one function every module
        shares, and `subprocess` calls it inside `wait(timeout=)` whenever a
        child (the `ps` that `_started_at` runs per launch) has closed its
        pipes but is not yet reaped -- which, on a loaded machine, ended the
        pass after the FIRST launch and failed this test with one cap."""
        sleep = staticmethod(lambda _seconds: (_ for _ in ()).throw(_OnePass()))

        def __getattr__(self, name):
            return getattr(time, name)
    monkeypatch.setattr(orchestrator.subprocess, "Popen", held)
    monkeypatch.setattr(orchestrator, "time", one_pass_clock())
    orch = _orchestrator(world, budget=budget, parallel=parallel)
    monkeypatch.setattr(orch, "_gate", lambda: "", raising=False)
    with pytest.raises(_OnePass):
        orch._loop()
    caps = [float(p.env["AL_SECURITY_UNIT_BUDGET"]) for p in launched]
    assert caps and sum(caps) <= budget + 1e-9, caps
    assert all(c >= orchestrator.MIN_UNIT_BUDGET for c in caps), caps
    assert len(caps) == min(parallel, int(budget // orchestrator.MIN_UNIT_BUDGET)), caps
    # Each cap is recorded on its unit, where an orchestrator that adopts the
    # run after this one died keeps it reserved.
    keys = [u["run_key"] for u in _units(world) if u["state"] == "running"]
    assert sorted(orchestrator._cap_of(k) for k in keys) == sorted(caps)


def test_a_budget_reached_by_a_float_sum_is_reached(world):
    """$0.70 and $0.10 add up to 0.7999999999999999 in floating point: a
    budget of $0.80 is spent, and nothing more is launched."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    conn = ledger.connect(world["db"])
    waiting = {u["id"] for u in ledger.units_of(conn, world["aid"])}
    paid = ledger.add_units(conn, world["aid"], [("hunt", {"profile": "deep"})] * 2)
    for uid, spend in zip(paid, (0.7, 0.1)):
        ledger.start_unit(conn, uid, "security-web/0")
        ledger.settle_unit(conn, uid, "done", spend, {}, "paid")
    assert sum(u["spend_usd"] for u in ledger.units_of(conn, world["aid"])) < 0.8
    _orchestrator(world, budget=0.8).run()
    assert all(ledger.get_unit(conn, uid)["state"] == "pending" for uid in waiting)
    assert "The analysis budget of $0.80 was spent before every unit ran." in _row(world)["coverage_note"]


def test_a_budget_that_is_not_a_number_is_refused_with_a_sentence(world, tmp_path, capsys):
    lock = tmp_path / "lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    assert _orchestrator(world, budget="5 USD", lock_dir=str(lock)).run() == 2
    err = capsys.readouterr().err
    assert "--budget must be a number" in err and "'5 USD'" in err
    assert "Traceback" not in err
    assert (_row(world)["state"], _units(world)) == ("running", []), "nothing was started, nothing closed"
    assert not lock.exists(), "released: the tick must not resume a run that can never start"


def test_the_orchestrate_verb_hands_every_flag_on_and_exits_with_the_run_s_code(world):
    from test_cli import fails
    out = fails(world["db"], "orchestrate", "--analysis", str(world["aid"]), "--engine", str(FAKE),
                "--job", "security-web", "--commit", world["sha"], "--repo", "web",
                "--repo-path", str(world["repo"]), "--prepare-root", str(world["tmp"] / "prepare"),
                "--budget", "ten")
    assert out.returncode == 2
    assert "--budget must be a number of US dollars, not 'ten'" in out.stderr
    assert "Traceback" not in out.stderr
    out = fails(world["db"], "orchestrate", "--analysis", str(world["aid"]), "--engine", str(FAKE),
                "--job", "security-web", "--commit", world["sha"], "--repo", "web",
                "--repo-path", str(world["repo"]), "--prepare-root", str(world["tmp"] / "prepare"),
                "--log-root", str(world["tmp"] / "logs"), "--offline", "--parallel", "2")
    assert out.returncode == 0, out.stderr
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_stop_interrupts_and_a_resume_finishes(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "slow")
    proc = _spawn(world)
    deadline = time.time() + 60
    while time.time() < deadline and not any(u["state"] == "running" for u in _units(world)):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=60) == 0
    assert _row(world)["state"] == "interrupted"
    assert not any(u["state"] == "running" for u in _units(world))
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    _orchestrator(world).run()
    assert _row(world)["state"] == "done"


def test_a_stop_judges_what_a_run_that_died_without_its_close_had_read(world, monkeypatch):
    """The runs a stop ends here die WITHOUT closing their units (a kill that
    reached them before their close could). What the read unit had read --
    its first range -- counts; the rest continues at the SAME attempt, and a
    resume reads only that."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "die-on-stop")
    proc = _spawn(world)
    logs = world["tmp"] / "logs" / "security-web"
    deadline = time.time() + 60
    while time.time() < deadline and not list(logs.glob("*.stream.ndjson")):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=60) == 0
    assert _row(world)["state"] == "interrupted"
    reads = [u for u in _units(world) if u["kind"] == "read"]
    first = next(u for u in reads if not u["parent"])
    assert first["state"] == "incomplete"
    assert first["evidence"]["covered"] == {"src/a.py": [[1, 40]]}
    cont = next(u for u in reads if u["parent"] == first["id"])
    assert (cont["attempt"], cont["state"]) == (1, "pending")
    assert [r["path"] for r in cont["payload"]["ranges"]] == ["src/b.py"]
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    _orchestrator(world).run()
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_stop_reaches_a_unit_that_was_still_starting(world, monkeypatch):
    """The engine's `stop` only reaches slots that exist AT THE MOMENT it runs
    (bin/agentloop's cmd_stop / _stop_slot): a unit still claiming its slot
    when the first `stop` fires takes it only afterwards, launches its agent,
    and would otherwise run to the end unseen. `late-stop` stands in for that
    unit -- it needs a SECOND `stop` call to end -- so this proves the
    orchestrator's interrupt loop keeps re-issuing `stop` on every poll,
    not just once, until nothing is left alive (or the grace runs out)."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "late-stop")
    monkeypatch.setenv("AL_SECURITY_STOP_GRACE_SECONDS", "20")
    proc = _spawn(world)
    deadline = time.time() + 60
    while time.time() < deadline and not any(u["state"] == "running" for u in _units(world)):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    try:
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
    assert _row(world)["state"] == "interrupted"
    assert not any(u["state"] == "running" for u in _units(world))


def _stale_registration(world, name):
    """A worktree of the analysed repo whose directory is gone and whose
    registration is not -- what a unit's tree removed by hand, or by a crash
    halfway through its teardown, leaves in `git worktree list`."""
    tree = world["tmp"] / name
    subprocess.run(["git", "-C", str(world["repo"]), "worktree", "add", "-q", "--detach",
                    str(tree), world["sha"]], check=True, env=GIT_ENV)
    subprocess.run(["rm", "-rf", str(tree)], check=True)
    return tree


def _registered(world, tree):
    out = subprocess.run(["git", "-C", str(world["repo"]), "worktree", "list", "--porcelain"],
                         capture_output=True, text=True, check=True).stdout
    return f"worktree {tree}" in out or f"worktree {os.path.realpath(tree)}" in out


def test_an_orchestrator_that_closes_sweeps_what_its_units_left(world, monkeypatch):
    """Done: the engine's `__unit-sweep` is asked for this job, its line goes
    into tick.log, and the analysed repo's registrations of trees that are
    gone are pruned."""
    calls, log = world["tmp"] / "sweeps", world["tmp"] / "tick.log"
    monkeypatch.setenv("FAKE_ENGINE_SWEEP_CALLS", str(calls))
    monkeypatch.setenv("FAKE_ENGINE_SWEEP_SAYS", "swept 1 unit worktree(s) (x-1) and 0 stale slot(s)")
    tree = _stale_registration(world, "unit-tree")
    assert _registered(world, tree)
    assert _orchestrator(world, log=str(log)).run() == 0
    assert _row(world)["state"] == "done"
    assert calls.read_text() == "security-web\n"
    assert "swept 1 unit worktree(s) (x-1) and 0 stale slot(s)" in log.read_text()
    assert not _registered(world, tree), "the stale registration outlived the analysis"


def test_an_orchestrator_that_is_stopped_sweeps_too(world, monkeypatch):
    """Interrupted, by the stop a dashboard sends: the sweep runs after the
    units' runs were stopped and judged, once, before the lock goes."""
    calls, log = world["tmp"] / "sweeps", world["tmp"] / "tick.log"
    monkeypatch.setenv("FAKE_ENGINE_MODE", "die-on-stop")
    monkeypatch.setenv("FAKE_ENGINE_SWEEP_CALLS", str(calls))
    monkeypatch.setenv("FAKE_ENGINE_SWEEP_SAYS", "swept 3 unit worktree(s) (a b c) and 1 stale slot(s) (36115)")
    tree = _stale_registration(world, "stopped-unit-tree")
    lock = world["tmp"] / "lock"
    lock.mkdir()
    proc = _spawn(world, log=str(log), lock_dir=str(lock))
    (lock / "pid").write_text(f"{proc.pid}\n")
    logs = world["tmp"] / "logs" / "security-web"
    deadline = time.time() + 60
    while time.time() < deadline and not list(logs.glob("*.stream.ndjson")):
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=60) == 0
    assert _row(world)["state"] == "interrupted"
    assert calls.read_text() == "security-web\n"
    text = log.read_text()
    assert "swept 3 unit worktree(s) (a b c) and 1 stale slot(s) (36115)" in text
    # After the interruption was written, never before: the sweep must come
    # once every unit it could remove the tree of has been judged.
    assert text.index("interrupted") < text.index("swept 3")
    assert not _registered(world, tree)
    assert not lock.exists(), "the lock is released after the sweep"


def test_an_orchestrator_that_fails_still_sweeps(world, monkeypatch):
    """A raise in the loop leaves the analysis interrupted -- and the sweep
    still runs: the `finally` that lets the lock go runs it first."""
    calls = world["tmp"] / "sweeps"
    monkeypatch.setenv("FAKE_ENGINE_SWEEP_CALLS", str(calls))
    orch = _orchestrator(world)

    def boom():
        raise RuntimeError("the loop broke")
    monkeypatch.setattr(orch, "_loop", boom)
    assert orch.run() == 1
    assert _row(world)["state"] == "interrupted"
    assert calls.read_text() == "security-web\n"


def test_a_sweep_the_engine_cannot_run_is_said_and_never_raises(world, monkeypatch, tmp_path):
    """An engine that answers the sweep non-zero: one line saying so, and the
    analysis closes exactly as it would have."""
    engine = tmp_path / "engine-sweep-fails"
    engine.write_text("#!/bin/sh\n"
                      f"[ \"$1\" = __unit-sweep ] && {{ echo 'no such job' >&2; exit 2; }}\n"
                      f"exec {sys.executable} {FAKE} \"$@\"\n")
    engine.chmod(0o755)
    log = world["tmp"] / "tick.log"
    assert _orchestrator(world, engine=str(engine), log=str(log)).run() == 0
    assert _row(world)["state"] == "done"
    assert "could not sweep what its units left (rc 2): no such job" in log.read_text()


def test_the_close_never_settles_an_analysis_interrupted_under_it(world):
    """A stop, or the next Analyse's sweep, can interrupt the analysis while
    this loop is ending: the close is `--if-running`, so the row stays
    `interrupted` for a resume and is never closed from half its units."""
    conn = ledger.connect(world["db"])
    assert ledger.interrupt_analysis(conn, world["aid"])
    _orchestrator(world)._finish("")
    assert _row(world)["state"] == "interrupted"


def test_the_orchestrator_writes_its_phase_into_its_own_lock(world, tmp_path, monkeypatch):
    """Between two units no slot is alive; the phase in the lock is what the
    page reads to know the analysis is still in hand (Task 13)."""
    lock = tmp_path / "lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    seen = []
    real = orchestrator.Orchestrator._set_phase

    def spy(self, phase):
        real(self, phase)
        seen.append((lock / "phase").read_text().strip())
    monkeypatch.setattr(orchestrator.Orchestrator, "_set_phase", spy)
    assert _orchestrator(world, lock_dir=str(lock)).run() == 0
    assert seen == ["preparing", "running units", "finishing"]
    assert not lock.exists(), "released on the way out, phase file and all"


def test_a_plan_that_fails_closes_the_analysis_capped_never_done(world, monkeypatch):
    """A quick analysis has no inventory, so no gap of its own would lower a
    `done` over units nobody planned: the failure has to."""
    aid = open_analysis(world["db"], profile="quick", commit=world["sha"], run_id="r2")
    run(world["db"], "prepare", "--analysis", str(aid), "--root", str(world["repo"]), "--offline")

    def broken(*_a, **_k):
        raise RuntimeError("the checklist could not be read")
    monkeypatch.setattr(orchestrator.units, "plan", broken)
    assert orchestrator.Orchestrator(world["db"], aid, **_kwargs(world)).run() == 0
    row = next(r for r in run(world["db"], "list", "--project", "web") if r["id"] == aid)
    assert row["state"] == "capped"
    assert "could not plan this analysis's units" in row["coverage_note"]


def test_the_lock_is_released_only_if_it_is_still_the_orchestrator_s(world, tmp_path):
    mine = tmp_path / "lock-mine"
    mine.mkdir()
    (mine / "pid").write_text(str(os.getpid()))
    _orchestrator(world, lock_dir=str(mine)).run()
    assert not mine.exists()
    theirs = tmp_path / "lock-theirs"
    theirs.mkdir()
    (theirs / "pid").write_text("1")
    # the analysis is closed now, so this run returns at once -- and must leave the lock alone
    _orchestrator(world, lock_dir=str(theirs)).run()
    assert theirs.exists()


# -- a failure is an interruption, never a `running` row behind a released lock

def _held_lock(tmp_path):
    lock = tmp_path / "lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))
    return lock


def test_a_raise_in_the_loop_leaves_the_analysis_interrupted(world, monkeypatch, tmp_path):
    """The ledger raising under the loop (a busy database, a disk error):
    the analysis is left `interrupted` -- resumable, offered Resume on the
    page -- never `running` behind a lock the orchestrator then releases."""
    real = orchestrator.ledger.units_of
    calls = []

    def flaky(conn, aid):
        calls.append(aid)
        if len(calls) == 2:
            raise RuntimeError("database is locked")
        return real(conn, aid)
    monkeypatch.setattr(orchestrator.ledger, "units_of", flaky)
    lock = _held_lock(tmp_path)
    assert _orchestrator(world, lock_dir=str(lock)).run() == 1
    row = _row(world)
    assert row["state"] == "interrupted"
    assert "because its orchestrator failed (RuntimeError)" in row["coverage_note"]
    assert not lock.exists(), "interrupted and resumable: nothing left for the tick to find"
    monkeypatch.setattr(orchestrator.ledger, "units_of", real)
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_start_unit_that_raises_leaves_the_analysis_interrupted(world, monkeypatch):
    def broken(*_a, **_k):
        raise RuntimeError("disk I/O error")
    monkeypatch.setattr(orchestrator.ledger, "start_unit", broken)
    assert _orchestrator(world).run() == 1
    assert _row(world)["state"] == "interrupted"


def test_a_close_that_fails_twice_leaves_the_analysis_interrupted(world, monkeypatch, tmp_path):
    """`finish` exiting non-zero is retried once; still failing, the row is
    interrupted rather than left `running`."""
    real = orchestrator.Orchestrator._cli
    finishes = []

    def failing(self, *args):
        if args and args[0] == "finish":
            finishes.append(args)
            return subprocess.CompletedProcess(args, 1, "", "database is locked")
        return real(self, *args)
    monkeypatch.setattr(orchestrator.Orchestrator, "_cli", failing)
    log = tmp_path / "tick.log"
    assert _orchestrator(world, log=str(log)).run() == 0
    assert len(finishes) == 2
    row = _row(world)
    assert row["state"] == "interrupted"
    assert "because its orchestrator failed (its close failed)" in row["coverage_note"]
    assert "could not close (try 2)" in log.read_text()


def test_when_nothing_can_be_written_the_lock_is_kept_for_the_tick(world, monkeypatch, tmp_path):
    """Not even the interruption can be written: the lock stays, so the tick
    finds its owner dead and resumes the analysis (security_resume_orphans)."""
    def broken(*_a, **_k):
        raise RuntimeError("disk I/O error")
    monkeypatch.setattr(orchestrator.ledger, "start_unit", broken)
    monkeypatch.setattr(orchestrator.ledger, "interrupt_analysis", broken)
    lock = _held_lock(tmp_path)
    assert _orchestrator(world, lock_dir=str(lock)).run() == 1
    assert lock.exists()
    assert _row(world)["state"] == "running"


# -- a pid is not a run -----------------------------------------------------------

def test_a_live_unrelated_pid_is_not_adopted(world):
    """After a reboot the kernel hands a unit's pid to something else. `kill
    -0` alone adopted it and waited on it for ever; the run is gone, so the
    unit is judged from the stream its run left, and the analysis closes."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    conn = ledger.connect(world["db"])
    read = next(u for u in ledger.units_of(conn, world["aid"]) if u["kind"] == "read")
    stranger = subprocess.Popen(["sleep", "60"])
    try:
        ledger.start_unit(conn, read["id"], f"security-web/{stranger.pid}")
        logs = world["tmp"] / "logs" / "security-web"
        logs.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        (logs / f"{stamp}-{stranger.pid}.stream.ndjson").write_text(
            _read_events(read["payload"]["ranges"]))
        assert _orchestrator(world).run() == 0
        assert stranger.poll() is None, "the stranger is left alone"
        assert (ledger.get_unit(conn, read["id"])["state"], _row(world)["state"]) == ("done", "done")
    finally:
        stranger.kill()
        stranger.wait()


def test_a_run_is_its_pid_its_start_and_its_command_line(world):
    fake = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                             "__run-unit", "security-web", "7", "42", "abc", "web"])
    try:
        started = orchestrator._started_at(fake.pid)
        assert started
        assert orchestrator._is_run(fake.pid, "security-web", 7, 42, started)
        assert orchestrator._is_run(fake.pid, "security-web", 7, 42)
        assert not orchestrator._is_run(fake.pid, "security-web", 7, 4)
        assert not orchestrator._is_run(fake.pid, "security-web", 8, 42, started)
        assert not orchestrator._is_run(fake.pid, "security-web", 7, 42, "Thu Jan  1 00:00:00 1970")
        key = orchestrator._run_key("security-web", fake.pid, started, 0.5)
        assert orchestrator._pid_of(key) == fake.pid and orchestrator._cap_of(key) == 0.5
        assert orchestrator._key_fields(key)["start"] == started
        assert orchestrator._pid_of(f"security-web/{fake.pid}") == fake.pid
    finally:
        fake.kill()
        fake.wait()
    assert not orchestrator._is_run(fake.pid, "security-web", 7, 42)


# -- an orphan prepare --------------------------------------------------------------

def _pgid_file(world):
    return world["tmp"] / "prepare" / f"security-web-{world['aid']}{orchestrator.PREPARE_PGID}"


def test_a_prepare_an_earlier_orchestrator_left_running_is_ended_first(world):
    """`prepare` leads a session of its own, so after its orchestrator was
    SIGKILLed it goes on running; the next orchestrator's prepare ends it --
    group and all -- before cutting the same checkout again."""
    orphan = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)",
                               "prepare", "--analysis", str(world["aid"]), "--root", "x"],
                              start_new_session=True)
    try:
        pgid = _pgid_file(world)
        pgid.parent.mkdir(parents=True, exist_ok=True)
        pgid.write_text(f"{orphan.pid}\n{orchestrator._started_at(orphan.pid)}\n")
        assert _orchestrator(world).run() == 0
        assert orphan.wait(timeout=10) is not None
        assert not pgid.exists()
        assert _row(world)["state"] == "done", _row(world)["coverage_note"]
    finally:
        if orphan.poll() is None:
            orphan.kill()
            orphan.wait()


def test_a_recorded_prepare_pid_that_is_something_else_now_is_left_alone(world):
    stranger = subprocess.Popen(["sleep", "60"], start_new_session=True)
    try:
        pgid = _pgid_file(world)
        pgid.parent.mkdir(parents=True, exist_ok=True)
        pgid.write_text(f"{stranger.pid}\n{orchestrator._started_at(stranger.pid)}\n")
        assert _orchestrator(world).run() == 0
        assert stranger.poll() is None
    finally:
        stranger.kill()
        stranger.wait()


# -- the engine's gates, and the provider's outages -------------------------------------

def test_a_closed_gate_stops_the_launches_and_interrupts_with_its_name(world, monkeypatch):
    """A unit is a forced run of the derived job, which skips run_job's own
    gates, so the orchestrator asks the engine for them before each launch:
    closed, nothing launches, and the analysis is interrupted with the gate
    named -- resumable once it reopens."""
    monkeypatch.setenv("FAKE_ENGINE_GATE", "the daily cap of security-web was reached ($3.10 / $3.00)")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    assert row["state"] == "interrupted"
    assert ("The engine interrupted this analysis because the daily cap of security-web was "
            "reached ($3.10 / $3.00)") in row["coverage_note"]
    assert all(u["state"] == "pending" for u in _units(world))
    monkeypatch.delenv("FAKE_ENGINE_GATE")
    run(world["db"], "resume", "--analysis", str(world["aid"]))
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_the_gate_is_asked_before_every_launch(world, monkeypatch):
    calls = world["tmp"] / "gate-calls"
    monkeypatch.setenv("FAKE_ENGINE_GATE_CALLS", str(calls))
    _orchestrator(world, parallel=1).run()
    runs = sum(1 for u in _units(world) if u["started"])
    assert runs and len(calls.read_text().split()) == runs


def test_a_run_the_provider_cut_short_keeps_its_attempt(world, monkeypatch):
    """`rate_limited` is the provider's doing, not the unit's: the close
    keeps the attempt, and the continuation finishes the unit."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "outage")
    assert _orchestrator(world).run() == 0
    firsts = [u for u in _units(world) if not u["parent"] and u["kind"] in ("hunt", "read")]
    assert firsts and all(u["state"] == "incomplete" and u["evidence"].get("cause") == "rate_limited"
                          for u in firsts)
    assert all(u["attempt"] == 1 for u in _units(world))
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_three_outages_in_a_row_give_the_lineage_up(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "always-outage")
    assert _orchestrator(world).run() == 0
    # (a triage unit over the sandbox's rows below the floor is done whatever
    # its run did: nothing it owes blocks)
    last = [u for u in _last_attempts(world).values() if u["kind"] in ("hunt", "read")]
    assert last and all(u["state"] == "failed" and u["attempt"] == 1 for u in last)
    row = _row(world)
    assert row["state"] == "capped"
    assert "3 runs in a row were cut short by the provider (rate_limited" in row["coverage_note"]


def test_units_that_cannot_start_pause_the_analysis_after_one_wave(world, monkeypatch):
    """Analysis 12 (2026-09-26): OpenCode failed every boot of the project,
    and the orchestrator spent three attempts on each of 231 lineages, in 42
    minutes, before it closed capped. Every unit failing to start is the
    environment: the gate closes after START_FAIL_BREAKER of them over two
    lineages or more, the analysis is left interrupted with the error in its
    note, and no lineage is given up for it."""
    runs = world["tmp"] / "runs"
    monkeypatch.setenv("FAKE_ENGINE_BUDGETS", str(runs))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    assert row["state"] == "interrupted", row["coverage_note"]
    assert ("the agent could not start: 3 units in a row ended before a session opened "
            "(last error: BadResource: FileSystem.access (/gone/repo))") in row["coverage_note"]
    launched = len(runs.read_text().splitlines())
    assert 3 <= launched <= 3 + orchestrator.BREAKER_RUNS - 1, launched
    assert not [u for u in _units(world) if u["state"] == "failed"], "no lineage given up for the environment"
    assert all(u["attempt"] == 1 for u in _units(world)), "a start failure keeps its attempt"


def test_one_unit_that_cannot_start_is_given_up_without_pausing_the_rest(world, monkeypatch):
    """One lineage failing to start is that unit's own trouble: the others
    run, the gate stays open, and after LAUNCH_STRIKES start failures in a
    row the unit is given up with the agent's own words in its note."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail-hunt")
    assert _orchestrator(world).run() == 0
    hunt = [u for u in _last_attempts(world).values() if u["kind"] == "hunt"]
    assert hunt and hunt[0]["state"] == "failed"
    assert hunt[0]["note"] == ("The engine could not run this unit: its agent could not start 3 times "
                               "in a row (BadResource: FileSystem.access (/gone/repo); see tick.log).")
    row = _row(world)
    assert row["state"] == "capped"
    assert "its agent could not start 3 times in a row" in row["coverage_note"]
    assert "the agent could not start: 3 units in a row" not in row["coverage_note"], "no gate for one lineage"


def test_a_paused_analysis_resumes_once_the_agent_can_start_and_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail")
    _orchestrator(world).run()
    assert _row(world)["state"] == "interrupted"
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    assert ledger.resume_analysis(ledger.connect(world["db"]), world["aid"]) is True
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]


def test_a_provider_that_refuses_every_unit_pauses_the_analysis_too(world, monkeypatch):
    """The morning after analysis 12, the Anthropic token had expired: every
    run answered 401, which the classifier files as `api_error`. That keeps
    each unit's attempt, and three in a row gave each lineage up -- the same
    burn as the start failures, by another cause. The breaker counts it."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "always-api-error")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    assert row["state"] == "interrupted", row["coverage_note"]
    assert "the provider refused 3 units in a row (api_error)" in row["coverage_note"]
    assert not [u for u in _units(world) if u["state"] == "failed"]
