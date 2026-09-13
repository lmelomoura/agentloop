"""The consolidated findings document: one project, every branch, one file.

The three renderers beside it answer "what did this analysis find". This one
answers "what is there to fix, and where", for a reader with no context, so
the tests here are about what that reader can and cannot tell from the file.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))

from security import report  # noqa: E402


def _f(fp, sev, state="open", branch="develop", **kw):
    row = {"fingerprint": fp, "branch": branch, "severity": sev, "state": state,
           "category": "sast", "rule": "a-rule", "title": f"finding {fp[:4]}",
           "cwe": "", "owasp": "", "scope": "", "analysis_id": 1, "first_seen": 0,
           "occurrences": [], "rationale": "", "remediation": ""}
    row.update(kw)
    return row


META = {"develop": {"id": 11, "commit_sha": "9f8e7d6c5b4a39281706", "profile": "deep"},
        "main": {"id": 14, "commit_sha": "1122334455667788990a", "profile": "standard"},
        "release": {"id": 15, "commit_sha": "aabbccddeeff00112233", "profile": "standard"}}


def test_a_branch_with_no_findings_is_named_as_clean():
    # Not seeing a branch and seeing it clean call for opposite actions: the
    # first means nobody looked, the second means there is nothing to do.
    groups = report._consolidated_groups([_f("a" * 16, "high")], META)
    md = report.consolidated_as_markdown("P", groups, {})
    assert "## `release`" in md
    assert "No findings recorded on this branch" in md


def test_every_finding_names_its_branch_and_the_commit_it_was_read_at():
    rows = [_f("a" * 16, "high"), _f("b" * 16, "low", branch="main")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {})
    # the branch on the finding itself, not only in the section heading: an
    # agent that copies one finding out of the file keeps the branch with it
    assert md.count("- **Branch:** `develop`") == 1
    assert md.count("- **Branch:** `main`") == 1
    assert "9f8e7d6c5b4a" in md and "112233445566" in md


def test_the_order_is_branch_then_severity_then_fingerprint():
    rows = [_f("zz" + "0" * 14, "low"), _f("aa" + "0" * 14, "critical"),
            _f("bb" + "0" * 14, "critical"), _f("cc" + "0" * 14, "high", branch="main")]
    groups = report._consolidated_groups(rows, META)
    assert [g["branch"] for g in groups] == ["develop", "main", "release"]
    assert [f["fingerprint"][:2] for f in groups[0]["open"]] == ["aa", "bb", "zz"]


def test_two_exports_of_the_same_state_are_byte_identical():
    # The first thing anyone does with two of these files is diff them, and a
    # pair of equally severe findings in an unstable order makes that useless.
    rows = [_f(c * 16, "high") for c in "dcba"]
    a = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {"at": 1})
    b = report.consolidated_as_markdown("P", report._consolidated_groups(list(reversed(rows)), META), {"at": 1})
    assert a == b


def test_resolved_findings_are_listed_last_and_marked_as_no_action():
    rows = [_f("a" * 16, "high"), _f("b" * 16, "low", state="fixed"),
            _f("c" * 16, "medium", state="accepted")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {})
    assert md.index("### Open") < md.index("### Resolved on this branch")
    assert "no action needed" in md
    # and they are not counted as work
    assert "**Findings:** 1 open, 2 resolved" in md


def test_the_header_says_the_filters_were_not_applied():
    rows = [_f("a" * 16, "critical"), _f("b" * 16, "info")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META),
                                         {"shown_on_screen": 1})
    assert "The screen was showing 1 of these" in md
    assert "carries everything recorded" in md
    assert "**Open by severity:** critical 1 · info 1" in md


def test_the_json_carries_the_same_grouping_and_the_same_order():
    rows = [_f("b" * 16, "high"), _f("a" * 16, "critical"), _f("c" * 16, "low", branch="main")]
    groups = report._consolidated_groups(rows, META)
    doc = json.loads(report.consolidated_as_json("P", groups, {"at": 7}))
    assert doc["project"] == "P" and doc["exported_at"] == 7
    assert doc["filters_applied"] is False and doc["severity_floor_applied"] is False
    assert [b["branch"] for b in doc["branches"]] == ["develop", "main", "release"]
    assert [f["fingerprint"][0] for f in doc["branches"][0]["open"]] == ["a", "b"]
    assert doc["branches"][0]["commit_sha"] == "9f8e7d6c5b4a39281706"
    assert doc["branches"][2]["open"] == [] and doc["branches"][2]["resolved"] == []


def test_an_occurrence_carries_its_line_and_a_pathless_one_does_not_invent_one():
    rows = [_f("a" * 16, "high", occurrences=[{"file": "app/x.py", "line": 88},
                                              {"file": "app/dir/", "line": None}])]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {})
    assert "`app/x.py`:88" in md
    assert "`app/dir/`\n" in md and "app/dir/`:" not in md


def test_resolved_is_the_ledger_s_own_definition_not_a_second_copy():
    # If queries ever adds a fourth resolved state, this document must follow
    # it without an edit -- which is why the constant is imported, not repeated.
    from security.queries import RESOLVED_STATES
    assert report.RESOLVED_STATES is RESOLVED_STATES
    for state in RESOLVED_STATES:
        groups = report._consolidated_groups([_f("a" * 16, "high", state=state)], META)
        assert groups[0]["open"] == [] and len(groups[0]["resolved"]) == 1
