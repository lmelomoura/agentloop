"""branchgit: the two git questions behind "fixed elsewhere", on a repository
the test builds. Every case that cannot be answered must come back None --
never False, which would render as "the fix is not here" when nobody looked.
"""
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from security import branchgit  # noqa: E402


def _git(repo, *args):
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                         text=True, check=True)
    return out.stdout.strip()


@pytest.fixture
def repo(tmp_path):
    """main with two commits; develop branched after the first, with one of
    its own; origin/main pointing at main's second commit (a remote-tracking
    ref made by hand, so no network and no second repository)."""
    r = tmp_path / "r"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    _git(r, "config", "user.email", "jane@example.org")
    _git(r, "config", "user.name", "Jane Example")
    (r / "a").write_text("1\n")
    _git(r, "add", "a"); _git(r, "commit", "-q", "-m", "one")
    first = _git(r, "rev-parse", "HEAD")
    (r / "a").write_text("2\n")
    _git(r, "commit", "-q", "-am", "two")
    second = _git(r, "rev-parse", "HEAD")
    _git(r, "checkout", "-q", "-b", "develop", first)
    (r / "b").write_text("x\n")
    _git(r, "add", "b"); _git(r, "commit", "-q", "-m", "dev")
    dev = _git(r, "rev-parse", "HEAD")
    _git(r, "update-ref", "refs/remotes/origin/main", second)
    return {"path": r, "first": first, "second": second, "dev": dev}


def test_a_commit_inside_the_branch_is_contained(repo):
    assert branchgit.contains(repo["path"], repo["first"], repo["dev"]) is True
    assert branchgit.contains(repo["path"], repo["dev"], repo["dev"]) is True


def test_a_commit_on_another_line_is_not(repo):
    # main's second commit never reached develop
    assert branchgit.contains(repo["path"], repo["second"], repo["dev"]) is False


def test_no_repository_is_none_never_false(tmp_path):
    assert branchgit.contains(tmp_path / "nowhere", "a" * 40, "b" * 40) is None
    assert branchgit.head_of(tmp_path / "nowhere", "main") is None


def test_a_commit_git_does_not_know_is_none(repo):
    assert branchgit.contains(repo["path"], "0" * 40, repo["dev"]) is None


def test_head_prefers_origin_over_a_local_branch_left_behind(repo):
    # local `main` is at `second` too here, so move it back to `first` to
    # make the two differ: the remote-tracking ref must win
    _git(repo["path"], "update-ref", "refs/heads/main", repo["first"])
    assert branchgit.head_of(repo["path"], "main") == repo["second"]
    # a branch that exists only locally is still found
    assert branchgit.head_of(repo["path"], "develop") == repo["dev"]


def test_an_unknown_branch_is_none(repo):
    assert branchgit.head_of(repo["path"], "release/nope") is None


def test_a_timeout_is_none(repo):
    assert branchgit.contains(repo["path"], repo["first"], repo["dev"], timeout=0.0001) is None
    assert branchgit.head_of(repo["path"], "main", timeout=0.0001) is None


def test_nothing_that_looks_like_an_option_reaches_git(repo):
    # a branch or commit spelled `-x` would sit in an option position
    assert branchgit.head_of(repo["path"], "--output=/tmp/x") is None
    assert branchgit.contains(repo["path"], "--foo", repo["dev"]) is None
    assert branchgit.contains(repo["path"], repo["first"], "-bar") is None
