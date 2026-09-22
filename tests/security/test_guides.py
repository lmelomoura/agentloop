# tests/security/test_guides.py
"""Which hunting guides `prepare` recommends: a table of signals, a rank, a
profile ceiling -- and never a failure of the deterministic phase."""
import re
from pathlib import Path

from security import guides

REPO = Path(__file__).resolve().parent.parent.parent
REFERENCES = REPO / "skills" / "security-analysis" / "references"


def _tree(tmp_path, *files):
    root = tmp_path / "repo"
    root.mkdir(exist_ok=True)
    for rel in files:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x\n")
    return root


def _components(*names):
    return [{"ecosystem": "npm", "name": n, "version": "1.0.0", "source": "package-lock.json",
             "scope": "runtime"} for n in names]


def test_every_guide_the_table_names_is_vendored_and_upstream_is_pinned():
    for name in guides.NAMES:
        assert (REFERENCES / f"{name}.md").is_file(), name
    upstream = (REFERENCES / "UPSTREAM.md").read_text()
    assert re.search(r"at commit `[0-9a-f]{40}`", upstream)
    assert "MIT" in upstream
    vendored = {p.stem for p in REFERENCES.glob("*.md")} - {"UPSTREAM"}
    assert vendored == set(guides.NAMES)


def test_attack_classes_is_always_recommended_even_on_an_empty_tree(tmp_path):
    root = _tree(tmp_path)
    for profile in ("quick", "standard"):
        assert guides.select(guides.signals(root, [], []), profile) == [guides.ALWAYS]
    assert guides.select(guides.signals(root, [], []), "deep") == list(guides.NAMES)


def test_signals_are_read_off_dependencies_and_paths(tmp_path):
    root = _tree(tmp_path, "src/App.jsx", "CLAUDE.md", ".github/workflows/ci.yml",
                 "Dockerfile", "db/migrate/001.rb")
    sig = guides.signals(root, [], _components("express", "@anthropic-ai/sdk", "pg"))
    chosen = guides.select(sig, "standard")
    assert chosen[0] == guides.ALWAYS
    assert set(chosen) == {"ATTACK-CLASSES", "WEB-PROTOCOL-AND-AUTH", "CLIENT-SIDE",
                           "CLOUD-AND-DEPLOYMENT", "SUPPLY-CHAIN-AND-RELEASE", "AI-AND-LLM",
                           "DATA-ISOLATION-AND-LIFECYCLE", "RESOURCE-EXHAUSTION-AND-AVAILABILITY"}


def test_quick_reads_attack_classes_and_the_single_best_match(tmp_path):
    root = _tree(tmp_path, "CLAUDE.md", "AGENTS.md", ".claude/settings.json", "skills/x/SKILL.md")
    sig = guides.signals(root, [], _components("express"))
    assert guides.select(sig, "quick") == ["ATTACK-CLASSES", "AI-AND-LLM"]


def test_ties_break_by_table_order_and_prefix_names_match(tmp_path):
    root = _tree(tmp_path)
    sig = guides.signals(root, [], _components("langchain-core", "@grpc/grpc-js"))
    assert guides.select(sig, "quick") == ["ATTACK-CLASSES", "AI-AND-LLM"]
    assert "PROTOCOLS-RPC-AND-MESSAGING" in guides.select(sig, "standard")
    assert "RESOURCE-EXHAUSTION-AND-AVAILABILITY" in guides.select(sig, "standard")


def test_ignored_paths_give_no_signal(tmp_path):
    root = _tree(tmp_path, ".github/workflows/ci.yml")
    assert "SUPPLY-CHAIN-AND-RELEASE" in guides.select(guides.signals(root, [], []), "standard")
    assert "SUPPLY-CHAIN-AND-RELEASE" not in guides.select(
        guides.signals(root, [".github/**"], []), "standard")


def test_supply_chain_follows_a_non_empty_inventory(tmp_path):
    root = _tree(tmp_path)
    assert "SUPPLY-CHAIN-AND-RELEASE" in guides.select(
        guides.signals(root, [], _components("left-pad")), "standard")


def test_recommend_never_raises(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("disk on fire")
    monkeypatch.setattr(guides, "signals", boom)
    chosen, note = guides.recommend(tmp_path, [], [], "standard")
    assert chosen == [guides.ALWAYS]
    assert "did not run" in note and "disk on fire" in note
    monkeypatch.undo()
    chosen, note = guides.recommend(_tree(tmp_path, "a.rs"), [], [], "standard")
    assert note == "" and "MEMORY-SAFETY-AND-BINARY" in chosen
