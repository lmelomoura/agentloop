# tests/security/test_inventory.py
"""The deep scope: what a line-by-line read must cover, and what it leaves out by rule."""
import os
import subprocess

import pytest

from security import inventory

GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def _repo(tmp_path, files, links=()):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=GIT_ENV)
    for rel, data in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
    for rel, target in links:
        (root / rel).symlink_to(target)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    return root


def _paths(scope):
    return [f["path"] for f in scope["files"]]


def test_source_is_in_scope_with_its_lines_bytes_and_one_range(tmp_path):
    root = _repo(tmp_path, {"src/app.py": "a\nb\nc\n", "src/tail.py": "x\ny"})
    scope = inventory.build(root)
    assert _paths(scope) == ["src/app.py", "src/tail.py"]
    app, tail = scope["files"]
    assert (app["lines"], app["bytes"], app["ranges"]) == (3, 6, [[1, 3, 6]])
    assert tail["lines"] == 2, "a last line without a newline is still a line"
    assert scope["totals"] == {"files": 2, "lines": 5, "bytes": 9}
    assert scope["git"] is True


@pytest.mark.parametrize("rel, data, reason", [
    ("node_modules/lib/index.js", "x\n", "dependency-tree"),
    ("app/vendor/lib.php", "x\n", "dependency-tree"),
    ("package-lock.json", "{}\n", "lockfile"),
    ("yarn.lock", "x\n", "lockfile"),
    ("logo.png", b"\x89PNG\x00\x01", "binary"),
    ("legacy.c", b"caf\xe9\n", "binary"),
    ("public/app.min.js", "x\n", "generated"),
    ("dist/bundle.js", "x" * 5001 + "\n", "generated"),
    ("dist/wide.js", ("y" * 301 + "\n") * 10, "generated"),
    ("docs/guide.md", "# t\n", "prose"),
    ("tests/fixtures/key.pem", "k\n", "ignored"),
])
def test_each_rule_leaves_its_file_out_under_its_own_name(tmp_path, rel, data, reason):
    root = _repo(tmp_path, {rel: data, "src/keep.py": "k\n"})
    scope = inventory.build(root)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"][reason] == {"count": 1, "examples": [rel]}


def test_a_gitlink_is_left_out_as_a_submodule(tmp_path):
    root = _repo(tmp_path, {"src/keep.py": "k\n"})
    sha = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True,
                         text=True, check=True).stdout.strip()
    subprocess.run(["git", "-C", str(root), "update-index", "--add", "--cacheinfo",
                    f"160000,{sha},lib/other"], check=True, env=GIT_ENV)
    scope = inventory.build(root)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["submodule"] == {"count": 1, "examples": ["lib/other"]}


def test_a_tracked_file_the_checkout_cannot_read_is_left_out_as_unreadable(tmp_path):
    root = _repo(tmp_path, {"src/locked.py": "x\n", "src/keep.py": "k\n"})
    locked = root / "src" / "locked.py"
    locked.chmod(0)
    try:
        if os.access(locked, os.R_OK):
            pytest.skip("this user reads a mode-000 file (root)")
        scope = inventory.build(root)
    finally:
        locked.chmod(0o644)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["unreadable"] == {"count": 1, "examples": ["src/locked.py"]}


def test_the_long_line_limit_is_the_read_tools_in_characters_not_bytes(tmp_path):
    """Claude Code's Read and OpenCode's read cut a line past 2,000
    CHARACTERS and still count it: 2,001 of them make a file `generated`;
    1,500 two-byte characters (3,000 bytes) do not."""
    short = "k\n" * 20
    root = _repo(tmp_path, {"src/wide.js": short + "x" * 2001 + "\n",
                            "src/accents.py": short + "é" * 1500 + "\n",
                            "src/edge.py": short + "x" * 2000 + "\n"})
    scope = inventory.build(root)
    assert _paths(scope) == ["src/accents.py", "src/edge.py"]
    assert scope["excluded"]["generated"]["examples"] == ["src/wide.js"]
    assert all("wide" not in f for f in scope["files"])


def test_under_defaults_off_a_wide_line_stays_in_scope_and_is_named(tmp_path):
    root = _repo(tmp_path, {"src/wide.js": "a\n" + "y" * 2500 + "\nb\n" + "z" * 2001 + "\n"})
    (wide,) = inventory.build(root, ["!defaults"])["files"]
    assert (wide["path"], wide["wide"]) == ("src/wide.js", [2, 4])


def test_a_path_no_unit_can_be_shown_is_left_out_by_name(tmp_path):
    """A control character (or U+2028) in a name would forge lines in any
    prompt or `security read` header it is printed on, and a path whose
    quoting outgrows half of `read`'s budget can never be shown with a
    chunk: neither can ever be proven read, so neither is owed for ever --
    each is left out under `unprintable-path`, its example escaped."""
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "keep.py").write_text("k\n")
    (tmp_path / "src" / "a\nb.py").write_text("x\n")
    (tmp_path / "src" / "c d.py").write_text("x\n")
    deep = tmp_path / "q"
    for _ in range(3):
        deep = deep / ("'" * 200)
    deep.mkdir(parents=True)
    (deep / "e.py").write_text("x\n")
    scope = inventory.build(tmp_path)
    assert _paths(scope) == ["src/keep.py"]
    slot = scope["excluded"]["unprintable-path"]
    assert slot["count"] == 3
    assert "src/a\\nb.py" in slot["examples"] and "src/c\\u2028d.py" in slot["examples"]
    assert all("\n" not in e and " " not in e for e in slot["examples"])
    assert "no unit can be shown" in inventory.summary(scope)


def test_ignore_paths_leave_a_file_out_as_ignored(tmp_path):
    root = _repo(tmp_path, {"legacy/old.py": "x\n", "src/keep.py": "k\n"})
    scope = inventory.build(root, ["legacy/**"])
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["ignored"]["count"] == 1


def test_a_tracked_symlink_is_never_followed(tmp_path):
    root = _repo(tmp_path, {"src/keep.py": "k\n"}, links=[("escape", "/etc/hosts")])
    scope = inventory.build(root)
    assert _paths(scope) == ["src/keep.py"]
    assert scope["excluded"]["symlink"] == {"count": 1, "examples": ["escape"]}


def test_defaults_off_reads_generated_files_and_prose_but_never_dependency_trees(tmp_path):
    root = _repo(tmp_path, {"public/app.min.js": "x\n", "docs/guide.md": "# t\n",
                            "vendor/lib.php": "x\n", "src/keep.py": "k\n"})
    scope = inventory.build(root, ["!defaults"])
    assert _paths(scope) == ["docs/guide.md", "public/app.min.js", "src/keep.py"]
    assert scope["excluded"]["dependency-tree"]["count"] == 1


def test_line_ranges_cut_on_line_boundaries_within_the_budget():
    four = b"aaaa\nbbbb\ncccc\ndddd\n"          # four lines of five bytes
    assert inventory.line_ranges(four, 10) == [[1, 2, 10], [3, 4, 10]]
    long_first = b"x" * 25 + b"\ny\n"          # a line is never split
    assert inventory.line_ranges(long_first, 10) == [[1, 1, 26], [2, 2, 2]]
    assert inventory.line_ranges(b"", 10) == []


def test_a_file_larger_than_one_reading_is_listed_as_several_ranges(tmp_path, monkeypatch):
    monkeypatch.setattr(inventory, "RANGE_BYTES", 10)
    root = _repo(tmp_path, {"src/big.py": "aaaa\nbbbb\ncccc\ndddd\n"})
    (big,) = inventory.build(root)["files"]
    assert big["ranges"] == [[1, 2, 10], [3, 4, 10]]


def test_only_newlines_split_lines_the_way_read_and_sed_number_them():
    assert inventory.count_lines(b"a\rb\x0cc\n") == 1
    assert inventory.count_lines(b"a\r\nb\r\n") == 2
    assert inventory.count_lines(b"") == 0


def test_an_empty_file_is_in_scope_with_nothing_to_read(tmp_path):
    root = _repo(tmp_path, {"src/__init__.py": "", "src/keep.py": "k\n"})
    empty = inventory.build(root)["files"][0]
    assert (empty["path"], empty["lines"], empty["ranges"]) == ("src/__init__.py", 0, [])


def test_the_first_three_examples_travel_with_the_count(tmp_path):
    files = {f"docs/{n}.md": "t\n" for n in "abcde"}
    files["src/keep.py"] = "k\n"
    slot = inventory.build(_repo(tmp_path, files))["excluded"]["prose"]
    assert slot == {"count": 5, "examples": ["docs/a.md", "docs/b.md", "docs/c.md"]}


def test_a_root_that_is_not_a_git_checkout_lists_every_file_and_says_so(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "a.py").write_text("x\n")
    scope = inventory.build(tmp_path)
    assert _paths(scope) == ["src/a.py"] and scope["git"] is False
    assert "not a git checkout" in inventory.summary(scope)


def test_the_summary_states_the_scope_and_names_each_rule_with_examples(tmp_path):
    root = _repo(tmp_path, {"src/a.py": "x\n", "public/app.min.js": "x\n"})
    text = inventory.summary(inventory.build(root))
    assert "The deep scope is 1 file (1 line, 2 bytes), each to be read in full." in text
    assert "generated or minified files: 1 (e.g. public/app.min.js)" in text
    assert '"!defaults"' in text
