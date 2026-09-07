"""Deleting a run must take its raw Codex stream with it.

The OpenAI launch writes `<stem>.stream.ndjson.raw` beside the normalized
`<stem>.stream.ndjson` (bin/agentloop, run_job's openai branch: the normalizer
is started with `--raw-out "$streamfile.raw"`). Two separate file-lists decide
what a run's deletion removes, and both were written before that file
existed, so both left it behind:

  - `_forget_stranded_row`, the reconciliation path for an index row whose
    journal line is already gone (the DB still has it, the journal does not).
  - `delete_run`'s own normal branch, for the common case: deleting a run
    that is still in the journal — the dashboard's delete button, for any run
    it currently lists.

One test per route, so neither can quietly start leaking the raw copy again.
"""

import json

JID = "j-raw-del"
START = 1700000000


def _make_files(data_dir, stamp):
    """The five original artifacts plus the new .raw copy, all real files."""
    d = data_dir / "logs" / JID
    d.mkdir(parents=True, exist_ok=True)
    logp = d / f"{stamp}.json"
    paths = {
        "json": logp,
        "stream": d / f"{stamp}.stream.ndjson",
        "raw": d / f"{stamp}.stream.ndjson.raw",
        "precheck": d / f"{stamp}.precheck.txt",
        "err": d / f"{stamp}.json.err",
        "watchdog": d / f"{stamp}.json.watchdog",
    }
    for p in paths.values():
        p.write_text("x")
    return paths


def test_forget_stranded_row_removes_the_raw_stream_too(srv, clean_data):
    """The reconciliation path: a DB row with no matching journal line."""
    paths = _make_files(srv.DATA_DIR, "20260907T000000Z-1")
    key = f"{JID}|{START}|{paths['json']}"
    conn = srv.db_conn()
    srv.db_init(conn)
    conn.execute(
        "INSERT INTO runs (key, job, start, log) VALUES (?, ?, ?, ?)",
        (key, JID, START, str(paths["json"])),
    )
    conn.commit()
    conn.close()

    removed = {"files": 0, "journal": 0, "db": 0}
    result = srv._forget_stranded_row(JID, START, removed)

    assert result is not None
    for name, p in paths.items():
        assert not p.exists(), f"{name} survived: {p}"
    assert removed["files"] == 6


def test_delete_run_removes_the_raw_stream_too(srv, clean_data):
    """The common case: the run is still in the journal (dashboard delete)."""
    paths = _make_files(srv.DATA_DIR, "20260907T000000Z-2")
    srv.RUNS_FILE.write_text(json.dumps({
        "id": JID, "status": "success", "start": START, "end": START + 60,
        "duration": 60, "cost": 0.1, "session": "s-1",
        "log": str(paths["json"]), "note": "", "cause": "",
    }) + "\n")

    removed = srv.delete_run(JID, START)

    assert removed is not None
    for name, p in paths.items():
        assert not p.exists(), f"{name} survived: {p}"
