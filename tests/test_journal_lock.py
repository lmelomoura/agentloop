"""The server's half of the journal lock.

Both sides take the same mkdir lock by name, so they have to agree on when a
lock may be broken. The engine now steals only from a dead owner; a server that
still broke on elapsed time would reintroduce the loss from the other side.

They also have to agree on what "the owner is gone" MEANS. `.journal.lock`
lives under data/, so it survives a reboot exactly like a run slot does, and
the kernel reissues pids from 1 on the way up -- a live-looking pid in a lock
left over from a previous boot can belong to an entirely different process.
The engine's own `lock_take` already checks `slot_alive` for this; these
tests cover the same fix on this side of the same lock.
"""

import os
import time

import pytest


def test_a_free_lock_is_taken_and_released(srv):
    with srv.journal_lock() as lk:
        assert lk.path.is_dir()
    assert not lk.path.exists()


def test_the_holder_records_its_pid(srv):
    with srv.journal_lock() as lk:
        assert (lk.path / "pid").read_text().strip() == str(os.getpid())


def test_the_holder_records_its_boot(srv):
    with srv.journal_lock() as lk:
        assert (lk.path / "boot").read_text().strip() == srv.boot_id()


def test_a_live_pid_from_a_different_boot_is_taken_at_once(srv):
    """The same recycled-pid trap `slot_alive` closes for a run slot, on this
    lock: a live-looking pid left over from before a reboot must not be
    waited on forever just because os.kill(pid, 0) still succeeds."""
    lock = srv.DATA_DIR / "locks" / ".journal.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    if lock.exists():
        for f in lock.iterdir():
            f.unlink()
        lock.rmdir()
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))  # us: genuinely alive
    (lock / "boot").write_text("not-this-boot")

    t0 = time.time()
    with srv.journal_lock():
        pass
    assert time.time() - t0 < 2.0


def test_a_lock_whose_owner_is_gone_is_taken_at_once(srv):
    lock = srv.DATA_DIR / "locks" / ".journal.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    if lock.exists():
        for f in lock.iterdir():
            f.unlink()
        lock.rmdir()
    lock.mkdir()
    dead = 99999
    while _alive(dead):
        dead -= 1
    (lock / "pid").write_text(str(dead))

    t0 = time.time()
    with srv.journal_lock():
        pass
    assert time.time() - t0 < 2.0


def test_a_live_holder_is_never_robbed(srv):
    """The engine holds this lock across a whole-journal rewrite. Breaking it on
    a timer is exactly how an appended run record gets overwritten and lost."""
    lock = srv.DATA_DIR / "locks" / ".journal.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    if lock.exists():
        for f in lock.iterdir():
            f.unlink()
        lock.rmdir()
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()))  # us: definitely alive
    try:
        with pytest.raises(TimeoutError):
            with srv.journal_lock(timeout=2.0):
                pass
    finally:
        for f in lock.iterdir():
            f.unlink()
        lock.rmdir()


class _Clock:
    """The server module's `time`, for one test: it moves only when the lock
    sleeps, and runs each scripted event once its moment has come, so a wait
    of a minute costs none and lands the same way on every run."""

    def __init__(self, *events):
        self.start = self.now = 1_000_000.0
        self.events = sorted(events, key=lambda e: e[0])

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        while self.events and self.now - self.start >= self.events[0][0]:
            self.events.pop(0)[1]()


def _made_without_pid(srv):
    """The journal lock as an owner holds it between its mkdir and its pid."""
    lock = srv.DATA_DIR / "locks" / ".journal.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    _drop(lock)
    lock.mkdir()
    return lock


def _drop(lock):
    if lock.exists():
        for f in lock.iterdir():
            f.unlink()
        lock.rmdir()


def test_a_waiter_that_waited_past_the_grace_never_robs_the_next_owner(srv, monkeypatch):
    """The engine's lock_take counted its own polls as the time an owner with
    no pid had had, so a waiter that had queued past the grace behind a live
    owner broke the NEXT owner's lock in the instant between its mkdir and its
    pid, and both held it. This side starts that clock when it stops reading
    an owner and drops it whenever it reads one: the waiter below arrives
    while the first owner has yet to write its pid, waits on it for longer
    than the grace, and then finds the lock as the next owner holds it before
    its pid -- which it waits on to the end of its time, and never breaks."""
    grace = srv.journal_lock.GRACE
    lock = _made_without_pid(srv)

    def owner_writes_its_pid():
        (lock / "pid").write_text(str(os.getpid()))
        (lock / "boot").write_text(srv.boot_id())

    def next_owner_before_its_pid():
        for f in lock.iterdir():
            f.unlink()

    monkeypatch.setattr(srv, "time", _Clock((0.5, owner_writes_its_pid),
                                            (grace + 5, next_owner_before_its_pid)))
    try:
        with pytest.raises(TimeoutError):
            with srv.journal_lock(timeout=2 * grace):
                pass
        assert lock.is_dir() and not any(lock.iterdir())
    finally:
        _drop(lock)


def test_a_lock_that_never_had_a_pid_is_broken_after_the_grace(srv, monkeypatch):
    """The control beside it: an owner killed between its mkdir and its pid
    must not wedge the journal, so a lock no poll ever found a pid in goes
    once the grace has passed -- and not before."""
    grace = srv.journal_lock.GRACE
    lock = _made_without_pid(srv)
    clock = _Clock()
    monkeypatch.setattr(srv, "time", clock)
    try:
        with srv.journal_lock(timeout=2 * grace):
            waited = clock.now - clock.start
            assert (lock / "pid").read_text().strip() == str(os.getpid())
        assert grace < waited < grace + 1
    finally:
        _drop(lock)


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def test_a_new_journal_line_actually_reaches_the_runs_table(srv, clean_data):
    """The regression that emptied the dashboard: _upsert's INSERT shipped with
    22 columns and 21 placeholders, so the FIRST new journal line after the
    server picked the code up made every ingest raise, load_data swallowed it,
    and the page said "No runs recorded yet" over an intact journal. This walks
    one real line through ingest() and reads it back."""
    import json
    srv.RUNS_FILE.write_text(json.dumps({
        "id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
        "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json",
        "note": "", "cause": ""}) + "\n")
    srv.ingest()
    conn = srv.db_conn()
    rows = conn.execute("SELECT job, status, cost FROM runs").fetchall()
    conn.close()
    assert [(r["job"], r["status"], r["cost"]) for r in rows] == [("j1", "success", 0.5)]
