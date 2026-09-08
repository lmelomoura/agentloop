"""The index is not rewritten whole to give back a megabyte.

Deleting a run ended in an unconditional VACUUM. Measured against the operator's
own index -- 513 MB, 405 runs -- one delete took **5.7 s**, handed back **0
bytes**, and a `/api/data` poll that landed during it waited **12.8 s** behind
the lock. Without the rewrite the same delete takes 20 ms. That is the whole of
"the trash takes forever, and meanwhile the runs list stops updating".

Deleting one run frees well under a megabyte, so the rewrite is not worth its own
cost per delete. It waits until there is enough to reclaim to pay for itself.
The freelist is the measure and `PRAGMA freelist_count` is instant, so deciding
costs nothing.
"""

import json

import pytest


def _fill(srv, runs=6, blob_kb=400):
    """A journal of `runs` runs, each carrying a blob big enough to matter."""
    lines = []
    for i in range(runs):
        stem = srv.DATA_DIR / "logs" / "j-vac" / f"2026090{i}T000000Z-{i}.json"
        stem.parent.mkdir(parents=True, exist_ok=True)
        stem.write_text(json.dumps({"result": "x" * (blob_kb * 1024)}))
        lines.append(json.dumps({
            "id": "j-vac", "status": "success", "start": 1700000000 + i,
            "end": 1700000060 + i, "duration": 60, "cost": 0.01,
            "session": f"s-{i}", "log": str(stem), "note": "", "cause": "",
        }))
    srv.RUNS_FILE.write_text("\n".join(lines) + "\n")
    srv.ingest()


def _freelist(srv):
    conn = srv.db_conn()
    pages = conn.execute("PRAGMA freelist_count").fetchone()[0]
    size = conn.execute("PRAGMA page_size").fetchone()[0]
    conn.close()
    return pages * size


def test_a_freelist_too_small_to_pay_for_the_rewrite_is_left_alone(srv, clean_data):
    """Below the floor, compact_db does nothing at all -- and says so."""
    _fill(srv)
    conn = srv.db_conn()
    conn.execute("DELETE FROM runs WHERE start=?", (1700000000,))
    conn.commit()
    conn.close()

    free_before = _freelist(srv)
    assert free_before > 0, "the delete freed no pages -- the fixture proves nothing"
    assert free_before < srv.COMPACT_MIN_FREE_BYTES

    before, after = srv.compact_db()

    assert after == before, "a rewrite that reclaims nothing must not run"
    assert _freelist(srv) == free_before, "the freelist was reclaimed anyway -- VACUUM ran"


def test_a_freelist_worth_reclaiming_is_reclaimed(srv, clean_data, monkeypatch):
    """Above the floor the rewrite runs, and the pages go back to the disk."""
    _fill(srv)
    conn = srv.db_conn()
    conn.execute("DELETE FROM runs WHERE start<?", (1700000003,))
    conn.commit()
    conn.close()

    assert _freelist(srv) > 0
    monkeypatch.setattr(srv, "COMPACT_MIN_FREE_BYTES", 1024)

    before, after = srv.compact_db()

    assert _freelist(srv) == 0, "the pages were not handed back"
    assert after < before, "the file did not shrink"


def test_deleting_one_run_does_not_rewrite_the_index(srv, clean_data):
    """The path the trash button takes: one run out, no half-gigabyte rewrite.

    Proven by what is left behind rather than by a clock: a VACUUM ends with an
    empty freelist, so pages still on it are proof none ran.
    """
    _fill(srv)

    removed = srv.delete_run("j-vac", 1700000000)

    assert removed is not None and removed["journal"] == 1
    assert _freelist(srv) > 0, "the freelist is empty -- the delete rewrote the index"
