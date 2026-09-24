# bin/security/slices.py
"""The deep inventory, packed into the units a single session reads in full.

WHY PACK AT ALL. A unit per file would pay a session's fixed cost -- the
skill, the guides, the prompt -- once per file: thousands of sessions on a
large repository. One unit for everything is the context window this whole
design exists to escape. A unit of about one reading (inventory.RANGE_BYTES)
of source is neither: ~85k tokens to read, a few dozen sessions for a very
large repository.

IN PATH ORDER, so the files of one directory travel together: a session that
reads a controller reads its neighbours, which is where a trace goes first.
A range larger than the budget -- one enormous line -- is a unit of its own;
it is never split, because nothing reads half a line.
"""

from .inventory import RANGE_BYTES

SLICE_BYTES = RANGE_BYTES


def pack(files, budget: int = SLICE_BYTES) -> list:
    """`files` as security/inventory.build lists them. A list of slices, each
    a list of {"path", "first", "last", "bytes"} in path order, none larger
    than `budget` unless it is a single range that is."""
    out, current, size = [], [], 0
    for f in sorted(files, key=lambda f: f["path"]):
        for first, last, nbytes in f["ranges"]:
            if current and size + nbytes > budget:
                out.append(current)
                current, size = [], 0
            current.append({"path": f["path"], "first": first, "last": last,
                            "bytes": nbytes})
            size += nbytes
    if current:
        out.append(current)
    return out
