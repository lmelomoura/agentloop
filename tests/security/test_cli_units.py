# tests/security/test_cli_units.py
"""The CLI of the pipeline's units: the plan prepare writes, the prompt, the close, the progress, the reader."""
import json
import os
import shlex
import subprocess
import sys

import pytest
from test_cli import CLI, fails, open_analysis, raw, run  # noqa: F401 -- the suite's own helpers

from security import cli as security_cli
from security import ledger
from security import units as security_units

GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}


def _repo(tmp_path, files):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=GIT_ENV)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "c"], check=True, env=GIT_ENV)
    return root


def _deep(db, tmp_path, files):
    """A deep analysis prepared the way its orchestrator prepares it: with
    `--plan`, the one flag that makes `prepare` write the plan."""
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, files)
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline", "--plan")
    return aid, root, out


def _units(db, aid):
    conn = ledger.connect(db)
    try:
        return ledger.units_of(conn, aid)
    finally:
        conn.close()


def _unit(db, aid, kind):
    """The first unit of `kind`. Never by position: an offline prepare can
    still record hygiene rows, and their triage units come first."""
    return next(u for u in _units(db, aid) if u["kind"] == kind)


def _start(db, unit_id):
    """A plan leaves every unit `pending` until the engine launches it --
    `security read` now refuses to serve anything else (minor 1), so any
    test that reads through it has to start the unit first, the way a real
    run would."""
    conn = ledger.connect(db)
    try:
        ledger.start_unit(conn, unit_id)
    finally:
        conn.close()


def test_a_deep_prepare_lists_the_scope_and_plans_a_hunt_and_the_reads(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, out = _deep(db, tmp_path, {"src/a.py": "x = 1\n", "docs/readme.md": "# t\n"})
    assert out["units"] == len(_units(db, aid))
    assert [u["kind"] for u in _units(db, aid) if u["kind"] != "triage"] == ["hunt", "read"]
    read = _unit(db, aid, "read")
    assert read["payload"]["ranges"] == [{"path": "src/a.py", "first": 1, "last": 1, "bytes": 6}]
    assert read["payload"]["guides"][0] == "ATTACK-CLASSES"
    assert "The deep scope is 1 file (1 line, 6 bytes)" in out["coverage_note"]
    assert "prose documents: 1 (e.g. docs/readme.md)" in out["coverage_note"]


def test_a_quick_prepare_plans_a_hunt_and_no_reads(tmp_path):
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline", "--plan")
    assert [u["kind"] for u in _units(db, aid) if u["kind"] != "triage"] == ["hunt"]
    assert "deep scope" not in out["coverage_note"]


def test_a_prepare_without_plan_plans_nothing(tmp_path):
    """ONLY A PIPELINE ANALYSIS PLANS. The orchestrator's prepare passes
    --plan; a hand run, the selftest's own fixtures and every test that
    prepares an analysis to exercise something else get the deterministic
    phase and no unit, exactly as before the pipeline -- so none of them can
    meet a planning failure it was not written about."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})
    out = run(db, "prepare", "--analysis", str(aid), "--root", str(root), "--offline")
    assert (out["units"], _units(db, aid)) == (0, [])
    assert "The deep scope is 1 file" in out["coverage_note"], "the scope is still listed"


def test_a_plan_that_fails_fails_prepare_loudly_and_leaves_no_unit(tmp_path, monkeypatch, capsys):
    """A planning failure is never reported as success: non-zero, the reason
    on stderr, no JSON, and no half of a plan -- ledger.add_units writes all
    of it or none. The phases' results stay: they are this analysis's, and
    the orchestrator closes it `capped` rather than paying for them twice.
    In-process, the way this suite's other prepare failures are, because a
    subprocess cannot be monkeypatched."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="deep")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})

    def broken(*_a, **_k):
        raise RuntimeError("the checklist could not be read")
    monkeypatch.setattr(security_units, "triage_items", broken)
    with pytest.raises(SystemExit) as refused:
        security_cli.main(["prepare", "--analysis", str(aid), "--root", str(root), "--offline",
                           "--plan", "--db", str(db)])
    assert refused.value.code not in (0, None)
    assert "could not be planned" in str(refused.value.code)
    assert "RuntimeError" in str(refused.value.code)
    assert capsys.readouterr().out == "", "no JSON: a failed plan is not an analysis ready to run"
    assert _units(db, aid) == []
    assert run(db, "analysis", "--id", str(aid))["prepared"] == 1


def test_slice_guides_narrows_by_the_slice_s_own_files(tmp_path):
    """Minor 5. Each read unit's guides come from ITS OWN files, not the
    whole repository's -- a slice of `.tsx` files calls for CLIENT-SIDE and
    a slice of plain files does not, using the real `guides.signals` /
    `guides.select` this analysis's own recommendation reads (guides.py)."""
    root = tmp_path / "repo"
    (root / "web").mkdir(parents=True)
    (root / "docs").mkdir()
    (root / "web" / "a.tsx").write_text("const x = 1;\n")
    (root / "docs" / "notes.md").write_text("# t\n")
    pick = security_cli._slice_guides(str(root), [], [])
    assert pick is not None
    assert pick([{"path": "web/a.tsx"}]) == ["ATTACK-CLASSES", "CLIENT-SIDE"]
    assert pick([{"path": "docs/notes.md"}]) == ["ATTACK-CLASSES"]


def test_slice_guides_falls_back_to_attack_classes_and_says_why_on_stderr(tmp_path, monkeypatch, capsys):
    """Minor 5. `_slice_guides` used to swallow `guides.signals` failing with
    no trace at all."""
    root = tmp_path / "repo"
    root.mkdir()
    def broken_signals(*_a, **_k):
        raise RuntimeError("the tree could not be walked")
    monkeypatch.setattr(security_cli.guides, "signals", broken_signals)
    pick = security_cli._slice_guides(str(root), [], [])
    assert pick is None
    assert "RuntimeError: the tree could not be walked" in capsys.readouterr().err


def test_slice_guides_falls_back_for_one_slice_and_says_why_on_stderr(tmp_path, monkeypatch, capsys):
    """Minor 5's other fallback: one slice's own `guides.select` failing
    must not silence itself either, and must not take down the plan."""
    root = tmp_path / "repo"
    root.mkdir()
    (root / "a.py").write_text("x = 1\n")
    def broken_select(*_a, **_k):
        raise RuntimeError("the guide table could not be read")
    monkeypatch.setattr(security_cli.guides, "select", broken_select)
    pick = security_cli._slice_guides(str(root), [], [])
    assert pick([{"path": "a.py"}]) == ["ATTACK-CLASSES"]
    assert "RuntimeError: the guide table could not be read" in capsys.readouterr().err


def test_the_guides_note_is_inserted_with_the_scope_notes_not_appended_after_them(tmp_path, monkeypatch, capsys):
    """Minor 6. `guides.recommend` fails here on purpose, so `guides_note` is
    not empty and this ordering actually runs -- dormant otherwise, since
    `recommend` almost never fails in practice. Reverting the
    `notes.insert(...)` this row uses back to `notes.append(...)` would put
    this sentence at the very END of the paragraph, after every phase's own
    notes, instead of beside the scope sentences it is filed under."""
    db = tmp_path / "security.db"
    aid = open_analysis(db, profile="quick")
    root = _repo(tmp_path, {"src/a.py": "x = 1\n"})
    def broken_signals(*_a, **_k):
        raise RuntimeError("the tree could not be walked")
    monkeypatch.setattr(security_cli.guides, "signals", broken_signals)
    security_cli.main(["prepare", "--analysis", str(aid), "--root", str(root), "--offline", "--db", str(db)])
    out = json.loads(capsys.readouterr().out)
    phases = json.loads(run(db, "analysis", "--id", str(aid))["coverage"])["phases"]
    scope_note = next(p["note"] for p in phases if p["name"] == "scope")
    assert "hunting-guide selection did not run" in scope_note
    assert out["coverage_note"].startswith(scope_note), (
        "the guides note must be part of the scope row's own contiguous prose")


def test_the_deep_scope_sentence_keeps_the_scope_row_a_substring_of_the_paragraph(tmp_path):
    """The invariant test_every_phases_prose_is_a_substring_of_the_paragraph
    (test_cli.py) pins for a quick prepare, on the deep one: the inventory
    sentence is filed under `scope`, so it has to stand beside the scope's
    other sentences at the head of the paragraph -- appended after the
    secret phase's notes, the scope row stopped being one run of it."""
    db = tmp_path / "security.db"
    aid, _root, out = _deep(db, tmp_path, {"src/a.py": "x = 1\n"})
    phases = json.loads(run(db, "analysis", "--id", str(aid))["coverage"])["phases"]
    notes = {p["name"]: p["note"] for p in phases}
    assert "The deep scope is 1 file" in notes["scope"]
    # The scope row is the paragraph's head, whatever the secret phase has to
    # say -- in this suite's engines-off configuration it says which scanner
    # ran, which is what used to sit between the scope's sentences.
    assert out["coverage_note"].startswith(notes["scope"])
    for name, note in notes.items():
        assert note in out["coverage_note"], f"{name}'s note is not in the paragraph: {note!r}"


def test_unit_prompt_prints_the_minted_prompt(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "x = 1\n"})
    read = _unit(db, aid, "read")
    text = raw(db, "unit-prompt", "--analysis", str(aid), "--unit", str(read["id"]), "--platform", "anthropic")
    assert f"SECURITY ANALYSIS {aid} · unit read 1/1" in text
    assert "src/a.py:1-1" in text


def _prompt(db, aid, uid):
    return raw(db, "unit-prompt", "--analysis", str(aid), "--unit", str(uid), "--platform", "anthropic")


def test_a_triage_prompt_lists_every_location_of_its_row(tmp_path):
    """A re-report REPLACES the stored locations, and the prompt asks for the
    row "exactly as shown": shown by its first location alone, a row of three
    would be narrowed to one."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    ledger.record_finding(conn, aid, {
        "fingerprint": "f" * 64, "category": "dependency", "rule": "CVE-2024-0001", "severity": "high",
        "title": "lib 1.0 is vulnerable", "producer": "trivy",
        "occurrences": [{"file": "api/composer.lock", "line": 0}, {"file": "web/composer.lock", "line": 0},
                        {"file": "cli/composer.lock", "line": 0}]})
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "f" * 64, "kind": "scanner", "category": "dependency"}]})
    text = _prompt(db, aid, uid)
    assert "locations (3): " in text
    for place in ("api/composer.lock", "web/composer.lock", "cli/composer.lock"):
        assert place in text


def test_a_read_prompt_names_a_decision_by_its_category_and_its_state(tmp_path):
    """`queries.decided_sast` entries carry neither `category` nor `state` --
    the real shape, produced here by a real decision on another branch, not a
    row built by hand with the two keys already in it."""
    db = tmp_path / "security.db"
    conn = ledger.connect(db)
    old = ledger.start_analysis(conn, "web", "web", "develop", "c0", "deep", "security-web")
    ledger.record_finding(conn, old, {
        "fingerprint": "d" * 64, "category": "sast", "rule": "open-redirect", "severity": "low",
        "title": "next param", "producer": "agent", "occurrences": [{"file": "src/a.py", "line": 1}]})
    ledger.finish_analysis(conn, old, "done")
    ledger.set_decision(conn, "web", "d" * 64, "accepted", "known and accepted", "operator")
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    text = _prompt(db, aid, _unit(db, aid, "read")["id"])
    assert "d" * 64 + " · sast/open-redirect · accepted · src/a.py:1 — next param" in text


def test_a_read_prompt_carries_what_the_operator_decided_on_this_branch(tmp_path):
    """A row the checklist lists with a decision is not open -- so `known`
    left it out -- and `decided_sast` leaves out whatever the checklist lists:
    a decision on this branch reached the unit from nowhere, and the unit
    minted the weakness again under a second identity."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    ledger.record_finding(conn, aid, {
        "fingerprint": "e" * 64, "category": "sast", "rule": "xss", "severity": "medium",
        "title": "unescaped name", "producer": "agent", "occurrences": [{"file": "src/a.py", "line": 1}]})
    ledger.set_decision(conn, "web", "e" * 64, "false_positive", "escaped by the template", "operator")
    text = _prompt(db, aid, _unit(db, aid, "read")["id"])
    assert "e" * 64 + " · sast/xss · false_positive · src/a.py:1 — unescaped name" in text


def _stream(tmp_path, root, path, first, last):
    events = [
        {"type": "system", "subtype": "init", "cwd": str(root)},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Read",
                                                        "input": {"file_path": str(root / path)}}]},
         "parent_tool_use_id": None},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                                                   "content": "".join(f"{n}\tx\n" for n in range(first, last + 1))}]},
         "parent_tool_use_id": None,
         "tool_use_result": {"type": "text", "file": {"filePath": str(root / path), "startLine": first,
                                                      "numLines": last - first + 1, "totalLines": last}}},
    ]
    stream = tmp_path / f"stream-{path.replace('/', '_')}-{first}.ndjson"
    stream.write_text("".join(json.dumps(e) + "\n" for e in events))
    return stream


def test_unit_close_settles_a_read_the_stream_proves_and_a_second_close_is_a_no_op(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\nc\n"})
    read = _unit(db, aid, "read")
    stream = _stream(tmp_path, root, "src/a.py", 1, 3)
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--stream", str(stream),
              "--root", str(root), "--status", "success", "--spend", "0.75")
    assert out == {"state": "done", "continuation": None}
    unit = _unit(db, aid, "read")
    assert (unit["state"], unit["spend_usd"]) == ("done", 0.75)
    again = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--status", "success")
    assert again == {"state": "done", "continuation": None}
    assert _unit(db, aid, "read")["spend_usd"] == 0.75


def test_unit_close_continues_what_a_read_left(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\nc\nd\n"})
    read = _unit(db, aid, "read")
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]),
              "--stream", str(_stream(tmp_path, root, "src/a.py", 1, 2)), "--root", str(root), "--status", "success")
    assert out["state"] == "incomplete"
    cont = next(u for u in _units(db, aid) if u["id"] == out["continuation"])
    assert (cont["attempt"], cont["payload"]["ranges"]) == (2, [{"path": "src/a.py", "first": 3, "last": 4, "bytes": 0}])


def test_unit_close_after_a_stop_keeps_the_attempt(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--status", "stopped")
    cont = next(u for u in _units(db, aid) if u["id"] == out["continuation"])
    assert cont["attempt"] == 1


def test_unit_close_refuses_a_unit_of_another_analysis(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    other = open_analysis(db, profile="deep", commit="def", run_id="r2")
    hunt = _unit(db, aid, "hunt")
    out = fails(db, "unit-close", "--analysis", str(other), "--unit", str(hunt["id"]), "--status", "success")
    assert out.returncode != 0 and "is not a unit of analysis" in out.stderr
    assert _unit(db, aid, "hunt")["state"] == "pending"


def test_unit_close_status_is_one_of_the_engine_s_own_run_statuses(tmp_path):
    """Minor 8. `--status` chokes on anything `run_classify` (bin/agentloop)
    could never actually produce, argparse's own door rather than a value
    reaching `units.judge` unnoticed."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    hunt = _unit(db, aid, "hunt")
    out = fails(db, "unit-close", "--analysis", str(aid), "--unit", str(hunt["id"]), "--status", "bogus")
    assert out.returncode != 0 and "invalid choice" in out.stderr


def _reader_env(aid, uid, root):
    return {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
            "AL_SECURITY_UNIT_ID": str(uid), "AL_RUN_CWD": str(root)}


def test_security_read_serves_numbered_chunks_and_records_them(tmp_path):
    db = tmp_path / "security.db"
    body = "".join(f"line {n}\n" for n in range(1, 251))
    aid, root, _ = _deep(db, tmp_path, {"src/big.py": body})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/big.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    assert lines[0] == "== src/big.py lines 1-200 of 250 =="
    # Minor 3: the second line, ahead of the numbered body, says this call
    # must be run alone.
    assert lines[1].startswith("-- run this command alone")
    assert lines[2] == "1\tline 1"
    assert "-- next: agentloop security read --path src/big.py --from 201" in out.stdout
    nxt = subprocess.run([sys.executable, str(CLI), "read", "--path", str(root / "src/big.py"), "--from", "201",
                          "--db", str(db)], capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert "-- end of file" in nxt.stdout
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [("src/big.py", 1, 200), ("src/big.py", 201, 250)]


def test_security_read_stops_at_the_byte_budget(tmp_path):
    db = tmp_path / "security.db"
    body = "".join("y" * 199 + "\n" for _ in range(100))   # 200 bytes a line
    aid, root, _ = _deep(db, tmp_path, {"src/wide.py": body})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/wide.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    # The budget is counted in what is actually PRINTED, "N\tTEXT", never the
    # 199-byte text alone (see cmd_read's own docstring): lines 1-9 print
    # with a one-digit number, costing len("N\t") + 199 + 1 = 202 bytes;
    # lines 10 and up print with two digits, costing 203. 9 * 202 + 30 * 203
    # = 1,818 + 6,090 = 7,908 <= 8,000, and adding line 40 (203 more) would
    # reach 8,111 > 8,000 -- so the chunk stops at line 39.
    assert out.stdout.splitlines()[0] == "== src/wide.py lines 1-39 of 100 =="
    # Minor 6: the recorded range must equal what was actually printed.
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [("src/wide.py", 1, 39)]


def test_security_read_counts_multi_byte_characters_by_their_utf8_bytes(tmp_path):
    """A budget counted in `len(text)` -- characters, not bytes -- undercounts
    every 2-byte character by half. 150 of an accented "e" is 150 characters
    but 300 bytes once it is actually printed and encoded, and the printed
    chunk has to fit inside READ_BYTES once encoded, not once counted."""
    db = tmp_path / "security.db"
    body = "".join("é" * 150 + "\n" for _ in range(100))
    aid, root, _ = _deep(db, tmp_path, {"src/multibyte.py": body, "src/a.py": "x = 1\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/multibyte.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    # Minor 6: pinned, not just bounded -- 9 lines at "N\t" + 300 + 1 = 303
    # bytes each (2,727), then 2-digit lines at 304 each: 17 more fit
    # (5,168, total 7,895); the 27th would reach 8,199 > 8,000. Line 1 is the
    # header, line 2 the piping warning (minor 3), so the body starts at 2.
    assert lines[0] == "== src/multibyte.py lines 1-26 of 100 =="
    footer = next(n for n, line in enumerate(lines) if line.startswith("-- next") or line == "-- end of file")
    body_text = "\n".join(lines[2:footer])
    # THE FINAL NEWLINE COUNTS TOO: `print("\n".join(out))` emits one more
    # byte after the body than `"\n".join` alone holds -- the loop's own
    # `cost` charges it per line (`join` gives n-1 interior newlines, print's
    # own terminator is the nth) -- so the tight bound adds it back rather
    # than just checking the joined text alone stays under budget.
    assert len(body_text.encode("utf-8")) + 1 <= security_cli.READ_BYTES
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [("src/multibyte.py", 1, 26)]


def test_security_read_shows_a_line_wider_than_the_budget_but_never_records_it(tmp_path):
    """Only possible under `!defaults` in a real analysis -- the default
    inventory already leaves out any file with a line over 5,000 bytes
    (security/inventory.py's `generated` rule) -- but `read` itself never
    consults the inventory, so the file need only exist on disk for this."""
    db = tmp_path / "security.db"
    body = "z" * 9000 + "\n" + "short\n"
    aid, root, _ = _deep(db, tmp_path, {"src/huge.py": body, "src/a.py": "x = 1\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/huge.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    assert "1\t" + "z" * 9000 in out.stdout
    assert "cannot be proven read here" in out.stdout
    assert "-- next: agentloop security read --path src/huge.py --from 2" in out.stdout
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == []


def test_security_read_refuses_outside_a_unit_and_outside_the_run(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    no_unit = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                             capture_output=True, text=True,
                             env={k: v for k, v in _reader_env(aid, read["id"], root).items()
                                  if k != "AL_SECURITY_UNIT_ID"})
    assert no_unit.returncode != 0 and "only a unit of an analysis" in no_unit.stderr
    outside = subprocess.run([sys.executable, str(CLI), "read", "--path", "/etc/hosts", "--db", str(db)],
                             capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert outside.returncode != 0 and "outside this run" in outside.stderr


def test_security_read_prints_multibyte_output_even_under_a_narrow_locale(tmp_path):
    """Minor 4. The count is UTF-8; `print` alone uses the process's own
    locale encoding, which `PYTHONIOENCODING=ascii` narrows to ascii here --
    and would raise on the very bytes just counted without
    `sys.stdout.reconfigure`."""
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "café\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    env = {**_reader_env(aid, read["id"], root), "PYTHONIOENCODING": "ascii"}
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                         capture_output=True, text=True, env=env)
    assert out.returncode == 0, out.stderr
    assert "café" in out.stdout
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [("src/a.py", 1, 1)]


def test_security_read_refuses_with_no_run_cwd_rather_than_a_silent_getcwd(tmp_path):
    """Minor 2. `AL_RUN_CWD` missing used to fall back to `os.getcwd()`
    silently -- a unit's shell that ran `cd src` first would then serve
    `a.py` and record it as `src/a.py`, one directory short of where it
    actually is."""
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    env = {k: v for k, v in _reader_env(aid, read["id"], root).items() if k != "AL_RUN_CWD"}
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                         capture_output=True, text=True, env=env)
    assert out.returncode != 0 and "AL_RUN_CWD" in out.stderr


def test_security_read_refuses_a_unit_that_is_not_running(tmp_path):
    """Minor 1. A plan leaves every unit `pending` until the engine starts
    it, and a settled unit is done being read from either -- serving either
    would let a `reset_unit` after a dead run go on inheriting lines served
    to the run that actually died."""
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    pending = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                             capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert pending.returncode != 0 and "is not running" in pending.stderr
    conn = ledger.connect(db)
    ledger.start_unit(conn, read["id"])
    ledger.settle_unit(conn, read["id"], "done", 0, {})
    done = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                          capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert done.returncode != 0 and "is not running" in done.stderr


def test_security_read_quotes_a_path_with_a_space_and_the_footer_command_serves_the_next_chunk(tmp_path):
    """I1. The footer names the exact next command, quoted the way a shell
    that runs it back would need -- proven by actually running it, split
    the way a shell would split it, rather than trusting the string alone."""
    db = tmp_path / "security.db"
    name = "src/my file.py"
    body = "".join(f"line {n}\n" for n in range(1, 251))
    aid, root, _ = _deep(db, tmp_path, {name: body})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", name, "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    footer = next(line for line in out.stdout.splitlines() if line.startswith("-- next:"))
    assert footer == f"-- next: agentloop security read --path {shlex.quote(name)} --from 201"
    words = shlex.split(footer[len("-- next: "):])
    flags = words[3:]   # drop "agentloop", "security", "read" -- this suite's CLI is bin/security/cli.py
    nxt = subprocess.run([sys.executable, str(CLI), "read", *flags, "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert nxt.returncode == 0, nxt.stderr
    assert "-- end of file" in nxt.stdout


def test_security_read_quotes_a_path_with_shell_metacharacters_in_the_next_command(tmp_path):
    db = tmp_path / "security.db"
    name = "src/$(echo pwned).py"
    body = "".join(f"line {n}\n" for n in range(1, 251))
    aid, root, _ = _deep(db, tmp_path, {name: body})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", name, "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode == 0, out.stderr
    # shlex.quote wraps the whole name in single quotes, under which a POSIX
    # shell expands nothing -- not `$( )`, not a backtick.
    assert f"-- next: agentloop security read --path {shlex.quote(name)} --from 201" in out.stdout


def test_security_read_refuses_a_path_with_a_control_character(tmp_path):
    """I1. A name that cannot be shown on a line of its own is refused
    outright: printing it raw could forge a fake `-- next:` or `-- end of
    file` line, or a header for a chunk never actually printed."""
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "x = 1\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a\nb.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode != 0
    assert out.stdout == "", "nothing is printed from the file"
    assert "cannot show" in out.stderr
    conn = ledger.connect(db)
    assert ledger.unit_reads(conn, read["id"]) == [], "nothing is recorded"


def test_security_read_refuses_a_dot_dot_path(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    (root.parent / "outside.py").write_text("z\n")
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "../outside.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode != 0 and "outside this run" in out.stderr


def test_security_read_refuses_an_inside_symlink_pointing_outside(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    outside = root.parent / "secret.py"
    outside.write_text("z\n")
    (root / "src" / "escape.py").symlink_to(outside)
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/escape.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode != 0 and "outside this run" in out.stderr


def test_security_read_refuses_a_closed_analysis(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    run(db, "finish", "--analysis", str(aid), "--state", "capped", "--spend", "0")
    out = subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                         capture_output=True, text=True, env=_reader_env(aid, read["id"], root))
    assert out.returncode != 0 and "closed" in out.stderr


def test_what_security_read_served_counts_at_the_close(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\nb\n"})
    read = _unit(db, aid, "read")
    _start(db, read["id"])
    subprocess.run([sys.executable, str(CLI), "read", "--path", "src/a.py", "--db", str(db)],
                   capture_output=True, text=True, env=_reader_env(aid, read["id"], root), check=True)
    out = run(db, "unit-close", "--analysis", str(aid), "--unit", str(read["id"]), "--root", str(root),
              "--status", "success")
    assert out["state"] == "done"


def test_report_gone_is_accepted_only_for_a_carried_sast_row_of_the_session_s_triage_unit(tmp_path):
    db = tmp_path / "security.db"
    aid, root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"},
        {"fingerprint": "d" * 64, "kind": "carried", "category": "dependency"}]})
    ledger.start_unit(conn, uid)
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(uid)}
    ok = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                         "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                        text=True, input=json.dumps({"reason": "the handler was deleted in this commit"}))
    assert ok.returncode == 0, ok.stderr
    assert ledger.gone_in(conn, aid) == {"c" * 64}
    for fp, reason in (("d" * 64, "r"), ("c" * 64, "")):
        bad = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                              "--fingerprint", fp, "--db", str(db)], env=env, capture_output=True,
                             text=True, input=json.dumps({"reason": reason}))
        assert bad.returncode != 0


def test_report_gone_refuses_a_unit_that_is_not_running(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}]})
    # never started: still pending
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(uid)}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                          "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": "the handler was deleted"}))
    assert out.returncode != 0 and "is not a carried sast finding" in out.stderr


def test_report_gone_refuses_a_unit_that_is_not_a_triage_unit(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    hunt = _unit(db, aid, "hunt")
    conn = ledger.connect(db)
    ledger.start_unit(conn, hunt["id"])
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(hunt["id"])}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                          "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": "r"}))
    assert out.returncode != 0 and "is not a carried sast finding" in out.stderr


def test_report_gone_refuses_a_unit_of_another_analysis(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    other = open_analysis(db, profile="deep", commit="def", run_id="r2")
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}]})
    ledger.start_unit(conn, uid)
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(other),
           "AL_SECURITY_UNIT_ID": str(uid)}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(other),
                          "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": "r"}))
    assert out.returncode != 0 and "is not a carried sast finding" in out.stderr


def test_report_gone_refuses_a_scanner_item_even_of_category_sast(tmp_path):
    """A `carried` sast row a triage unit read and found gone is one thing;
    a `scanner` row of THIS analysis at that same category is a different
    debt (re-report it, or leave it triaged) that `report-gone` never
    settles, whatever its category."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "s" * 64, "kind": "scanner", "category": "sast"}]})
    ledger.start_unit(conn, uid)
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(uid)}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                          "--fingerprint", "s" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": "r"}))
    assert out.returncode != 0 and "is not a carried sast finding" in out.stderr


def test_report_gone_refuses_with_no_unit_id_naming_that_not_the_fingerprint(tmp_path):
    """Minor 8. With no AL_SECURITY_UNIT_ID there is no session to check a
    carried row against -- the message must say that, not accuse the
    fingerprint of being wrong."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid)}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                          "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": "r"}))
    assert out.returncode != 0
    assert "AL_SECURITY_UNIT_ID is not set" in out.stderr
    assert "is not a carried sast finding" not in out.stderr


@pytest.mark.parametrize("bad_reason", [5, ["x"], None, {}])
def test_report_gone_refuses_a_non_string_reason_with_the_reason_message_not_a_crash(tmp_path, bad_reason):
    """Minor 8. `(payload.get("reason") or "").strip()` raised AttributeError
    on a non-string, truthy `reason` (5, ["x"]) -- refused the same way an
    empty one is, never a crash."""
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n"})
    conn = ledger.connect(db)
    uid = ledger.add_unit(conn, aid, "triage", {"items": [
        {"fingerprint": "c" * 64, "kind": "carried", "category": "sast"}]})
    ledger.start_unit(conn, uid)
    env = {**os.environ, "AL_SECURITY_AGENT": "1", "AL_SECURITY_ANALYSIS_ID": str(aid),
           "AL_SECURITY_UNIT_ID": str(uid)}
    out = subprocess.run([sys.executable, str(CLI), "report-gone", "--analysis", str(aid),
                          "--fingerprint", "c" * 64, "--db", str(db)], env=env, capture_output=True,
                         text=True, input=json.dumps({"reason": bad_reason}))
    assert out.returncode != 0
    assert "a reason is required" in out.stderr


def test_units_prints_the_progress_and_a_unit_s_label(tmp_path):
    db = tmp_path / "security.db"
    aid, _root, _ = _deep(db, tmp_path, {"src/a.py": "a\n", "src/b.py": "b\n"})
    summary = run(db, "units", "--analysis", str(aid))
    assert summary["kinds"]["read"] == {"total": 1, "done": 0, "running": 0, "pending": 1, "failed": 0}
    assert summary["deep"] == {"files": 2, "files_read": 0, "lines": 2, "lines_read": 0}
    hunt = _unit(db, aid, "hunt")
    assert raw(db, "units", "--analysis", str(aid), "--label", str(hunt["id"])).strip() == "hunt 1/1"
