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
