# tests/security/test_prompts.py
"""The verifier's prompt: minted from the ledger, never by the hunter."""
from security import prompts

FINDING = {
    "fingerprint": "b" * 64, "rule": "sql-injection", "severity": "high",
    "title": "string-built SQL in the search handler",
    "rationale": "THE HUNTER'S PERSUASIVE PROSE, which must not travel",
    "occurrences": [{"file": "app/db.py", "line": 12, "snippet_hash": "h"}],
    "candidate": {
        "trace": [{"kind": "entrypoint", "file": "app/api.py", "line": 42,
                   "scope": "search", "description": "the q parameter"},
                  {"kind": "sink", "file": "app/db.py", "line": 12,
                   "scope": "find", "description": "concatenated into execute()"}],
        "intended_control": "queries are parameterised",
        "confidence": {"score": "high", "reason": "unconditional"},
        "likelihood": {"score": "high", "reason": "unauthenticated"},
        "impact": {"score": "high", "reason": "full read"}},
}


def test_the_prompt_carries_the_chain_and_the_command():
    out = prompts.verifier_prompt(7, FINDING)
    assert "app/api.py:42" in out and "app/db.py:12" in out
    assert "queries are parameterised" in out
    assert "high" in out
    assert "agentloop security report-verdict --analysis 7 --fingerprint " + "b" * 64 in out
    for word in prompts.VERDICT_WORDS:
        assert word in out


def test_the_prompt_does_not_carry_the_hunters_rationale():
    """The decision that defines the independence: the candidate is a chain a
    verifier can check line by line; the rationale is the prose that argued
    the finding, and reading it is how a fresh reader stops being fresh."""
    out = prompts.verifier_prompt(7, FINDING)
    assert "PERSUASIVE PROSE" not in out
    assert "your job is to disprove" in out.lower()


def test_a_finding_without_a_candidate_still_gets_a_usable_prompt():
    bare = dict(FINDING, candidate=None)
    out = prompts.verifier_prompt(7, bare)
    assert "app/db.py:12" in out, "the occurrences are what is left to read"
    assert "no trace was recorded" in out
