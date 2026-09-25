# tests/security/test_slices.py
"""Packing the deep inventory into units: bounded, in path order, never splitting a range."""
from security import slices


def _file(path, *ranges):
    return {"path": path, "lines": ranges[-1][1] if ranges else 0,
            "bytes": sum(r[2] for r in ranges), "ranges": [list(r) for r in ranges]}


def _shape(out):
    return [[(e["path"], e["first"], e["last"]) for e in s] for s in out]


def test_ranges_are_packed_in_path_order_up_to_the_budget():
    files = [_file("b/two.py", (1, 5, 40)), _file("a/one.py", (1, 3, 70)),
             _file("c/three.py", (1, 2, 50))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("a/one.py", 1, 3)], [("b/two.py", 1, 5), ("c/three.py", 1, 2)]]


def test_a_range_larger_than_the_budget_is_a_slice_of_its_own():
    files = [_file("big.py", (1, 1, 500)), _file("small.py", (1, 1, 10))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("big.py", 1, 1)], [("small.py", 1, 1)]]


def test_each_range_of_a_cut_file_is_its_own_entry():
    files = [_file("huge.py", (1, 100, 90), (101, 180, 90))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("huge.py", 1, 100)], [("huge.py", 101, 180)]]


def test_a_file_with_nothing_to_read_contributes_nothing():
    assert slices.pack([_file("empty.py")], budget=100) == []


def test_every_entry_carries_its_bytes_and_no_slice_exceeds_the_budget():
    files = [_file(f"d/{n:02}.py", (1, 10, 30)) for n in range(10)]
    out = slices.pack(files, budget=100)
    assert all(sum(e["bytes"] for e in s) <= 100 for s in out)
    assert sum(len(s) for s in out) == 10


def test_a_slice_reaching_exactly_the_budget_is_full_and_the_next_range_starts_a_new_one():
    files = [_file("a.py", (1, 5, 60)), _file("b.py", (1, 3, 40)), _file("c.py", (1, 1, 1))]
    out = slices.pack(files, budget=100)
    assert _shape(out) == [[("a.py", 1, 5), ("b.py", 1, 3)], [("c.py", 1, 1)]]
    assert sum(e["bytes"] for e in out[0]) == 100


def test_two_small_ranges_of_one_file_share_a_slice():
    files = [_file("cut.py", (1, 10, 30), (11, 20, 30)), _file("next.py", (1, 2, 50))]
    assert _shape(slices.pack(files, budget=100)) == [
        [("cut.py", 1, 10), ("cut.py", 11, 20)], [("next.py", 1, 2)]]


def test_the_default_budget_is_one_reading():
    assert slices.SLICE_BYTES == 300_000
