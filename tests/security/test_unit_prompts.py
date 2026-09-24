# tests/security/test_unit_prompts.py
"""The prompt of each unit: minted from the ledger, one job each, and the reading the platform can prove."""
import pytest

from security import prompts

ANALYSIS = {"id": 21, "project": "web", "repo": "web", "branch": "main",
            "commit_sha": "0123456789abcdef", "profile": "deep"}
ROW = {"fingerprint": "a" * 64, "kind": "scanner", "category": "dependency",
       "rule": "CVE-2024-0001", "severity": "high", "title": "lib 1.0 is vulnerable",
       "file": "composer.lock", "line": 0, "producer": "trivy", "state": "new"}
RANGES = [{"path": "src/Auth/Login.php", "first": 1, "last": 240, "bytes": 9000},
          {"path": "src/Auth/Reset.php", "first": 1, "last": 80, "bytes": 3000}]


def _p(kind, context, platform="anthropic", label=None):
    return prompts.unit_prompt(ANALYSIS, label or f"{kind} 1/1", platform, kind, context)


@pytest.mark.parametrize("kind, context", [
    ("triage", {"rows": [ROW]}),
    ("hunt", {"guides": ["ATTACK-CLASSES"]}),
    ("read", {"ranges": RANGES, "guides": ["ATTACK-CLASSES"], "known": [], "decided": []}),
])
def test_every_unit_names_its_analysis_its_place_and_the_three_rules(kind, context):
    out = _p(kind, context, label=f"{kind} 3/9 · attempt 2")
    assert "SECURITY ANALYSIS 21 · unit " + f"{kind} 3/9 · attempt 2" in out
    assert "branch main · commit 0123456789ab" in out
    assert "agentloop security finish" in out and "Never" in out
    assert "subagent" in out
    assert f'section "Unit: {kind}"' in out


def test_the_skill_is_invoked_by_name_on_claude_code_and_opencode_and_read_by_path_on_codex():
    assert "Invoke the `security-analysis` skill" in _p("hunt", {"guides": []})
    opencode = _p("hunt", {"guides": []}, platform="opencode")
    assert "Invoke the `security-analysis` skill" in opencode, \
        "OpenCode's CLI reads ~/.claude/skills (measured): by name, as before the pipeline"
    assert str(prompts.SKILL_DIR / "SKILL.md") in opencode, "and by path, for a machine where the link is missing"
    codex = _p("hunt", {"guides": []}, platform="openai")
    assert str(prompts.SKILL_DIR / "SKILL.md") in codex
    assert "Invoke the" not in codex


def test_each_platform_is_told_how_its_subagent_tool_is_closed():
    claude = _p("hunt", {"guides": []})
    assert "the `Agent` tool (the CLI's roster calls it `Task`) is closed for this run" in claude
    assert "The `task` tool is closed for this run" in _p("hunt", {"guides": []}, platform="opencode")
    codex = _p("hunt", {"guides": []}, platform="openai")
    assert "Never call `spawn_agent`" in codex
    assert "`Agent`" not in codex and "`task`" not in codex, "the Codex CLI has neither tool"


def test_a_triage_unit_lists_each_row_with_what_it_is():
    carried = dict(ROW, fingerprint="c" * 64, kind="carried", category="sast", rule="xss",
                   producer="agent", file="src/View.php", line=12, title="unescaped name")
    out = _p("triage", {"rows": [ROW, carried]})
    assert "[scanner] " + "a" * 64 + " · dependency/CVE-2024-0001 · high · composer.lock · by trivy" in out
    assert "[carried] " + "c" * 64 + " · sast/xss · high · src/View.php:12 · by agent" in out
    assert "re-report it under the fingerprint given" in out
    assert "agentloop security report-gone" in out and "no `candidate`" in out


def test_a_scanner_row_whose_severity_changed_shows_the_scanner_s_too():
    """The judge owes a scanner row at medium or above at the severity its
    scanner filed OR at the one it holds now (security/units.py). A row
    another unit lowered to `low` is still owed -- and the unit sees why."""
    lowered = dict(ROW, severity="low", scanner_severity="high")
    kept = dict(ROW, fingerprint="b" * 64, scanner_severity="high")
    out = _p("triage", {"rows": [lowered, kept]})
    assert "[scanner] " + "a" * 64 + " · dependency/CVE-2024-0001 · low (scanner: high) · composer.lock · by trivy" in out
    assert "[scanner] " + "b" * 64 + " · dependency/CVE-2024-0001 · high · composer.lock · by trivy" in out, \
        "a severity nobody changed is shown once"
    assert "Either severity counts" in out


def test_a_triage_row_shows_every_location_it_has():
    """A re-report REPLACES the stored locations (ledger.record_finding), so a
    row shown by its first location alone and re-reported "exactly as shown"
    would be narrowed to that one."""
    many = dict(ROW, occurrences=[{"file": "api/composer.lock", "line": 0},
                                  {"file": "web/composer.lock", "line": 4},
                                  {"file": "cli/composer.lock", "line": 0}])
    out = _p("triage", {"rows": [many]})
    assert "locations (3): api/composer.lock, web/composer.lock:4, cli/composer.lock" in out
    assert "EVERY location listed" in out


def test_a_read_unit_lists_its_ranges_and_says_how_reading_is_proven():
    known = [{"fingerprint": "k" * 64, "category": "sast", "rule": "sql-injection", "severity": "high",
              "state": "open", "title": "raw query", "file": "src/Auth/Login.php", "line": 40}]
    decided = [{"fingerprint": "d" * 64, "category": "sast", "rule": "open-redirect", "severity": "low",
                "state": "accepted", "title": "next param", "file": "src/Auth/Reset.php", "line": 7}]
    out = _p("read", {"ranges": RANGES, "guides": ["ATTACK-CLASSES", "WEB-PROTOCOL-AND-AUTH"],
                      "known": known, "decided": decided})
    assert "src/Auth/Login.php:1-240" in out and "src/Auth/Reset.php:1-80" in out
    assert "2 ranges, 12,000 bytes" in out
    assert "Read tool" in out
    assert "k" * 64 + " · sast/sql-injection · high · src/Auth/Login.php:40 — raw query" in out
    assert "d" * 64 + " · sast/open-redirect · accepted · src/Auth/Reset.php:7 — next param" in out
    assert str(prompts.SKILL_DIR / "references" / "WEB-PROTOCOL-AND-AUTH.md") in out
    assert "sink" in out


def test_on_codex_a_read_unit_reads_through_security_read_only():
    out = _p("read", {"ranges": RANGES, "guides": [], "known": [], "decided": []}, platform="openai")
    assert "agentloop security read --path <path> --from <line>" in out
    assert "A `cat` or `sed` of a file proves nothing" in out
    assert "Run each call alone" in out and "recorded as read in full" in out
    assert "Read tool" not in out


def test_a_hunt_unit_carries_the_profile_s_scope():
    deep = _p("hunt", {"guides": ["ATTACK-CLASSES"]})
    assert "following the calls in depth" in deep
    assert "Other units of this analysis read every file line by line" in deep
    quick = prompts.unit_prompt(dict(ANALYSIS, profile="quick"), "hunt 1/1", "anthropic", "hunt", {"guides": []})
    assert "only code that touches external input" in quick
    assert "line by line" not in quick


def test_a_verify_unit_is_the_verifier_prompt_under_the_unit_header():
    finding = {"fingerprint": "b" * 64, "rule": "xss", "severity": "high", "title": "t",
               "rationale": "PERSUASION", "occurrences": [{"file": "a.py", "line": 3}], "candidate": {}}
    out = _p("verify", {"finding": finding})
    assert out.startswith("SECURITY ANALYSIS 21 · unit verify 1/1")
    assert prompts.verifier_prompt(21, finding) in out
    assert "PERSUASION" not in out
