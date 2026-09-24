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
          agent findings the previous analysis left open (Job 1)
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
"""

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
    analysis, and every open agent finding a previous analysis left."""
    _analysis, findings = queries.checklist(conn, analysis_id)
    items = []
    for f in findings:
        if not queries.is_open(f.get("state", "")):
            continue
        producer = f.get("producer") or ""
        if f.get("analysis_id") == analysis_id and producer not in ("", diff.AGENT):
            kind = "scanner"
        elif f.get("analysis_id") != analysis_id and producer:
            # CARRIED, of any producer: an agent finding the last analysis left
            # open, and a deterministic row whose producer did not run this time
            # (`pending`) -- which vanishes from the next baseline unless it is
            # re-reported, and comes back as `regressed` when the engine returns.
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
    guides -- leaves the analysis with no unit at all, to be planned again."""
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
        for piece in slices.pack(ledger.inventory_of(conn, analysis_id).get("files", [])):
            chosen = slice_guides(piece) if slice_guides else ["ATTACK-CLASSES"]
            specs.append(("read", {"ranges": piece, "guides": chosen}))
    return ledger.add_units(conn, analysis_id, specs)


def plan_verification(conn, analysis_id) -> list:
    """One verify unit per finding OF THIS ANALYSIS in the queue that has none
    yet. A carried row belongs to another analysis and cannot take a verdict
    here -- its re-check is the triage units' debt."""
    have = {u["payload"].get("fingerprint") for u in ledger.units_of(conn, analysis_id)
            if u["kind"] == "verify"}
    ids = []
    for f in queries.verify_queue(conn, analysis_id):
        if f.get("analysis_id") != analysis_id or f["fingerprint"] in have:
            continue
        ids.append(ledger.add_unit(conn, analysis_id, "verify", {"fingerprint": f["fingerprint"]}))
        have.add(f["fingerprint"])
    return ids


def launchable(conn, analysis_id, capacity) -> list:
    """Pending units in the order they run, then by number; at most `capacity`."""
    if capacity <= 0:
        return []
    pending = [u for u in ledger.units_of(conn, analysis_id) if u["state"] == "pending"]
    pending.sort(key=lambda u: (KIND_RANK.get(u["kind"], 9), u["seq"]))
    return pending[:capacity]


def unsettled(all_units, kinds=None) -> list:
    return [u for u in all_units if u["state"] in ("pending", "running")
            and (kinds is None or u["kind"] in kinds)]


def _decided(conn, project, fingerprint) -> bool:
    return conn.execute("SELECT 1 FROM decision WHERE project=? AND fingerprint=?",
                        (project, fingerprint)).fetchone() is not None


def _merge_spans(spans) -> list:
    """[first, last] spans, sorted, with the overlapping and the adjacent
    joined into one."""
    out = []
    for first, last in sorted((int(a), int(b)) for a, b in spans):
        if out and first <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], last)
        else:
            out.append([first, last])
    return out


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
    return {path: _merge_spans(spans) for path, spans in out.items()}


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
    aid = unit["analysis_id"]
    project = conn.execute("SELECT project FROM analysis WHERE id=?", (aid,)).fetchone()["project"]
    owed = unit["payload"].get("items") or []
    gone = ledger.gone_in(conn, aid)
    left = []
    for item in owed:
        fp = item["fingerprint"]
        if _decided(conn, project, fp):
            continue
        row = conn.execute("SELECT triaged, severity, producer FROM finding"
                           " WHERE analysis_id=? AND fingerprint=?", (aid, fp)).fetchone()
        if item["kind"] == "scanner":
            if row is None or row["triaged"] or row["severity"] not in BLOCKING:
                continue
        elif row is not None:
            continue
        elif item.get("category") == "sast" and fp in gone:
            # A carried sast finding the unit read and SAID is gone
            # (`report-gone`): its absence from this analysis is a reading,
            # not a silence, and it closes `fixed`.
            continue
        left.append({k: item[k] for k in ("fingerprint", "kind", "category") if k in item})
    ev = {"items": len(owed), "missing": [i["fingerprint"] for i in left]}
    if not left:
        return True, None, ev, f"Triaged: {len(owed)} row(s)."
    return False, {"items": left}, ev, f"{len(left)} of {len(owed)} row(s) not triaged."


def _judge_verify(conn, unit):
    fp = unit["payload"].get("fingerprint", "")
    row = conn.execute("SELECT verdict FROM finding WHERE analysis_id=? AND fingerprint=?",
                       (unit["analysis_id"], fp)).fetchone()
    if row is not None and row["verdict"]:
        return True, None, {"verdict": row["verdict"]}, f"Verdict: {row['verdict']}."
    return False, None, {"verdict": ""}, "No verdict was recorded."


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
    A read unit records no `covered` span for it: its slice stays owed."""
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
    """Settle `unit` and plan what it left. Returns the unit's final state and
    the id of its continuation, if one was planned."""
    if done:
        ledger.settle_unit(conn, unit["id"], "done", spend_usd, evidence, note)
        return {"state": "done", "continuation": None}
    attempt = unit["attempt"] if stopped else unit["attempt"] + 1
    if attempt > MAX_ATTEMPTS:
        ledger.settle_unit(conn, unit["id"], "failed", spend_usd, evidence,
                           f"{note} Gave up after {MAX_ATTEMPTS} attempts.".strip())
        return {"state": "failed", "continuation": None}
    ledger.settle_unit(conn, unit["id"], "incomplete", spend_usd, evidence, note)
    payload = remaining if remaining is not None else unit["payload"]
    cid = ledger.add_unit(conn, unit["analysis_id"], unit["kind"], payload,
                          attempt=attempt, parent=unit["id"])
    return {"state": "incomplete", "continuation": cid}


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
