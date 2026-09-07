"""The Codex -> stream-json normalizer, tested on the measured fixtures.

Every fixture under test/fixtures/codex/ is a real `codex exec --json` run
(or the Codex rollout beside it), captured on 2026-09-05 and 2026-09-07 — no
event here was written from memory. The normalizer is pure: feed() takes one
Codex event and returns the canonical events it becomes, so these tests drive
it in-process; one test drives the CLI itself, because the FIFO launch in
run_job only ever sees that.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NORM = REPO / "bin" / "platforms" / "openai_stream.py"
FIX = REPO / "test" / "fixtures" / "codex"
EXAMPLE_PRICES = REPO / "config" / "pricing.example.json"

_spec = importlib.util.spec_from_file_location("openai_stream", NORM)
osm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(osm)

PRICE = {"input": 4.0, "cached_input": 0.4, "output": 20.0, "cache_write": 0.0}
THREAD_02 = "01a071d5-47b0-7343-bcbd-216945ef7927"


def events_of(name):
    out = []
    for line in (FIX / name).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:  # noqa: BLE001
            continue
    return out


def normalize(name=None, events=None, price=None, model="gpt-5.6-sol"):
    n = osm.Normalizer(model, "workspace-write", "/tmp/x", price)
    out = []
    for ev in (events if events is not None else events_of(name)):
        out.extend(n.feed(ev))
    out.extend(n.finish())
    return out


def as_text(events):
    return "\n".join(json.dumps(e) for e in events) + "\n"


# ------------------------------------------------------------ the shape

def test_the_first_line_is_the_init_event_carrying_the_thread_id():
    out = normalize("02-tool-use.jsonl")
    first = out[0]
    assert first["type"] == "system" and first["subtype"] == "init"
    assert first["session_id"] == THREAD_02
    assert first["model"] == "gpt-5.6-sol"          # what was ASKED for
    assert first["platform"] == "openai"
    assert first["permissionMode"] == "workspace-write"
    assert first["tools"] == []


def test_a_finished_turn_ends_in_a_success_result():
    out = normalize("02-tool-use.jsonl")
    last = out[-1]
    assert last["type"] == "result"
    assert last["subtype"] == "success" and last["is_error"] is False
    assert last["session_id"] == THREAD_02
    assert last["result"] == "done"                  # the last agent_message
    assert last["num_turns"] == sum(1 for e in out if e["type"] == "assistant")
    assert last["permission_denials"] == []
    assert last["platform"] == "openai"
    assert last["usage"] == {"input_tokens": 32675, "cache_read_input_tokens": 28160,
                             "cache_creation_input_tokens": 0, "output_tokens": 123}
    assert last["tokens"] == {"input": 32675, "cached": 28160, "cache_write": 0,
                              "output": 123, "reasoning": 0}
    assert "api_error_status" in last and last["api_error_status"] is None


def test_a_command_becomes_a_bash_tool_use_and_its_result():
    out = normalize("02-tool-use.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    results = [b for e in out if e["type"] == "user"
               for b in e["message"]["content"] if b["type"] == "tool_result"]
    assert uses == [{"type": "tool_use", "id": "item_1", "name": "Bash",
                     "input": {"command": "/bin/zsh -lc 'ls && cat a.txt'"}}]
    assert results[0]["tool_use_id"] == "item_1"
    assert "alpha" in results[0]["content"]
    assert results[0]["is_error"] is False


def test_the_server_timeline_draws_the_command(srv):
    turns = srv.parse_turns_text(as_text(normalize("02-tool-use.jsonl")))
    tools = [t for turn in turns for t in turn["tools"]]
    assert tools and tools[0]["tool"] == "Bash"
    assert "ls && cat a.txt" in tools[0]["hint"]


def test_a_truncated_copy_still_salvages_session_and_turns(srv):
    text = as_text(normalize("02-tool-use.jsonl"))
    cut = text[: len(text) // 2]
    last_text, turns, sess = srv._salvage_from_stream(cut)
    assert sess == THREAD_02
    assert turns >= 1


def test_events_that_have_no_translation_produce_nothing():
    assert normalize(events=[{"type": "turn.started"}]) == []
    n = osm.Normalizer("m", "read-only", "/", None)
    assert n.feed({"type": "item.started", "item": {"id": "r", "type": "reasoning"}}) == []
    assert n.feed({"type": "item.completed", "item": {"id": "r", "type": "reasoning"}}) == []


def test_a_file_change_is_a_generic_tool_use_naming_the_file():
    out = normalize("10-file-change-workspace-write.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    assert len(uses) == 1
    assert uses[0]["name"] == "file_change"
    assert uses[0]["input"]["description"].startswith("add /")
    assert uses[0]["input"]["description"].endswith("/marker.txt")
    for key in ("id", "type", "status"):
        assert key not in uses[0]["input"]


def test_an_unknown_item_type_is_a_generic_tool_use_with_an_empty_result():
    out = normalize("17-spawn-under-disable-multi-agent.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    results = [b for e in out if e["type"] == "user"
               for b in e["message"]["content"] if b["type"] == "tool_result"]
    assert uses[0]["name"] == "collab_tool_call"
    assert uses[0]["input"]["tool"] == "wait"
    assert results == [{"type": "tool_result", "tool_use_id": "item_0", "content": "",
                        "is_error": False}]


def test_a_completed_item_that_was_never_started_gets_its_tool_use_first():
    ev = {"type": "item.completed", "item": {"id": "x1", "type": "command_execution",
                                             "command": "true", "aggregated_output": "",
                                             "exit_code": 2, "status": "completed"}}
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"}, ev])
    kinds = [(e["type"], e["message"]["content"][0]["type"]) for e in out[1:]]
    assert kinds == [("assistant", "tool_use"), ("user", "tool_result")]
    assert out[2]["message"]["content"][0]["is_error"] is True   # exit 2


def test_a_long_command_output_is_cut_at_eight_kilobytes():
    big = "x" * 20_000
    ev = {"type": "item.completed", "item": {"id": "b", "type": "command_execution",
                                             "command": "yes", "aggregated_output": big,
                                             "exit_code": 0, "status": "completed"}}
    out = normalize(events=[ev])
    content = out[-1]["message"]["content"][0]["content"]
    assert len(content.encode()) < 9_000 and content.endswith("[truncated]")


# ------------------------------------------------------------ failures

def test_an_unknown_model_carries_the_embedded_status_400():
    out = normalize("04-unknown-model.jsonl")
    last = out[-1]
    assert last["type"] == "result" and last["is_error"] is True
    assert last["subtype"] == "error_during_execution"
    assert last["api_error_status"] == 400
    assert "not supported" in last["result"]
    assert last["cost_basis"] == "none" and last["total_cost_usd"] is None
    assert last["usage"] == {"input_tokens": 0, "cache_read_input_tokens": 0,
                             "cache_creation_input_tokens": 0, "output_tokens": 0}
    # the item-level error was also shown to the reader, as text
    texts = [b["text"] for e in out if e["type"] == "assistant"
             for b in e["message"]["content"] if b["type"] == "text"]
    assert any(t.startswith("error: ") for t in texts)


def test_an_item_level_error_is_shown_as_text_and_never_ends_the_run():
    # Measured (04-unknown-model.jsonl line 2): Codex emits item.completed
    # type "error" for a BENIGN warning ("Defaulting to fallback metadata")
    # and keeps going. If the run is later cut off with no top-level `error`
    # or `turn.failed`, this must not synthesize a result at finish() -- that
    # would rob the engine of its salvage path (which only fires when there
    # is NO result event) and turn a killed run into an error.
    out = normalize(events=[
        {"type": "thread.started", "thread_id": "t"},
        {"type": "item.completed", "item": {"id": "item_0", "type": "error",
                                            "message": "Model metadata for `x` not found."}},
        {"type": "item.completed", "item": {"id": "item_1", "type": "agent_message",
                                            "text": "done"}},
    ])
    assert out[-1]["type"] != "result"
    assert out[-1]["message"]["content"][0] == {"type": "text", "text": "done"}
    texts = [b["text"] for e in out if e["type"] == "assistant"
             for b in e["message"]["content"] if b["type"] == "text"]
    assert any(t.startswith("error: ") for t in texts)


def test_an_exhausted_quota_carries_429():
    last = normalize("quota-exhausted.jsonl")[-1]
    assert last["type"] == "result" and last["is_error"] is True
    assert last["api_error_status"] == 429


def test_an_error_with_no_turn_failed_still_ends_the_run_at_eof():
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"},
                            {"type": "error", "message": "boom"}])
    assert out[-1]["type"] == "result" and out[-1]["is_error"] is True
    assert out[-1]["result"] == "boom" and out[-1]["api_error_status"] is None


def test_a_run_cut_off_before_its_final_event_emits_no_result():
    evs = events_of("02-tool-use.jsonl")
    out = normalize(events=[e for e in evs if e["type"] != "turn.completed"])
    assert out[-1]["type"] != "result"


def test_only_one_result_is_ever_emitted_for_a_run():
    usage = {"input_tokens": 1, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
             "output_tokens": 1, "reasoning_output_tokens": 0}
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"},
                            {"type": "turn.completed", "usage": usage},
                            {"type": "turn.completed", "usage": usage}])
    assert sum(1 for e in out if e["type"] == "result") == 1


def test_error_status_reads_the_embedded_json_then_the_quota_phrase():
    assert osm.error_status(json.dumps({"status": 503})) == 503
    assert osm.error_status("You've hit your usage limit. Try again later.") == 429
    assert osm.error_status("something else") is None
    assert osm.error_status(json.dumps({"status": True})) is None   # bool is not a status


# ------------------------------------------------------------ the estimate

def test_the_estimate_follows_the_price_table():
    last = normalize("02-tool-use.jsonl", price=PRICE)[-1]
    expected = round(((32675 - 28160) * 4.0 + 28160 * 0.4 + 123 * 20.0) / 1_000_000, 6)
    assert last["total_cost_usd"] == expected
    assert last["cost_basis"] == "estimated"


def test_reasoning_tokens_are_reported_but_not_billed_twice():
    last = normalize("15-effort-high-reasoning-tokens.jsonl", price=PRICE)[-1]
    assert last["tokens"]["reasoning"] == 35 and last["tokens"]["output"] == 42
    expected = round(((16252 - 12032) * 4.0 + 12032 * 0.4 + 42 * 20.0) / 1_000_000, 6)
    assert last["total_cost_usd"] == expected


def test_without_a_price_the_cost_is_null_and_the_basis_says_so():
    last = normalize("02-tool-use.jsonl", price=None)[-1]
    assert last["total_cost_usd"] is None and last["cost_basis"] == "none"
    assert last["tokens"]["input"] == 32675          # tokens are still reported


def test_no_usage_on_turn_completed_means_no_estimate():
    # A price IS on file here -- the point is that with no `usage` dict at
    # all, tokens_of() defaults every counter to zero, and zero tokens must
    # never be read as a genuine, billable turn worth an estimated $0.00.
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"},
                            {"type": "turn.completed"}], price=PRICE)
    last = out[-1]
    assert last["type"] == "result" and last["subtype"] == "success"
    assert last["total_cost_usd"] is None and last["cost_basis"] == "none"
    assert last["tokens"] == {"input": 0, "cached": 0, "cache_write": 0,
                              "output": 0, "reasoning": 0}


def test_an_empty_usage_dict_is_the_same_absence_as_no_usage_at_all():
    # `turn.completed {"usage": {}}` -- the CLI sent the key with nothing in
    # it. `isinstance(usage, dict)` alone waves that through, and a priced
    # model then gets an "estimated" $0.00 off five zeroed counters, which is
    # exactly the false report the guard above exists to prevent.
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"},
                            {"type": "turn.completed", "usage": {}}], price=PRICE)
    last = out[-1]
    assert last["type"] == "result" and last["subtype"] == "success"
    assert last["total_cost_usd"] is None and last["cost_basis"] == "none"


def test_load_price_treats_null_and_missing_slugs_as_no_price(tmp_path):
    table = tmp_path / "p.json"
    table.write_text(json.dumps({"openai": {
        "priced": {"input": 1, "cached_input": 0.1, "output": 2, "cache_write": 0},
        "half": {"input": None, "cached_input": 0.1, "output": 2}}}))
    assert osm.load_price(str(table), "priced") == {"input": 1.0, "cached_input": 0.1,
                                                    "output": 2.0, "cache_write": 0.0}
    assert osm.load_price(str(table), "half") is None
    assert osm.load_price(str(table), "absent") is None
    assert osm.load_price(str(tmp_path / "nope.json"), "priced") is None


def test_the_example_table_prices_every_visible_catalog_model():
    table = json.loads(EXAMPLE_PRICES.read_text())["openai"]
    catalog = json.loads((FIX / "models-catalog.stripped.json").read_text())["models"]
    for m in catalog:
        if m["visibility"] != "list":
            continue
        row = table[m["slug"]]
        assert all(isinstance(row[k], (int, float)) for k in ("input", "cached_input", "output"))


# ------------------------------------------------------------ the CLI

def test_the_cli_normalizes_stdin_and_copies_every_raw_line(tmp_path):
    raw_in = (FIX / "02-tool-use.jsonl").read_text() + "this line is not json\n"
    raw_out = tmp_path / "copy.raw"
    p = subprocess.run([sys.executable, "-u", str(NORM), "--model", "gpt-5.6-sol",
                        "--permission", "read-only", "--cwd", "/tmp/x",
                        "--pricing", str(EXAMPLE_PRICES), "--raw-out", str(raw_out)],
                       input=raw_in, capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    lines = [json.loads(ln) for ln in p.stdout.splitlines()]
    assert lines[0]["subtype"] == "init" and lines[-1]["type"] == "result"
    assert lines[-1]["cost_basis"] == "estimated"
    assert raw_out.read_text() == raw_in            # copied verbatim, bad line included
    assert p.stderr == ""
