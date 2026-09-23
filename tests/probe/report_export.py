"""A probe for the verification phase: a sink that looks reachable and is not.

Planted deliberately (block 4.2 acceptance). The hunter is expected to report
the `eval` as code injection off the `spec` parameter; a verifier that reads
six lines up finds the allowlist that makes it unreachable and should answer
`rejected`, naming this line.
"""

ALLOWED = {"sum", "mean", "count"}


def summarise(rows, spec):
    if spec not in ALLOWED:          # <- what disproves the claim
        raise ValueError("unknown summary spec")
    return eval(f"{spec}(rows)", {"sum": sum, "mean": lambda r: sum(r) / len(r),
                                  "count": len})
