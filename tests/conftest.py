"""Test harness for the control server.

The server binds CONFIG_DIR/DATA_DIR at IMPORT time from the environment, and
its import has side effects (it creates the dirs and mints a control token). So
the environment has to point at a scratch tree before the module is ever
imported — hence the session-scoped fixture below and the import inside it,
rather than at the top of a test file.

The server ships as `bin/agentloop-server` with no .py extension (it is an
executable, not a package), so it is loaded by path.
"""

import importlib.util
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SERVER = REPO / "bin" / "agentloop-server"


@pytest.fixture(scope="session")
def srv(tmp_path_factory):
    """The server module, bound to a throwaway config/data tree.

    Two more things every test in the session shares, set before import for
    the same reason CONFIG/DATA are: an empty AGENTLOOP_LAUNCH_AGENTS_DIR, so
    _installed_config_dir (and the engine subprocesses al() launches) never
    read a developer machine's own ~/Library/LaunchAgents -- a test that
    wants a REAL plist points this at one of its own (see
    test_platforms_api.py's default_dir tests); and the three AGENTLOOP_*_BIN
    stand-ins test/e2e.test.sh already uses, so `platform check` and the
    catalog resolves this module and the engine subprocesses it launches both
    run never reach a real claude, codex or opencode."""
    root = tmp_path_factory.mktemp("al")
    (root / "config").mkdir()
    (root / "data").mkdir()
    (root / "launch-agents").mkdir()
    os.environ["AGENTLOOP_CONFIG"] = str(root / "config")
    os.environ["AGENTLOOP_DATA"] = str(root / "data")
    os.environ["AGENTLOOP_LAUNCH_AGENTS_DIR"] = str(root / "launch-agents")
    os.environ["AGENTLOOP_CLAUDE_BIN"] = str(REPO / "test" / "fake-claude")
    os.environ["AGENTLOOP_CODEX_BIN"] = str(REPO / "test" / "fake-codex")
    os.environ["AGENTLOOP_OPENCODE_BIN"] = str(REPO / "test" / "fake-opencode")
    spec = importlib.util.spec_from_loader(
        "al_server", importlib.machinery.SourceFileLoader("al_server", str(SERVER)))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["al_server"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def clean_data(srv):
    """An empty data dir for one test.

    Everything a test can leave behind, not just the journal: run dirs and lock
    slots leak between tests otherwise, and a test that asserts on "what is on
    disk right now" then reads the previous test's fixtures as its own.
    """
    for p in (srv.RUNS_FILE, srv.DB_FILE,
              Path(str(srv.DB_FILE) + "-wal"), Path(str(srv.DB_FILE) + "-shm"),
              srv.DATA_DIR / "tick.log"):
        if p.exists():
            p.unlink()
    for name in ("logs", "worktrees", "locks"):
        d = srv.DATA_DIR / name
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
    return srv
