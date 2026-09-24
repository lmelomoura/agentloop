# bin/security/evidence.py
"""What a unit's session proves it read -- off its own stream, never its word.

THE RESULT, NOT THE REQUEST. Measured on 1,620 real Claude Code `Read`
calls (2026-09-24): a read asked without a limit can come back cut by a
token cap (lines 1-1096 of 1,724), and a result that is not an error can
hold nothing ("shorter than the provided offset", "contents are empty").
Counting what was ASKED would swear to lines nobody saw. What the model
received is on the result: `tool_use_result.file.{startLine, numLines}` on
the main agent's `user` event (OpenCode's normaliser now writes the same
shape from `state.metadata.display`), and failing that the numbered lines
of the content itself (`N\\t` on Claude Code, `N: ` on OpenCode).

ONLY THE UNIT'S OWN READS. An event with a `parent_tool_use_id` is a
subagent's: the engine distributes the work, so a subagent's reads prove
nothing about this unit -- its launch is counted instead (`tasks`), and the
unit that launched one is judged a failed attempt (security/units.py).

ONLY INSIDE THE RUN. A path is made relative to the run's root after both
are resolved (a worktree under a symlinked temp dir is the same place);
anything outside the root is not this analysis's code and counts nothing.

THE CODEX CLI HAS NO READ TOOL, and its shell reads cannot be proven from
the stream (wrapped in `/bin/zsh -lc`, chained, capped at 8 KB, sometimes
lost). There the reading goes through `agentloop security read`, whose
ledger record is the proof; `with_served` joins it to the stream's reads,
and a unit on any platform may use either.
"""

import json
import os
import re
from dataclasses import dataclass, field

_GUIDE = re.compile(r"security-analysis/references/([A-Z][A-Z-]*)\.md")
_NUMBERED = re.compile(r"^\s*(\d+)(?:\t|: )", re.MULTILINE)


@dataclass(frozen=True)
class Session:
    reads: dict = field(default_factory=dict)
    tasks: int = 0
    guides: set = field(default_factory=set)


EMPTY = Session()


def _relative(path, root_real):
    if not isinstance(path, str) or not path:
        return None
    full = path if os.path.isabs(path) else os.path.join(root_real, path)
    real = os.path.realpath(full)
    if real != root_real and not real.startswith(root_real + os.sep):
        return None
    return os.path.relpath(real, root_real).replace(os.sep, "/")


def _numbered_range(content):
    if isinstance(content, list):
        content = "\n".join(b.get("text", "") for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str):
        return None
    numbers = [int(n) for n in _NUMBERED.findall(content)]
    return (min(numbers), max(numbers)) if numbers else None


def _structured_range(event):
    result = event.get("tool_use_result")
    file = result.get("file") if isinstance(result, dict) else None
    if not isinstance(file, dict):
        return None
    try:
        start, count = int(file.get("startLine")), int(file.get("numLines"))
    except (TypeError, ValueError):
        return None
    return (start, start + count - 1) if count > 0 else ()


def merge_spans(spans):
    """[(first, last)] line spans, sorted, with the overlapping and the
    adjacent joined into one. The package's one merge of spans: the proof of
    reading here, and what a read unit covered and what the deep scope still
    owes (security/units.py), all join theirs with it."""
    out = []
    for first, last in sorted(spans):
        if out and first <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], last))
        else:
            out.append((first, last))
    return out


def parse(lines, root) -> Session:
    root_real = os.path.realpath(str(root))
    asked, reads, guides, tasks = {}, {}, set(), 0
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict) or event.get("parent_tool_use_id"):
            continue
        message = event.get("message")
        blocks = message.get("content") if isinstance(message, dict) else None
        if not isinstance(blocks, list):
            continue
        if event.get("type") == "assistant":
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                guides.update(_GUIDE.findall(json.dumps(inp)))
                if block.get("name") in ("Task", "Agent"):
                    tasks += 1
                elif block.get("name") == "Read":
                    asked[block.get("id")] = inp.get("file_path") or inp.get("filePath")
        elif event.get("type") == "user":
            results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
            for block in results:
                path = asked.pop(block.get("tool_use_id"), None)
                if path is None or block.get("is_error"):
                    continue
                span = _structured_range(event) if len(results) == 1 else None
                if span is None:
                    span = _numbered_range(block.get("content"))
                rel = _relative(path, root_real)
                if span and rel:
                    reads.setdefault(rel, []).append(span)
    return Session(reads={p: merge_spans(s) for p, s in reads.items()}, tasks=tasks, guides=guides)


def read_session(stream_path, root) -> Session:
    if not stream_path:
        return EMPTY
    try:
        with open(stream_path, encoding="utf-8", errors="replace") as handle:
            return parse(handle, root)
    except OSError:
        return EMPTY


def with_served(session, served) -> Session:
    reads = {p: list(s) for p, s in session.reads.items()}
    for path, first, last in served:
        reads.setdefault(path, []).append((int(first), int(last)))
    return Session(reads={p: merge_spans(s) for p, s in reads.items()},
                   tasks=session.tasks, guides=set(session.guides))


def missing(ranges, reads) -> list:
    """The part of each wanted range no read covers, as ranges of its own. A
    range untouched keeps its bytes; a piece of one carries 0 (only its lines
    are known)."""
    out = []
    for wanted in ranges:
        first, last = int(wanted["first"]), int(wanted["last"])
        cursor, gaps = first, []
        for a, b in merge_spans(reads.get(wanted["path"], [])):
            if b < cursor or a > last:
                continue
            if a > cursor:
                gaps.append((cursor, a - 1))
            cursor = max(cursor, b + 1)
            if cursor > last:
                break
        if cursor <= last:
            gaps.append((cursor, last))
        for a, b in gaps:
            whole = (a, b) == (first, last)
            out.append({"path": wanted["path"], "first": a, "last": b,
                        "bytes": int(wanted.get("bytes", 0)) if whole else 0})
    return out
