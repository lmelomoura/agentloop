# bin/security/verdict.py
"""What a verifier concludes about one candidate.

THREE WORDS AND A REASON. A verifier is a second agent with fresh context
that read the code and tried to DISPROVE the hunter's claim (see
security/prompts.py for the text it is given):

    confirmed         it read the code and could not disprove the claim
    needs_validation  it tried and cannot conclude: a fact the code does not
                      hold is missing -- a production setting, a proxy rule
    rejected          it disproved the claim, and says with what

THE REASON IS NEVER OPTIONAL, for any of the three. "Looks like a false
positive" is not a verdict and neither is "agreed": the reason is the whole
evidence that a verifier existed and read something, and it is what a human
reads in the report when a finding leaves the posture.

Refusals name the FIELD and the rule, never the value -- the caller re-runs
with a description instead of a quotation, exactly as `report-finding`'s own
door does (see cli._refuse_if_secret).
"""

VERDICTS = ("confirmed", "needs_validation", "rejected")
# The same cap every other agent-written free text carries (cli.MAX_TEXT).
MAX_REASON = 10000
KEYS = ("verdict", "reason")


class VerdictError(ValueError):
    """A refusal: `field` names the key ('' for the payload itself),
    `message` the rule. Neither ever carries a value."""

    def __init__(self, field, message):
        super().__init__(f"{field}: {message}" if field else message)
        self.field = field
        self.message = message


def validate(payload):
    """(verdict, reason), stripped -- or a VerdictError."""
    if not isinstance(payload, dict):
        raise VerdictError("", "must be an object with `verdict` and `reason`")
    extra = sorted(set(payload) - set(KEYS))
    if extra:
        raise VerdictError("", "has keys this ledger does not know: " + ", ".join(extra))
    if payload.get("verdict") not in VERDICTS:
        raise VerdictError("verdict", "must be one of " + ", ".join(VERDICTS))
    reason = payload.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise VerdictError("reason", "must be a non-empty string: a verdict without a "
                           "reason is an opinion, and the report prints the reason")
    if len(reason) > MAX_REASON:
        raise VerdictError("reason", f"is {len(reason)} characters and the limit is {MAX_REASON}")
    return payload["verdict"], reason.strip()
