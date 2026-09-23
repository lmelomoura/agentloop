# tests/security/test_verdict.py
"""The verdict a verifier writes: a closed vocabulary and a reason that is
never optional. Every refusal names the field and never the text."""
import pytest

from security import verdict


def test_a_valid_payload_comes_back_normalised():
    assert verdict.validate({"verdict": "rejected", "reason": "  the guard at db.py:9 rejects it  "}) \
        == ("rejected", "the guard at db.py:9 rejects it")


@pytest.mark.parametrize("payload, field, rule", [
    ({}, "verdict", "must be one of"),
    ({"verdict": "maybe", "reason": "r"}, "verdict", "must be one of"),
    ({"verdict": 5, "reason": "r"}, "verdict", "must be one of"),
    ({"verdict": "confirmed"}, "reason", "non-empty string"),
    ({"verdict": "confirmed", "reason": "   "}, "reason", "non-empty string"),
    ({"verdict": "confirmed", "reason": 5}, "reason", "non-empty string"),
    ({"verdict": "confirmed", "reason": "r", "severity": "high"}, "", "does not know: severity"),
])
def test_every_refusal_names_the_field_and_the_rule(payload, field, rule):
    with pytest.raises(verdict.VerdictError) as exc:
        verdict.validate(payload)
    assert exc.value.field == field
    assert rule in exc.value.message


def test_a_reason_over_the_cap_is_refused():
    with pytest.raises(verdict.VerdictError) as exc:
        verdict.validate({"verdict": "confirmed", "reason": "x" * (verdict.MAX_REASON + 1)})
    assert exc.value.field == "reason"
    assert str(verdict.MAX_REASON) in exc.value.message


def test_a_payload_that_is_not_an_object_is_refused():
    with pytest.raises(verdict.VerdictError) as exc:
        verdict.validate(["confirmed"])
    assert exc.value.field == ""
    assert "object" in exc.value.message


def test_a_refusal_never_quotes_the_value():
    with pytest.raises(verdict.VerdictError) as exc:
        verdict.validate({"verdict": "AKIAQYLPMN5HNXMEFRTG", "reason": "r"})
    assert "AKIA" not in str(exc.value)
