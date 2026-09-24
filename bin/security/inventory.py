# bin/security/inventory.py
"""The deep profile's scope, listed before anyone reads a line of it.

WHY A LIST. `deep` promises "all versioned code". Until this module that
promise lived only in the skill's prose, and the agent that had to keep it
was the same agent that decided when it had: two analyses of a
~300,000-line repository closed `capped` because the agent chose to stop,
and below the size where a model gives up, `done` was only its word. The
inventory turns the promise into something the engine can check: the exact
files -- and, for a file too large for one reading, the exact line ranges --
a deep analysis has to read in full.

EVERY FILE LEFT OUT IS COUNTED UNDER THE RULE THAT LEFT IT OUT. The rules
run in a fixed order and the first that matches names the reason, so no file
is counted twice, and the first three paths under each reason travel with
the count into the coverage note:

  ignored          `ignore_paths` and the default noise filter (ignores.ignored)
  symlink          a tracked symlink: reading it reads wherever it points
  submodule        a gitlink: another repository's code
  dependency-tree  node_modules/, vendor/, .venv/, bower_components/
  lockfile         the dependency phase's own input
  unreadable       tracked, but the checkout cannot read it
  binary           a NUL byte, or not UTF-8
  generated        *.min.js/.min.mjs/.min.css/.map, a line over 5,000 bytes,
                   or more than 300 bytes per line on average
  prose            .md, .markdown, .rst, .adoc, .txt

`!defaults` (ignores.DEFAULTS_OFF) switches `generated` and `prose` off, on
top of the noise filter it already switched off. The others always apply: a
dependency tree is code nobody here wrote, a lockfile has its own phase, and
a binary has no lines to read.

LINES ARE COUNTED THE WAY A READER COUNTS THEM: the number of `\\n`, plus one
when the last byte is not one. Only `\\n` splits a line -- not `\\r`, form
feeds or the other separators `bytes.splitlines` honours -- because the Read
tool and `sed -n` both number lines that way, and the proof of reading
(security/evidence.py) compares these numbers with theirs.
"""

import subprocess
from pathlib import Path

from . import deps, ignores

# The size of one reading. A file up to this many bytes is one range; a
# larger one is cut into consecutive line ranges of at most this many bytes,
# and security/slices.py packs ranges into units of the same size: ~85k
# tokens of source, which keeps every unit's session far below any context
# window however large the repository is.
RANGE_BYTES = 300_000

DEPENDENCY_DIRS = frozenset({"node_modules", "vendor", ".venv", "bower_components"})
# What the dependency phase reads, plus the lockfiles of the ecosystems
# Trivy reads and security/deps.py does not.
LOCKFILES = deps.LOCKFILE_NAMES | frozenset({
    "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json", "Gemfile.lock",
    "Cargo.lock", "Pipfile.lock", "packages.lock.json", "mix.lock",
    "pubspec.lock", "gradle.lockfile", "bun.lockb"})
GENERATED_SUFFIXES = (".min.js", ".min.mjs", ".min.css", ".map")
LONGEST_LINE = 5_000
AVERAGE_LINE = 300
PROSE_SUFFIXES = (".md", ".markdown", ".rst", ".adoc", ".txt")
REASONS = ("ignored", "symlink", "submodule", "dependency-tree", "lockfile",
           "unreadable", "binary", "generated", "prose")
EXAMPLES = 3

_LABELS = {
    "ignored": "ignored by ignore_paths or the default filter",
    "symlink": "symlinks, never followed",
    "submodule": "submodules",
    "dependency-tree": "files in dependency trees",
    "lockfile": "lockfiles (read by the dependency phase)",
    "unreadable": "unreadable files",
    "binary": "binary or non-UTF-8 files",
    "generated": "generated or minified files",
    "prose": "prose documents",
}
_MODE_SYMLINK = "120000"
_MODE_GITLINK = "160000"


def count_lines(data: bytes) -> int:
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def _lines(data: bytes):
    """Each line WITH its terminating `\\n`, split on `\\n` only."""
    start, end_of_data = 0, len(data)
    while start < end_of_data:
        end = data.find(b"\n", start)
        if end == -1:
            yield data[start:]
            return
        yield data[start:end + 1]
        start = end + 1


def line_ranges(data: bytes, budget: int) -> list:
    """[first, last, bytes] ranges covering every line, each at most `budget`
    bytes -- except a single line longer than the budget, which is a range
    of its own: a line is never split, because nothing reads half of one."""
    ranges, first, size, number = [], 1, 0, 0
    for chunk in _lines(data):
        number += 1
        if size and size + len(chunk) > budget:
            ranges.append([first, number - 1, size])
            first, size = number, 0
        size += len(chunk)
    if number:
        ranges.append([first, number, size])
    return ranges


def _generated(name: str, data: bytes, lines: int) -> bool:
    if name.endswith(GENERATED_SUFFIXES):
        return True
    if not lines:
        return False
    longest = max(len(chunk.rstrip(b"\r\n")) for chunk in _lines(data))
    return longest > LONGEST_LINE or len(data) / lines > AVERAGE_LINE


def _tracked(root: Path):
    """(mode, path) for every entry the checkout's index tracks, or None
    when `root` is not a git checkout."""
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-s", "-z"],
                             capture_output=True, check=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    entries = []
    for record in out.split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        entries.append((meta.split(b" ", 1)[0].decode(),
                        path.decode("utf-8", "surrogateescape")))
    return entries


def _walked(root: Path) -> list:
    """The fallback for a root that is not a git checkout (a test's empty
    directory, a hand run): every regular file outside `.git`. Never what an
    engine run meets -- the orchestrator prepares a worktree."""
    out = []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if ".git" in rel.parts:
            continue
        if path.is_symlink():
            out.append((_MODE_SYMLINK, rel.as_posix()))
        elif path.is_file():
            out.append(("100644", rel.as_posix()))
    return out


def _classify(root: Path, mode: str, rel: str, patterns, defaults: bool):
    """(reason, None) for a file left out, (None, bytes) for one in scope."""
    if ignores.ignored(rel, patterns):
        return "ignored", None
    if mode == _MODE_SYMLINK:
        return "symlink", None
    if mode == _MODE_GITLINK:
        return "submodule", None
    parts = rel.split("/")
    if any(part in DEPENDENCY_DIRS for part in parts[:-1]):
        return "dependency-tree", None
    name = parts[-1]
    if name in LOCKFILES:
        return "lockfile", None
    try:
        data = (root / rel).read_bytes()
    except OSError:
        return "unreadable", None
    if b"\0" in data:
        return "binary", None
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return "binary", None
    if defaults and _generated(name, data, count_lines(data)):
        return "generated", None
    if defaults and name.lower().endswith(PROSE_SUFFIXES):
        return "prose", None
    return None, data


def build(root, patterns=()) -> dict:
    """The deep scope of the checkout at `root`, as the ledger's
    `analysis_inventory` table stores it. `files` is sorted by path; a
    file with no lines is listed with no ranges, because there is
    nothing in it to read."""
    root = Path(root)
    patterns = tuple(p for p in (patterns or ()) if p)
    defaults = ignores.defaults_apply(patterns)
    entries = _tracked(root)
    in_git = entries is not None
    if not in_git:
        entries = _walked(root)
    files = []
    excluded = {reason: {"count": 0, "examples": []} for reason in REASONS}
    for mode, rel in sorted(entries, key=lambda entry: entry[1]):
        reason, data = _classify(root, mode, rel, patterns, defaults)
        if reason:
            slot = excluded[reason]
            slot["count"] += 1
            if len(slot["examples"]) < EXAMPLES:
                slot["examples"].append(rel)
            continue
        lines = count_lines(data)
        files.append({"path": rel, "lines": lines, "bytes": len(data),
                      "ranges": line_ranges(data, RANGE_BYTES) if lines else []})
    return {"files": files, "excluded": excluded, "git": in_git,
            "totals": {"files": len(files),
                       "lines": sum(f["lines"] for f in files),
                       "bytes": sum(f["bytes"] for f in files)}}


def _plural(n: int, word: str) -> str:
    return f"{n:,} {word}{'' if n == 1 else 's'}"


def summary(scope: dict) -> str:
    """The `scope` coverage row's sentence: what the deep read covers, and
    what it leaves out, rule by rule, with examples."""
    totals = scope.get("totals") or {"files": 0, "lines": 0, "bytes": 0}
    text = (f"The deep scope is {_plural(totals['files'], 'file')} "
            f"({_plural(totals['lines'], 'line')}, {_plural(totals['bytes'], 'byte')}), "
            "each to be read in full.")
    if scope.get("git") is False:
        text += (" This root is not a git checkout, so every file under it was "
                 "listed, not only the versioned ones.")
    left = [(reason, slot) for reason, slot in (scope.get("excluded") or {}).items()
            if slot.get("count")]
    if left:
        text += " Left out by rule: " + "; ".join(
            f"{_LABELS.get(reason, reason)}: {slot['count']:,} "
            f"(e.g. {', '.join(slot['examples'])})" for reason, slot in left) + "."
    if any(reason in ("generated", "prose") for reason, _ in left):
        text += (' Add "!defaults" to the project\'s ignore_paths to read '
                 "generated files and prose as well.")
    return text
