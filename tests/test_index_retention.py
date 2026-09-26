"""The run index does not grow without limit.

Every finished run's transcript, precheck output and stderr land in the
`runs` row and stay there once the files are pruned (see test_stored_stream.py)
-- for as long as the index exists, on every install, forever. That is
unbounded growth by design, and the whole reason `index.db` on the operator's
own machine reached 751 MB.

The retention trim (_trim_old_runs) is the fix: past a configurable window
(index_retention_days, default 30, 0 = keep forever) it clears the large text
columns of an already-pruned row and marks it `trimmed=1`, but never touches
the row itself -- job, start, status, cost, duration, session, model, note,
cause and every other summary field survive for good. It runs inside
ingest()'s own write lock, at most once a day, and in bounded batches so a
day with a large backlog cannot turn one ingest() pass into a long stall.
"""

import json

import pytest

DAY = 86_400


@pytest.fixture
def reset_retention(srv):
    """The setting lives in app.db's `prefs` table, which -- unlike index.db
    -- clean_data does not wipe between tests (it is not part of the
    disposable index; see load_settings' own comment). Put it back to the
    default before and after every test in this file."""
    conn = srv.app_conn()
    conn.execute("DELETE FROM prefs WHERE key=?", ("index_retention_days",))
    conn.commit()
    conn.close()
    yield srv
    conn = srv.app_conn()
    conn.execute("DELETE FROM prefs WHERE key=?", ("index_retention_days",))
    conn.commit()
    conn.close()


def _journal_run(srv, jid, start, blob="x" * 4000):
    """One journal line for `jid`, with real files behind it so ingest() can
    read and then prune them -- retention only ever touches a row already
    `pruned` (files gone), so a test must earn that state honestly, the same
    way test_index_compaction.py's `_fill` does."""
    stem = srv.DATA_DIR / "logs" / jid / f"run-{start}.json"
    stem.parent.mkdir(parents=True, exist_ok=True)
    stem.write_text(json.dumps({"result": blob, "total_cost_usd": 0.02}))
    (stem.with_name(stem.stem + ".stream.ndjson")).write_text(
        json.dumps({"type": "system", "subtype": "init", "session_id": "s-" + str(start),
                    "model": "claude-opus-5"}) + "\n")
    line = json.dumps({"id": jid, "status": "success", "start": start,
                       "end": start + 60, "duration": 60, "cost": 0.02,
                       "session": "s-" + str(start), "log": str(stem),
                       "note": "", "cause": ""})
    with open(srv.RUNS_FILE, "a") as f:
        f.write(line + "\n")
    return stem


def _row(srv, jid, start):
    conn = srv.db_conn()
    try:
        return conn.execute("SELECT * FROM runs WHERE job=? AND start=?",
                            (jid, start)).fetchone()
    finally:
        conn.close()


def test_a_run_past_the_window_is_trimmed(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    now = 2_000_000_000
    old_start = now - 40 * DAY
    _journal_run(srv, "j-old", old_start)
    srv.ingest()
    row = _row(srv, "j-old", old_start)
    assert row["pruned"] == 1, "the fixture must earn a pruned row for the trim to see"

    conn = srv.db_conn()
    trimmed = srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    assert trimmed == 1
    row = _row(srv, "j-old", old_start)
    assert row["trimmed"] == 1
    assert row["stream"] == ""
    assert row["result_json"] == ""
    assert row["precheck_txt"] == ""
    assert row["stderr"] == ""


def test_a_run_inside_the_window_is_left_alone(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    now = 2_000_000_000
    recent_start = now - 10 * DAY
    _journal_run(srv, "j-recent", recent_start)
    srv.ingest()
    row = _row(srv, "j-recent", recent_start)
    assert row["pruned"] == 1

    conn = srv.db_conn()
    trimmed = srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    assert trimmed == 0
    row = _row(srv, "j-recent", recent_start)
    assert row["trimmed"] == 0
    assert row["stream"] != ""
    assert row["result_json"] != ""


def test_summary_fields_survive_a_trim(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    now = 2_000_000_000
    old_start = now - 90 * DAY
    _journal_run(srv, "j-summary", old_start)
    srv.ingest()

    conn = srv.db_conn()
    srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    row = _row(srv, "j-summary", old_start)
    assert row["trimmed"] == 1
    assert row["job"] == "j-summary"
    assert row["start"] == old_start
    assert row["status"] == "success"
    assert row["cost"] == 0.02
    assert row["duration"] == 60
    assert row["session"] == "s-" + str(old_start)


def test_zero_disables_the_trim(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 0)
    now = 2_000_000_000
    old_start = now - 400 * DAY
    _journal_run(srv, "j-forever", old_start)
    srv.ingest()

    conn = srv.db_conn()
    trimmed = srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    assert trimmed == 0
    row = _row(srv, "j-forever", old_start)
    assert row["trimmed"] == 0
    assert row["stream"] != ""


def test_the_trim_runs_at_most_once_a_day(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    now = 2_000_000_000
    old_start = now - 60 * DAY
    _journal_run(srv, "j-once", old_start)
    srv.ingest()

    conn = srv.db_conn()
    first = srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()
    assert first == 1

    # A second run of the very old row, further out of the window still,
    # minutes later: the daily gate must refuse it even though the row would
    # otherwise still qualify (it is already trimmed anyway, but a second
    # candidate row proves the gate, not just the "nothing left to do" case).
    newer_but_old_start = now - 45 * DAY
    _journal_run(srv, "j-once-2", newer_but_old_start)
    srv.ingest()

    conn = srv.db_conn()
    second = srv._trim_old_runs(conn, True, now=now + 60)
    conn.commit()
    conn.close()
    assert second == 0, "the daily gate must refuse a trim run under a day after the last one"

    row = _row(srv, "j-once-2", newer_but_old_start)
    assert row["trimmed"] == 0

    # A day later, the gate opens again and picks up what it deferred.
    conn = srv.db_conn()
    third = srv._trim_old_runs(conn, True, now=now + DAY + 60)
    conn.commit()
    conn.close()
    assert third == 1
    row = _row(srv, "j-once-2", newer_but_old_start)
    assert row["trimmed"] == 1


def test_the_trim_batches_a_large_backlog(reset_retention, clean_data, monkeypatch):
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    monkeypatch.setattr(srv, "TRIM_BATCH_ROWS", 2)
    monkeypatch.setattr(srv, "TRIM_MAX_BATCHES", 2)
    now = 2_000_000_000
    old_start = now - 90 * DAY
    for i in range(7):
        _journal_run(srv, f"j-batch-{i}", old_start + i)
    srv.ingest()

    conn = srv.db_conn()
    trimmed_first = srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()
    # TRIM_BATCH_ROWS * TRIM_MAX_BATCHES = 4, of the 7 eligible rows: bounded,
    # not everything in one call.
    assert trimmed_first == 4

    conn = srv.db_conn()
    trimmed_second = srv._trim_old_runs(conn, True, now=now + DAY)
    conn.commit()
    conn.close()
    assert trimmed_second == 3, "the remaining 3 rows are picked up the next day"


def test_a_resync_keeps_a_trimmed_row_trimmed(reset_retention, clean_data):
    """A resync (offset rewound, schema bump, etc.) must not un-trim a row --
    its preserved `art` is already empty (see _upsert's preserve branch), and
    the `trimmed` flag has to ride along with it or the dashboard would show
    a transcript that was, in fact, removed for good."""
    srv = reset_retention
    srv.set_setting("index_retention_days", 30)
    now = 2_000_000_000
    old_start = now - 90 * DAY
    stem = _journal_run(srv, "j-resync", old_start)
    srv.ingest()
    conn = srv.db_conn()
    srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()
    row = _row(srv, "j-resync", old_start)
    assert row["trimmed"] == 1

    # Force a full resync: the files are already gone (pruned), so the only
    # way to observe them again is through the preserved row.
    assert not stem.exists()
    (srv.DATA_DIR / ".reingest").touch()
    srv.ingest()

    row = _row(srv, "j-resync", old_start)
    assert row["trimmed"] == 1
    assert row["stream"] == ""
    assert row["result_json"] == ""
    assert row["job"] == "j-resync"


def test_never_touches_a_run_newer_than_the_window(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 5)
    now = 2_000_000_000
    just_inside = now - 4 * DAY
    just_outside = now - 6 * DAY
    _journal_run(srv, "j-inside", just_inside)
    _journal_run(srv, "j-outside", just_outside)
    srv.ingest()

    conn = srv.db_conn()
    srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    assert _row(srv, "j-inside", just_inside)["trimmed"] == 0
    assert _row(srv, "j-outside", just_outside)["trimmed"] == 1


def test_load_run_detail_reports_trimmed_and_the_window(reset_retention, clean_data):
    srv = reset_retention
    srv.set_setting("index_retention_days", 14)
    now = 2_000_000_000
    old_start = now - 90 * DAY
    _journal_run(srv, "j-detail", old_start)
    srv.ingest()
    conn = srv.db_conn()
    srv._trim_old_runs(conn, True, now=now)
    conn.commit()
    conn.close()

    detail = srv.load_run_detail("j-detail", old_start)
    assert detail is not None
    assert detail["trimmed"] is True
    assert detail["retention_days"] == 14


def test_the_page_states_the_removal_in_terminal_and_timeline(srv):
    """The dialog's Terminal and Timeline panes -- the two surfaces
    test_stored_stream.py already pins for the transcript-gap message -- each
    read `d.trimmed` and, when set, print the retention sentence as plain
    text (no innerHTML sink new to this change) rather than falling back to
    their ordinary "nothing here" copy."""
    page = srv.render_page("boot-authed")
    assert "d.trimmed" in page
    assert "The transcript was removed after " in page
    assert "retention_days" in page


def test_setting_set_validates_and_round_trips(reset_retention):
    srv = reset_retention
    code, payload = srv.set_setting("index_retention_days", 45)
    assert code == 200, payload
    assert srv.load_settings()["index_retention_days"] == 45

    code, payload = srv.set_setting("index_retention_days", -1)
    assert code == 400
    code, payload = srv.set_setting("index_retention_days", 3.5)
    assert code == 400
    code, payload = srv.set_setting("bogus_key", 5)
    assert code == 400

    code, payload = srv.set_setting("index_retention_days", 0)
    assert code == 200
    assert srv.load_settings()["index_retention_days"] == 0
