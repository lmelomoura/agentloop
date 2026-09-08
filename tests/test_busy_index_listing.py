"""A busy index must not turn 405 runs into "No runs recorded yet".

`load_data` wraps the whole listing in one except that degraded to an empty
list. That except exists for a real reason -- it once hid a broken INSERT for a
morning, so it prints -- but "the database is busy for a moment" and "the
database is broken" are different answers and it gave the same one to both.

Busy is the ordinary case: anything holding the index (a compaction, an ingest
of a large transcript) makes a concurrent read wait out `timeout=5` and raise
`database is locked`, and the page then paints an empty Runs table over a
journal that is entirely intact. Seen twice in the operator's own server.log.

So: retry once, and if it is still busy serve the last listing this process
actually managed to read, flagged `runs_stale` so the page can say so. The
cache only ever replays something that was genuinely served -- a truly broken
index has never filled it, and still shows nothing, loudly.
"""

import json
import sqlite3

import pytest


def _one_run(srv):
    srv.RUNS_FILE.write_text(json.dumps({
        "id": "j-busy", "status": "success", "start": 1700000000,
        "end": 1700000060, "duration": 60, "cost": 0.25, "session": "s-busy",
        "log": str(srv.DATA_DIR / "logs" / "j-busy" / "x.json"),
        "note": "", "cause": "",
    }) + "\n")


def _locked(*a, **k):
    raise sqlite3.OperationalError("database is locked")


def test_a_busy_index_serves_the_last_listing_it_managed_to_read(srv, clean_data, monkeypatch):
    _one_run(srv)
    good = srv.load_data()
    assert [r["id"] for r in good["runs"]] == ["j-busy"]
    assert good["runs_stale"] is False

    monkeypatch.setattr(srv, "db_conn", _locked)
    out = srv.load_data()

    assert [r["id"] for r in out["runs"]] == ["j-busy"], \
        "a busy index blanked the runs list"
    assert out["runs_stale"] is True, "stale data must be flagged as stale"


def test_a_busy_index_is_retried_before_it_is_given_up_on(srv, clean_data, monkeypatch):
    """One retry, because the lock that blocks a read is usually milliseconds old."""
    _one_run(srv)
    srv.load_data()

    real, calls = srv.db_conn, {"n": 0}

    def flaky(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(*a, **k)

    monkeypatch.setattr(srv, "db_conn", flaky)
    out = srv.load_data()

    assert calls["n"] > 1, "the read was not retried"
    assert [r["id"] for r in out["runs"]] == ["j-busy"]
    assert out["runs_stale"] is False, "a retry that succeeded is not stale"


def test_an_index_that_never_worked_still_shows_nothing(srv, clean_data, monkeypatch):
    """The cache replays what was served, never invents a listing.

    A first request against a genuinely broken index has nothing to fall back
    on, and must keep reporting the emptiness rather than hiding it.
    """
    _one_run(srv)
    monkeypatch.setattr(srv, "_LAST_RUNS", [])
    monkeypatch.setattr(srv, "db_conn", _locked)

    out = srv.load_data()

    assert out["runs"] == []
    assert out["runs_stale"] is True
