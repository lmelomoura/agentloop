"""bin/platforms/costing.py -- the estimate a stopped/killed/crashed run gets
when it never reported a cost of its own.

The fixture (test/fixtures/costing/stopped-with-usage.ndjson) is synthetic
and neutral: an init event naming a model, two assistant "turns" each
repeated several times under the SAME message id and the SAME usage object
-- exactly what a real killed run's stream measured against the live
install looked like (one line per content block, all carrying that turn's
cumulative usage) -- and no result event at all, the shape of a run that was
stopped, killed, watchdog-timed-out or crashed before it could report
anything.
"""
import importlib.util
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MOD = REPO / "bin" / "platforms" / "costing.py"
FIX = REPO / "test" / "fixtures" / "costing"

_spec = importlib.util.spec_from_file_location("costing", MOD)
costing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(costing)

PRICE = {"input": 4.0, "cached_input": 0.2, "output": 20.0, "cache_write": 0.0}


def write_pricing(tmp_path, table):
    p = tmp_path / "pricing.json"
    p.write_text(json.dumps(table))
    return str(p)


def test_usage_deduplicated_per_message_id():
    events = costing.events_from_stream(str(FIX / "stopped-with-usage.ndjson"))
    tokens = costing.usage_from_events(events)
    # Each of the two turns appears on the stream 3x and 2x respectively,
    # always with the SAME usage -- a naive sum over every line would give
    # 5x/4x these numbers. Deduplication by message id keeps exactly one
    # figure per turn.
    assert tokens == {"input": 5, "cached": 2500, "cache_write": 1000, "output": 50}


def test_usage_from_events_is_none_without_any_usage():
    events = [{"type": "system", "subtype": "init", "model": "claude-opus-5-5"},
              {"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}}]
    assert costing.usage_from_events(events) is None


def test_estimate_matches_the_deduplicated_tokens():
    tokens = {"input": 5, "cached": 2500, "cache_write": 1000, "output": 50}
    # (5*4 + 2500*0.2 + 1000*0 + 50*20) / 1e6 = (20 + 500 + 0 + 1000) / 1e6
    assert costing.estimate(tokens, PRICE) == 0.00152


def test_estimate_stream_cost_stopped_run_with_usage_is_estimated_and_nonzero(tmp_path):
    pricing = write_pricing(tmp_path, {"anthropic": {"claude-opus-5-5": PRICE}})
    cost, basis, tokens = costing.estimate_stream_cost(str(FIX / "stopped-with-usage.ndjson"), pricing)
    assert basis == "estimated"
    assert cost == 0.00152
    assert cost > 0
    assert tokens == {"input": 5, "cached": 2500, "cache_write": 1000, "output": 50}


def test_estimate_stream_cost_without_a_price_row_is_none():
    # config/pricing.json exists but carries no row for this model: an
    # unpriced model must record "none", never a silent $0.00 that reads as
    # free.
    pricing = None
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        pricing = str(Path(d) / "pricing.json")
        Path(pricing).write_text(json.dumps({"anthropic": {}}))
        cost, basis, tokens = costing.estimate_stream_cost(str(FIX / "stopped-with-usage.ndjson"), pricing)
    assert cost is None
    assert basis == "none"
    assert tokens == {"input": 5, "cached": 2500, "cache_write": 1000, "output": 50}


def test_estimate_stream_cost_without_any_usage_is_none(tmp_path):
    stream = tmp_path / "empty.ndjson"
    stream.write_text('{"type":"system","subtype":"init","model":"claude-opus-5-5"}\n')
    pricing = write_pricing(tmp_path, {"anthropic": {"claude-opus-5-5": PRICE}})
    cost, basis, tokens = costing.estimate_stream_cost(str(stream), pricing)
    assert cost is None
    assert basis == "none"
    assert tokens is None


def test_provider_inferred_from_stream_defaults_to_anthropic():
    events = costing.events_from_stream(str(FIX / "stopped-with-usage.ndjson"))
    assert costing.provider_from_events(events) == "anthropic"


def test_provider_from_events_reads_an_explicit_platform():
    events = [{"type": "system", "subtype": "init", "model": "gpt-5.6-sol", "platform": "openai"}]
    assert costing.provider_from_events(events) == "openai"


def test_model_from_events_reads_the_init_line():
    events = costing.events_from_stream(str(FIX / "stopped-with-usage.ndjson"))
    assert costing.model_from_events(events) == "claude-opus-5-5"


def test_cli_prints_the_same_estimate(tmp_path, capsys):
    pricing = write_pricing(tmp_path, {"anthropic": {"claude-opus-5-5": PRICE}})
    rc = costing.main(["--stream", str(FIX / "stopped-with-usage.ndjson"), "--pricing", pricing])
    out = json.loads(capsys.readouterr().out)
    assert rc == 0
    assert out["cost"] == 0.00152
    assert out["cost_basis"] == "estimated"
    assert out["tokens"] == {"input": 5, "cached": 2500, "cache_write": 1000, "output": 50}
