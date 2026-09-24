"""The account a run signed in as, carried from the journal and the slot to
the run dialog. Two ADDITIVE columns (`account`, `account_dir`) and a schema
bump that re-reads the journal; a record from before accounts reads empty.

Also: the 6 -> 7 bump itself, and why ingest() must backfill those two
columns in place (LIGHT_SCHEMA_BUMPS) rather than pay for a full resync --
see bin/agentloop-server's SCHEMA_VERSION comment and ingest()'s own
docstring. The production incident this covers: a 606 MB index, 464 runs,
most pruned, held the write lock for ~7 minutes on this exact bump."""
import json
import os
import sqlite3

OLD_CREATE = """CREATE TABLE runs (
    key TEXT PRIMARY KEY, job TEXT, start INTEGER, status TEXT,
    duration INTEGER, cost REAL, session TEXT, log TEXT, forced INTEGER,
    precheck_note TEXT, result_json TEXT, stream TEXT, precheck_txt TEXT,
    stderr TEXT, doc TEXT, project TEXT, model TEXT, model_id TEXT,
    note TEXT, resumed_from TEXT, cause TEXT, platform TEXT, cost_basis TEXT,
    tokens TEXT, pruned INTEGER DEFAULT 0)"""

_SIX_COLS = ("key", "job", "start", "status", "duration", "cost", "session", "log",
             "forced", "precheck_note", "result_json", "stream", "precheck_txt",
             "stderr", "doc", "project", "model", "model_id", "note",
             "resumed_from", "cause", "platform", "cost_basis", "tokens", "pruned")

SENTINEL_JSON = json.dumps({"result": "sentinel-result"})
SENTINEL_STREAM = "sentinel-stream-content"
SENTINEL_PRECHECK = "sentinel-precheck"
SENTINEL_STDERR = "sentinel-stderr"
SENTINEL_DOC = "sentinel-doc-content"


def _record(**over):
    rec = {"id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
           "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json", "note": "",
           "cause": "", "forced": False, "precheck": "", "project": "", "model": "opus",
           "model_id": "claude-opus-5", "resumed_from": "", "platform": "anthropic"}
    rec.update(over)
    return rec


def _six_row(key, job, start, log):
    """One already-pruned row's values, schema-6 shape (_SIX_COLS's own
    order) -- real stored content a light bump must never touch."""
    return (key, job, start, "success", 100, 0.5, "s-" + job, log,
            0, "", SENTINEL_JSON, SENTINEL_STREAM, SENTINEL_PRECHECK, SENTINEL_STDERR,
            SENTINEL_DOC, "", "opus", "claude-opus-5", "", "", "", "anthropic",
            "reported", "{}", 1)


def _seed_schema_six(srv, schema="6"):
    """A DB at the given stored schema (schema 6's own shape -- no account
    columns), holding two already-pruned rows with real stored content and
    matching FTS rows, plus the journal that produced them: j1's record
    carries account fields, j2's does not. `offset`/`sig` are set to match
    the journal exactly as written here, so -- the schema aside -- ingest()
    sees nothing to resync: the only difference from a stable, already-
    indexed install is the schema number itself."""
    key1, key2 = "j1|1700000000|/no/such/j1.json", "j2|1700000100|/no/such/j2.json"
    srv.RUNS_FILE.write_text(
        json.dumps({"id": "j1", "start": 1700000000, "log": "/no/such/j1.json",
                    "account": "cliente-a", "account_dir": "/Users/me/.claude-a"}) + "\n"
        + json.dumps({"id": "j2", "start": 1700000100, "log": "/no/such/j2.json"}) + "\n")
    size = srv.RUNS_FILE.stat().st_size
    sig = srv._ndjson_sig()
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    placeholders = ",".join("?" * len(_SIX_COLS))
    cols_sql = ",".join(_SIX_COLS)
    conn.execute(f"INSERT INTO runs ({cols_sql}) VALUES ({placeholders})",
                 _six_row(key1, "j1", 1700000000, "/no/such/j1.json"))
    conn.execute(f"INSERT INTO runs ({cols_sql}) VALUES ({placeholders})",
                 _six_row(key2, "j2", 1700000100, "/no/such/j2.json"))
    conn.execute("CREATE VIRTUAL TABLE runs_fts USING fts5(key UNINDEXED, content)")
    conn.execute("INSERT INTO runs_fts (key, content) VALUES (?,?)", (key1, SENTINEL_DOC))
    conn.execute("INSERT INTO runs_fts (key, content) VALUES (?,?)", (key2, SENTINEL_DOC))
    conn.execute("INSERT INTO meta (key, value) VALUES ('schema', ?)", (schema,))
    conn.execute("INSERT INTO meta (key, value) VALUES ('offset', ?)", (str(size),))
    conn.execute("INSERT INTO meta (key, value) VALUES ('sig', ?)", (sig,))
    conn.commit()
    conn.close()
    return key1, key2


def _watch_upsert(srv, monkeypatch):
    """A spy on the real _upsert -- calls still go through (so ingest() can
    complete normally and its result can be inspected afterwards), but every
    call is counted, so a test can prove whether the full/incremental path
    (the only two callers of _upsert) ran at all."""
    calls = []
    orig = srv._upsert

    def wrapper(*a, **k):
        calls.append(1)
        return orig(*a, **k)

    monkeypatch.setattr(srv, "_upsert", wrapper)
    return calls


def test_the_schema_is_seven(srv):
    assert srv.SCHEMA_VERSION == "7"


def test_the_six_to_seven_bump_is_listed_as_light(srv):
    """The whole reason ingest() can skip the full resync for this exact
    bump: both new columns are copied straight off the journal record, no
    artifact read involved."""
    assert srv.LIGHT_SCHEMA_BUMPS[("6", "7")] == ("account", "account_dir")


def test_a_run_detail_names_its_account(srv, clean_data):
    srv.RUNS_FILE.write_text(
        json.dumps(_record(account="cliente-a", account_dir="/Users/me/.claude-a")) + "\n"
        + json.dumps(_record(id="j2", session="s-2", account="default", account_dir="")) + "\n"
        + json.dumps(_record(id="j3", session="s-3")) + "\n")
    d1 = srv.load_run_detail("j1", 1700000000)["record"]
    assert (d1["account"], d1["account_dir"]) == ("cliente-a", "/Users/me/.claude-a")
    d2 = srv.load_run_detail("j2", 1700000000)["record"]
    assert (d2["account"], d2["account_dir"]) == ("default", "")
    d3 = srv.load_run_detail("j3", 1700000000)["record"]
    assert (d3["account"], d3["account_dir"]) == ("", ""), "a record from before accounts reads empty"


def test_an_index_from_schema_six_gains_the_two_columns(srv, clean_data, monkeypatch):
    """6 -> 7 is a listed light bump (LIGHT_SCHEMA_BUMPS): with the journal
    otherwise unchanged (offset/sig already matching it), ingest() must
    backfill the row in place rather than run the full resync -- proven here
    by making the full path (_upsert) raise if it is reached at all."""
    def _boom(*a, **k):
        raise AssertionError("the full path ran: _upsert was called")
    monkeypatch.setattr(srv, "_upsert", _boom)

    srv.RUNS_FILE.write_text(json.dumps(_record(account="cliente-a", account_dir="/x/a")) + "\n")
    size = srv.RUNS_FILE.stat().st_size
    sig = srv._ndjson_sig()
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO meta (key, value) VALUES ('schema', '6')")
    conn.execute("INSERT INTO meta (key, value) VALUES ('offset', ?)", (str(size),))
    conn.execute("INSERT INTO meta (key, value) VALUES ('sig', ?)", (sig,))
    # A row already indexed under schema 6, as if a previous ingest had run.
    key = "j1|1700000000|/nope.json"
    conn.execute(
        "INSERT INTO runs (key, job, start, status, duration, cost, session, log,"
        " forced, precheck_note, result_json, stream, precheck_txt, stderr, doc,"
        " project, model, model_id, note, resumed_from, cause, platform, cost_basis,"
        " tokens, pruned) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (key, "j1", 1700000000, "success", 100, 0.5, "s-1", "/nope.json",
         0, "", "", "", "", "", "", "", "opus", "claude-opus-5", "", "", "",
         "anthropic", "reported", "{}", 0))
    conn.commit(); conn.close()

    srv.ingest()   # must not raise -- see _boom above

    conn = srv.db_conn()
    try:
        cols = [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
        row = conn.execute("SELECT account, account_dir FROM runs WHERE job='j1'").fetchone()
    finally:
        conn.close()
    assert {"account", "account_dir"} <= set(cols)
    assert (row["account"], row["account_dir"]) == ("cliente-a", "/x/a")


def test_a_schema_six_bump_alone_backfills_in_place_without_the_full_resync(srv, clean_data, monkeypatch):
    """The production incident this fix is for, at a two-row scale: an
    already-pruned run's stored content, doc and FTS row must survive
    ingest() byte for byte -- and the full/incremental path must never run
    at all, proven by making _upsert raise. j2's own journal record carries
    no account fields, so it must stay empty rather than inherit j1's."""
    key1, key2 = _seed_schema_six(srv)

    def _boom(*a, **k):
        raise AssertionError("the full path ran: _upsert was called")
    monkeypatch.setattr(srv, "_upsert", _boom)

    srv.ingest()   # must not raise -- see _boom above

    conn = srv.db_conn()
    try:
        assert srv._meta_get(conn, "schema") == "7"
        row1 = conn.execute("SELECT * FROM runs WHERE key=?", (key1,)).fetchone()
        row2 = conn.execute("SELECT * FROM runs WHERE key=?", (key2,)).fetchone()
        fts1 = conn.execute("SELECT content FROM runs_fts WHERE key=?", (key1,)).fetchone()
        fts2 = conn.execute("SELECT content FROM runs_fts WHERE key=?", (key2,)).fetchone()
    finally:
        conn.close()

    assert (row1["account"], row1["account_dir"]) == ("cliente-a", "/Users/me/.claude-a")
    assert (row2["account"] or "", row2["account_dir"] or "") == ("", ""), \
        "j2's journal record carries no account fields -- it must stay empty, not inherit j1's"
    for row in (row1, row2):
        assert row["result_json"] == SENTINEL_JSON
        assert row["stream"] == SENTINEL_STREAM
        assert row["precheck_txt"] == SENTINEL_PRECHECK
        assert row["stderr"] == SENTINEL_STDERR
        assert row["doc"] == SENTINEL_DOC
        assert row["pruned"] == 1
    assert fts1["content"] == SENTINEL_DOC
    assert fts2["content"] == SENTINEL_DOC


def test_a_stored_schema_outside_the_table_still_takes_the_full_resync(srv, clean_data, monkeypatch):
    """schema 5 -> 7 is not a listed light bump (only 6 -> 7 is) -- even with
    the journal otherwise unchanged, it must take the full resync."""
    _seed_schema_six(srv, schema="5")
    calls = _watch_upsert(srv, monkeypatch)

    srv.ingest()

    assert calls, "schema '5' -> '7' is not a listed light bump; it must take the full resync"
    conn = srv.db_conn()
    try:
        assert srv._meta_get(conn, "schema") == "7"
    finally:
        conn.close()


def test_a_schema_bump_with_the_reingest_flag_still_takes_the_full_resync(srv, clean_data, monkeypatch):
    """6 -> 7 alone is a light bump, but a forced .reingest flag means the
    journal may have been rewritten (a job/project rename edits history) --
    that always wins, on an otherwise-eligible schema bump or not."""
    _seed_schema_six(srv)
    (srv.DATA_DIR / ".reingest").touch()
    calls = _watch_upsert(srv, monkeypatch)

    srv.ingest()

    assert calls, "a forced reingest must take the full resync even on an eligible schema bump"


def test_a_schema_bump_with_a_changed_sig_still_takes_the_full_resync(srv, clean_data, monkeypatch):
    """6 -> 7 alone is a light bump, but a stored signature that no longer
    matches the journal's head means it may have been rewritten -- that
    always wins too, the same as the forced flag above."""
    _seed_schema_six(srv)
    conn = srv.db_conn()
    conn.execute("UPDATE meta SET value='does-not-match' WHERE key='sig'")
    conn.commit(); conn.close()
    calls = _watch_upsert(srv, monkeypatch)

    srv.ingest()

    assert calls, "a changed signature must take the full resync even on an eligible schema bump"


def test_a_live_run_names_its_account_off_the_slot(srv, clean_data):
    """A run still going is not in the journal yet: its slot says which account
    it signed in as from its first second, as it says when it started."""
    srv.JOBS_FILE.write_text(json.dumps({"jobs": [{"id": "jlive", "project": "P"}]}))
    srv.PROJECTS_FILE.write_text(json.dumps({"projects": [{"name": "P"}]}))
    start = 1700000700
    slot = srv.DATA_DIR / "locks" / "jlive" / "4244"
    slot.mkdir(parents=True, exist_ok=True)
    (slot / "pid").write_text(str(os.getpid()))       # this process is alive, so the slot is
    (slot / "start").write_text(str(start))
    (slot / "boot").write_text(srv.boot_id())
    (slot / "account").write_text("cliente-a\n")
    (slot / "account_dir").write_text("/Users/me/.claude-a\n")
    assert srv.active_runs_for("jlive")[0]["account"] == "cliente-a"
    d = srv.load_run_detail("jlive", start)
    assert d is not None and d["live"] is True
    assert (d["record"]["account"], d["record"]["account_dir"]) == ("cliente-a", "/Users/me/.claude-a")
