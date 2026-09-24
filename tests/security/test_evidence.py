# tests/security/test_evidence.py
"""The proof of reading: what a unit's own stream shows it read, and nothing it only asked for.

The fixtures are real captured event shapes (2026-09-24, 1,620 Claude Code
`Read` calls) with neutral paths and content; see the task that added them."""
from pathlib import Path

from security import evidence

FIXTURES = Path(__file__).parent / "fixtures" / "streams"
ROOT = "/Users/me/run"


def _claude():
    return evidence.read_session(FIXTURES / "claude-reads.ndjson", ROOT)


def test_a_read_counts_the_lines_its_result_carried():
    assert _claude().reads["src/app.py"] == [(1, 3)]


def test_a_read_cut_by_the_token_cap_counts_only_what_came_back():
    first_five = (FIXTURES / "claude-reads.ndjson").read_text().splitlines()[:5]
    assert evidence.parse(first_five, ROOT).reads["src/big.py"] == [(1, 1096)]
    assert _claude().reads["src/big.py"] == [(1, 1724)], "the next read picked up where the cap cut"


def test_a_result_that_read_nothing_counts_nothing():
    assert "src/short.py" not in _claude().reads


def test_an_error_counts_nothing():
    assert "src/gone.py" not in _claude().reads


def test_a_read_outside_the_run_root_counts_nothing():
    assert not any("secret" in path for path in _claude().reads)


def test_a_subagent_s_reads_count_nothing_and_its_launch_is_counted():
    session = _claude()
    assert "src/sub.py" not in session.reads
    assert session.tasks == 1


def test_a_read_with_no_result_counts_nothing_and_a_stray_result_is_ignored():
    assert "src/noresult.py" not in _claude().reads


def test_without_the_structured_range_the_numbered_lines_are_the_proof():
    assert _claude().reads["src/prefix.py"] == [(7, 8)]


def test_the_guides_a_session_opened_are_named():
    assert _claude().guides == {"ATTACK-CLASSES"}


def test_opencode_reads_count_by_the_range_the_normaliser_now_keeps():
    session = evidence.read_session(FIXTURES / "opencode-reads.ndjson", ROOT)
    assert session.reads["src/a.txt"] == [(1, 2)]
    assert session.reads["src/b.txt"] == [(4, 5)]


def test_a_missing_stream_is_an_empty_session():
    assert evidence.read_session(FIXTURES / "nope.ndjson", ROOT) == evidence.EMPTY
    assert evidence.read_session(None, ROOT) == evidence.EMPTY


def test_what_security_read_served_joins_the_stream_s_reads():
    session = evidence.with_served(_claude(), [("src/app.py", 4, 9), ("src/new.py", 1, 5)])
    assert session.reads["src/app.py"] == [(1, 9)], "adjacent spans are one span"
    assert session.reads["src/new.py"] == [(1, 5)]


def test_missing_is_what_the_reads_do_not_cover_of_each_range():
    reads = {"a.py": [(1, 10), (21, 30)], "b.py": [(1, 100)]}
    wanted = [{"path": "a.py", "first": 1, "last": 30, "bytes": 300},
              {"path": "b.py", "first": 1, "last": 50, "bytes": 90},
              {"path": "c.py", "first": 1, "last": 5, "bytes": 5}]
    assert evidence.missing(wanted, reads) == [
        {"path": "a.py", "first": 11, "last": 20, "bytes": 0},
        {"path": "c.py", "first": 1, "last": 5, "bytes": 5}]


def test_adjacent_reads_cover_a_range_together():
    assert evidence.missing([{"path": "a.py", "first": 1, "last": 9, "bytes": 1}],
                            {"a.py": [(5, 9), (1, 4)]}) == []


def test_spans_are_merged_sorted_with_the_overlapping_and_the_adjacent_joined():
    """The package's one merge of line spans -- the proof of reading here, and
    what a read unit covered and the deep scope still owes (units.py)."""
    assert evidence.merge_spans([(20, 30), (1, 4), (5, 9), (8, 12), (40, 40)]) == \
        [(1, 12), (20, 30), (40, 40)]
    assert evidence.merge_spans([]) == []


def test_a_relative_root_path_and_a_symlinked_root_resolve_to_the_same_files(tmp_path):
    real = tmp_path / "real"
    (real / "src").mkdir(parents=True)
    link = tmp_path / "link"
    link.symlink_to(real)
    line = ('{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read",'
            '"input":{"file_path":"%s/src/x.py"}}]},"parent_tool_use_id":null}\n'
            '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1",'
            '"content":"1\\tx\\n"}]},"parent_tool_use_id":null}\n') % real
    session = evidence.parse(line.splitlines(), str(link))
    assert session.reads == {"src/x.py": [(1, 1)]}


def test_a_non_dict_message_is_skipped_and_the_real_read_still_counts():
    lines = [
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/ok.py"}}]},'
        '"parent_tool_use_id":null}',
        '{"type":"user","message":"a string","parent_tool_use_id":null}',
        '{"type":"assistant","message":["x"],"parent_tool_use_id":null}',
        '{"type":"assistant","message":7}',
        '{"type":"user","message":{"role":"user","content":'
        '[{"type":"tool_result","tool_use_id":"t1","content":"1\\tok\\n"}]},'
        '"parent_tool_use_id":null}',
    ]
    assert evidence.parse(lines, ROOT).reads == {"src/ok.py": [(1, 1)]}


def test_two_tool_results_in_one_event_each_fall_back_to_their_own_numbered_lines():
    lines = [
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/a.py"}},'
        '{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"src/b.py"}}]},'
        '"parent_tool_use_id":null}',
        '{"type":"user","message":{"role":"user","content":'
        '[{"type":"tool_result","tool_use_id":"t1","content":"1\\ta\\n2\\tb\\n"},'
        '{"type":"tool_result","tool_use_id":"t2","content":"5\\tx\\n"}]},'
        '"parent_tool_use_id":null,'
        '"tool_use_result":{"type":"text","file":{"filePath":"src/a.py","startLine":1,"numLines":100}}}',
    ]
    session = evidence.parse(lines, ROOT)
    assert session.reads["src/a.py"] == [(1, 2)]
    assert session.reads["src/b.py"] == [(5, 5)], "never (1, 100) from the event-level result"


def test_a_relative_file_path_resolves_against_the_run_root_and_one_that_escapes_it_counts_nothing():
    lines = [
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/rel.py"}}]},'
        '"parent_tool_use_id":null}',
        '{"type":"user","message":{"role":"user","content":'
        '[{"type":"tool_result","tool_use_id":"t1","content":"1\\tx\\n"}]},'
        '"parent_tool_use_id":null}',
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"../outside.py"}}]},'
        '"parent_tool_use_id":null}',
        '{"type":"user","message":{"role":"user","content":'
        '[{"type":"tool_result","tool_use_id":"t2","content":"1\\ty\\n"}]},'
        '"parent_tool_use_id":null}',
    ]
    session = evidence.parse(lines, ROOT)
    assert session.reads == {"src/rel.py": [(1, 1)]}
