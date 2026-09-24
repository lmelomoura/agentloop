"""A long run keeps the end of its transcript once it is indexed.

The index keeps each finished run's stream in its `stream` column, and the
run's files are pruned right after -- from then on the row is the only copy.
It used to keep the FIRST STREAM_CAP bytes (`read_bytes()[:cap]`), so every
run longer than that lost its END for good: the agent's last decisions, why
it stopped, the close. Security analyses pass the cap routinely; 11 of the
last 12 in one index were stored at ~1.99 MB, every one cut at the head. The
live view had the opposite fault: it kept the last STREAM_CAP characters, so
a long run still going lost its init event -- its session, its model.

Both now keep the first half and the last half, each cut on a line boundary,
joined by one marker line that is itself a stream event. Every reader passes
over it, and the two views a person reads (Terminal, Timeline) show a line
saying how much is missing, where it is missing.
"""
import json
import os
import re

INIT = {"type": "system", "subtype": "init", "session_id": "sess-long",
        "model": "claude-opus-5", "tools": []}
CLOSE = "CLOSE: stopping here — every file was read"
GAP_LINE = re.compile(r"… \d+\.\d MB of the transcript omitted …")


def _line(ev):
    # Raw UTF-8, not \u escapes: the CLI writes its stream that way.
    return json.dumps(ev, ensure_ascii=False) + "\n"


def _said(text, tool=None):
    content = [{"type": "text", "text": text}]
    if tool:
        content.append({"type": "tool_use", "id": "t", "name": "Read",
                        "input": {"file_path": tool}})
    return {"type": "assistant", "message": {"content": content}}


def _long_stream(turns=150, result_size=20_000, result=True):
    """A run whose stream passes STREAM_CAP: the init event, `turns` steps of
    the agent reading a file and a large result coming back, then the agent's
    close and -- unless the run was killed -- the result event. The em dash
    puts multi-byte characters on every agent line."""
    out = [_line(INIT)]
    for i in range(turns):
        out.append(_line(_said(f"step {i} — reading the next file", tool=f"/repo/src/f{i}.txt")))
        out.append(_line({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t", "content": "r" * result_size}]}}))
    out.append(_line(_said(CLOSE)))
    if result:
        out.append(_line({"type": "result", "subtype": "success", "result": "done",
                          "session_id": "sess-long", "num_turns": turns + 1}))
    return "".join(out)


def _marker(omitted):
    return _line({"type": "system", "subtype": "stream_truncated", "omitted_bytes": omitted})


def _artifacts(srv, job, stamp, result, stream):
    d = srv.DATA_DIR / "logs" / job
    d.mkdir(parents=True, exist_ok=True)
    logp = d / f"{stamp}.json"
    logp.write_text(json.dumps(result))
    (d / f"{stamp}.stream.ndjson").write_text(stream)
    return logp


def _record(**over):
    rec = {"id": "j-long", "status": "success", "start": 1700000000, "end": 1700003600,
           "duration": 3600, "cost": 4.2, "session": "sess-long", "log": "/nope.json",
           "note": "", "cause": "", "forced": True, "precheck": "", "project": "",
           "model": "opus", "model_id": "", "resumed_from": "", "platform": "anthropic"}
    rec.update(over)
    return rec


def _ingest_long_run(srv, **over):
    """One long run, journaled and ingested, its files pruned. Returns the
    stream that was on disk."""
    text = over.pop("stream", None) or _long_stream()
    result = over.pop("result", None) or {"result": "done", "num_turns": 151,
                                          "session_id": "sess-long"}
    logp = _artifacts(srv, over.get("id", "j-long"), "20260920T000000Z-1", result, text)
    srv.RUNS_FILE.write_text(json.dumps(_record(log=str(logp), **over)) + "\n")
    srv.ingest()
    assert not logp.exists(), "the files are pruned: the row is the only copy now"
    return text


def _stored(srv, job="j-long"):
    conn = srv.db_conn()
    try:
        return conn.execute("SELECT stream, model_id FROM runs WHERE job=?", (job,)).fetchone()
    finally:
        conn.close()


# ------------------------------------------------------------ the helper

def test_a_stream_within_the_cap_is_stored_byte_for_byte(srv):
    data = _long_stream(turns=3, result_size=100).encode()
    assert srv._fit_stream(data, len(data)) == data, "exactly at the cap is within it"
    assert srv._fit_stream(data, len(data) + 1) == data
    assert srv._fit_stream(b"", 100) == b""


def test_a_stream_over_the_cap_keeps_its_first_and_last_lines(srv):
    data = _long_stream(turns=40, result_size=700).encode()
    cap = 8_000
    out = srv._fit_stream(data, cap)
    assert len(out) <= cap, "the marker is paid for inside the cap, never on top of it"
    orig, kept = data.splitlines(keepends=True), out.splitlines(keepends=True)
    marks = [i for i, ln in enumerate(kept) if b'"stream_truncated"' in ln]
    assert len(marks) == 1, "exactly one marker, between the two halves"
    g = marks[0]
    head, tail = kept[:g], kept[g + 1:]
    assert head == orig[:len(head)], "the head is the stream's first whole lines"
    assert tail == orig[len(orig) - len(tail):], "the tail is its last whole lines"
    assert json.loads(kept[g]) == {"type": "system", "subtype": "stream_truncated",
                                   "omitted_bytes": len(data) - len(b"".join(head)) - len(b"".join(tail))}
    # Both halves are really there: a cut that keeps a line of each is no fix.
    assert len(b"".join(head)) > cap // 3 and len(b"".join(tail)) > cap // 3


def test_a_cut_that_lands_on_a_line_boundary_keeps_that_whole_line(srv):
    """Equal lines, and a cap whose halves hold a whole number of them: the
    head window ends exactly on a newline and the tail window starts exactly
    on a line, so neither half may give up a line it had room for -- and with
    both halves full, the marker still has to fit inside the cap."""
    lines = [b'{"n":%05d}\n' % i for i in range(100)]
    size = len(lines[0])
    cap = 2 * 20 * size + srv.STREAM_GAP_ROOM
    out = srv._fit_stream(b"".join(lines), cap)
    assert len(out) <= cap
    kept = out.splitlines(keepends=True)
    assert kept[:20] == lines[:20] and kept[21:] == lines[80:] and len(kept) == 41
    assert json.loads(kept[20])["omitted_bytes"] == 60 * size


def test_a_line_longer_than_half_the_cap_is_left_out_whole_never_split(srv):
    small = [b'{"n":%05d}\n' % i for i in range(30)]
    huge = b'{"type":"user","message":"' + b"z" * 5000 + b'"}\n'
    kept = srv._fit_stream(b"".join(small[:15]) + huge + b"".join(small[15:]), 1000) \
        .splitlines(keepends=True)
    assert kept[:15] == small[:15] and kept[16:] == small[15:], \
        "a line straddling the middle goes whole, and nothing around it does"
    assert not any(b"zzzz" in ln for ln in kept)
    # The same rule at the very start: a first line too big for the head
    # leaves no head at all, rather than half an event.
    first = srv._fit_stream(huge + b"".join(small), 1000)
    assert first.startswith(b'{"type":"system","subtype":"stream_truncated"')
    assert first.endswith(b"".join(small[-10:]))


def test_a_last_line_cut_off_mid_write_stays_at_the_end(srv):
    """A killed run is usually cut mid-line. That fragment is the newest byte
    the run wrote: it stays where it is, and the readers skip it as they
    always have."""
    lines = [b'{"n":%05d}\n' % i for i in range(100)]
    partial = b'{"type":"assistant","mess'
    out = srv._fit_stream(b"".join(lines) + partial, 400)
    assert out.endswith(lines[-1] + partial)


# ------------------------------------------------------------ the index

def test_an_indexed_long_run_keeps_the_end_of_its_transcript(srv, clean_data):
    text = _ingest_long_run(srv)
    raw = text.encode()
    assert len(raw) > srv.STREAM_CAP, "the fixture has to pass the cap to prove anything"
    row = _stored(srv)
    stored = row["stream"].encode()
    assert len(stored) <= srv.STREAM_CAP
    assert "�" not in row["stream"], "a cut on a newline never splits a character"
    kept, orig = stored.splitlines(keepends=True), raw.splitlines(keepends=True)
    assert json.loads(kept[0]) == INIT, "the head still opens the run"
    assert CLOSE in row["stream"], "the agent's close survives the cap"
    assert json.loads(kept[-1])["type"] == "result"
    for ln in kept:
        json.loads(ln)                  # every stored line is a whole event
    marks = [ln for ln in kept if b'"stream_truncated"' in ln]
    assert len(marks) == 1
    g = kept.index(marks[0])
    assert kept[:g] == orig[:g] and kept[g + 1:] == orig[len(orig) - (len(kept) - g - 1):]
    assert json.loads(marks[0])["omitted_bytes"] == len(raw) - (len(stored) - len(marks[0]))
    assert row["model_id"] == "claude-opus-5", \
        "a record that names no model id still gets it from the stored head"


def test_the_run_dialog_shows_the_start_the_gap_and_the_end(srv, clean_data):
    _ingest_long_run(srv)
    d = srv.load_run_detail("j-long", 1700000000)
    convo = d["conversation"]
    gaps = [i for i, c in enumerate(convo) if c.get("gap")]
    assert len(gaps) == 1, "the Terminal shows where the transcript was cut"
    g = gaps[0]
    assert GAP_LINE.fullmatch(convo[g]["text"]), convo[g]["text"]
    assert convo[0]["text"].startswith("step 0 "), "the start is there"
    assert convo[-1]["text"] == CLOSE, "and so is the end, after the gap"
    before = int(convo[g - 1]["text"].split()[1])
    after = int(convo[g + 1]["text"].split()[1])
    assert after > before + 1, "the steps on either side of the gap are not neighbours"

    turns = d["turns"]
    tgaps = [t for t in turns if t.get("gap")]
    assert len(tgaps) == 1 and tgaps[0]["text"] == convo[g]["text"], \
        "the Timeline shows the same gap, in the same words"
    assert "n" not in tgaps[0], "a gap is not a turn and takes no number"
    real = [t for t in turns if not t.get("gap")]
    assert [t["n"] for t in real] == list(range(1, len(real) + 1))
    assert real[-1]["text"] == CLOSE


def test_a_killed_long_run_salvages_its_real_last_message(srv, clean_data):
    """A run with no result event is rebuilt from its stream: the dialog says
    it did not finish and quotes the agent's last message. With the head
    alone that "last" message was one from about two megabytes in -- a
    sentence from the middle of the run, presented as the one it ended on."""
    _ingest_long_run(srv, id="j-killed", status="error", cause="killed",
                     stream=_long_stream(result=False),
                     result={"is_error": True, "subtype": "no_result_event", "result": ""})
    a = srv.load_run_detail("j-killed", 1700000000)["agent"]
    assert a["salvaged"] is True
    assert a["result"].endswith(CLOSE)
    assert a["session"] == "sess-long"


def test_a_long_live_run_keeps_its_start_and_its_newest_lines(srv, clean_data):
    """The live view read the stream's last STREAM_CAP characters: past the
    cap the init event fell out of the window, and with it the session and
    the model the dialog names for a run still going."""
    jid, start = "j-live-long", 1700001000
    logdir = srv.DATA_DIR / "logs" / jid
    logdir.mkdir(parents=True, exist_ok=True)
    logp = logdir / "20231114T222000Z-5100.json"
    (logdir / "20231114T222000Z-5100.stream.ndjson").write_text(_long_stream(result=False))
    slot = srv.DATA_DIR / "locks" / jid / "5100"
    slot.mkdir(parents=True, exist_ok=True)
    (slot / "pid").write_text(str(os.getpid()))       # this process is alive, so the slot is
    (slot / "start").write_text(str(start))
    (slot / "boot").write_text(srv.boot_id())
    (slot / "logfile").write_text(str(logp))
    d = srv.load_run_detail(jid, start)
    assert d is not None and d["live"] is True
    assert d["record"]["session"] == "sess-long", "the init event is in the head"
    assert d["record"]["model_id"] == "claude-opus-5"
    convo = d["conversation"]
    assert [c for c in convo if c.get("gap") and GAP_LINE.fullmatch(c["text"])]
    assert convo[0]["text"].startswith("step 0 ")
    assert convo[-1]["text"] == CLOSE, "the newest line is still the last one shown"


# ------------------------------------------------------------ the readers

def test_every_reader_of_a_stored_stream_passes_over_the_marker(srv):
    s = (_line(INIT)
         + _line({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10,
                  "error_status": 529, "error": "overloaded"})
         + _line(_said("before the gap")) + _marker(5_000_000)
         + _line(_said("after the gap")))
    assert srv._model_id_from_stream(s) == "claude-opus-5"
    assert srv._platform_from_stream(s) == "anthropic"
    assert srv._api_retries(s)["count"] == 1
    assert srv._salvage_from_stream(s) == ("after the gap", 2, "sess-long")
    assert [t.get("text") for t in srv.parse_turns_text(s)] == \
        ["before the gap", "… 4.8 MB of the transcript omitted …", "after the gap"]
    assert [c.get("text") for c in srv.parse_conversation(s)] == \
        ["before the gap", "… 4.8 MB of the transcript omitted …", "after the gap"]
    doc = srv._build_doc({"id": "j"}, {"stream": s})
    assert "before the gap" in doc and "after the gap" in doc


def test_sizes_read_the_way_the_page_writes_them(srv):
    assert srv._human_bytes(0) == "0 B"
    assert srv._human_bytes(900) == "900 B"
    assert srv._human_bytes(1536) == "1.5 KB"
    assert srv._human_bytes(1_258_291) == "1.2 MB"
    assert srv._human_bytes(3 * 1024 ** 3) == "3.0 GB"


def test_a_view_over_its_limit_keeps_both_ends_and_says_what_it_left_out(srv):
    """The Timeline listed the first 300 turns and the Terminal the first 400
    messages, then stopped -- so on a run with more, the end the index now
    keeps was still never on screen. Past the limit a view keeps its first
    half and its last half, and one line in between counts the rest."""
    text = "".join(_line(_said(f"step {i}")) for i in range(1000))
    turns = srv.parse_turns_text(text)
    real = [t for t in turns if not t.get("gap")]
    assert len(real) == 300
    assert (real[0]["text"], real[-1]["text"]) == ("step 0", "step 999")
    assert [t["text"] for t in turns if t.get("gap")] == ["… 700 turns not shown …"]
    assert turns[150].get("gap") and (turns[149]["n"], turns[151]["n"]) == (150, 851), \
        "a turn keeps its number, so the jump says how many are not shown"
    convo = srv.parse_conversation(text)
    real = [c for c in convo if not c.get("gap")]
    assert len(real) == 400 and real[-1]["text"] == "step 999"
    assert convo[200].get("gap") and convo[200]["text"] == "… 600 messages not shown …"
    one = srv.parse_conversation(text, limit=999)
    assert [c["text"] for c in one if c.get("gap")] == ["… 1 message not shown …"]


def test_a_stream_gap_inside_what_a_view_leaves_out_is_still_named(srv):
    """A capped stream's marker sits in the middle of the transcript, which is
    exactly where a view over its limit cuts. The one line left there has to
    say both things, or the reader never learns the transcript itself was
    cut."""
    text = ("".join(_line(_said(f"step {i}")) for i in range(500)) + _marker(5 * 1024 * 1024)
            + "".join(_line(_said(f"step {i}")) for i in range(500, 1000)))
    gaps = [t["text"] for t in srv.parse_turns_text(text) if t.get("gap")]
    assert gaps == ["… 700 turns not shown, and 5.0 MB of the transcript omitted …"]
    # A marker in the part a view keeps stays in its own place.
    text = ("".join(_line(_said(f"step {i}")) for i in range(100)) + _marker(2048)
            + "".join(_line(_said(f"step {i}")) for i in range(100, 1000)))
    gaps = [t["text"] for t in srv.parse_turns_text(text) if t.get("gap")]
    assert gaps == ["… 2.0 KB of the transcript omitted …", "… 700 turns not shown …"]
