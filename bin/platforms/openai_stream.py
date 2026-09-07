#!/usr/bin/env python3
"""Codex CLI JSONL -> Claude Code stream-json, one line at a time.

`codex exec --json` prints one event per line: thread.started, turn.started,
item.started / item.completed, turn.completed, turn.failed, error. Every
reader in this scheduler -- the watchdog, turn_is_over, bind_session, the
classifier, the dashboard's Timeline and Terminal -- reads the stream-json
shape Claude Code emits. This filter turns the one into the other at the
boundary, so none of those readers learns a second dialect.

Pure and unbuffered: stdin in, stdout out, one canonical line per Codex event
that has a translation, flushed at once (the watchdog measures the file
growing; the Terminal follows it live). Every raw line is copied to --raw-out
BEFORE anything is done with it, so a line that is not JSON, or an event this
filter has never seen, is never lost: it is copied and skipped, which is what
every reader already does with a truncated line.

The only other thing it knows is the price table (--pricing). The Codex
stream carries tokens and no dollars, so the final `result` carries an
ESTIMATE -- or null, with cost_basis "none", when the model has no price.
"""
import argparse
import json
import sys

OUTPUT_CAP = 8192               # bytes of a command's output kept in a tool_result
QUOTA_PHRASE = "hit your usage limit"


def load_price(path, model):
    """The per-1M price row for `model`, or None: no file, no row, or a null
    in any of the three billed fields. `cache_write` may be absent (0)."""
    try:
        with open(path, encoding="utf-8") as fh:
            table = json.load(fh)
    except Exception:  # noqa: BLE001 -- a missing or broken table is "no price"
        return None
    row = (table.get("openai") or {}).get(model) if isinstance(table, dict) else None
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


def tokens_of(usage):
    """The five counters of a turn.completed `usage`, as ints, missing = 0."""
    u = usage if isinstance(usage, dict) else {}

    def n(key):
        v = u.get(key)
        return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0

    return {"input": n("input_tokens"), "cached": n("cached_input_tokens"),
            "cache_write": n("cache_write_input_tokens"), "output": n("output_tokens"),
            "reasoning": n("reasoning_output_tokens")}


def estimate(tokens, price):
    """USD for one turn at `price` (USD per 1,000,000 tokens); None without a
    price. `output` already INCLUDES `reasoning` (measured: 15-effort-high),
    so reasoning is never billed a second time."""
    if price is None:
        return None
    uncached = max(0, tokens["input"] - tokens["cached"])
    usd = (uncached * price["input"] + tokens["cached"] * price["cached_input"]
           + tokens["cache_write"] * price["cache_write"] + tokens["output"] * price["output"])
    return round(usd / 1_000_000, 6)


def error_status(message):
    """The status a failed turn carries: the `status` of the JSON the CLI
    embeds in its message (04-unknown-model: 400), else 429 when the message
    is the quota refusal, else None. The engine's cause taxonomy reads it
    unchanged: 429 -> rate_limited, anything else -> api_error."""
    text = message or ""
    try:
        embedded = json.loads(text)
        if isinstance(embedded, dict):
            status = embedded.get("status")
            if isinstance(status, int) and not isinstance(status, bool):
                return status
    except Exception:  # noqa: BLE001
        pass
    if QUOTA_PHRASE in text.lower():
        return 429
    return None


class Normalizer:
    """One Codex event in, zero or more canonical events out."""

    def __init__(self, model, permission, cwd, price):
        self.model, self.permission, self.cwd, self.price = model, permission, cwd, price
        self.session = ""
        self.started = set()        # item ids whose tool_use is already out
        self.assistant_events = 0   # what `result.num_turns` reports
        self.last_text = ""         # the last agent_message: `result.result`
        self.pending_error = None   # an `error` waiting for its turn.failed
        self.done = False           # a result has been emitted

    def _msg(self, role, blocks):
        return {"type": "assistant" if role == "assistant" else "user",
                "message": {"role": role, "content": blocks},
                "session_id": self.session}

    def _assistant(self, blocks):
        self.assistant_events += 1
        return self._msg("assistant", blocks)

    def _tool_use(self, item):
        kind = item.get("type") or "item"
        if kind == "command_execution":
            block = {"type": "tool_use", "id": item.get("id"), "name": "Bash",
                     "input": {"command": item.get("command") or ""}}
        else:
            # Generic: the item minus its bookkeeping. It shows on the Timeline
            # under its own type instead of disappearing.
            inp = {k: v for k, v in item.items() if k not in ("id", "type", "status")}
            if kind == "file_change":
                inp["description"] = ", ".join(
                    f"{c.get('kind') or 'change'} {c.get('path') or '?'}"
                    for c in (item.get("changes") or []) if isinstance(c, dict))
            block = {"type": "tool_use", "id": item.get("id"), "name": kind, "input": inp}
        self.started.add(item.get("id"))
        return self._assistant([block])

    def _tool_result(self, item):
        if item.get("type") == "command_execution":
            out = item.get("aggregated_output") or ""
            if len(out.encode("utf-8")) > OUTPUT_CAP:
                out = out.encode("utf-8")[:OUTPUT_CAP].decode("utf-8", errors="ignore") \
                    + "\n...[truncated]"
            code = item.get("exit_code")
            is_error = code is not None and code != 0
        else:
            out, is_error = "", False
        return self._msg("user", [{"type": "tool_result", "tool_use_id": item.get("id"),
                                   "content": out, "is_error": is_error}])

    def _result(self, usage=None, error=None):
        self.done = True
        base = {"type": "result", "session_id": self.session, "platform": "openai",
                "num_turns": self.assistant_events, "permission_denials": []}
        if error is None:
            toks = tokens_of(usage)
            # No `usage` dict at all (turn.completed sent none) is not the same
            # as a turn that genuinely used zero tokens: tokens_of() defaults
            # every counter to zero either way, so without this guard a priced
            # model with no usage data would still get an "estimated" $0.00.
            # An EMPTY dict is that same absence wearing the key -- `{}` carries
            # no more information than no key at all, so it fails the guard too.
            cost = estimate(toks, self.price) if isinstance(usage, dict) and usage else None
            base.update({"subtype": "success", "is_error": False, "result": self.last_text,
                         # the names the engine's salvage and the modal already sum
                         "usage": {"input_tokens": toks["input"],
                                   "cache_read_input_tokens": toks["cached"],
                                   "cache_creation_input_tokens": toks["cache_write"],
                                   "output_tokens": toks["output"]},
                         "total_cost_usd": cost,
                         "cost_basis": "estimated" if cost is not None else "none",
                         "tokens": toks,
                         "api_error_status": None})
        else:
            base.update({"subtype": "error_during_execution", "is_error": True,
                         "result": error, "total_cost_usd": None, "cost_basis": "none",
                         "tokens": None, "api_error_status": error_status(error),
                         # every reader of `result` can sum `usage` blindly,
                         # win or lose -- an error turn billed nothing, not
                         # "nothing recorded"
                         "usage": {"input_tokens": 0, "cache_read_input_tokens": 0,
                                   "cache_creation_input_tokens": 0, "output_tokens": 0}})
        return base

    def feed(self, ev):
        kind = ev.get("type")
        if kind == "thread.started":
            self.session = ev.get("thread_id") or ""
            # FIRST line, always: session_from_stream reads five lines and stops.
            return [{"type": "system", "subtype": "init", "session_id": self.session,
                     "model": self.model, "platform": "openai",
                     "permissionMode": self.permission, "cwd": self.cwd, "tools": []}]
        if kind in ("item.started", "item.completed"):
            item = ev.get("item") or {}
            itype = item.get("type")
            if itype == "reasoning":
                return []                   # Claude's thinking is not drawn either
            if itype == "agent_message":
                if kind != "item.completed":
                    return []
                text = item.get("text") or ""
                self.last_text = text
                return [self._assistant([{"type": "text", "text": text}])]
            if itype == "error":
                if kind != "item.completed":
                    return []
                msg = item.get("message") or ""
                # Measured (04-unknown-model.jsonl line 2): this item can be a
                # BENIGN warning ("Defaulting to fallback metadata") that the
                # CLI carries on past. It is shown to the reader as text; only
                # a top-level `error` event (below) can end the run -- an
                # item-level one must never become the run's ending, or a run
                # cut off later with no turn.failed loses its salvage path.
                return [self._assistant([{"type": "text", "text": "error: " + msg}])]
            if kind == "item.started":
                return [self._tool_use(item)]
            out = []
            if item.get("id") not in self.started:
                out.append(self._tool_use(item))
            out.append(self._tool_result(item))
            return out
        if kind == "turn.completed":
            if self.done:              # one result per run: a later turn is ignored
                return []
            return [self._result(usage=ev.get("usage"))]
        if kind == "error":
            self.pending_error = ev.get("message") or self.pending_error or "error"
            return []
        if kind == "turn.failed":
            if self.done:              # one result per run: a later turn is ignored
                return []
            msg = ((ev.get("error") or {}).get("message")) or self.pending_error or "turn failed"
            self.pending_error = None
            return [self._result(error=msg)]
        return []                           # turn.started, and anything not seen yet

    def finish(self):
        """EOF. An `error` with no `turn.failed` after it still ends the run."""
        if self.pending_error and not self.done:
            msg, self.pending_error = self.pending_error, None
            return [self._result(error=msg)]
        return []


def main(argv=None):
    ap = argparse.ArgumentParser(description="Codex JSONL on stdin -> stream-json on stdout")
    ap.add_argument("--model", required=True, help="the slug the run asked for")
    ap.add_argument("--permission", required=True, help="the run's permission_mode")
    ap.add_argument("--cwd", required=True, help="the run's working directory")
    ap.add_argument("--pricing", default="", help="config/pricing.json")
    ap.add_argument("--raw-out", default="", help="where every raw line is copied")
    args = ap.parse_args(argv)
    price = load_price(args.pricing, args.model) if args.pricing else None
    norm = Normalizer(args.model, args.permission, args.cwd, price)
    raw = open(args.raw_out, "ab") if args.raw_out else None
    out = sys.stdout

    def emit(events):
        for e in events:
            out.write(json.dumps(e) + "\n")     # ASCII-safe whatever the locale
        out.flush()

    try:
        # Bytes in, so a locale with no UTF-8 (launchd's default) can neither
        # refuse a curly quote on the way in nor mangle the raw copy.
        for bline in sys.stdin.buffer:
            if raw is not None:
                raw.write(bline if bline.endswith(b"\n") else bline + b"\n")
                raw.flush()
            line = bline.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:  # noqa: BLE001 -- copied above, skipped here
                continue
            if isinstance(ev, dict):
                emit(norm.feed(ev))
        emit(norm.finish())
    finally:
        if raw is not None:
            raw.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
