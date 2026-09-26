# bin/security/orchestrator.py
"""Runs an analysis's units to the end and closes it: the engine's half of the pipeline.

WHY A PROCESS OF ITS OWN, AND WHY IT IS NOT A MODEL. An analysis used to be
one agent deciding when it had done enough; on a large repository it always
decided early. This loop decides instead, from the ledger: it launches every
unit the plan holds (security/units.py), at most `parallel` at a time, each
as an ordinary run of the derived job (`__run-unit` in bin/agentloop); it
lets each run's own close judge the unit and plan what it left undone; it
launches the continuations; it plans verification once everything else has
settled; and it closes the analysis from what the units proved (`finish
--from-units`). Nothing here reads a model's opinion of its own progress.

EVERYTHING IS IN THE LEDGER, so this process can die at any moment and a new
one picks up where it stopped: a unit whose run is still alive is adopted, a
unit whose run died without a close is judged from the stream and the ledger
it left -- exactly as its own close would have judged it (units.close) -- and
a done unit never runs twice.

A RUN THAT DIED IS NOT THE UNIT'S FAILURE. What it proved counts; what it did
not becomes a continuation at the SAME attempt. Three runs of one lineage in a
row that end without a close are the engine saying it cannot run it: the
lineage is given up with that reason, and the close names it. A run that
left NO stream proved nothing at all -- the stream is the only thing that
shows whether the session launched a subagent -- so it is judged as a
disqualified one: nothing it did counts, and a verify unit's own verdict goes
with the attempt.

A UNIT WHOSE RUN STARTED AN AGENT IS NEVER SENT BACK UNDER THE SAME ID. If
its judgement fails, the judgement is retried on a later poll; `reset_unit`
is kept for a launch that failed before any agent ran. Reset and relaunched,
the unit would keep its id while an orphan of the first run could still be
reading under it -- and `unit_reads(since=started)` tells two runs apart only
a wall-clock second apart.

A STOP IS NOT A FAILURE EITHER. SIGTERM (the engine's `stop`, which signals
the pid in the analysis lock) stops launching, has the engine stop the units'
runs -- each closes its unit `stopped`, which continues at the same attempt;
one that dies before its close is judged as above -- and leaves the analysis
`interrupted`, to be resumed.

THE BUDGET IS THE ANALYSIS'S. The spend is the units' sum; nothing is
launched once it reaches `budget`, and each unit is given an even share of
what remains -- on Claude Code the engine turns it into `--max-budget-usd`;
elsewhere it is read at the end, which is why this loop checks the sum
itself before every launch. WHAT REMAINS IS NET OF WHAT IS PROMISED: the cap
handed to every unit still in flight is reserved until that unit settles, so
the caps in flight plus the spend never add up to more than the budget. The
spend alone counts only the units that closed, and a pass that launched P
units off it handed out B, B/2, B/3 ... -- 1.83 times the budget at P=3.
MIN_UNIT_BUDGET is a floor, never a way over the budget: when what remains
is below it, nothing is launched, and once nothing is in flight the close
says why the rest never ran.

THE ENGINE'S OWN GATES STILL HOLD. A unit runs as a forced run of the
derived job, which skips run_job's usage-window, daily and global-cap gates
-- so the orchestrator asks the engine for them (`__unit-gate`) before every
launch, and a closed one stops the launches and leaves the analysis
`interrupted` with a note naming the gate, to be resumed once it reopens. A
run the provider cut short (the classifier's `rate_limited` or `api_error`)
is not the unit's failure either: its close keeps the attempt, and three
such runs in a row of one lineage give it up as the engine not being able to
run it, exactly as three runs that died unclosed do.

A PID IS NOT A RUN. After a reboot, or simply later, the kernel hands a
unit's old pid to some other process, and `kill -0` alone would adopt it and
wait on it for ever. A run is adopted only while its pid still names the
process this orchestrator launched: its start time (recorded in the unit's
`run_key`) and its command line (`__run-unit <job> <analysis> <unit>`).

A FAILURE IS AN INTERRUPTION, NOT A `running` ROW. Anything that raises in
here, or a close (`finish`) that fails twice, leaves the analysis
`interrupted` -- resumable, and offered Resume on the page -- and when even
that cannot be written the lock is kept, so the tick finds its owner dead
and resumes it. A row left `running` behind a released lock is one nothing
would ever look at again.

ITS LIFE IS DATA. The phase it is in goes into its lock (`phase`), and the
page reads it beside the lock's liveness (security_checklist in
bin/agentloop-server): between two units no run is alive, and that is not an
analysis that died.
"""

import calendar
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import ledger, units

# bin/platforms is this repo's other python package, a sibling of security/
# (both live under bin/, on sys.path via cli.py's own insert) -- costing.py
# is the one place a run's cost is ESTIMATED after the fact, from its own
# stream, shared with bin/agentloop's run_job salvage path.
from platforms import costing

MIN_UNIT_BUDGET = 0.50
LAUNCH_STRIKES = 3
# How many polls a unit whose judgement raised is retried on before this
# orchestrator leaves it `running`: the close then names it "never finished",
# and a resume judges it again. Never reset instead (see the docstring).
JUDGE_TRIES = 5
# Overridable only for a test that needs the wait itself to be short -- the
# production default is the number an operator actually needs a unit's agent
# to notice a TERM and close cleanly, never something a test should wait out.
STOP_GRACE_SECONDS = int(os.environ.get("AL_SECURITY_STOP_GRACE_SECONDS") or 300)
# Spends are sums of floats: ten units of 0.10 add up to 0.9999999999999999.
_CENT_EPSILON = 1e-9
CLI = Path(__file__).resolve().parent / "cli.py"
# The engine exports these into a unit's run; the orchestrator must never pass
# them on -- its own CLI calls are the engine's, not an agent's.
_SESSION_VARS = ("AL_SECURITY_AGENT", "CC_SECURITY_AGENT",
                 "AL_SECURITY_UNIT_ID", "CC_SECURITY_UNIT_ID",
                 "AL_SECURITY_UNIT_BUDGET")
PREPARE_FAILED_NOTE = ("The deterministic phase did not complete -- a phase, or the planning "
                       "of the units, failed (see tick.log) -- so no unit ran.")
STRUCK_OUT_NOTE = ("The engine could not run this unit: {n} runs ended without a close "
                   "(see tick.log).")
STRUCK_OUT_OUTAGE_NOTE = ("The engine could not run this unit: {n} runs in a row were cut short "
                          "by the provider ({cause}; see tick.log).")
# The judgement of a dead run that raised: by id, never by label -- the
# label reads the ledger, which may be the very thing failing.
JUDGE_RETRY_LOG = "could not judge unit {uid} ({why}) — trying again"
JUDGE_GAVE_UP_LOG = ("could not judge unit {uid} ({why}) — left running after {tries} tries; "
                     "a resume judges it again")
BUDGET_SPENT_NOTE ="The analysis budget of ${budget:.2f} was spent before every unit ran."
BUDGET_FLOOR_NOTE = ("The analysis budget of ${budget:.2f} had ${left:.2f} left -- less than the "
                     "${floor:.2f} one unit is given -- before every unit ran.")
GATE_NOTE = ("The engine interrupted this analysis because {gate}; the units it finished are "
             "kept, and a resume continues it once the gate reopens.")
FAILED_NOTE = ("The engine interrupted this analysis because its orchestrator failed "
               "({what}); the units it finished are kept, and a resume continues it.")
# The classifier's causes (run_classify in bin/agentloop) for a run the
# PROVIDER ended: the unit's close keeps the attempt for them (units.close),
# and this loop counts them as runs the engine could not run.
OUTAGE_CAUSES = units.OUTAGE_CAUSES
# `__unit-gate`'s answer when one of the engine's gates is closed; the
# sentence naming it is on its stdout.
GATE_CLOSED_RC = 3
# The file beside a prepare's checkout that names the process group running
# it: `prepare` leads a session of its own, and one whose orchestrator was
# SIGKILLed keeps running -- the next `_prepare` of the same analysis ends it
# before cutting the same checkout again. Beside the checkout, not in the
# analysis lock: the tick breaks a dead orchestrator's lock (lock_break)
# before it resumes the analysis, and the file would go with it.
PREPARE_PGID = ".pgid"


def _alive(pid) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _ps(pid, field) -> str:
    """One `ps -o <field>=` of `pid`, or '' when it names no process."""
    try:
        out = subprocess.run(["ps", "-o", f"{field}=", "-p", str(int(pid))],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def _started_at(pid) -> str:
    """The process's start time as `ps` prints it (`lstart`): what tells the
    process a pid named when it was recorded from whatever the kernel has
    handed that number to since -- a reboot, or a wrap."""
    return " ".join(_ps(pid, "lstart").split())


def _run_key(job, pid, started="", cap=None) -> str:
    """`<job>/<pid>`, then `;start=<lstart>` and `;cap=<usd>` when known:
    what a later orchestrator needs to know the run is still the one this
    one launched (`_is_run`) and how much of the budget it holds."""
    key = f"{job}/{pid}"
    if started:
        key += f";start={started}"
    if cap is not None:
        key += f";cap={cap:.2f}"
    return key


def _key_fields(run_key) -> dict:
    head, *rest = (run_key or "").split(";")
    fields = dict(part.split("=", 1) for part in rest if "=" in part)
    tail = head.rsplit("/", 1)[-1]
    fields["pid"] = int(tail) if tail.isdigit() else None
    return fields


def _pid_of(run_key):
    return _key_fields(run_key)["pid"]


def _cap_of(run_key):
    try:
        return float(_key_fields(run_key).get("cap", ""))
    except ValueError:
        return None


def _is_run(pid, job, analysis_id, unit_id, started="") -> bool:
    """Whether `pid` is STILL the run of this unit: alive, started when the
    run_key says it was (when it says), and running `__run-unit <job>
    <analysis> <unit>` -- run_job runs in that very process (security_run_unit
    in bin/agentloop calls it as a function), so the command line holds for
    the run's whole life. A pid that fails any of the three is some other
    process now, and the unit's run is gone."""
    if not pid or not _alive(pid):
        return False
    if started and _started_at(pid) != started:
        return False
    args = f" {_ps(pid, 'args')} "
    return f" __run-unit {job} {analysis_id} {unit_id} " in args


def _parse_budget(value):
    """(budget, refusal). The engine hands the derivation's own value
    (security_analysis_budget in bin/agentloop: the derived job's
    max_budget_usd, whose fallback for a declared value that is not a number
    is SECURITY_FALLBACK_BUDGET_USD), so text float() cannot read is a hand
    run -- refused with a sentence, never a traceback the tick would take for
    a crash and resume three times."""
    text = str(value if value is not None else "").strip()
    if not text:
        return None, ""
    try:
        budget = float(text)
    except ValueError:
        budget = math.nan
    if not math.isfinite(budget):
        return None, f"--budget must be a number of US dollars, not {text!r}"
    return budget, ""


def _stream_root(stream):
    """The run's own root, off its stream's init event (`cwd`, which every
    platform's normalised stream carries): a dead run's reads are made
    relative to it, as the engine's close makes them relative to run_job's
    cwd."""
    try:
        with open(stream, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(event, dict) and event.get("type") == "system"
                        and event.get("subtype") == "init"):
                    return str(event.get("cwd") or "")
    except OSError:
        pass
    return ""


class Orchestrator:
    def __init__(self, db, analysis_id, *, engine, job, commit, repo, repo_path, prepare_root,
                 log_root=None, parallel=3, budget=None, ignore="", log=None, lock_dir=None,
                 poll=2.0, pricing_file=None, offline=False):
        self.db, self.aid = str(db), int(analysis_id)
        self.engine, self.job, self.commit, self.repo = str(engine), job, commit, repo
        self.repo_path, self.prepare_root = str(repo_path), Path(prepare_root)
        self.log_root = Path(log_root) if log_root else None
        # config/pricing.json: a dead run's judgement (_judge_orphan) prices
        # whatever usage its stream carries from this table, same as
        # bin/agentloop's own salvage path -- see bin/platforms/costing.py.
        self.pricing_file = str(pricing_file) if pricing_file else None
        self.parallel = max(1, min(8, int(parallel or 3)))
        self.budget, self.budget_error = _parse_budget(budget)
        self.ignore, self.log_path, self.lock_dir, self.poll = ignore or "", log, lock_dir, poll
        self.offline = bool(offline)     # tests: `prepare --offline`, no network
        self.conn = ledger.connect(self.db)
        self.children = {}        # pid -> (Popen, unit id)
        self.adopted = {}         # pid -> unit id: runs a previous orchestrator left alive
        self.unjudged = {}        # unit id -> [pid, tries]: dead runs whose judgement raised
        self.strikes = {}         # lineage root id -> its runs in a row that died unclosed
        self.reserved = {}        # unit id -> the budget cap its run in flight was handed
        self.stopping = False
        self.budget_spent = False
        self.budget_left = None   # set when the floor, not the spend, stopped the launches
        self.gate = ""            # the engine's gate that closed, in the engine's words
        self.keep_lock = False    # nothing could be written: the tick must find us dead
        self.prepare_proc = None
        self.env = {k: v for k, v in os.environ.items() if k not in _SESSION_VARS}

    # -- small helpers -------------------------------------------------------
    def log(self, message):
        """One tick.log line in log_tick's own format -- `<ISO UTC> <job>:
        <message>` (bin/agentloop) -- because the dashboard reads that file
        by exactly that shape (checks_24h, bin/agentloop-server) and skips a
        line in any other."""
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = f"{stamp} {self.job}: analysis {self.aid} — {message}\n"
        if self.log_path:
            try:
                with open(self.log_path, "a", encoding="utf-8") as out:
                    out.write(line)
                return
            except OSError:
                pass
        sys.stderr.write(line)

    def _on_signal(self, _signum, _frame):
        self.stopping = True
        proc = self.prepare_proc
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)   # `prepare` leads its own group
            except OSError:
                pass

    def _cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), "--db", self.db, *args],
                              env=self.env, capture_output=True, text=True)

    def _row(self):
        return self.conn.execute("SELECT * FROM analysis WHERE id=?", (self.aid,)).fetchone()

    def _git(self, *args):
        return subprocess.run(["git", "-C", self.repo_path, *args], capture_output=True, text=True)

    def _lock_is_mine(self) -> bool:
        if not self.lock_dir:
            return False
        try:
            return Path(self.lock_dir, "pid").read_text().strip() == str(os.getpid())
        except OSError:
            return False

    def _set_phase(self, phase):
        """The phase this orchestrator is in -- preparing, running units,
        finishing, stopping -- written into its lock, where the server reads
        it beside the lock's liveness for the page (security_checklist):
        between two units no slot is alive, and the phase is what says the
        analysis is still in hand. Only into a lock that is still this
        process's own, and atomically, so a reader never sees half a word."""
        if not self._lock_is_mine():
            return
        tmp = Path(self.lock_dir, ".phase.tmp")
        try:
            tmp.write_text(phase + "\n")
            os.replace(tmp, Path(self.lock_dir, "phase"))
        except OSError:
            pass

    def _in_flight(self) -> bool:
        return bool(self.children or self.adopted or self.unjudged)

    def _run_alive(self, unit) -> bool:
        """Whether `unit`'s run, as its run_key names it, is still that run."""
        fields = _key_fields(unit["run_key"])
        return _is_run(fields["pid"], self.job, self.aid, unit["id"], fields.get("start", ""))

    # -- the run ---------------------------------------------------------------
    def run(self) -> int:
        previous = {s: signal.signal(s, self._on_signal)
                    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            if self.budget_error:
                # Before anything else, and inside the `finally` that lets the
                # lock go: nothing started, so nothing is closed either, and a
                # lock left behind would have the tick resume a run that can
                # never start.
                message = f"{self.budget_error}. Nothing was started."
                sys.stderr.write(f"orchestrate: {message}\n")
                self.log(message)
                return 2
            try:
                return self._run()
            except Exception as exc:  # noqa: BLE001 -- see "A FAILURE IS AN INTERRUPTION"
                return self._failed(f"{type(exc).__name__}: {exc}")
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)
            self._sweep()
            self._release()

    def _sweep(self):
        """What the units left that no live run owns, removed as this
        orchestrator exits -- done, capped, interrupted or failed -- and
        while it still holds the analysis lock, so no next analysis is
        launching units meanwhile. A unit tears its own tree down and
        releases its own slot when its run ends, but one killed outright runs
        nothing, and one whose close failed keeps its tree for the judgement
        this orchestrator has made by now. The engine decides what is dead
        (`__unit-sweep`: slot_alive, lock_abandoned, wt_is_claimed -- the
        rules every other walker of the slots applies), never a second copy
        of them here; then `git worktree prune` in the analysed repo, for a
        registration whose directory is already gone. One tick.log line
        when something went. Never raises: a sweep that fails leaves what
        the tick's own TTL sweep removes later."""
        try:
            out = subprocess.run([self.engine, "__unit-sweep", self.job], env=self.env,
                                 capture_output=True, text=True, timeout=300,
                                 stdin=subprocess.DEVNULL)
            said = (out.stdout or "").strip().splitlines()
            if out.returncode != 0:
                self.log(f"could not sweep what its units left (rc {out.returncode}): "
                         f"{(out.stderr or '').strip()[-200:]}")
            elif said:
                self.log(said[-1])
        except (OSError, subprocess.SubprocessError) as exc:
            self.log(f"could not sweep what its units left: {exc}")
        try:
            self._git("worktree", "prune")
        except OSError:
            pass

    def _run(self) -> int:
        row = self._row()
        if row is None or row["state"] != "running":
            self.log(f"is {row['state'] if row else 'missing'}; nothing to run")
            return 0
        if not row["prepared"] and not self._prepare():
            if self.stopping:
                return self._interrupt()
            self._finish(PREPARE_FAILED_NOTE, state="capped")
            return 0
        if not ledger.units_of(self.conn, self.aid) and not self._plan():
            return 0
        self._adopt()
        self._set_phase("running units")
        self._loop()
        if self.stopping:
            return self._interrupt()
        if self.gate:
            return self._interrupt(GATE_NOTE.format(gate=self.gate))
        # THE BUDGET SENTENCE ONLY WHEN IT IS TRUE: units left unsettled. A
        # budget the last unit spent to the cent left nothing unrun, and
        # "spent before every unit ran" would be a false line in the report.
        left = units.unsettled(ledger.units_of(self.conn, self.aid))
        note = ""
        if self.budget_spent and left:
            note = (BUDGET_FLOOR_NOTE.format(budget=self.budget, left=self.budget_left,
                                             floor=MIN_UNIT_BUDGET)
                    if self.budget_left is not None else BUDGET_SPENT_NOTE.format(budget=self.budget))
        self._finish(note)
        return 0

    def _failed(self, what) -> int:
        """Something raised: the analysis is left `interrupted` -- its
        units' runs stopped and judged as a stop would (`_interrupt`) -- and
        if even that raises, with the one UPDATE that makes it resumable, on
        a connection of its own. When nothing can be written at all, the lock
        is kept: the tick finds its owner dead, interrupts the analysis and
        resumes it (security_resume_orphans in bin/agentloop)."""
        self.log(f"failed: {what}")
        note = FAILED_NOTE.format(what=what.split(":", 1)[0])
        try:
            self._interrupt(note)
            return 1
        except Exception as exc:  # noqa: BLE001 -- the last resort follows
            self.log(f"could not stop and interrupt cleanly ({type(exc).__name__}: {exc})")
        try:
            conn = ledger.connect(self.db)
            ledger.interrupt_analysis(conn, self.aid, note)
            state = conn.execute("SELECT state FROM analysis WHERE id=?", (self.aid,)).fetchone()
            if state is not None and state["state"] == "running":
                raise RuntimeError("the analysis is still running")
            self.log("interrupted — `agentloop security resume` continues it")
        except Exception as exc:  # noqa: BLE001
            self.keep_lock = True
            self.log(f"could not interrupt it either ({type(exc).__name__}: {exc}) — the lock "
                     "is kept, so the tick resumes it")
        return 1

    def _prepare(self) -> bool:
        """The deterministic phase, once, in a checkout of the analysed commit
        that is this orchestrator's alone, and with `--plan`: only the
        orchestrator's prepare writes the plan (security/cli.py, cmd_prepare).

        OUTSIDE THE ENGINE'S WORKTREES FOLDER -- <prepare-root>/<job>-<id>,
        $DATA_DIR/security/prepare in production. Every directory under
        $WORKTREES_DIR is a run dir to the engine and the server: the tick's
        orphan sweep adopts it (writing `.ended` into the very checkout being
        analysed) and tears it down once its TTL is up, and the dashboard
        os.walk()s it on every poll. Whatever a prepare that died left at the
        path is cleared before the checkout is cut, and the checkout -- and
        git's record of it -- goes when the phase ends, whatever the outcome.

        A failure here is non-zero from `prepare`: a phase that broke, or a
        plan that could not be written (all or nothing, so there is no half of
        one). Either way the caller closes the analysis `capped`."""
        self._set_phase("preparing")
        tree = self.prepare_root / f"{self.job}-{self.aid}"
        tree.parent.mkdir(parents=True, exist_ok=True)
        pgid_file = tree.parent / f"{tree.name}{PREPARE_PGID}"
        self._end_orphan_prepare(pgid_file)
        self._drop_tree(tree)
        made = self._git("worktree", "add", "--detach", str(tree), self.commit)
        if made.returncode != 0:
            self.log(f"could not cut a worktree at {self.commit[:12]} for the deterministic "
                     f"phase: {made.stderr.strip()}")
            self._drop_tree(tree)
            return False
        try:
            self.log("deterministic phase started")
            # A process group of its own, so a stop reaches whatever the
            # phase launched (the scanners) and not only the CLI.
            self.prepare_proc = subprocess.Popen(
                [sys.executable, str(CLI), "--db", self.db, "prepare", "--analysis", str(self.aid),
                 "--root", str(tree), "--ignore", self.ignore, "--plan",
                 *(["--offline"] if self.offline else [])],
                env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                start_new_session=True)
            try:
                pgid_file.write_text(f"{self.prepare_proc.pid}\n"
                                     f"{_started_at(self.prepare_proc.pid)}\n")
            except OSError:
                pass
            _out, err = self.prepare_proc.communicate()
            code = self.prepare_proc.returncode
        finally:
            self.prepare_proc = None
            pgid_file.unlink(missing_ok=True)
            self._drop_tree(tree)
        if code != 0:
            self.log(f"deterministic phase failed (rc {code}): {(err or '').strip()[-400:]}")
            return False
        self.log("deterministic phase done")
        return True

    def _end_orphan_prepare(self, pgid_file):
        """A prepare an earlier orchestrator of this analysis started and never
        saw end -- it was SIGKILLed, and `prepare` leads a session of its own,
        so it went on running on the very checkout this one is about to cut
        again, writing into the same analysis. Ended, with its whole group,
        before anything else -- but ONLY while the recorded pid is still that
        process: started when the file says it was, and running `prepare
        --analysis <this analysis>`. A pid the kernel has handed to anything
        else since is left alone."""
        try:
            pid_text, started = (pgid_file.read_text().split("\n") + ["", ""])[:2]
        except OSError:
            return
        pgid_file.unlink(missing_ok=True)
        if not pid_text.strip().isdigit():
            return
        pid = int(pid_text)
        args = f" {_ps(pid, 'args')} "
        if (not _alive(pid) or _started_at(pid) != started.strip()
                or f" prepare --analysis {self.aid} " not in args):
            return
        self.log(f"ending the deterministic phase an earlier orchestrator left running (pid {pid})")
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pid, sig)
            except OSError:
                return
            deadline = time.time() + 10
            while time.time() < deadline and _alive(pid) and not _ps(pid, "stat").startswith("Z"):
                time.sleep(0.1)
            if not _alive(pid) or _ps(pid, "stat").startswith("Z"):
                return

    def _drop_tree(self, tree):
        """The prepare checkout gone, and git's record of it with it: `worktree
        remove --force` for a registered one, rmtree for whatever is left (a
        directory a crash left behind unregistered), then `worktree prune`, so
        no registration outlives its directory in the operator's checkout."""
        if tree.exists():
            self._git("worktree", "remove", "--force", str(tree))
            shutil.rmtree(tree, ignore_errors=True)
        self._git("worktree", "prune")

    def _plan(self) -> bool:
        """A prepared analysis with no units: prepared before the pipeline, or
        a resume after a prepare whose plan failed (nothing half-written: the
        plan is all or nothing). Planned here, without the per-slice guides.
        A plan that fails closes the analysis `capped` with the reason, never
        a `done` over units nobody planned."""
        try:
            planned = units.plan(self.conn, self.aid)
        except Exception as exc:  # noqa: BLE001 -- said in tick.log and in the report
            self.log(f"could not plan its units: {type(exc).__name__}: {exc}")
            self._finish(f"The engine could not plan this analysis's units "
                         f"({type(exc).__name__}), so no unit ran.", state="capped")
            return False
        self.log(f"{len(planned)} unit(s) planned")
        return True

    def _adopt(self):
        """Every unit a previous orchestrator left `running`: a run still alive
        is adopted and waited for (its own close settles the unit); one that is
        gone is judged from what it left, as `_after` judges a child of this
        orchestrator that died unclosed."""
        for u in ledger.units_of(self.conn, self.aid):
            if u["state"] != "running":
                continue
            pid = _pid_of(u["run_key"])
            if self._run_alive(u):
                self.adopted[pid] = u["id"]
                # ITS CAP STAYS RESERVED until it settles. A run_key from
                # before caps were recorded holds none: the floor is the
                # least any launched unit was ever handed.
                if self.budget is not None:
                    cap = _cap_of(u["run_key"])
                    self.reserved[u["id"]] = MIN_UNIT_BUDGET if cap is None else cap
            else:
                self._after(u["id"], pid)

    def _loop(self):
        verify_planned = False
        while not self.stopping:
            self._reap()
            everything = ledger.units_of(self.conn, self.aid)
            spend = sum(u["spend_usd"] for u in everything)
            if self.budget is not None and spend >= self.budget - _CENT_EPSILON:
                self.budget_spent = True
            if not verify_planned and not units.unsettled(everything, ("triage", "hunt", "read")):
                planned = units.plan_verification(self.conn, self.aid)
                verify_planned = True
                if planned:
                    self.log(f"{len(planned)} verify unit(s) planned")
                continue
            if not self.budget_spent and not self.gate:
                self._launch_pass(spend)
            # NOTHING IN FLIGHT AND NOTHING TO LAUNCH: done. That includes a
            # triage, hunt or read unit left `running` because its judgement
            # kept failing (JUDGE_TRIES) -- verification is never planned over
            # it, and the close names it "never finished".
            if not self._in_flight():
                waiting = any(u["state"] == "pending" for u in ledger.units_of(self.conn, self.aid))
                if self.budget_spent or self.gate or not waiting:
                    return
            time.sleep(self.poll)

    def _launch_pass(self, spend):
        """Launch what the room allows, each unit with its share of what the
        budget has left NET OF THE CAPS STILL IN FLIGHT (see the module
        docstring), and each only past the engine's own gates."""
        room = self.parallel - len(self.children) - len(self.adopted)
        for n, unit in enumerate(units.launchable(self.conn, self.aid, room)):
            outages, cause = self._outages_before(unit)
            if outages >= LAUNCH_STRIKES:
                # THE PROVIDER CUT SHORT THE LINEAGE'S LAST LAUNCH_STRIKES RUNS
                # IN A ROW: given up, as three runs that died unclosed are.
                # Counted off the ledger at the launch, never off this
                # process's memory: a continuation is pending the moment its
                # parent's close commits, before this loop has even reaped
                # that parent's process -- and a resume must count the same.
                ledger.settle_unit(self.conn, unit["id"], "failed", 0, {},
                                   STRUCK_OUT_OUTAGE_NOTE.format(n=outages, cause=cause))
                self.log(f"unit {units.label(self.conn, unit)} failed: the engine could not run it")
                continue
            cap = None
            if self.budget is not None:
                left = self.budget - spend - sum(self.reserved.values())
                if left < MIN_UNIT_BUDGET - _CENT_EPSILON:
                    # BELOW THE FLOOR: nothing more starts now. With runs
                    # still in flight what they do not spend comes back when
                    # they settle; with none, the budget is what stopped the
                    # analysis, and the close says so.
                    if not self._in_flight():
                        self.budget_spent = True
                        self.budget_left = max(0.0, left)
                    return
                cap = max(MIN_UNIT_BUDGET, left / (room - n))
                # In whole cents, rounded DOWN: a cap printed to the cent
                # must never round the sum of the caps over the budget.
                cap = math.floor(min(cap, left) * 100 + 1e-6) / 100
            gate = self._gate()
            if gate:
                self.gate = gate
                self.log(f"stops launching: {gate}")
                return
            self._launch(unit, cap)

    def _gate(self) -> str:
        """The engine's own gates for a launch of the derived job -- the
        usage window, the job's daily cap, the global daily cap -- asked of
        the engine itself (`__unit-gate`), never computed a second time here.
        '' when they are open. An engine that cannot answer is not a closed
        gate: the launch goes through the same engine, and fails -- and is
        counted -- there."""
        try:
            out = subprocess.run([self.engine, "__unit-gate", self.job], env=self.env,
                                 capture_output=True, text=True, timeout=120,
                                 stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as exc:
            self.log(f"could not ask the engine for its gates: {exc}")
            return ""
        if out.returncode == GATE_CLOSED_RC:
            return out.stdout.strip() or "one of the engine's spend or usage gates is closed"
        if out.returncode != 0:
            self.log(f"could not ask the engine for its gates (rc {out.returncode}): "
                     f"{out.stderr.strip()[-200:]}")
        return ""

    def _launch(self, unit, cap=None):
        env = dict(self.env)
        if cap is not None:
            env["AL_SECURITY_UNIT_BUDGET"] = f"{cap:.2f}"
        # RUNNING BEFORE THE LAUNCH, not after: a verify unit's session writes
        # its verdict through a door that only opens for a running unit, and a
        # fast one would otherwise reach it first.
        if not ledger.start_unit(self.conn, unit["id"], f"{self.job}/launching"):
            return
        try:
            proc = subprocess.Popen([self.engine, "__run-unit", self.job, str(self.aid),
                                     str(unit["id"]), self.commit, self.repo],
                                    env=env, stdin=subprocess.DEVNULL)
        except OSError as exc:
            # THE ONE CASE FOR `reset_unit`: nothing was started, so no agent
            # can have written, read or been served anything under this id.
            # Back to `pending` in the same attempt -- and a strike, because
            # an engine that cannot be started is the engine saying it cannot
            # run the unit.
            ledger.reset_unit(self.conn, unit["id"])
            self.log(f"unit {units.label(self.conn, unit)} could not be launched: {exc}")
            self._strike(ledger.get_unit(self.conn, unit["id"]), unit["id"])
            return
        if cap is not None:
            self.reserved[unit["id"]] = cap
        self.children[proc.pid] = (proc, unit["id"])
        ledger.set_run_key(self.conn, unit["id"],
                           _run_key(self.job, proc.pid, _started_at(proc.pid), cap))
        self.log(f"unit {units.label(self.conn, unit)} launched (pid {proc.pid}"
                 f"{f', budget ${cap:.2f}' if cap is not None else ''})")

    def _reap(self):
        for pid, (proc, uid) in list(self.children.items()):
            if proc.poll() is None:
                continue
            del self.children[pid]
            self._after(uid, pid)
        for pid, uid in list(self.adopted.items()):
            unit = ledger.get_unit(self.conn, uid)
            if unit is not None and self._run_alive(unit):
                continue
            del self.adopted[pid]
            self._after(uid, pid)
        for uid, (pid, _tries) in list(self.unjudged.items()):
            self._after(uid, pid)

    def _after(self, uid, pid):
        unit = ledger.get_unit(self.conn, uid)
        if unit is None or unit["state"] == "pending":
            self.unjudged.pop(uid, None)
            self.reserved.pop(uid, None)
            return
        lineage = units.lineage_root(self.conn, unit)["id"]
        if unit["state"] != "running":
            self.unjudged.pop(uid, None)
            self.reserved.pop(uid, None)
            self.log(f"unit {units.label(self.conn, unit)} {unit['state']} "
                     f"(${unit['spend_usd']:.2f}) — {unit['note']}")
            self.strikes.pop(lineage, None)      # a run closed it: the engine can run it
            return
        # THE RUN ENDED WITHOUT CLOSING ITS UNIT -- killed, crashed, or
        # orphaned by an orchestrator that died. Judged from what it left, as
        # its own close would have judged it (units.close, under `stopped`):
        # what it proved counts, and the rest continues at the SAME attempt,
        # because a run that died is not the unit's failure. Three such
        # endings in a row of one lineage are the engine saying it cannot run
        # it: the continuation is given up with that reason, and the close
        # names it.
        out = self._judge_orphan(unit, pid)
        if out is None:
            return                               # retried on the next poll (_reap)
        self.reserved.pop(uid, None)
        if out.get("continuation"):
            self._strike(unit, out["continuation"])
        else:
            self.log(f"unit {units.label(self.conn, unit)} ended without its close — judged "
                     f"{out.get('state')} from what its run left")

    def _outages_before(self, unit):
        """(n, cause): how many of `unit`'s ancestors IN A ROW, nearest first,
        closed on a provider outage (their evidence carries the classifier's
        cause, units.close) -- and the nearest one's cause."""
        n, cause, node = 0, "", unit
        while node["parent"]:
            node = ledger.get_unit(self.conn, node["parent"])
            if node is None or (node.get("evidence") or {}).get("cause") not in OUTAGE_CAUSES:
                break
            cause = cause or node["evidence"]["cause"]
            n += 1
        return n, cause

    def _strike(self, unit, next_id):
        """One more run of `unit`'s lineage that ended without a close;
        `next_id` is the unit that would run next -- the continuation, or the
        unit itself when its launch never started. At LAUNCH_STRIKES it is
        settled `failed` instead, with the reason the close names."""
        lineage = units.lineage_root(self.conn, unit)["id"]
        self.strikes[lineage] = self.strikes.get(lineage, 0) + 1
        if self.strikes[lineage] >= LAUNCH_STRIKES:
            ledger.settle_unit(self.conn, next_id, "failed", 0, {},
                               STRUCK_OUT_NOTE.format(n=LAUNCH_STRIKES))
            self.log(f"unit {units.label(self.conn, unit)} failed: the engine could not run it")
        else:
            self.log(f"unit {units.label(self.conn, unit)} ended without its close — "
                     "what it left was judged, and the rest runs again at the same attempt")

    def _stream_of(self, unit, pid):
        """The stream a unit's run left, found by the name run_job gives it:
        <log-root>/<job>/<UTC stamp>-<pid>.stream.ndjson, <pid> being the
        process this orchestrator launched (the run's own $$). The newest one
        stamped no earlier than the unit started -- a pid the kernel reissued
        names older files too. None without a log root or a file."""
        if not self.log_root or not pid:
            return None
        started = int(unit.get("started") or 0)
        best = None
        for path in Path(self.log_root, self.job).glob(f"*-{pid}.stream.ndjson"):
            try:
                when = calendar.timegm(time.strptime(path.name.split("-", 1)[0], "%Y%m%dT%H%M%SZ"))
            except ValueError:
                continue
            if when >= started - 5 and (best is None or when > best[0]):
                best = (when, path)
        return str(best[1]) if best else None

    def _judge_orphan(self, unit, pid):
        """{"state", "continuation"} for a unit whose run died unclosed, or
        None when the judgement raised -- the unit then stays `running` and
        is judged again on a later poll (JUDGE_TRIES), never reset: its run
        started an agent, and see the module docstring for why that unit
        must not run again under the same id.

        THROUGH THE ONE CLOSE (units.close), under `stopped`, with the stream
        it left if one is found. Without one, that close judges it as a
        disqualified attempt -- the stream is the only proof of what the
        session did and of whether it launched a subagent, so nothing counts
        and a verify unit's own verdict is cleared in the settle's
        transaction -- and, being `stopped`, the whole unit runs again at the
        same attempt. The rule lives in the close, not here, so the engine's
        `unit-close` handed an empty stream is held to it too.

        SPEND, ESTIMATED FROM THE STREAM. A run that died here never told
        run_job its cost either -- there is no run_job frame left to tell it
        anything -- so without this the unit would settle at spend_usd 0.0
        despite whatever real tokens it spent. costing.estimate_stream_cost
        reads the same table bin/agentloop's own salvage path does
        (config/pricing.json, --pricing above); with no stream, no usage in
        it, or no price for the model, it comes back None and this unit
        settles at 0.0 exactly as it always has."""
        try:
            stream = self._stream_of(unit, pid) or ""
            spend = 0.0
            if stream and self.pricing_file:
                cost, _basis, _tokens = costing.estimate_stream_cost(stream, self.pricing_file)
                if cost is not None:
                    spend = cost
            out = units.close(self.conn, unit, stream=stream,
                              root=_stream_root(stream) if stream else "", status="stopped",
                              spend_usd=spend)
        except Exception as exc:  # noqa: BLE001 -- a unit must never stay `running` for ever
            tries = self.unjudged.get(unit["id"], [pid, 0])[1] + 1
            why = f"{type(exc).__name__}: {exc}"
            if tries >= JUDGE_TRIES:
                self.unjudged.pop(unit["id"], None)
                self.log(JUDGE_GAVE_UP_LOG.format(uid=unit["id"], why=why, tries=tries))
            else:
                self.unjudged[unit["id"]] = [pid, tries]
                self.log(JUDGE_RETRY_LOG.format(uid=unit["id"], why=why))
            return None
        self.unjudged.pop(unit["id"], None)
        return out

    def _interrupt(self, note="") -> int:
        """Stop the units' runs and leave the analysis `interrupted` -- with
        `note` in its paragraph when something other than a stop is the
        reason (a gate that closed, a failure)."""
        self._set_phase("stopping")
        self.log("stopping its units")
        deadline = time.time() + STOP_GRACE_SECONDS
        # Re-issue the stop on every poll, not once: a unit launched just
        # before this loop started can still be between claiming its slot
        # and spawning its agent (bin/agentloop's run_job, ~6235) when the
        # first `stop` runs, so that first call never reaches it -- the slot
        # it takes appears only afterwards. A second `stop` during THIS wait
        # does reach it (cmd_stop now stops the job's slots too), so keep
        # asking until nothing is left alive or the grace runs out.
        while (self.children or self.adopted) and time.time() < deadline:
            try:
                subprocess.run([self.engine, "stop", self.job], capture_output=True, timeout=120,
                               env={**self.env, "AL_SECURITY_ORCHESTRATOR": "1"})
            except (OSError, subprocess.SubprocessError) as exc:
                self.log(f"could not ask the engine to stop the units: {exc}")
            self._reap()
            if not (self.children or self.adopted):
                break
            time.sleep(min(self.poll, 1.0))
        # Past the grace, a unit whose run is STILL ALIVE stays `running`: its
        # own close settles it whenever it ends, and a resume adopts it. One
        # whose run is gone -- including one a predecessor left and this loop
        # never launched, and one whose judgement raised -- is judged from
        # what it left; one that still cannot be is left for the resume.
        for u in ledger.units_of(self.conn, self.aid):
            if u["state"] == "running" and not self._run_alive(u):
                self._judge_orphan(u, _pid_of(u["run_key"]))
        ledger.interrupt_analysis(self.conn, self.aid, note)
        self.log("interrupted — `agentloop security resume` continues it")
        return 0

    def _finish(self, note, state="done"):
        """The close, from the units' proof -- and ONLY of a row still
        `running` (`--if-running`): a stop, or the next Analyse's sweep, may
        have interrupted the analysis while this loop was ending, and an
        interrupted analysis is the resume's to continue, never this close's
        to settle."""
        self._set_phase("finishing")
        args = ["finish", "--analysis", str(self.aid), "--state", state, "--from-units",
                "--if-running"]
        if note:
            args += ["--note", note]
        # TWICE, then an interruption: a close that fails -- a busy ledger,
        # a crash in the CLI -- must never leave the row `running` behind a
        # lock this process is about to release (see the module docstring).
        for attempt in (1, 2):
            out = self._cli(*args)
            if out.returncode == 0:
                break
            self.log(f"could not close (try {attempt}): {out.stderr.strip()[-400:]}")
            if attempt == 1:
                time.sleep(min(self.poll, 1.0))
        row = self._row()
        if row["state"] == "running":
            ledger.interrupt_analysis(self.conn, self.aid,
                                      FAILED_NOTE.format(what="its close failed"))
            self.log("interrupted — the close failed; `agentloop security resume` continues it")
            return
        self.log(f"closed {row['state']} (${row['spend_usd']:.2f})")

    def _release(self):
        if self.keep_lock:
            return
        if self._lock_is_mine():
            shutil.rmtree(self.lock_dir, ignore_errors=True)
