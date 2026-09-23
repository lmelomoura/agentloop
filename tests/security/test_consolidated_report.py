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


def _f(fp, sev, state="open", branch="develop", repo="P", **kw):
    row = {"fingerprint": fp, "repo": repo, "branch": branch, "severity": sev,
           "state": state,
           "category": "sast", "rule": "a-rule", "title": f"finding {fp[:4]}",
           "cwe": "", "owasp": "", "scope": "", "analysis_id": 1, "first_seen": 0,
           "occurrences": [], "rationale": "", "remediation": ""}
    row.update(kw)
    return row


# Keyed by (repository, branch): the unit a finding is read in. A project with
# one checkout files it under the project's own name.
META = {("P", "develop"): {"id": 11, "commit_sha": "9f8e7d6c5b4a39281706", "profile": "deep"},
        ("P", "main"): {"id": 14, "commit_sha": "1122334455667788990a", "profile": "standard"},
        ("P", "release"): {"id": 15, "commit_sha": "aabbccddeeff00112233", "profile": "standard"}}


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


def test_the_html_is_the_same_document_with_the_same_order_and_escapes_what_it_prints():
    rows = [_f("b" * 16, "high", title="<b>not markup</b>", branch="main"),
            _f("a" * 16, "critical", branch="main",
               occurrences=[{"file": "app/<x>.py", "line": 3}])]
    meta = {("P", "main"): {"id": 1, "commit_sha": "0011223344556677", "profile": "deep"}}
    doc = report.consolidated_as_html("P & Q", report._consolidated_groups(rows, meta), {})
    # escaped, never rendered: a title comes from analysed code
    assert "&lt;b&gt;not markup&lt;/b&gt;" in doc and "<b>not markup</b>" not in doc
    assert "app/&lt;x&gt;.py" in doc
    assert "P &amp; Q" in doc
    # same order as the Markdown: critical before high
    assert doc.index("a" * 16) < doc.index("b" * 16)
    assert "001122334455" in doc


def test_the_sbom_bundle_lists_every_branch_and_says_it_is_not_a_merge():
    entries = [{"repo": "P", "branch": "main", "analysis_id": 1, "commit_sha": "c1",
                "sbom": {"bomFormat": "CycloneDX"}},
               {"repo": "P", "branch": "develop", "analysis_id": 2, "commit_sha": "c2",
                "sbom": None}]
    doc = json.loads(report.consolidated_sboms("P", entries, {"at": 5}))
    assert [b["branch"] for b in doc["branches"]] == ["develop", "main"]
    assert doc["branches"][0]["sbom"] is None          # said, not omitted
    assert doc["branches"][1]["sbom"]["bomFormat"] == "CycloneDX"
    assert "not a merge" in doc["format"]


def test_a_fix_already_in_the_branch_is_said_first_and_tells_the_agent_to_reanalyse():
    rows = [_f("a" * 16, "high", fixed_elsewhere={"branch": "main", "commit": "c0ffee" * 7,
                                                  "analysis_id": 9, "at": 1, "in_this_branch": True}),
            _f("b" * 16, "high", fixed_elsewhere={"branch": "main", "commit": "c0ffee" * 7,
                                                  "analysis_id": 9, "at": 1, "in_this_branch": False}),
            _f("c" * 16, "high")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {})
    # the header counts both kinds before any finding is listed
    head = md.split("## `")[0]
    assert "1 whose fix is already in the branch" in head
    assert "1 fixed on another branch but not yet in this one" in head
    # and each finding says its own case, in words an agent acts on
    assert "ALREADY in this branch" in md and "re-analyse this branch" in md
    assert "not yet in this branch — see that fix" in md
    # a finding nobody fixed anywhere says nothing about it
    c_block = md.split("#### [high] finding cccc")[1]
    assert "Fixed elsewhere" not in c_block


def test_an_undetermined_ancestry_is_said_as_undetermined_never_as_absent():
    rows = [_f("a" * 16, "high", fixed_elsewhere={"branch": "main", "commit": "abc",
                                                  "unknown_reason": "no checkout configured"})]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META), {})
    assert "could not be determined (no checkout configured)" in md
    assert "not yet in this branch" not in md and "ALREADY" not in md


def test_the_json_and_html_carry_the_same_annotation():
    fe = {"branch": "main", "commit": "d" * 40, "analysis_id": 3, "at": 2, "in_this_branch": True}
    rows = [_f("a" * 16, "high", fixed_elsewhere=fe)]
    groups = report._consolidated_groups(rows, META)
    doc = json.loads(report.consolidated_as_json("P", groups, {}))
    assert doc["branches"][0]["open"][0]["fixed_elsewhere"] == fe
    html_doc = report.consolidated_as_html("P", groups, {})
    assert "ALREADY in this branch" in html_doc


def test_a_finding_open_on_two_branches_is_one_on_the_screen_and_the_header_says_so():
    # The screen counts findings -- one row per fingerprint across branches --
    # while this document lists a finding once per branch it is on. Measured
    # against rows, a screen showing its one finding read as a screen that
    # had hidden another.
    rows = [_f("a" * 16, "high"), _f("a" * 16, "high", branch="main")]
    md = report.consolidated_as_markdown("P", report._consolidated_groups(rows, META),
                                         {"shown_on_screen": 1})
    assert "**Findings:** 2 open (1 distinct across branches)" in md
    assert "The screen was showing" not in md


TWO_REPOS = {("web", "main"): {"id": 1, "commit_sha": "1111111111111111", "profile": "quick"},
             ("web-admin", "main"): {"id": 2, "commit_sha": "2222222222222222", "profile": "deep"}}


def test_two_repositories_on_one_branch_name_are_two_sections_each_at_its_own_commit():
    # Grouped by branch name, the two `main`s were one section under one
    # commit -- the one repository's sha printed over the other's findings.
    rows = [_f("a" * 16, "high", repo="web", branch="main", title="in web"),
            _f("b" * 16, "high", repo="web-admin", branch="main", title="in web-admin")]
    groups = report._consolidated_groups(rows, TWO_REPOS)
    assert [(g["repo"], g["branch"], g["analysis"]["id"], [f["title"] for f in g["open"]])
            for g in groups] == [("web", "main", 1, ["in web"]),
                                 ("web-admin", "main", 2, ["in web-admin"])]
    md = report.consolidated_as_markdown("P", groups, {})
    assert "## `web` › `main` at `111111111111`" in md
    assert "## `web-admin` › `main` at `222222222222`" in md
    # the repository on the finding itself, as the branch is: a finding
    # copied out of the file keeps the checkout it has to be fixed in
    assert md.count("- **Repository:** `web-admin`") == 1
    assert "**Branches:** 2 (in 2 repositories)" in md
    doc = json.loads(report.consolidated_as_json("P", groups, {}))
    assert [(b["repo"], b["branch"], b["commit_sha"]) for b in doc["branches"]] == \
        [("web", "main", "1111111111111111"), ("web-admin", "main", "2222222222222222")]
    assert doc["branches"][1]["open"][0]["repo"] == "web-admin"
    html_doc = report.consolidated_as_html("P", groups, {})
    assert "<code>web-admin</code> › <code>main</code>" in html_doc


def test_one_repository_s_document_reads_as_it_always_did():
    # The control: the repository is said only when there is more than one.
    rows = [_f("a" * 16, "high"), _f("b" * 16, "low", branch="main")]
    groups = report._consolidated_groups(rows, META)
    md = report.consolidated_as_markdown("P", groups, {})
    assert "## `develop` at `9f8e7d6c5b4a`" in md
    assert "›" not in md and "**Repository:**" not in md
    assert "**Branches:** 3\n" in md
    assert "›" not in report.consolidated_as_html("P", groups, {})
