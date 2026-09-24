"""A stop from the dashboard tells the engine it came from the dashboard.

The engine records where a stop came from -- in the run's note, its stop
marker and a tick.log line (bin/agentloop `stop_origin`), and test/e2e.test.sh
scenario 53 drives both origins through a real run. What is tested here is
the server's half: it is the one caller that can vouch for itself, and it has
to say so on every stop it makes, one run or all of a job's. Every stop used
to be recorded as the operator's, from the dashboard, typed in a terminal or
not -- and on 2026-09-24 one the operator had not made was put down to them.
"""


def test_every_dashboard_stop_says_it_comes_from_the_dashboard(srv, monkeypatch):
    calls = []

    def fake_al(args, stdin=None, background=False, env=None):
        calls.append((args, env))
        return True, "stopping"

    monkeypatch.setattr(srv, "al", fake_al)
    assert srv.stop_run("security-web", "4321") == (True, "stopping")
    srv.stop_run("security-web")
    assert [args for args, _ in calls] == [["stop", "security-web", "4321"],
                                          ["stop", "security-web"]]
    assert all(env == {"AL_STOP_SOURCE": "dashboard"} for _, env in calls)
