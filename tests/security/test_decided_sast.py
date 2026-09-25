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


def test_another_project_is_another_thing(conn):
    """The decision is against project `web`, but the fingerprint's ONLY
    finished record is in project `api`, repo `web` -- same repo name, so
    only the `a.project=?` predicate can be the one excluding it."""
    _analysis(conn, "develop", [{"fingerprint": FP}], project="api", repo="web")
    ledger.set_decision(conn, "web", FP, "accepted", "theirs", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_another_repository_is_another_thing(conn):
    """Project `web` on both sides; the fingerprint's ONLY finished record is
    in repo `web-admin`, so only the `a.repo=?` predicate can be the one
    excluding it -- the same fingerprint in another repository is another
    thing with the same name (the rule `fixed_elsewhere` keeps)."""
    _analysis(conn, "develop", [{"fingerprint": FP}], repo="web-admin")
    ledger.set_decision(conn, "web", FP, "accepted", "another repository", "me")
    main = _analysis(conn, "main", state="running")
    assert queries.decided_sast(conn, main) == []


def test_a_capped_analysis_is_a_finished_record(conn):
    """`capped` is a finished analysis -- the operator stopped it early, but
    it closed -- same as `done`. Its finding is the newest one on record and
    must be the one handed over, title and all."""
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the done run's words"}])
    _analysis(conn, "develop", [{"fingerprint": FP, "title": "the capped run's words"}],
              state="capped")
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    (entry,) = queries.decided_sast(conn, main)
    assert entry["title"] == "the capped run's words"


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


def test_a_checklist_the_caller_already_holds_is_not_computed_again(conn, monkeypatch):
    """`cmd_checklist` has this analysis's checklist in hand already, on a
    connection that does not memoise it -- handed in, it must be used, not
    computed a second time (the reason `posture` takes `latest`)."""
    _analysis(conn, "develop", [{"fingerprint": FP}])
    ledger.set_decision(conn, "web", FP, "accepted", "why", "me")
    main = _analysis(conn, "main", state="running")
    _an, listed = queries.checklist(conn, main)

    def _refuse(*_args, **_kwargs):
        raise AssertionError("checklist() computed a second time")
    monkeypatch.setattr(queries, "checklist", _refuse)
    assert [e["fingerprint"] for e in queries.decided_sast(conn, main, listed=listed)] == [FP]


def test_the_skill_tells_the_agent_to_fold_into_a_decided_sast_and_never_to_copy_one():
    """The list is inert without the instruction: an agent that is never told
    to look in `decided_sast` mints the second identity anyway. And an agent
    told only to use it would re-report every entry as if it were work carried
    over -- so the same paragraph has to say both halves."""
    text = SKILL.read_text()
    rules = re.search(r"^## Rules for every unit$(.*?)^## Unit: triage$", text,
                      re.DOTALL | re.MULTILINE)
    assert rules, "SKILL.md no longer has a Rules for every unit section this test can read"
    blocks = [b for b in rules.group(1).split("\n\n") if "`decided_sast`" in b]
    assert blocks, "the rules never tell the agent about `decided_sast`"
    assert any("copied exactly" in b and "did not find yourself" in b for b in blocks), \
        "no paragraph both says to reuse the entry's fingerprint and not to copy entries"


def test_the_skill_carries_the_rule_across_and_puts_every_fold_in_the_summary():
    """A fold is invisible once it lands -- the finding takes the decision's
    state -- so the skill has to say both what keeps it honest (the entry's
    rule, which the door checks) and where it is seen (the unit's summary)."""
    text = SKILL.read_text()
    rules = re.search(r"^## Rules for every unit$(.*?)^## Unit: triage$", text,
                      re.DOTALL | re.MULTILINE)
    assert rules, "SKILL.md no longer has a Rules for every unit section this test can read"
    blocks = [b for b in rules.group(1).split("\n\n") if "`decided_sast`" in b]
    assert any("`rule`" in b and "refuses" in b for b in blocks), \
        "the fold must carry the entry's rule across, and say the door checks it"
    summary = [p for p in text.split("\n\n") if "one-paragraph summary" in p]
    assert summary, "SKILL.md no longer asks for a final summary this test can read"
    assert "`decided_sast`" in summary[0] and "file:line" in summary[0], \
        "the final summary must list every fold and where it was found"
    assert "agrees" in summary[0], \
        "the final summary must ask whether the reading agrees with the decision's reason"


def test_the_skill_states_that_a_decided_finding_keeps_its_category_and_rule():
    """The rule the door enforces has to be stated where every re-report route
    reads it -- a triage unit's carried and scanner rows, a hunt's or a read's
    fold alike -- not only implied by what the door refuses."""
    text = SKILL.read_text()
    rules = text.split("## Rules for every unit", 1)
    assert len(rules) == 2, "SKILL.md no longer has this section this test can read"
    assert "A decided finding keeps its category and rule" in rules[1]
