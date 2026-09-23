"""The `fixed_elsewhere` annotation on findings rows, end to end: a real ledger
driven through the CLI and a real git repository the test builds, so the
ancestry answer is git's and not a stand-in's.

The one rule every case here guards: NOTHING CHANGES A ROW'S STATE. Ancestry
proves the fix is present, not that the finding is absent.
"""
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from security import queries  # noqa: E402

CLI = Path(__file__).resolve().parents[2] / "bin" / "security" / "cli.py"

# A complete, valid candidate -- what every `sast` finding at medium or above
# has to carry through the door since block 4.1 (see cli._candidate_requirements).
SAST_CANDIDATE = {
    "trace": [
        {"kind": "entrypoint", "file": "app/x.py", "line": 1, "scope": "handle",
         "description": "the parameter comes from the request"},
        {"kind": "sink", "file": "app/x.py", "line": 1, "scope": "query",
         "description": "the string reaches execute()"}],
    "intended_control": "queries are parameterised",
    "confidence": {"score": "high", "reason": "the concatenation is unconditional"},
    "likelihood": {"score": "high", "reason": "the endpoint is unauthenticated"},
    "impact": {"score": "critical", "reason": "full read of the database"},
}
FP = "a" * 64


def _run(db, *args, stdin=None):
    out = subprocess.run([sys.executable, str(CLI), *args, "--db", str(db)],
                         capture_output=True, text=True, input=stdin, check=False)
    assert out.returncode == 0, out.stderr
    return out.stdout


def _git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                          text=True, check=True).stdout.strip()


@pytest.fixture
def repo(tmp_path):
    """main: c1 -> c2 (the fix). develop: branched at c1 with its own commit,
    so c2 is NOT in develop. origin/* refs point at the local tips."""
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    _git(r, "config", "user.email", "jane@example.org")
    _git(r, "config", "user.name", "Jane Example")
    (r / "a").write_text("1\n"); _git(r, "add", "a"); _git(r, "commit", "-q", "-m", "c1")
    c1 = _git(r, "rev-parse", "HEAD")
    (r / "a").write_text("fixed\n"); _git(r, "commit", "-q", "-am", "c2 fix")
    c2 = _git(r, "rev-parse", "HEAD")
    _git(r, "checkout", "-q", "-b", "develop", c1)
    (r / "b").write_text("x\n"); _git(r, "add", "b"); _git(r, "commit", "-q", "-m", "dev")
    dev = _git(r, "rev-parse", "HEAD")
    _git(r, "update-ref", "refs/remotes/origin/main", c2)
    _git(r, "update-ref", "refs/remotes/origin/develop", dev)
    return {"path": r, "c1": c1, "c2": c2, "dev": dev}


def _analysis(db, tmp_path, branch, commit, fps, project="web", repo="web"):
    aid = json.loads(_run(db, "open-analysis", "--project", project, "--repo", repo,
                          "--branch", branch, "--commit", commit, "--profile", "quick",
                          "--run-id", f"r-{branch}-{commit[:6]}"))["analysis_id"]
    root = tmp_path / f"root-{aid}"; root.mkdir()
    _run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    for fp in fps:
        _run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps({
            "fingerprint": fp, "category": "sast", "rule": "sql-injection",
            "severity": "high", "title": "t", "rationale": "r", "remediation": "m",
            "candidate": SAST_CANDIDATE,
            "occurrences": [{"file": "a", "line": 1}]}))
    _run(db, "finish", "--analysis", str(aid), "--state", "done")
    return aid


def _rows(db, repo_paths, **filters):
    c = sqlite3.connect(db); c.row_factory = sqlite3.Row
    f = {"show_resolved": True}; f.update(filters)
    return queries.finding_rows(c, "web", f, repo_paths=repo_paths, per_page=100)["rows"]


def test_fixed_on_main_and_not_yet_in_develop(tmp_path, repo):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], [FP])      # open on develop
    _analysis(db, tmp_path, "main", repo["c1"], [FP])          # seen on main
    _analysis(db, tmp_path, "main", repo["c2"], [])            # gone on main at c2
    rows = _rows(db, {"web": str(repo["path"])}, branch=["develop"])
    (r,) = rows
    assert r["state"] in ("new", "open")                        # UNCHANGED
    fe = r["fixed_elsewhere"]
    assert fe["branch"] == "main" and fe["commit"] == repo["c2"]
    assert fe["in_this_branch"] is False                        # c2 is not in develop


def test_fixed_on_main_and_already_merged_into_develop(tmp_path, repo):
    # develop merges main's fix but is not re-analysed: the finding is still
    # open in the ledger, and git says the fix is already here
    _git(repo["path"], "checkout", "-q", "develop")
    _git(repo["path"], "merge", "-q", "--no-edit", repo["c2"])
    merged = _git(repo["path"], "rev-parse", "HEAD")
    _git(repo["path"], "update-ref", "refs/remotes/origin/develop", merged)
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], [FP])      # analysed BEFORE the merge
    _analysis(db, tmp_path, "main", repo["c1"], [FP])
    _analysis(db, tmp_path, "main", repo["c2"], [])
    (r,) = _rows(db, {"web": str(repo["path"])}, branch=["develop"])
    assert r["state"] in ("new", "open")                        # STILL open: nobody re-analysed
    assert r["fixed_elsewhere"]["in_this_branch"] is True


def test_the_case_that_lies_if_you_let_it(tmp_path, repo):
    # develop merged the fix AND reintroduced the pattern in its own commit,
    # then was re-analysed: the finding is genuinely open here. Ancestry
    # still says the fix commit is present -- which is TRUE -- and the state
    # says open -- which is also true. Both stay; neither overrides the other.
    _git(repo["path"], "checkout", "-q", "develop")
    _git(repo["path"], "merge", "-q", "--no-edit", repo["c2"])
    (repo["path"] / "a").write_text("1\n"); _git(repo["path"], "commit", "-q", "-am", "reintroduce")
    again = _git(repo["path"], "rev-parse", "HEAD")
    _git(repo["path"], "update-ref", "refs/remotes/origin/develop", again)
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "main", repo["c1"], [FP])
    _analysis(db, tmp_path, "main", repo["c2"], [])
    _analysis(db, tmp_path, "develop", again, [FP])            # found again, after the merge
    (r,) = _rows(db, {"web": str(repo["path"])}, branch=["develop"])
    assert r["state"] in ("new", "open")
    assert r["fixed_elsewhere"]["in_this_branch"] is True       # the fix IS an ancestor
    # and this is exactly why nothing here ever marks it fixed


def test_no_checkout_configured_says_so_instead_of_false(tmp_path, repo):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], [FP])
    _analysis(db, tmp_path, "main", repo["c1"], [FP])
    _analysis(db, tmp_path, "main", repo["c2"], [])
    (r,) = _rows(db, {}, branch=["develop"])                     # no repo_paths at all
    fe = r["fixed_elsewhere"]
    assert fe["branch"] == "main"
    assert "in_this_branch" not in fe
    assert "no checkout" in fe["unknown_reason"]


def test_a_branch_git_does_not_know_is_unknown_not_false(tmp_path, repo):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "release", "f" * 40, [FP])          # no such branch in the repo
    _analysis(db, tmp_path, "main", repo["c1"], [FP])
    _analysis(db, tmp_path, "main", repo["c2"], [])
    (r,) = _rows(db, {"web": str(repo["path"])}, branch=["release"])
    fe = r["fixed_elsewhere"]
    assert "in_this_branch" not in fe and "git could not answer" in fe["unknown_reason"]


def test_a_finding_nobody_fixed_anywhere_carries_no_annotation(tmp_path, repo):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], [FP])
    _analysis(db, tmp_path, "main", repo["c2"], [FP])           # open on both
    (r,) = _rows(db, {"web": str(repo["path"])}, branch=["develop"])
    assert "fixed_elsewhere" not in r


def test_git_is_asked_per_branch_pair_not_per_finding(tmp_path, repo, monkeypatch):
    # 40 findings open on develop, all fixed on main: one head_of, one
    # contains. A version that asked per finding would be 40x that and
    # nobody would notice on a small project.
    from security import branchgit
    calls = {"head_of": 0, "contains": 0}
    real_head, real_contains = branchgit.head_of, branchgit.contains
    monkeypatch.setattr(branchgit, "head_of", lambda *a, **k: (calls.__setitem__("head_of", calls["head_of"] + 1), real_head(*a, **k))[1])
    monkeypatch.setattr(branchgit, "contains", lambda *a, **k: (calls.__setitem__("contains", calls["contains"] + 1), real_contains(*a, **k))[1])
    fps = [f"{i:064x}" for i in range(40)]
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], fps)
    _analysis(db, tmp_path, "main", repo["c1"], fps)
    _analysis(db, tmp_path, "main", repo["c2"], [])
    rows = _rows(db, {"web": str(repo["path"])}, branch=["develop"])
    assert len(rows) == 40 and all("fixed_elsewhere" in r for r in rows)
    assert calls == {"head_of": 1, "contains": 1}, calls


def test_an_unfiltered_group_still_carries_the_open_branchs_fixed_elsewhere(tmp_path, repo):
    # Every test above filters to one branch before grouping, where
    # `_group_by_fingerprint` has nothing to do. Unfiltered, develop's open
    # row and main's fixed row collapse into one group whose representative
    # is develop (open outranks fixed in GROUP_STATE_ORDER) -- the annotation
    # must still be read off THAT row's own branch and repo, not lost to the
    # grouping.
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", repo["dev"], [FP])      # open on develop
    _analysis(db, tmp_path, "main", repo["c1"], [FP])          # seen on main
    _analysis(db, tmp_path, "main", repo["c2"], [])            # gone on main at c2
    (r,) = _rows(db, {"web": str(repo["path"])})                # no branch filter: grouped
    assert r["state"] in ("new", "open")
    assert r["branch"] == "develop"
    assert [b["branch"] for b in r["branches"]] == ["develop", "main"]
    fe = r["fixed_elsewhere"]
    assert fe["branch"] == "main" and fe["commit"] == repo["c2"]
    assert fe["in_this_branch"] is False
