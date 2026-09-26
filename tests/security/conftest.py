"""Loads bin/security as a package. bin/ has no __init__ chain of its own."""
import os
import sys
from pathlib import Path

# Modify sys.path at module load time, BEFORE conftest is fully initialized
REPO = Path(__file__).resolve().parent.parent.parent
bin_path = str(REPO / "bin")
if bin_path not in sys.path:
    sys.path.insert(0, bin_path)

# WHICH SECRET SCANNER THESE TESTS EXERCISE, DECIDED HERE AND NOT BY THE
# MACHINE. `prepare` prefers gitleaks whenever it is installed, so without
# this line the same test suite tests two different products depending on
# whether somebody has run `brew install gitleaks` -- and the tests that plant
# a credential and assert what came back would pass on one laptop and fail on
# the next. They are tests OF the built-in scanner reached through the CLI, so
# they are pinned to it.
#
# `setdefault`, not an assignment: `AL_SECURITY_ENGINES=on pytest` runs the
# same suite against the engines, which is how the difference between the two
# is inspected rather than guessed at. The engine path has its own tests in
# test_adapters.py, which switch it on explicitly.
os.environ.setdefault("AL_SECURITY_ENGINES", "off")


import contextlib
import io

import pytest


@pytest.fixture
def cli_inproc(monkeypatch):
    """`bin/security/cli.py` run through its own `main()` in THIS process.

    For SETUP, never for the verb a test is about: the process boundary is
    the contract test_cli.py drives (an exit code and a line of JSON), and a
    test asserting on that keeps the subprocess. What this is for is the
    scaffolding around it -- the dozens of `report-finding` calls a test
    needs before it can ask its one question. Each of those used to be a
    python start-up of its own, and two tests spent ~25 s of a run doing
    nothing else. Same verb, same argument parsing, same ledger writes; only
    the interpreter is shared. Returns stdout, like the subprocess helpers.
    """
    from security import cli

    def run(db, *args, stdin=""):
        out = io.StringIO()
        with monkeypatch.context() as m:
            m.setattr("sys.stdin", io.StringIO(stdin))
            with contextlib.redirect_stdout(out):
                cli.main([*args, "--db", str(db)])
        return out.getvalue()
    return run
