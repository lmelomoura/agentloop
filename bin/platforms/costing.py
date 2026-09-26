#!/usr/bin/env python3
"""The cost of a run that never reported one.

A run's `result` event carries `total_cost_usd` -- Anthropic's own dollar
figure, or (see openai_stream.py, opencode_stream.py) an estimate those two
normalizers already make turn by turn from the stream's tokens, priced from
config/pricing.json under `cost_basis: "estimated"`. A run that is stopped,
killed, watchdog-timed-out or crashes never gets that far: no `result` event
ever reaches the stream, so the engine used to record spend_usd 0.0 for
several minutes of real claude-opus tokens -- silently under-reporting an
analysis's spend and letting a budget cap run over it without ever seeing
the cost that blew past it.

This module is the ONE place that estimate is made after the fact, from
whatever assistant events a killed run's stream DOES carry, so bin/agentloop
(a stopped run's salvage path in run_job) and security/orchestrator.py (a
run that died before its own close ran -- `_judge_orphan`) price it the same
way instead of each inventing their own arithmetic. The formula and the
table are the ones openai_stream.py / opencode_stream.py already use for
their own platforms (USD per 1,000,000 tokens, in config/pricing.json,
keyed by platform then by model) -- this is not a second pricing
implementation, it is the same one, run once more after the stream has gone
cold.

DEDUPLICATION, BY MESSAGE ID. A single assistant TURN reaches the stream as
several lines -- one per content block (text, tool_use, ...) -- and every
one of them carries the SAME message id and the SAME (cumulative, per-turn)
`usage` object (measured against a real killed run's stream: a message id
repeated five times, each with byte-identical usage). Summing every line's
usage, as the engine's own salvage note used to, multiplies a turn's real
cost by however many content blocks it had. The fix is to keep only the
LAST usage seen for each distinct message id, then sum those -- one figure
per turn, which is what the API actually billed.
"""
from __future__ import annotations

import argparse
import json
import sys

# platform (as bin/agentloop and the normalizers name it) -> the top-level
# key config/pricing.json prices it under. Anthropic's own CLI carries no
# "platform" field in its init event (only openai_stream.py and
# opencode_stream.py add one, for their own platform) -- provider_of below
# reads that absence as "anthropic", the only platform with none.
PROVIDER_KEYS = ("anthropic", "openai", "opencode")


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def load_price(pricing_path, provider, model):
    """The per-1,000,000-token price row for `provider`/`model`, or None: no
    file, no row for that provider, no row for that model, or a non-numeric
    value in any of the three billed fields. `cache_write` may be absent
    (read as 0) -- the same tolerance load_price has in openai_stream.py and
    opencode_stream.py, whose tables this reads unchanged."""
    if not pricing_path or not model:
        return None
    try:
        with open(pricing_path, encoding="utf-8") as fh:
            table = json.load(fh)
    except Exception:  # noqa: BLE001 -- a missing or broken table is "no price"
        return None
    if not isinstance(table, dict):
        return None
    row = (table.get(provider) or {}).get(model) if isinstance(table.get(provider), dict) else None
    if not isinstance(row, dict):
        return None
    prices = {}
    for key in ("input", "cached_input", "output"):
        v = row.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        prices[key] = float(v)
    cw = row.get("cache_write", 0)
    prices["cache_write"] = float(cw) if isinstance(cw, (int, float)) and not isinstance(cw, bool) else 0.0
    return prices


def estimate(tokens, price):
    """USD for `tokens` at `price` (USD per 1,000,000 tokens); None without a
    price. Anthropic's own convention (measured against a real stream):
    `input_tokens` already EXCLUDES both the cache-read and the cache-write
    tokens, so nothing here subtracts them back out -- unlike the Codex
    convention openai_stream.py's estimate() corrects for."""
    if price is None:
        return None
    usd = (tokens.get("input", 0) * price["input"] + tokens.get("cached", 0) * price["cached_input"]
           + tokens.get("cache_write", 0) * price["cache_write"] + tokens.get("output", 0) * price["output"])
    return round(usd / 1_000_000, 6)


def events_from_stream(stream_path):
    """Every JSON line of `stream_path`, tolerant of a truncated or garbled
    one anywhere in it (a killed run is usually cut off mid-write) -- the
    same tolerance run_job's own salvage jq already has."""
    events = []
    if not stream_path:
        return events
    try:
        with open(stream_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:  # noqa: BLE001 -- skipped, not fatal
                    continue
                if isinstance(ev, dict):
                    events.append(ev)
    except OSError:
        pass
    return events


def usage_from_events(events):
    """{"input","cached","cache_write","output"} summed across every
    DISTINCT assistant message id, keeping only the last (== the fullest,
    since a turn's usage only grows as it streams) usage seen for each one --
    see the module docstring. None when the stream carries no usage at all
    (nothing to estimate, as opposed to a turn that genuinely used zero
    tokens -- callers tell the two apart the same way the normalizers do:
    absence means "no data", not "free")."""
    last_seen = {}
    order = []
    for i, ev in enumerate(events):
        if ev.get("type") != "assistant":
            continue
        msg = ev.get("message")
        if not isinstance(msg, dict):
            continue
        usage = msg.get("usage")
        if not isinstance(usage, dict) or not usage:
            continue
        mid = msg.get("id") or f"__no_id_{i}"
        if mid not in last_seen:
            order.append(mid)
        last_seen[mid] = usage
    if not last_seen:
        return None
    tokens = {"input": 0, "cached": 0, "cache_write": 0, "output": 0}
    for mid in order:
        u = last_seen[mid]
        tokens["input"] += _num(u.get("input_tokens"))
        tokens["cached"] += _num(u.get("cache_read_input_tokens"))
        tokens["cache_write"] += _num(u.get("cache_creation_input_tokens"))
        tokens["output"] += _num(u.get("output_tokens"))
    return tokens


def model_from_events(events):
    """The model the run's own init event names, or "": the same field
    openai_stream.py and opencode_stream.py write into their synthesized
    init line, and the one Anthropic's own CLI already carries."""
    for ev in events:
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            m = ev.get("model")
            if isinstance(m, str) and m:
                return m
    return ""


def provider_from_events(events):
    """The platform a stream's own init event names, or "anthropic" when it
    names none -- only openai_stream.py and opencode_stream.py stamp one; the
    real Claude Code CLI's init event carries no "platform" key at all
    (measured against a real stream)."""
    for ev in events:
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            p = ev.get("platform")
            if isinstance(p, str) and p in PROVIDER_KEYS:
                return p
            return "anthropic"
    return "anthropic"


def estimate_stream_cost(stream_path, pricing_path, provider=None, model=""):
    """(cost, cost_basis, tokens) for a run with no reported cost. `cost` is
    None and `cost_basis` is "none" when the stream carries no usage, or
    when the model has no price -- exactly as the normalizers already
    distinguish "no data" from "free". `provider`/`model` override what the
    stream itself would say, for a caller that already knows them (run_job
    knows `platform`; the orchestrator, judging a dead run, does not, so it
    leaves both unset and this reads them off the stream)."""
    events = events_from_stream(stream_path)
    tokens = usage_from_events(events)
    if tokens is None:
        return None, "none", None
    prov = provider or provider_from_events(events)
    mdl = model or model_from_events(events)
    price = load_price(pricing_path, prov, mdl) if mdl else None
    cost = estimate(tokens, price) if price is not None else None
    basis = "estimated" if cost is not None else "none"
    return cost, basis, tokens


def main(argv=None):
    ap = argparse.ArgumentParser(description="estimate a stopped/killed run's cost from its own stream")
    ap.add_argument("--stream", required=True, help="the run's stream-json (or its raw copy)")
    ap.add_argument("--pricing", required=True, help="config/pricing.json")
    ap.add_argument("--provider", default="", help="platform key in pricing.json; default: read from the stream")
    ap.add_argument("--model", default="", help="model id to price; default: read from the stream")
    args = ap.parse_args(argv)
    cost, basis, tokens = estimate_stream_cost(args.stream, args.pricing, args.provider or None, args.model)
    json.dump({"cost": cost, "cost_basis": basis, "tokens": tokens}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
