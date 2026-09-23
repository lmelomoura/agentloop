"""`queries.decided_sast` -- the `sast` findings the operator already ruled on
that an analysis's checklist does not list, handed to the agent beside the
checklist so the same hole found again is folded into the decided identity
instead of minted a second time.

Measured on one project's ledger (2026-09-23): one access-control hole was
minted under one fingerprint on main and under another on develop, and was
accepted twice. Every case below is a way this list could hand the agent too
much or too little.
"""
import re
from pathlib import Path

import pytest

from security import ledger, queries

SKILL = Path(__file__).resolve().parents[2] / "skills" / "security-analysis" / "SKILL.md"
FP = "a" * 64


@pytest.fixture
def conn(tmp_path):
    return ledger.connect(tmp_path / "security.db")


def _analysis(conn, branch, findings=(), state="done", project="web", repo="web"):
    """One analysis of `branch` holding `findings` -- each an agent `sast`
    unless it says otherwise -- closed in `state`; `running` leaves it open,
    the way the agent's own analysis is while it reads the checklist."""
    aid = ledger.start_analysis(conn, project, repo, branch, "sha", "quick", "r")
    for extra in findings:
        finding = {"category": "sast", "rule": "broken-access-control",
                   "severity": "medium", "title": "the drawer proxies any candidate",
                   "producer": "agent",
                   "occurrences": [{"file": "app/queue.php", "line": 54}]}
        finding.update(extra)
        ledger.record_finding(conn, aid, finding)
    ledger.mark_prepared(conn, aid)
    if state != "running":
        ledger.finish_analysis(conn, aid, state)
    return aid


def test_a_sast_decided_on_another_branch_is_handed_to_the_agent(conn):
    dev = _analysis(conn, "develop", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "accepted", "product decision RP-217", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == [{
        "fingerprint": FP, "rule": "broken-access-control",
        "title": "the drawer proxies any candidate", "severity": "medium",
        "occurrences": [{"file": "app/queue.php", "line": 54}],
        "last_seen": {"branch": "develop", "analysis_id": dev},
        "decision": {"state": "accepted", "reason": "product decision RP-217"}}]


def test_a_decided_sast_the_checklist_already_lists_is_not_repeated(conn):
    _analysis(conn, "main", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "false_positive", "not reachable", "me")
    nxt = _analysis(conn, "main", state="running")      # FP is in its baseline
    assert queries.decided_sast(conn, nxt) == []


def test_a_decided_sast_this_branch_lost_from_its_baseline_is_handed_back(conn):
    _analysis(conn, "main", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    _analysis(conn, "main")                             # not re-reported: out of the baseline
    nxt = _analysis(conn, "main", state="running")
    assert [e["fingerprint"] for e in queries.decided_sast(conn, nxt)] == [FP]


def test_only_the_agents_own_sast_is_handed_over(conn):
    semgrep, secret = "5" * 64, "6" * 64
    _analysis(conn, "develop", [
        {"fingerprint": semgrep, "producer": "semgrep", "rule": "sql-injection"},
        {"fingerprint": secret, "category": "secret", "rule": "aws-access-token",
         "producer": "gitleaks"}])
    for fp in (semgrep, secret):
        ledger.set_decision(conn, "web", fp, "false_positive", "fixture", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_a_sast_nobody_ruled_on_is_not_handed_over(conn):
    _analysis(conn, "develop", [{"fingerprint": FP}])
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_another_project_or_repository_is_another_thing(conn):
    other = "7" * 64
    _analysis(conn, "develop", [{"fingerprint": FP}], project="api", repo="api")
    ledger.set_decision(conn, "api", FP, "accepted", "theirs", "me")
    _analysis(conn, "develop", [{"fingerprint": other}], repo="web-admin")
    ledger.set_decision(conn, "web", other, "accepted", "another repository", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_the_newest_finished_record_describes_the_entry(conn):
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the old words",
                                 "occurrences": [{"file": "app/old.php", "line": 1}]}])
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the new words",
                                 "occurrences": [{"file": "app/new.php", "line": 2}]}])
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "a failed run's words"}],
              state="failed")
    _analysis(conn, "feature", [{"fingerprint": FP, "title": "a running run's words"}],
              state="running")
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    (entry,) = queries.decided_sast(conn, main)
    assert entry["title"] == "the new words"
    assert entry["occurrences"] == [{"file": "app/new.php", "line": 2}]


def test_the_list_comes_in_a_stable_order(conn):
    xss, bac = "b" * 64, "c" * 64
    _analysis(conn, "develop", [{"fingerprint": xss, "rule": "xss"},
                                {"fingerprint": bac, "rule": "broken-access-control"}])
    for fp in (xss, bac):
        ledger.set_decision(conn, "web", fp, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    assert [e["rule"] for e in queries.decided_sast(conn, main)] == \
        ["broken-access-control", "xss"]


def test_the_skill_tells_the_agent_to_fold_into_a_decided_sast_and_never_to_copy_one():
    """The list is inert without the instruction: an agent that is never told
    to look in `decided_sast` mints the second identity anyway. And an agent
    told only to use it would re-report every entry as if it were work carried
    over -- so the same paragraph has to say both halves."""
    text = SKILL.read_text()
    job3 = re.search(r"\*\*3\. The SAST pass\*\*(.*?)## Rules that are not negotiable",
                     text, re.DOTALL)
    assert job3, "SKILL.md no longer has a Job 3 section this test can read"
    blocks = [b for b in job3.group(1).split("\n\n") if "`decided_sast`" in b]
    assert blocks, "Job 3 never tells the agent about `decided_sast`"
    assert any("copied exactly" in b and "did not find yourself" in b for b in blocks), \
        "no paragraph both says to reuse the entry's fingerprint and not to copy entries"
