"""/api/models per platform, and the one vocabulary the server mirrors from
the engine.

The page will read platforms, models, efforts and permission modes from this
endpoint (plan B2); until then the old top-level keys (`models`, `efforts`)
stay exactly as they were, so the page that exists today keeps working. The
permission vocabulary lives in the engine (platform_permissions) and the
server repeats it with labels: `test_the_permission_vocabulary_matches_the_engine`
is what keeps the two from drifting, the way the backoff curve test does.
"""
import json
import os
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE = REPO / "bin" / "agentloop"
FAKE_CODEX = REPO / "test" / "fake-codex"
FIX = REPO / "test" / "fixtures" / "codex"


def _catalog_block():
    cat = json.loads((FIX / "models-catalog.stripped.json").read_text())["models"]
    return {"at": 1788616000, "source": "fixture", "models": [
        {"slug": m["slug"], "display_name": m["display_name"], "description": m["description"],
         "default_effort": m["default_reasoning_level"],
         "efforts": [l["effort"] for l in m["supported_reasoning_levels"]],
         "visibility": m["visibility"], "priority": m["priority"],
         "deprecated_by": (m.get("upgrade") or {}).get("model") or "",
         "retires_at": (m.get("upgrade") or {}).get("retirement_at") or ""}
        for m in cat]}


def _write_models(srv, openai=None, resolved=None):
    data = {"resolved": resolved or {"opus": {"id": "claude-opus-5", "at": 1788585387}}}
    if openai is not None:
        data["openai"] = openai
    (srv.CONFIG_DIR / "models.json").write_text(json.dumps(data))


def _run_platforms(tmp_path, seed_catalog=False):
    """Run `agentloop platforms` the way a real install would -- except the
    CLI is the fake and every path is a scratch dir under tmp_path, so this
    NEVER reaches the real ~/.codex or runs the real codex (platform_ready
    openai shells out to `codex login status`, which the fixture answers)."""
    config_dir, data_dir, codex_home = (tmp_path / "config"), (tmp_path / "data"), (tmp_path / "codex-home")
    for d in (config_dir, data_dir, codex_home):
        d.mkdir(parents=True, exist_ok=True)
    if seed_catalog:
        (config_dir / "models.json").write_text(json.dumps({"resolved": {}, "openai": _catalog_block()}))
    env = dict(os.environ, AGENTLOOP_CODEX_BIN=str(FAKE_CODEX), CODEX_HOME=str(codex_home),
               AGENTLOOP_CONFIG=str(config_dir), AGENTLOOP_DATA=str(data_dir))
    out = subprocess.run(["/bin/bash", str(ENGINE), "platforms"],
                         capture_output=True, text=True, env=env, check=True).stdout
    return json.loads(out)


def test_the_old_keys_are_still_there_for_the_current_page(srv):
    _write_models(srv, openai=_catalog_block())
    out = srv.list_models()
    assert "claude-opus-5" in out["models"]
    assert out["efforts"] == ["low", "medium", "high", "xhigh", "max"]


def test_the_old_models_key_lists_anthropic_models_only(srv, tmp_path, monkeypatch):
    """The dashboard that exists today drives its model selector off the old
    `models` key, and every job it edits is an Anthropic one. A Codex slug
    reaching that list -- from the example OpenAI job a fresh install seeds
    into jobs.json, or from a single OpenAI run already in the history -- is a
    value the page will happily offer and `set-field model` then refuses (500).
    So `models` carries what `platform_model_ok anthropic` accepts, nothing
    else, and `platforms.anthropic.models` stays the same list.
    """
    monkeypatch.setattr(srv, "JOBS_FILE", tmp_path / "jobs.json")
    monkeypatch.setattr(srv, "DB_FILE", tmp_path / "index.db")
    # No CLI to scan, so every id below has one traceable source.
    monkeypatch.setenv("AGENTLOOP_CLAUDE_BIN", str(tmp_path / "no-claude"))
    _write_models(srv, openai=_catalog_block(),
                  resolved={"sonnet": {"id": "claude-sonnet-9", "at": 1788585387}})
    srv.JOBS_FILE.write_text(json.dumps({"jobs": [
        {"id": "a", "model": "claude-opus-5"},
        {"id": "o", "platform": "openai", "model": "gpt-5.6-luna"}]}))
    conn = srv.db_conn()
    srv.db_init(conn)
    conn.execute("INSERT INTO runs (key, job, model_id, platform)"
                 " VALUES ('o|1|x.json', 'o', 'gpt-5.6-sol', 'openai')")
    conn.commit()
    conn.close()

    out = srv.list_models()
    assert "claude-opus-5" in out["models"]          # the anthropic job's own model
    assert "claude-sonnet-9" in out["models"]        # what the family resolved to
    assert [m for m in out["models"] if m.startswith("gpt-")] == []
    assert out["platforms"]["anthropic"]["models"] == out["models"]
    # and the slugs are still offered where they belong
    assert "gpt-5.6-luna" in [m["v"] for m in out["platforms"]["openai"]["models"]]


def test_platforms_carry_the_catalog_visible_models_in_priority_order(srv):
    _write_models(srv, openai=_catalog_block())
    (srv.CONFIG_DIR / "pricing.json").write_text(
        json.dumps({"openai": {"gpt-5.6-sol": {"input": 4, "cached_input": 0.4, "output": 20}}}))
    p = srv.list_models()["platforms"]
    assert set(p) == {"anthropic", "openai"}
    a, o = p["anthropic"], p["openai"]
    assert a["available"] is True and a["default_model"] == "opus"
    assert a["models"] == srv.list_models()["models"]
    assert [m["v"] for m in a["permissions"]] == \
        ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    assert o["available"] is True and o["catalog_at"] == 1788616000
    slugs = [m["v"] for m in o["models"]]
    assert slugs == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4-mini"]
    assert "gpt-reserve" not in slugs                        # hidden stays hidden
    sol = o["models"][0]
    assert sol["label"] == "GPT-5.6-Sol" and sol["efforts"][-1] == "ultra"
    assert sol["default_effort"] == "low" and sol["priced"] is True
    mini = o["models"][-1]
    assert mini["deprecated_by"] == "gpt-5.6-luna" and mini["retires_at"].startswith("2026-08-31")
    assert mini["priced"] is False                          # no pricing.json row
    assert o["efforts"] == ["low", "medium", "high", "xhigh", "max", "ultra"]
    assert [m["v"] for m in o["permissions"]] == ["read-only", "workspace-write", "full-access"]
    assert o["default_model"] == "gpt-5.6-sol"


def test_an_unavailable_catalog_says_why(srv):
    _write_models(srv, openai={"at": 1, "available": False, "reason": "codex not installed"})
    o = srv.list_models()["platforms"]["openai"]
    assert o["available"] is False and o["reason"] == "codex not installed"
    assert o["models"] == [] and o["default_model"] == ""


def test_a_missing_block_is_resolved_once_when_codex_exists(srv, monkeypatch):
    _write_models(srv, openai=None)
    calls = []

    def fake_al(args, stdin=None, background=False):
        calls.append(args)
        _write_models(srv, openai=_catalog_block())
        return True, "ok"
    monkeypatch.setattr(srv, "al", fake_al)
    monkeypatch.setattr(srv.shutil, "which", lambda name: "/opt/homebrew/bin/codex")
    o = srv.list_models()["platforms"]["openai"]
    assert calls == [["resolve-models", "openai"]]
    assert o["available"] is True


def test_a_missing_block_without_codex_is_reported_not_resolved(srv, monkeypatch):
    _write_models(srv, openai=None)
    monkeypatch.setattr(srv, "al", lambda *a, **k: (_ for _ in ()).throw(AssertionError("al called")))
    monkeypatch.setattr(srv.shutil, "which", lambda name: None)
    # _openai_platform's last-resort discovery checks this exact path too
    # (launchd gives a job a minimal PATH, so shutil.which("codex") alone
    # misses a real install); a dev machine that actually has Codex there
    # must not make "no codex" a host-dependent result.
    monkeypatch.setattr(srv.os.path, "exists", lambda p: False)
    monkeypatch.delenv("AGENTLOOP_CODEX_BIN", raising=False)
    o = srv.list_models()["platforms"]["openai"]
    assert o["available"] is False and "codex" in o["reason"]


def test_the_permission_vocabulary_matches_the_engine(srv, tmp_path):
    engine = _run_platforms(tmp_path)
    for platform, modes in srv.PLATFORM_PERMISSIONS.items():
        assert [m["v"] for m in modes] == engine[platform]["permissions"], platform
    assert engine["anthropic"]["efforts"] == ["low", "medium", "high", "xhigh", "max"]
    assert engine["openai"]["efforts"] == []                  # no catalog resolved in this scratch config


def test_the_engines_openai_efforts_are_the_visible_catalogs_union(tmp_path):
    # Same rule cmd_platforms and the server's _openai_platform both apply:
    # the union of the VISIBLE models' efforts, not the fixed six levels a
    # bare `openai_catalog_efforts ""` used to fall back to regardless of
    # whether a catalog was even resolved.
    engine = _run_platforms(tmp_path, seed_catalog=True)
    assert engine["openai"]["efforts"] == ["low", "medium", "high", "xhigh", "max", "ultra"]


def test_the_server_lets_platform_through_set_field():
    src = (REPO / "bin" / "agentloop-server").read_text()
    allow = src[src.index('elif op == "set_field"'):][:900]
    assert '"platform"' in allow


def test_the_openai_platform_carries_its_prices_and_their_freshness(srv):
    _write_models(srv, openai=_catalog_block())
    (srv.CONFIG_DIR / "pricing.json").write_text(json.dumps({
        "_source_url": "file:///fixture", "_refreshed_at": 1788800000,
        "openai": {
            "gpt-5.6-sol": {"input": 4, "cached_input": 0.4, "output": 20, "cache_write": 5,
                            "source": "litellm", "at": 1788800000},
            "gpt-5.5": {"input": 9, "cached_input": 9, "output": 9, "cache_write": 0, "source": "manual"}}}))
    o = srv.list_models()["platforms"]["openai"]
    assert o["pricing_at"] == 1788800000 and o["pricing_source"] == "file:///fixture"
    by = {m["v"]: m for m in o["models"]}
    assert by["gpt-5.6-sol"]["priced"] is True
    assert by["gpt-5.6-sol"]["price"] == {"input": 4, "cached_input": 0.4, "output": 20,
                                          "cache_write": 5, "source": "litellm", "at": 1788800000}
    assert by["gpt-5.5"]["price"]["source"] == "manual" and by["gpt-5.5"]["price"]["at"] is None
    assert by["gpt-5.6-luna"]["priced"] is False and by["gpt-5.6-luna"]["price"] is None
    assert o["unpriced"] == ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4-mini"]


def test_without_a_price_table_the_platform_says_so(srv):
    _write_models(srv, openai=_catalog_block())
    p = srv.CONFIG_DIR / "pricing.json"
    if p.exists():
        p.unlink()
    o = srv.list_models()["platforms"]["openai"]
    assert o["pricing_at"] == 0 and o["pricing_source"] == ""
    assert o["unpriced"] == [m["v"] for m in o["models"]]
    assert all(m["price"] is None for m in o["models"])
