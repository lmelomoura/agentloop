# bin/security/units.py
"""The work an analysis is split into, and what each piece owes.

THE ENGINE PLANS; A SESSION EXECUTES. Until this module an analysis was one
agent doing four jobs in one context and deciding for itself when it had
done enough -- and on a large repository it always decided early, because
the repository did not fit. Now `prepare` ends by writing the plan: units,
each small enough for a fresh session and closed in scope, each run by the
engine (security/orchestrator.py) and judged by what it left behind --
never by what it said.

  triage  up to TRIAGE_BATCH rows: the scanners' findings (Job 2) and the
          findings the previous analysis left open (Job 1)
  hunt    the profile's reachability pass (in deep bounded to standard's
          scope: the exhaustive read belongs to the read units)
  read    deep only: one slice of the inventory (security/slices.py)
  verify  one finding of THIS analysis in the verification queue, planned
          only once every other unit has settled -- the queue is only final
          then

A UNIT IS NEVER REWRITTEN. What it left undone becomes a NEW unit whose
`parent` is this one, carrying only what is missing, one attempt up; a
lineage gets MAX_ATTEMPTS, and what the last one still left is a gap the
close names. A stop is not the unit's failure: its continuation keeps the
same attempt.

A UNIT IS CREDITED ONLY WITH ITS OWN WORK. Every write a session makes is
stamped with its unit -- `finding.unit` on a re-report, `verified_by =
"unit:<id>"` on a verdict, its own rows in `unit_gone` -- and the judge
counts nothing else. The ledger's state alone cannot say whose work it is:
a row marked triaged, a verdict, a `report-gone` all look the same whether
this unit wrote them, another unit did, or an attempt disqualified for
launching a subagent did -- and counting that last one would close its
continuation with no work done.
"""

import sqlite3

from . import diff, evidence, ledger, queries, slices

TRIAGE_BATCH = 25
MAX_ATTEMPTS = 3
# The close's own floor (cli.TRIAGE_BLOCKING, pinned equal by a test): a
# scanner row below it never blocks `done`, so it never keeps a unit open.
BLOCKING = ("critical", "high", "medium")
KIND_RANK = {"triage": 0, "hunt": 1, "read": 2, "verify": 3}
_SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
# The classifier notes that make a `warning` a truncated run rather than a
# noisy one -- the reading `security_close_analysis` applies in the engine.
_TRUNCATED = ("BUDGET LIMITED", "UNDECLARED ENDING", "UNDELIVERED")


def triage_items(conn, analysis_id) -> list:
    """What Jobs 1 and 2 owe, worst first: every open scanner row of this
    analysis, and every open finding a previous analysis left."""
    _analysis, findings = queries.checklist(conn, analysis_id)
    items = []
    for f in findings:
        if not queries.is_open(f.get("state", "")):
            continue
        producer = f.get("producer") or ""
        if f.get("analysis_id") == analysis_id and producer not in ("", diff.AGENT):
            kind = "scanner"
        elif f.get("analysis_id") != analysis_id:
            # CARRIED, of any producer: an agent finding the last analysis left
            # open, a deterministic row whose producer did not run this time
            # (`pending`) -- which vanishes from the next baseline unless it is
            # re-reported, and comes back as `regressed` when the engine returns
            # -- and a row from before the `producer` column (''), which closes
            # `fixed` on this analysis's `done` (diff._proven) unless somebody
            # re-checks it.
            kind = "carried"
        else:
            continue
        items.append({"fingerprint": f["fingerprint"], "kind": kind,
                      "category": f.get("category", ""), "severity": f.get("severity", "")})
    items.sort(key=lambda i: (_SEV_RANK.get(i["severity"], 9), i["kind"] != "scanner",
                              i["fingerprint"]))
    return items


def plan(conn, analysis_id, slice_guides=None) -> list:
    """The analysis's first units, written once. An analysis that already has
    units -- a resume, a second `prepare` -- gets none: planning twice would
    run the same work twice. `slice_guides(ranges)` names the hunting guides
    a read unit's files call for (`prepare` builds it from the same signals
    the analysis's own recommendation reads); without it a read unit gets
    ATTACK-CLASSES alone.

    COMPUTED WHOLE, THEN WRITTEN IN ONE TRANSACTION (ledger.add_units). The
    refusal above makes a partial plan permanent, so nothing is written until
    every unit is known: a failure anywhere -- the checklist, a slice's
    guides -- leaves the analysis with no unit at all, to be planned again.

    AND THE REFUSAL IS DECIDED WHERE THE PLAN IS WRITTEN. The check on entry
    only spares the work of computing a plan nobody will write; the one that
    counts runs inside that transaction (the guard): asked only before it, a
    second caller that planned the analysis in between left two plans --
    every slice read twice, every row triaged twice.

    A DEEP ANALYSIS IS NEVER PLANNED WITHOUT ITS INVENTORY. `inventory_of`
    reads a missing row and one that does not decode as {} -- which, taken
    for a scope, is an empty repository: a plan with no read unit, and a
    debt (`owed`) of nothing, so the close would name no line unread. The
    refusal raises before anything is written, and `prepare --plan` fails
    loudly on it."""
    if ledger.units_of(conn, analysis_id):
        return []
    profile = conn.execute("SELECT profile FROM analysis WHERE id=?",
                           (analysis_id,)).fetchone()["profile"]
    specs = []
    items = triage_items(conn, analysis_id)
    for start in range(0, len(items), TRIAGE_BATCH):
        batch = [{"fingerprint": i["fingerprint"], "kind": i["kind"], "category": i["category"]}
                 for i in items[start:start + TRIAGE_BATCH]]
        specs.append(("triage", {"items": batch}))
    specs.append(("hunt", {"profile": profile}))
    if profile == "deep":
        files = ledger.inventory_of(conn, analysis_id).get("files")
        if not isinstance(files, list):
            raise ValueError(
                f"analysis {analysis_id} is deep and has no inventory to plan its reads from: "
                "its scope was never listed, or the list stored for it could not be read")
        for piece in slices.pack(files):
            chosen = slice_guides(piece) if slice_guides else ["ATTACK-CLASSES"]
            specs.append(("read", {"ranges": piece, "guides": chosen}))

    def no_units_yet(c, planned):
        return [] if ledger.units_of(c, analysis_id) else planned
    return ledger.add_units(conn, analysis_id, specs, guard=no_units_yet)


def plan_verification(conn, analysis_id) -> list:
    """One verify unit per finding OF THIS ANALYSIS in the queue that has none
    yet. A carried row belongs to another analysis and cannot take a verdict
    here -- its re-check is the triage units' debt.

    Which findings already have one is asked INSIDE the transaction that
    writes the new ones (ledger.add_units' guard). Read before the queue, as
    it was, the answer was stale by the write: a second caller that planned
    in between doubled every verification."""
    specs = [("verify", {"fingerprint": f["fingerprint"]})
             for f in queries.verify_queue(conn, analysis_id)
             if f.get("analysis_id") == analysis_id]

    def not_planned_yet(c, wanted):
        have = {u["payload"].get("fingerprint") for u in ledger.units_of(c, analysis_id)
                if u["kind"] == "verify"}
        out = []
        for kind, payload in wanted:
            if payload["fingerprint"] not in have:
                have.add(payload["fingerprint"])
                out.append((kind, payload))
        return out
    return ledger.add_units(conn, analysis_id, specs, guard=not_planned_yet)


def launchable(conn, analysis_id, capacity) -> list:
    """Pending units in the order they run, then by number; at most `capacity`."""
    if capacity <= 0:
        return []
    pending = [u for u in ledger.units_of(conn, analysis_id) if u["state"] == "pending"]
    pending.sort(key=lambda u: (KIND_RANK.get(u["kind"], 9), u["seq"]))
    return pending[:capacity]


def unsettled(all_units, kinds=None) -> list:
    """The units of `all_units` still owed a run or in one -- `pending` or
    `running` -- and only of `kinds` when given. Asked of a list the caller
    already holds, never of the ledger: the orchestrator reads its units once
    a pass, and asks this whether every triage, hunt and read has settled
    (the verification queue is final only then) and whether a spent budget
    left any unit unrun."""
    return [u for u in all_units if u["state"] in ("pending", "running")
            and (kinds is None or u["kind"] in kinds)]


def _covered(wanted, reads) -> dict:
    """{path: [[first, last], ...]}: what of this unit's OWN ranges the session
    proved it read -- each proven span cut to the ranges the payload holds.

    RECORDED WHATEVER THE OUTCOME. The deep read's debt is the inventory minus
    the union of these spans over every read unit (`owed`), so a unit that
    read half its slice before it fell short has paid for that half, and one
    that gave up without saying what it missed -- no `covered` at all --
    still owes the whole slice. Lines read outside the payload count for
    nothing here: they are some other unit's to prove."""
    out = {}
    for r in wanted:
        first, last = int(r["first"]), int(r["last"])
        for a, b in reads.get(r["path"], []):
            lo, hi = max(int(a), first), min(int(b), last)
            if lo <= hi:
                out.setdefault(r["path"], []).append((lo, hi))
    return {path: [list(s) for s in evidence.merge_spans(spans)] for path, spans in out.items()}


def _judge_read(unit, session):
    wanted = unit["payload"].get("ranges") or []
    left = evidence.missing(wanted, session.reads)
    ev = {"ranges": len(wanted), "missing": left, "covered": _covered(wanted, session.reads),
          "guides": sorted(session.guides)}
    if not left:
        return True, None, ev, f"Read in full: {len(wanted)} range(s)."
    remaining = {"ranges": left}
    if unit["payload"].get("guides"):
        remaining["guides"] = unit["payload"]["guides"]   # the continuation hunts with the same guides
    return False, remaining, ev, f"{len(left)} of {len(wanted)} range(s) not read in full."


def _judge_triage(conn, unit):
    """Which of its rows this unit settled, by ITS OWN writes alone.

    A scanner row counts once this unit's re-report marked it triaged
    (`finding.unit` names the unit), or when it sits below the floor at the
    severity its scanner gave it. A carried row counts once this unit
    re-reported it into this analysis, or -- a `sast` one -- said it is gone
    (`report-gone`, ledger.gone_by). Either counts when the operator decided
    it: a human's ruling needs nobody's reading.

    FAIL-CLOSED ON A RACE, KNOWINGLY. Another unit that re-reports one of
    these rows after this one moves `finding.unit` to itself, and this
    unit's lineage then owes the row again and re-reports it. A reading done
    twice costs a run; one credited to a unit that never did it costs the
    analysis its word."""
    aid, uid = unit["analysis_id"], unit["id"]
    project = conn.execute("SELECT project FROM analysis WHERE id=?", (aid,)).fetchone()["project"]
    decided = ledger.decisions_for(conn, project)
    gone = ledger.gone_by(conn, uid)
    owed = unit["payload"].get("items") or []
    left = []
    for item in owed:
        fp = item["fingerprint"]
        if fp in decided:
            continue
        row = conn.execute("SELECT triaged, severity, unit FROM finding"
                           " WHERE analysis_id=? AND fingerprint=?", (aid, fp)).fetchone()
        mine = row is not None and row["unit"] == uid
        if item["kind"] == "scanner":
            if row is None:
                # UNREACHABLE, and settled if it is ever reached: nothing
                # deletes a finding, and `migrate-rules` -- the one verb that
                # moves a row to another fingerprint -- is refused while an
                # analysis is open (cli.cmd_migrate_rules). A row that is not
                # there leaves nothing for a unit to read.
                continue
            if row["triaged"] and mine:
                continue
            if not row["triaged"] and row["severity"] not in BLOCKING:
                # Below the floor at the severity its SCANNER gave it: the
                # close never asks for its reading. A severity an agent's
                # re-report wrote (`triaged`) is that writer's reading --
                # an attempt disqualified for a subagent lowering a `high`
                # to `low` included -- and counts for the writer alone,
                # through the line above.
                continue
        elif mine:
            continue
        elif item.get("category") == "sast" and fp in gone:
            # A carried sast finding this unit read and SAID is gone
            # (`report-gone`): its absence from this analysis is a reading,
            # not a silence, and it closes `fixed`.
            continue
        left.append({k: item[k] for k in ("fingerprint", "kind", "category") if k in item})
    ev = {"items": len(owed), "missing": [i["fingerprint"] for i in left]}
    if not left:
        return True, None, ev, f"Triaged: {len(owed)} row(s)."
    return False, {"items": left}, ev, f"{len(left)} of {len(owed)} row(s) not triaged by this unit."


def _judge_verify(conn, unit):
    """Done on a verdict THIS unit wrote: `verified_by` names it
    (`unit:<id>`). A verdict on the row from anybody else -- the hunter that
    minted the finding verifying it itself, another unit, the operator, a
    verifier from before the pipeline -- is not this unit's reading, and
    counting it would credit the unit with a verification it never did."""
    fp = unit["payload"].get("fingerprint", "")
    row = conn.execute("SELECT verdict, verified_by FROM finding WHERE analysis_id=? AND fingerprint=?",
                       (unit["analysis_id"], fp)).fetchone()
    if row is None or not row["verdict"]:
        return False, None, {"verdict": ""}, "No verdict was recorded."
    if row["verified_by"] != f"unit:{unit['id']}":
        return False, None, {"verdict": "", "verified_by": row["verified_by"]}, (
            f"The verdict on this finding was written by {row['verified_by'] or 'an unnamed writer'}, "
            "not by this unit.")
    return True, None, {"verdict": row["verdict"]}, f"Verdict: {row['verdict']}."


def _judge_hunt(status, reason):
    worked = status == "success" or (
        status == "warning" and not any(mark in (reason or "") for mark in _TRUNCATED))
    if worked:
        return True, None, {"status": status}, "The pass ran to its end."
    return False, None, {"status": status, "reason": reason or ""}, (
        f"The run ended {status}{': ' + reason if reason else ''}.")


def judge(conn, unit, session, status, reason=""):
    """(done, remaining, evidence, note) for one run of `unit`. `remaining`
    is the payload of the continuation -- only what is still owed -- or None
    for "all of it again".

    A SESSION THAT LAUNCHED A SUBAGENT FAILS ITS ATTEMPT, WHATEVER ITS KIND.
    The engine distributes the work; a triage, a hunt or a verdict a
    subagent produced is not this unit's work any more than a subagent's
    reads are (security/evidence.py counts only the unit's own), so nothing
    this attempt did counts and the whole payload runs again, one attempt up.
    A read unit records no `covered` span for it: its slice stays owed. Nor
    does what it wrote count for the continuation, which is credited with
    its own writes alone; a verify attempt's verdict is cleared at its close."""
    if session.tasks:
        ev = {"tasks": session.tasks, "guides": sorted(session.guides)}
        if unit["kind"] == "read":
            ev.update({"ranges": len(unit["payload"].get("ranges") or []), "covered": {}})
        return False, None, ev, (
            f"This session launched {session.tasks} subagent(s). The engine distributes "
            "the work, so nothing this attempt did counts.")
    if unit["kind"] == "read":
        done, remaining, ev, note = _judge_read(unit, session)
    elif unit["kind"] == "triage":
        done, remaining, ev, note = _judge_triage(conn, unit)
    elif unit["kind"] == "verify":
        done, remaining, ev, note = _judge_verify(conn, unit)
    else:
        done, remaining, ev, note = _judge_hunt(status, reason)
    # What each session opened of the hunting guides, whatever its kind: the
    # close aggregates them into the analysis's `guides.read`.
    ev.setdefault("guides", sorted(session.guides))
    return done, remaining, ev, note


def conclude(conn, unit, *, done, evidence, note, spend_usd, remaining=None, stopped=False):
    """Settle `unit` and plan what it left, in ONE transaction
    (ledger.conclude_unit). Returns the unit's state and the id of its
    continuation, if one was planned.

    THE LEDGER'S ANSWER, NOT THE CALLER'S INTENT. A unit already settled --
    by another close, or by an earlier call holding the same copy of it --
    is left as it is, gets no continuation, and the state returned is the
    one the ledger holds. Two closes of one unit used to continue it twice,
    a close over a unit settled `done` elsewhere answered "incomplete" and
    planned more work, and a kill between the settle and the continuation
    lost the continuation for good."""
    if done:
        state, continuation = "done", None
    else:
        attempt = unit["attempt"] if stopped else unit["attempt"] + 1
        if attempt > MAX_ATTEMPTS:
            state, continuation = "failed", None
            note = f"{note} Gave up after {MAX_ATTEMPTS} attempts.".strip()
        else:
            payload = remaining if remaining is not None else unit["payload"]
            state, continuation = "incomplete", (unit["kind"], payload, attempt, unit["id"])
    settled, cid = ledger.conclude_unit(conn, unit["id"], state, spend_usd, evidence, note,
                                        continuation)
    if not settled:
        return {"state": ledger.get_unit(conn, unit["id"])["state"], "continuation": None}
    return {"state": state, "continuation": cid}


def lineage_root(conn, unit):
    """The first unit of this unit's lineage -- what the label numbers, and
    what the orchestrator counts a lineage's runs that died by."""
    while unit["parent"]:
        unit = ledger.get_unit(conn, unit["parent"])
    return unit


def label(conn, unit) -> str:
    """"read 7/25", "read 7/25 · attempt 2": the place of the unit's lineage
    among the analysis's first units of its kind, and the attempt."""
    root = lineage_root(conn, unit)
    firsts = [u for u in ledger.units_of(conn, unit["analysis_id"])
              if u["kind"] == unit["kind"] and not u["parent"]]
    place = next((n for n, u in enumerate(firsts, 1) if u["id"] == root["id"]), 0)
    text = f"{unit['kind']} {place}/{len(firsts)}"
    return text if unit["attempt"] == 1 else f"{text} · attempt {unit['attempt']}"


def _lineages(all_units):
    """(root, last attempt) for every lineage, in the order of the roots --
    how a unit that was continued is counted: by where its lineage ended."""
    children = {}
    for u in all_units:
        if u["parent"]:
            children.setdefault(u["parent"], []).append(u)
    out = []
    for root in (u for u in all_units if not u["parent"]):
        last = root
        while children.get(last["id"]):
            last = max(children[last["id"]], key=lambda c: c["seq"])
        out.append((root, last))
    return out


def owed(conn, analysis_id, all_units=None, inventory=None) -> list:
    """The deep scope's lines no read unit proved it read, as
    [{"path", "first", "last"}] in inventory order: every range of the
    inventory minus the union of the `covered` spans the read units of this
    analysis recorded (`_judge_read`), WHATEVER THEIR STATE.

    FROM THE INVENTORY, NOT FROM THE UNITS. Counting what each lineage's last
    attempt still carried left out everything no unit carries -- a slice a
    plan cut short never got -- and everything a unit gave up on without
    naming it: a crash, a subagent, three runs the engine could not finish
    all settle with no `missing`, and each read "in full". A unit that
    covered nothing proved nothing. THE ONE COMPUTATION OF THE DEBT: `summary`
    reads it for the page, and the close (`gaps`, security/units.py) for the
    report."""
    if inventory is None:
        inventory = ledger.inventory_of(conn, analysis_id)
    if not inventory:
        return []
    if all_units is None:
        all_units = ledger.units_of(conn, analysis_id)
    covered = {}
    for u in all_units:
        spans = u["evidence"].get("covered") if u["kind"] == "read" else None
        if not isinstance(spans, dict):
            continue
        for path, pairs in spans.items():
            for pair in pairs if isinstance(pairs, list) else []:
                try:
                    covered.setdefault(path, []).append((int(pair[0]), int(pair[1])))
                except (TypeError, ValueError, IndexError):
                    continue    # a cell nobody could have written: it proves nothing
    merged = {path: evidence.merge_spans(spans) for path, spans in covered.items()}
    # THE SAME GAP COMPUTATION `evidence.missing` runs for one unit's own
    # ranges against its session's reads (I2): the inventory's ranges are
    # its "wanted", the union of every read unit's covered spans is its
    # "reads". Only the "bytes" key `missing` adds to each gap is not part
    # of `owed`'s own return shape, so it is dropped below.
    ranges = [{"path": f["path"], "first": int(rng[0]), "last": int(rng[1])}
             for f in inventory.get("files") or [] for rng in f.get("ranges") or []]
    return [{"path": g["path"], "first": g["first"], "last": g["last"]}
           for g in evidence.missing(ranges, merged)]


def summary(conn, analysis_id):
    """What the page shows while an analysis runs and after it: per kind, how
    many lineages are done, running, waiting or given up (each judged by its
    LAST attempt); in a deep analysis, how much of the inventory has been
    read (`owed`); and what the units cost. None on a ledger that predates the
    unit table -- the read-only paths never migrate."""
    try:
        all_units = ledger.units_of(conn, analysis_id)
    except sqlite3.OperationalError:
        return None
    lineages = _lineages(all_units)
    kinds = {}
    for kind in ledger.UNIT_KINDS:
        lasts = [last for root, last in lineages if root["kind"] == kind]
        if not lasts:
            continue
        counts = {"total": len(lasts), "done": 0, "running": 0, "pending": 0, "failed": 0}
        for last in lasts:
            state = last["state"]
            counts[state if state in ("done", "running", "failed") else "pending"] += 1
        kinds[kind] = counts
    deep = None
    inventory = ledger.inventory_of(conn, analysis_id)
    if inventory:
        left = owed(conn, analysis_id, all_units, inventory)
        paths_left = {s["path"] for s in left}
        lines = int((inventory.get("totals") or {}).get("lines", 0))
        files = inventory.get("files") or []
        deep = {"files": len(files),
                "files_read": sum(1 for f in files if f["path"] not in paths_left),
                "lines": lines,
                "lines_read": lines - sum(s["last"] - s["first"] + 1 for s in left)}
    return {"kinds": kinds, "deep": deep, "units": len(all_units),
            "spend_usd": round(sum(u["spend_usd"] for u in all_units), 4)}


def close(conn, unit, *, stream="", root="", status="error", reason="", spend_usd=0.0) -> dict:
    """Judge one run of `unit` by what it left -- its stream, what `security
    read` served it, the ledger -- and conclude it. {"state", "continuation"}.

    THE ONE CLOSE OF A UNIT. The engine's `unit-close` (a run that ended) and
    the orchestrator (a run that died without closing, security/orchestrator.py)
    both come here, so a unit is judged the same way whichever of them saw its
    run end. A unit already settled is left exactly as it is: the orchestrator
    closes a unit whose run died before its own close could. Settled is asked
    of the LEDGER, not of the caller's copy: a close holding an old copy of a
    unit another close has settled must not judge it again -- least of all
    clear the verdict it was credited with (below)."""
    unit = ledger.get_unit(conn, unit["id"])
    if unit["state"] not in ("pending", "running"):
        return {"state": unit["state"], "continuation": None}
    session = evidence.read_session(stream or None, root or ".")
    # ONLY THIS RUN'S OWN READS (minor 1). A unit `reset_unit` sends back to
    # `pending` after its run died keeps its id and its `started`, so a
    # chunk `security read` recorded for that dead run is still on
    # `unit_read` under the same unit id -- `since` (set fresh by
    # `start_unit` on every launch) keeps only what THIS run was served.
    # `read` itself also now refuses to serve a unit that is not `running`
    # (cli.cmd_read), so nothing new can land between a reset and the next
    # launch either.
    session = evidence.with_served(session, ledger.unit_reads(conn, unit["id"], since=unit["started"]))
    done, remaining, ev, note = judge(conn, unit, session, status, reason)
    if session.tasks and unit["kind"] == "verify":
        # A VERDICT NOBODY CAN PROVE THIS UNIT REASONED MUST NOT STAND. The
        # session launched a subagent, so `judge` credits it with nothing --
        # but the verdict on its finding, stamped with this unit's id by
        # whoever in the session wrote it, would outlive the attempt:
        # `record_verdict` writes a row's verdict once, so the continuation
        # could never write its own and the lineage never finish, and a
        # `rejected` would drop the finding from the exposure for good.
        # Cleared BEFORE the conclude, so a kill in between leaves the unit
        # running with nothing credited, to be judged again.
        ledger.clear_verdict(conn, unit["analysis_id"], unit["payload"].get("fingerprint", ""),
                             f"unit:{unit['id']}")
    return conclude(conn, unit, done=done, evidence=ev, note=note, spend_usd=spend_usd,
                    remaining=remaining, stopped=status == "stopped")
