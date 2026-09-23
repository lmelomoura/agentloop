"""queries.fixed_elsewhere: where else in the repository the same fingerprint
has been given up as fixed. Built on real ledgers driven through the CLI, so
`fixed` here is the one `diff.classify` computes -- with `_proven` and the
decisions -- never a look-alike.
"""
import json
import subprocess
import sqlite3
import sys
from pathlib import Path

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
FP_A = "a" * 64
FP_B = "b" * 64


def _run(db, *args, stdin=None):
    out = subprocess.run([sys.executable, str(CLI), *args, "--db", str(db)],
                         capture_output=True, text=True, input=stdin, check=False)
    assert out.returncode == 0, out.stderr
    return out.stdout


def _analysis(db, tmp_path, branch, commit, findings, repo="web", project="web"):
    """One finished analysis of `branch` at `commit` reporting `findings`
    (a list of fingerprints), prepared so `done` is not downgraded."""
    aid = json.loads(_run(db, "open-analysis", "--project", project, "--repo", repo,
                          "--branch", branch, "--commit", commit, "--profile", "quick",
                          "--run-id", f"r-{branch}-{commit[:4]}"))["analysis_id"]
    root = tmp_path / f"repo-{aid}"
    root.mkdir()
    _run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    for fp in findings:
        payload = {"fingerprint": fp, "category": "sast", "rule": "sql-injection",
                   "severity": "high", "title": "t", "rationale": "r", "remediation": "m",
                   "candidate": SAST_CANDIDATE,
                   "occurrences": [{"file": "app/x.py", "line": 1}]}
        _run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(payload))
    _run(db, "finish", "--analysis", str(aid), "--state", "done")
    return aid


def _conn(db):
    c = sqlite3.connect(db)
    c.row_factory = sqlite3.Row
    return c


def test_a_fingerprint_fixed_on_another_branch_is_reported_with_that_branch(tmp_path):
    db = tmp_path / "l.db"
    # develop: A open. main: A seen, then A gone -> fixed on main.
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "2" * 16, [])
    got = queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A])
    assert set(got) == {FP_A}
    assert got[FP_A]["branch"] == "main"
    assert got[FP_A]["commit"] == "2" * 16          # the analysis that proved it gone
    assert got[FP_A]["analysis_id"]


def test_a_fingerprint_still_open_everywhere_is_absent(tmp_path):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A])
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A]) == {}


def test_the_same_branch_never_answers_for_itself(tmp_path):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "1" * 16, [FP_A])
    _analysis(db, tmp_path, "develop", "2" * 16, [])   # fixed on develop itself
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A]) == {}


def test_another_repository_does_not_count(tmp_path):
    # same project, same fingerprint, a different repo: another thing with
    # the same name
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A], repo="other")
    _analysis(db, tmp_path, "main", "2" * 16, [], repo="other")
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A]) == {}


def test_another_repository_s_newer_run_of_the_branch_does_not_answer_for_this_one(tmp_path):
    # The same route through a shared branch name: this repository HAS a
    # main, where the finding is still open, and the other repository's run
    # of main -- the newer one, where it is fixed -- used to be the one read.
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "2" * 16, [FP_A], repo="other")
    _analysis(db, tmp_path, "main", "3" * 16, [], repo="other")
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A]) == {}


def test_this_repository_s_own_fix_is_found_when_another_ran_the_branch_later(tmp_path):
    # The control beside it: the proof on this repository's main is still
    # found when the other repository analysed main after it.
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "2" * 16, [])
    _analysis(db, tmp_path, "main", "3" * 16, [FP_A], repo="other")
    got = queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A])
    assert set(got) == {FP_A}
    assert (got[FP_A]["branch"], got[FP_A]["commit"]) == ("main", "2" * 16)


def test_only_the_asked_for_fingerprints_come_back(tmp_path):
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A, FP_B])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A, FP_B])
    _analysis(db, tmp_path, "main", "2" * 16, [])
    got = queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_B])
    assert set(got) == {FP_B}
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", []) == {}


def test_a_fixed_that_is_not_proven_does_not_count(tmp_path):
    # An analysis that never ran `prepare` closes `capped`, and a baseline
    # finding missing from it is `pending`, not `fixed` (diff._proven). That
    # rule is the ledger's, not this function's -- and this pins that it is
    # honoured by reusing checklist rather than re-deriving the state.
    db = tmp_path / "l.db"
    _analysis(db, tmp_path, "develop", "d" * 16, [FP_A])
    _analysis(db, tmp_path, "main", "1" * 16, [FP_A])
    aid = json.loads(_run(db, "open-analysis", "--project", "web", "--repo", "web",
                          "--branch", "main", "--commit", "3" * 16, "--profile", "quick",
                          "--run-id", "r-unprepared"))["analysis_id"]
    _run(db, "finish", "--analysis", str(aid), "--state", "done")   # downgraded: no prepare
    assert queries.fixed_elsewhere(_conn(db), "web", "web", "develop", [FP_A]) == {}
