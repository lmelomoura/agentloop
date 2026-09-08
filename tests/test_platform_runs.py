"""What a run records about its platform, and how the server carries it.

Three journal fields arrive with the OpenAI platform: `platform`, `cost_basis`
(reported | estimated | none) and `tokens`. The database gains them as
ADDITIVE columns (the runs table is never dropped: it holds the content of
pruned runs whose files are gone), old journal lines are backfilled, and the
raw Codex stream kept beside the normalized one is pruned with the rest.
"""
import json
import sqlite3
from pathlib import Path

OLD_CREATE = """CREATE TABLE runs (
    key TEXT PRIMARY KEY, job TEXT, start INTEGER, status TEXT,
    duration INTEGER, cost REAL, session TEXT, log TEXT, forced INTEGER,
    precheck_note TEXT, result_json TEXT, stream TEXT, precheck_txt TEXT,
    stderr TEXT, doc TEXT, project TEXT, model TEXT, model_id TEXT,
    note TEXT, resumed_from TEXT, cause TEXT, pruned INTEGER DEFAULT 0)"""


def _artifacts(srv, job, stamp, result, stream="", raw=None):
    d = srv.DATA_DIR / "logs" / job
    d.mkdir(parents=True, exist_ok=True)
    logp = d / f"{stamp}.json"
    logp.write_text(json.dumps(result))
    (d / f"{stamp}.stream.ndjson").write_text(stream)
    if raw is not None:
        (d / f"{stamp}.stream.ndjson.raw").write_text(raw)
    return logp


def _record(srv, **over):
    rec = {"id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
           "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json", "note": "",
           "cause": "", "forced": False, "precheck": "", "project": "", "model": "opus",
           "model_id": "claude-opus-5", "resumed_from": ""}
    rec.update(over)
    return rec


def _write_journal(srv, *recs):
    srv.RUNS_FILE.write_text("".join(json.dumps(r) + "\n" for r in recs))


def _columns(srv):
    conn = srv.db_conn()
    try:
        return [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
    finally:
        conn.close()


def test_an_old_database_gains_the_three_columns_without_losing_rows(srv, clean_data):
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO runs (key, job, start, status, pruned, result_json, stream)"
                 " VALUES ('j0|1|/gone.json', 'j0', 1, 'success', 1, '{\"result\":\"kept\"}', '')")
    conn.commit(); conn.close()
    _write_journal(srv, _record(srv, id="j0", start=1, log="/gone.json"))
    srv.ingest()
    cols = _columns(srv)
    assert {"platform", "cost_basis", "tokens"} <= set(cols)
    conn = srv.db_conn()
    row = conn.execute("SELECT result_json, pruned, platform FROM runs WHERE job='j0'").fetchone()
    conn.close()
    assert row["pruned"] == 1 and "kept" in row["result_json"]     # a pruned row survives the resync
    assert row["platform"] == "anthropic"


def test_a_journal_line_from_before_platforms_is_backfilled(srv, clean_data):
    logp = _artifacts(srv, "j1", "20260901T000000Z-1",
                      {"total_cost_usd": 0.5, "result": "RUN COMPLETE: ok",
                       "usage": {"input_tokens": 10, "cache_read_input_tokens": 3,
                                 "cache_creation_input_tokens": 1, "output_tokens": 4}})
    _write_journal(srv, _record(srv, log=str(logp)))
    srv.ingest()
    conn = srv.db_conn()
    row = conn.execute("SELECT platform, cost_basis, tokens FROM runs").fetchone()
    conn.close()
    assert row["platform"] == "anthropic"
    assert row["cost_basis"] == "reported"
    assert json.loads(row["tokens"]) == {"input": 10, "cached": 3, "cache_write": 1,
                                         "output": 4, "reasoning": 0}


def test_an_openai_record_keeps_its_fields_through_the_api(srv, clean_data):
    tokens = {"input": 32675, "cached": 28160, "cache_write": 0, "output": 123, "reasoning": 0}
    stream = json.dumps({"type": "system", "subtype": "init", "session_id": "thr-1",
                         "model": "gpt-5.6-sol", "platform": "openai"}) + "\n"
    logp = _artifacts(srv, "j2", "20260907T000000Z-2",
                      {"total_cost_usd": 0.031784, "cost_basis": "estimated", "tokens": tokens,
                       "result": "RUN COMPLETE: ok", "num_turns": 3, "session_id": "thr-1"},
                      stream=stream, raw='{"type":"thread.started","thread_id":"thr-1"}\n')
    _write_journal(srv, _record(srv, id="j2", log=str(logp), session="thr-1", cost=0.031784,
                                model="gpt-5.6-sol", model_id="gpt-5.6-sol", platform="openai",
                                cost_basis="estimated", tokens=tokens))
    runs = srv.load_data()["runs"]
    assert runs[0]["platform"] == "openai" and runs[0]["cost_basis"] == "estimated"
    d = srv.load_run_detail("j2", 1700000000)
    assert d["record"]["platform"] == "openai"
    assert d["record"]["cost_basis"] == "estimated"
    assert d["agent"]["tokens"] == tokens
    assert d["agent"]["cost_basis"] == "estimated"
    assert d["record"]["model_id"] == "gpt-5.6-sol"
    assert runs[0]["model_id"] == "gpt-5.6-sol" and runs[0]["model"] == "gpt-5.6-sol", \
        "the runs list carries the model, so a row can say what ran without opening it"


def test_the_raw_codex_stream_is_pruned_with_the_other_artifacts(srv, clean_data):
    logp = _artifacts(srv, "j3", "20260907T000000Z-3", {"result": "x", "total_cost_usd": 0},
                      stream='{"type":"result","result":"x"}\n', raw='{"type":"turn.completed"}\n')
    raw = logp.with_name(logp.stem + ".stream.ndjson.raw")
    assert raw.exists()
    _write_journal(srv, _record(srv, id="j3", log=str(logp)))
    srv.ingest()
    assert not raw.exists() and not logp.exists()


def test_the_prepare_sidecar_is_shown_in_the_run_and_pruned_with_the_other_artifacts(srv, clean_data):
    """On OpenAI the engine runs `security prepare` itself before the CLI and
    writes its output to `<log>.prepare` -- never to `.err`, whose bytes turn a
    clean run into a warning. The run's stderr carries it behind a one-line
    header, so a `prepare failed (rc N)` in tick.log can be diagnosed from the
    run dialog; the prune then takes the file with the run's other artifacts,
    as it takes the raw Codex stream. An empty sidecar adds nothing."""
    logp = _artifacts(srv, "j5", "20260907T000000Z-5", {"result": "x", "total_cost_usd": 0},
                      stream='{"type":"result","result":"x"}\n')
    prep = Path(str(logp) + ".prepare")
    rec = _record(srv, id="j5", log=str(logp), platform="openai")
    prep.write_text("")
    assert srv._read_artifacts(rec)["stderr"] == ""
    prep.write_text("trivy: misconfiguration scan timed out\nprepare failed (rc 1)\n")
    art = srv._read_artifacts(rec)
    assert art["stderr"] == "--- prepare ---\ntrivy: misconfiguration scan timed out\nprepare failed (rc 1)\n"
    Path(str(logp) + ".err").write_text("codex: warning\n")
    assert srv._read_artifacts(rec)["stderr"] == (
        "codex: warning\n--- prepare ---\ntrivy: misconfiguration scan timed out\nprepare failed (rc 1)\n"
    ), "the agent's own stderr comes first, the header keeps the two apart"
    _write_journal(srv, rec)
    srv.ingest()
    assert not prep.exists() and not logp.exists()
    d = srv.load_run_detail("j5", 1700000000)
    assert "--- prepare ---\ntrivy: misconfiguration scan timed out" in d["stderr"], \
        "the DB row is all that is left of the sidecar once the prune took it"


def test_a_record_with_no_tokens_stores_null_and_none(srv, clean_data):
    logp = _artifacts(srv, "j4", "20260907T000000Z-4",
                      {"is_error": True, "subtype": "no_result_event", "result": ""})
    _write_journal(srv, _record(srv, id="j4", log=str(logp), status="error", cause="killed",
                                platform="openai", cost_basis="none", tokens=None, cost=0))
    srv.ingest()
    d = srv.load_run_detail("j4", 1700000000)
    assert d["record"]["cost_basis"] == "none"
    assert d["agent"].get("tokens") is None


def test_a_live_run_reports_its_platform_from_the_stream(srv):
    assert srv._platform_from_stream('{"type":"system","subtype":"init","platform":"openai"}\n') == "openai"
    assert srv._platform_from_stream('{"type":"system","subtype":"init","model":"claude-opus-5"}\n') == "anthropic"
    assert srv._platform_from_stream("") == "anthropic"
