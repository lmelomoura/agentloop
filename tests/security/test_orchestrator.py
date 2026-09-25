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
    """0.05: the first unit launched -- whichever kind it is, with or without
    the sandbox's hygiene row -- spends 0.10, so the rest never start."""
    _orchestrator(world, budget=0.05, parallel=1).run()
    row = _row(world)
    assert row["state"] == "capped"
    assert "The analysis budget of $0.05 was spent before every unit ran." in row["coverage_note"]
    assert any(u["state"] == "pending" for u in _units(world))


def test_a_budget_the_last_unit_spends_to_the_cent_is_not_a_gap(world):
    """The sentence says units were left unrun; with none left it would be a
    false statement in the report."""
    run(world["db"], "prepare", "--analysis", str(world["aid"]), "--root", str(world["repo"]),
        "--offline", "--plan")
    planned = len(_units(world))
    _orchestrator(world, budget=round(0.1 * planned, 2), parallel=1).run()
    row = _row(world)
    assert row["state"] == "done", row["coverage_note"]
    assert "budget" not in row["coverage_note"]


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
