# tests/security/test_candidate.py
"""The `candidate` document: validated at the door, stored canonical, decoded
for every reader. `decode` never raises; every refusal names a path and never
a value."""
import pytest

from security import candidate


def _doc(**over):
    doc = {
        "trace": [
            {"kind": "entrypoint", "file": "app/api.py", "line": 42,
             "scope": "handle_upload", "description": "filename read from the request"},
            {"kind": "sink", "file": "app/storage.py", "line": 19,
             "scope": "save", "description": "open() on the joined path"}],
        "intended_control": "uploads stay under the upload root",
        "confidence": {"score": "high", "reason": "the join is unconditional"},
        "likelihood": {"score": "high", "reason": "any tenant can upload"},
        "impact": {"score": "high", "reason": "arbitrary file write"},
        "conditions": [{"kind": "authentication_level", "description": "a tenant session"}],
    }
    doc.update(over)
    return doc


def test_a_full_document_validates_and_round_trips():
    doc = candidate.validate(_doc(), required=candidate.KEYS)
    assert candidate.decode(candidate.encode(doc)) == doc


def test_encoding_is_independent_of_key_order():
    a = candidate.encode(candidate.validate(_doc()))
    reordered = dict(reversed(list(_doc().items())))
    b = candidate.encode(candidate.validate(reordered))
    assert a == b
    assert "\n" not in a and ": " not in a


@pytest.mark.parametrize("over, path, rule", [
    ({"trace": []}, "trace", "at least one step"),
    ({"trace": "x"}, "trace", "at least one step"),
    ({"trace": [{"kind": "leak", "file": "a", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].kind", "must be one of"),
    ({"trace": [{"kind": "sink", "file": "/etc/passwd", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].file", "repository-relative"),
    ({"trace": [{"kind": "sink", "file": "a/../b", "line": 1, "scope": "s", "description": "d"}]},
     "trace[0].file", "repository-relative"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 0, "scope": "s", "description": "d"}]},
     "trace[0].line", "1 or more"),
    ({"trace": [{"kind": "sink", "file": "a", "line": True, "scope": "s", "description": "d"}]},
     "trace[0].line", "1 or more"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 1, "scope": "", "description": "d"}]},
     "trace[0].scope", "non-empty string"),
    ({"trace": [{"kind": "sink", "file": "a", "line": 1, "scope": "s", "description": "d", "x": 1}]},
     "trace[0]", "does not know: x"),
    ({"confidence": {"score": "sure", "reason": "r"}}, "confidence.score", "must be one of"),
    ({"confidence": {"score": "high"}}, "confidence.reason", "non-empty string"),
    ({"impact": {"score": "critical", "reason": "r", "extra": 1}}, "impact", "does not know: extra"),
    ({"likelihood": "high"}, "likelihood", "must be an object"),
    ({"conditions": [{"kind": "moon_phase", "description": "d"}]}, "conditions[0].kind", "must be one of"),
    ({"conditions": {"kind": "data_state"}}, "conditions", "must be a list"),
    ({"intended_control": ""}, "intended_control", "non-empty string"),
    ({"payloads": ["x"]}, "", "does not know: payloads"),
])
def test_every_refusal_names_the_path_and_the_rule(over, path, rule):
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(**over))
    assert exc.value.path == path
    assert rule in exc.value.message


def test_a_repeated_step_is_refused():
    doc = _doc()
    doc["trace"].append(dict(doc["trace"][0]))
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(doc)
    assert exc.value.path == "trace[2]"
    assert "repeats" in exc.value.message


def test_more_than_fifty_steps_are_refused():
    steps = [{"kind": "propagation", "file": "a.py", "line": i + 1, "scope": "f",
              "description": "d"} for i in range(51)]
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(trace=steps))
    assert exc.value.path == "trace"
    assert "51" in exc.value.message


def test_a_text_over_the_cap_is_refused_by_path():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(intended_control="x" * (candidate.MAX_TEXT + 1)))
    assert exc.value.path == "intended_control"
    assert str(candidate.MAX_TEXT) in exc.value.message


def test_a_document_over_the_byte_cap_is_refused():
    steps = [{"kind": "propagation", "file": "a.py", "line": i + 1, "scope": "f",
              "description": "d" * candidate.MAX_TEXT} for i in range(7)]
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(trace=steps))
    assert exc.value.path == ""
    assert "bytes" in exc.value.message


def test_required_keys_are_held_to_and_named():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate({"confidence": {"score": "low", "reason": "r"}},
                           required=("trace", "intended_control", "confidence"))
    assert exc.value.path == ""
    assert "missing required key(s): trace, intended_control" in exc.value.message


def test_a_trace_is_refused_where_the_category_has_no_data_flow():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(), trace_allowed=False)
    assert exc.value.path == "trace"
    assert "not accepted" in exc.value.message


def test_a_refusal_never_quotes_the_value():
    with pytest.raises(candidate.CandidateError) as exc:
        candidate.validate(_doc(confidence={"score": "AKIAQYLPMN5HNXMEFRTG", "reason": "r"}))
    assert "AKIA" not in str(exc.value)


def test_the_ceiling_rule():
    assert candidate.within_ceiling("high", {"impact": {"score": "high", "reason": "r"}})
    assert candidate.within_ceiling("low", {"impact": {"score": "critical", "reason": "r"}})
    assert not candidate.within_ceiling("critical", {"impact": {"score": "high", "reason": "r"}})
    assert candidate.within_ceiling("critical", {})
    assert candidate.within_ceiling("critical", None)


def test_texts_names_every_free_text_field_by_path():
    paths = [p for p, _ in candidate.texts(candidate.validate(_doc()))]
    assert paths == ["trace[0].scope", "trace[0].description", "trace[1].scope",
                     "trace[1].description", "intended_control", "confidence.reason",
                     "likelihood.reason", "impact.reason", "conditions[0].description"]
    assert "open() on the joined path" in candidate.search_text(_doc())
    assert candidate.search_text(None) == ""


def test_decode_never_raises_and_confidence_is_derived():
    assert candidate.decode("") is None
    assert candidate.decode(None) is None
    assert candidate.decode("{") is None
    assert candidate.decode("[1]") is None
    assert candidate.confidence_of(None) == ""
    assert candidate.confidence_of({"confidence": {"score": "low", "reason": "r"}}) == "low"
    assert candidate.confidence_of({"confidence": "low"}) == ""
