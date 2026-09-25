"""`security export-findings` — the whole project, every branch, one document.

The renderer is tested beside this (test_consolidated_report.py) over rows
handed to it. What is tested here is the verb: that it reads the same path the
screen reads, that it reaches every page of it, and that a project nobody has
ever analysed is an error rather than an empty file.
"""
import json
import subprocess
import sys
from pathlib import Path

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


def _run(db, *args, check=True):
    out = subprocess.run([sys.executable, str(CLI), *args, "--db", str(db)],
                         capture_output=True, text=True, check=False)
    if check:
        assert out.returncode == 0, out.stderr
    return out


def _open(db, project, branch, commit, aid_profile="quick", repo=None):
    out = _run(db, "open-analysis", "--project", project, "--repo", repo or project,
               "--branch", branch, "--commit", commit, "--profile", aid_profile,
               "--run-id", f"r-{branch}")
    return json.loads(out.stdout)["analysis_id"]


def _finding(db, aid, fingerprint, severity="high", title="a finding",
             rule="sql-injection", category="sast", path="app/x.py", line=1,
             run=None):
    payload = {"fingerprint": fingerprint, "category": category, "rule": rule,
               "severity": severity, "title": title,
               "rationale": "because", "remediation": "fix it",
               "occurrences": [{"file": path, "line": line}]}
    if category == "sast":
        payload["candidate"] = SAST_CANDIDATE
    if run is not None:
        run(db, "report-finding", "--analysis", str(aid), stdin=json.dumps(payload))
        return
    out = subprocess.run([sys.executable, str(CLI), "report-finding", "--analysis",
                          str(aid), "--db", str(db)],
                         input=json.dumps(payload), capture_output=True,
                         text=True, check=False)
    assert out.returncode == 0, out.stderr


def _prepared(db, tmp_path, project, branch, commit, repo=None):
    aid = _open(db, project, branch, commit, repo=repo)
    root = tmp_path / f"repo-{aid}"
    root.mkdir(parents=True, exist_ok=True)
    _run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    return aid


def _close(db, aid):
    _run(db, "finish", "--analysis", str(aid), "--state", "done")


def test_a_project_nobody_analysed_is_an_error_not_an_empty_document(tmp_path):
    # An empty document is the worst answer to a typo: an agent reads it,
    # finds nothing to do, and reports that everything is fine.
    db = tmp_path / "l.db"
    aid = _prepared(db, tmp_path, "web", "main", "aaa")
    _close(db, aid)
    out = _run(db, "export-findings", "--project", "wbe", "--format", "md", check=False)
    assert out.returncode != 0
    assert "wbe" in out.stderr and "web" in out.stderr


def test_the_document_carries_every_branch_with_the_commit_it_was_read_at(tmp_path):
    db = tmp_path / "l.db"
    a1 = _prepared(db, tmp_path, "web", "main", "1111111111111111")
    _finding(db, a1, "f" * 64, severity="critical", title="on main")
    _close(db, a1)
    a2 = _prepared(db, tmp_path, "web", "develop", "2222222222222222")
    _finding(db, a2, "e" * 64, severity="low", title="on develop")
    _close(db, a2)

    md = _run(db, "export-findings", "--project", "web", "--format", "md").stdout
    assert "## `develop` at `222222222222`" in md
    assert "## `main` at `111111111111`" in md
    assert "- **Branch:** `main`" in md and "- **Branch:** `develop`" in md
    assert "on main" in md and "on develop" in md


def test_the_json_is_the_same_document_parsed(tmp_path):
    db = tmp_path / "l.db"
    aid = _prepared(db, tmp_path, "web", "main", "abc0000000000000")
    _finding(db, aid, "a" * 64, severity="critical")
    _close(db, aid)
    doc = json.loads(_run(db, "export-findings", "--project", "web",
                          "--format", "json").stdout)
    assert doc["project"] == "web"
    assert doc["filters_applied"] is False
    assert [b["branch"] for b in doc["branches"]] == ["main"]
    assert doc["branches"][0]["commit_sha"] == "abc0000000000000"
    assert doc["branches"][0]["open"][0]["fingerprint"] == "a" * 64


def test_it_reaches_past_the_first_page(tmp_path, cli_inproc):
    # finding_rows caps a page at MAX_PER_PAGE; a document that stops there
    # would be silently short, which is the one failure an agent cannot see.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bin"))
    from security.queries import MAX_PER_PAGE

    db = tmp_path / "l.db"
    aid = _prepared(db, tmp_path, "web", "main", "abc0000000000000")
    n = MAX_PER_PAGE + 7
    # The findings are scaffolding, reported in-process (conftest's
    # `cli_inproc`): a python start-up each was most of this test's time.
    # The verb under test, export-findings, still runs as a subprocess.
    for i in range(n):
        _finding(db, aid, f"{i:064x}", title=f"finding {i}", run=cli_inproc)
    _close(db, aid)
    doc = json.loads(_run(db, "export-findings", "--project", "web",
                          "--format", "json").stdout)
    got = doc["branches"][0]["open"] + doc["branches"][0]["resolved"]
    assert len(got) == n, len(got)
    assert len({f["fingerprint"] for f in got}) == n


def test_the_header_reports_what_the_screen_was_showing_when_asked(tmp_path):
    db = tmp_path / "l.db"
    aid = _prepared(db, tmp_path, "web", "main", "abc0000000000000")
    _finding(db, aid, "a" * 64, severity="critical")
    _finding(db, aid, "b" * 64, severity="info")
    _close(db, aid)
    md = _run(db, "export-findings", "--project", "web", "--format", "md",
              "--shown", "1").stdout
    assert "The screen was showing 1 of these" in md
    # and without the flag it still says the filters were not applied
    plain = _run(db, "export-findings", "--project", "web", "--format", "md").stdout
    assert "carries everything recorded" in plain


def test_the_document_stays_one_row_per_branch(tmp_path):
    # The screen groups a finding on two branches into one row; this document
    # does not -- a fix is applied on a branch, and each branch's section has
    # to list what there is to fix on it.
    db = tmp_path / "l.db"
    a1 = _prepared(db, tmp_path, "web", "main", "1111111111111111")
    _finding(db, a1, "f" * 64, title="on both")
    _close(db, a1)
    a2 = _prepared(db, tmp_path, "web", "develop", "2222222222222222")
    _finding(db, a2, "f" * 64, title="on both")
    _close(db, a2)
    doc = json.loads(_run(db, "export-findings", "--project", "web",
                          "--format", "json").stdout)
    on = {b["branch"]: [f["fingerprint"] for f in b["open"]] for b in doc["branches"]}
    assert on == {"develop": ["f" * 64], "main": ["f" * 64]}


def _two_repositories_on_main(db, tmp_path):
    a1 = _prepared(db, tmp_path, "web", "main", "1111111111111111")
    _finding(db, a1, "f" * 64, title="in web")
    _close(db, a1)
    a2 = _prepared(db, tmp_path, "web", "main", "2222222222222222", repo="web-admin")
    _finding(db, a2, "e" * 64, title="in web-admin")
    _close(db, a2)
    return a1, a2


def test_every_repository_on_a_shared_branch_name_is_its_own_section(tmp_path):
    # A fix is applied in a checkout: `main` of web and `main` of web-admin
    # are two places, each read at its own commit. The document used to hold
    # only the repository analysed last, under the other one's name.
    db = tmp_path / "l.db"
    a1, a2 = _two_repositories_on_main(db, tmp_path)
    doc = json.loads(_run(db, "export-findings", "--project", "web",
                          "--format", "json").stdout)
    got = [(b["repo"], b["branch"], b["analysis_id"], b["commit_sha"],
            [f["title"] for f in b["open"]], [f["repo"] for f in b["open"]])
           for b in doc["branches"]]
    assert got == [("web", "main", a1, "1111111111111111", ["in web"], ["web"]),
                   ("web-admin", "main", a2, "2222222222222222", ["in web-admin"], ["web-admin"])]
    md = _run(db, "export-findings", "--project", "web", "--format", "md").stdout
    assert "## `web` › `main` at `111111111111`" in md
    assert "## `web-admin` › `main` at `222222222222`" in md
    assert "- **Repository:** `web-admin`" in md
    sbom = json.loads(_run(db, "export-findings", "--project", "web",
                           "--format", "sbom").stdout)
    assert [(b["repo"], b["branch"], b["analysis_id"]) for b in sbom["branches"]] == \
        [("web", "main", a1), ("web-admin", "main", a2)]


def test_a_single_repository_document_does_not_name_the_repository(tmp_path):
    # The control: a project with one checkout reads as it always did -- its
    # repository is the project's own name, and saying it is noise.
    db = tmp_path / "l.db"
    aid = _prepared(db, tmp_path, "web", "main", "1111111111111111")
    _finding(db, aid, "f" * 64)
    _close(db, aid)
    md = _run(db, "export-findings", "--project", "web", "--format", "md").stdout
    assert "## `main` at `111111111111`" in md
    assert "›" not in md and "**Repository:**" not in md
