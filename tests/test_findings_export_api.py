"""`GET /api/security/findings-export` — the download behind the Export button.

The document itself is tested in tests/security/. What is tested here is the
edge: the closed format list, the status code a typo earns, and the download
filename — the one place in this route where free text an operator typed
reaches a header.
"""
import json

import pytest


@pytest.fixture
def export(srv, monkeypatch):
    """The handler with the engine stubbed, so these are tests of the route."""
    calls = []

    def fake_al(args, **kw):
        calls.append(args)
        if args[:2] == ["security", "export-findings"]:
            project = args[args.index("--project") + 1]
            if project == "ghost":
                return False, "no analysis has ever run for project 'ghost' — known: web"
            if project == "broken":
                return False, "database is locked"
            return True, f"# Findings — {project}\n"
        return True, ""

    monkeypatch.setattr(srv, "al", fake_al)
    return srv, calls


def test_a_format_outside_the_list_is_refused_at_the_edge(export):
    srv, calls = export
    code, body, headers = srv.security_findings_export("web", "pdf")
    # pdf never reaches the engine: the route checks the format itself, and
    # this asserts the handler agrees with it rather than trusting the caller
    assert code == 400 and headers is None
    for fmt in ("md", "json", "html", "sbom"):
        code, body, headers = srv.security_findings_export("web", fmt)
        assert code == 200 and headers is not None, fmt


def test_the_sbom_bundle_is_not_named_like_a_single_cyclonedx(export):
    # One CycloneDX per branch side by side is not a CycloneDX document, and
    # SBOM tooling fed a `.cdx.json` of it would choke on the envelope.
    srv, _ = export
    _, _, headers = srv.security_findings_export("web", "sbom")
    assert headers["Content-Disposition"].endswith('findings-web.sboms.json"')
    assert ".cdx.json" not in headers["Content-Disposition"]


def test_a_project_nobody_analysed_is_a_404_not_an_empty_file(export):
    srv, _ = export
    code, body, headers = srv.security_findings_export("ghost", "md")
    assert code == 404 and headers is None
    assert "ghost" in body["error"]


def test_any_other_engine_failure_is_a_500_and_says_what_happened(export):
    srv, _ = export
    code, body, headers = srv.security_findings_export("broken", "md")
    assert code == 500 and headers is None
    assert "database is locked" in body["error"]


def test_a_download_earns_an_event_under_the_project(export):
    srv, calls = export
    srv.security_findings_export("web", "json")
    kinds = [a[a.index("--kind") + 1] for a in calls if "--kind" in a]
    assert kinds == ["findings_exported"]


def test_a_failed_export_earns_no_event(export):
    # An event says a document left the machine. None did.
    srv, calls = export
    srv.security_findings_export("ghost", "md")
    assert not [a for a in calls if "--kind" in a]


@pytest.mark.parametrize("project,expected", [
    ("Minerva", "findings-Minerva.md"),
    ("../etc/passwd", "findings-etc-passwd.md"),
    ('a"; rm -rf /', "findings-a-rm--rf.md"),
    ("Sec App/v2", "findings-Sec-App-v2.md"),
    ("....", "findings-project.md"),
    ("com espaços", "findings-com-espa-os.md"),
])
def test_the_download_name_is_a_flat_token_whatever_the_project_is_called(
        srv, project, expected):
    # The project name is free text an operator typed and it ends up in a
    # Content-Disposition header. Nothing here may carry a slash, a quote, a
    # leading dash or a `..`.
    got = srv._download_name(project, "md")
    assert got == expected
    for bad in ('"', "/", "\\", "\n", ".."):
        assert bad not in got


def test_a_very_long_project_name_cannot_stretch_the_header(srv):
    got = srv._download_name("x" * 500, "json")
    assert len(got) < 100 and got.endswith(".json")


def test_the_shown_count_travels_but_a_bad_one_does_not_cost_the_download(export):
    srv, calls = export
    srv.security_findings_export("web", "md", shown=7)
    assert ["--shown", "7"] == calls[0][-2:]
    calls.clear()
    # None is the honest value for "the page did not say": the header then
    # states the rule without the comparison, rather than inventing a number.
    srv.security_findings_export("web", "md", shown=None)
    assert "--shown" not in calls[0]
