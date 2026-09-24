"""The account a run signed in as, carried from the journal and the slot to
the run dialog. Two ADDITIVE columns (`account`, `account_dir`) and a schema
bump that re-reads the journal; a record from before accounts reads empty."""
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


def _record(**over):
    rec = {"id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
           "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json", "note": "",
           "cause": "", "forced": False, "precheck": "", "project": "", "model": "opus",
           "model_id": "claude-opus-5", "resumed_from": "", "platform": "anthropic"}
    rec.update(over)
    return rec


def test_the_schema_is_seven(srv):
    assert srv.SCHEMA_VERSION == "7"


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


def test_an_index_from_schema_six_gains_the_two_columns(srv, clean_data):
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO meta (key, value) VALUES ('schema', '6')")
    conn.commit(); conn.close()
    srv.RUNS_FILE.write_text(json.dumps(_record(account="cliente-a", account_dir="/x/a")) + "\n")
    srv.ingest()
    conn = srv.db_conn()
    try:
        cols = [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
        row = conn.execute("SELECT account, account_dir FROM runs WHERE job='j1'").fetchone()
    finally:
        conn.close()
    assert {"account", "account_dir"} <= set(cols)
    assert (row["account"], row["account_dir"]) == ("cliente-a", "/x/a")


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
