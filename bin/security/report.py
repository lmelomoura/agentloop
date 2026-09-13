# bin/security/report.py
"""Markdown, JSON and HTML, generated on download from the ledger.

Reports are never written to disk. A risk accepted after the analysis ran
should appear as accepted in the file you download -- a stored artefact would
instead hand you a frozen document that disagrees with the page you have open.
"""

import html
import json
import time

from . import coverage
# One definition of what "resolved" means, imported rather than repeated:
# a second copy is how the export and the screen would come to disagree
# about which findings are still work. queries imports diff and ledger,
# never report, so this cannot cycle.
from .queries import RESOLVED_STATES

STATES = ("new", "regressed", "open", "partial", "pending", "fixed", "accepted", "false_positive")
# Ordered most severe first. `info` is last on purpose: it is below the default
# min_severity floor, so an informational finding is recorded and stays out of
# the way until somebody lowers the floor to look for it.
SEVERITIES = ("critical", "high", "medium", "low", "info")


def _summary(findings):
    by_state = {s: 0 for s in STATES}
    by_severity = {s: 0 for s in SEVERITIES}
    accepted_in_severity = 0
    for f in findings:
        by_state[f["state"]] = by_state.get(f["state"], 0) + 1
        if f["state"] not in ("fixed", "false_positive"):
            by_severity[f["severity"]] = by_severity.get(f["severity"], 0) + 1
            if f["state"] == "accepted":
                accepted_in_severity += 1
    return {"by_state": by_state, "by_severity": by_severity, "total": len(findings),
            "accepted_in_severity": accepted_in_severity}


def _unknown_states(by_state):
    """States present in the data but outside the STATES contract.

    `_summary` counts these into `by_state` unconditionally (dict.get with a
    default), so they are never lost from the JSON report. The MD and HTML
    checklists iterate the fixed STATES tuple instead of by_state's keys, so
    without this they would silently drop any such count from the two formats
    a human actually reads.
    """
    return [s for s in by_state if s not in STATES]


# `scope` reads as a bare word in the ledger and as a sentence fragment in a
# report, and the gap between the two is where a reader guesses wrong. "dev"
# alone invites "so I can ignore it"; "unknown" alone invites "so it is
# probably fine". Both are expanded here, in the one place all three formats
# read, so the two a human downloads cannot describe the column differently.
#
# A value not in this table renders as itself rather than being dropped: a
# vocabulary this module has not been taught is still a fact the ledger holds,
# and hiding it would be the silent-difference failure one level down.
_SCOPE_LABELS = {
    "dev": "dev — a development-only dependency, not shipped",
    "runtime": "runtime — this dependency ships",
    "unknown": "unknown — this lockfile format does not say whether it ships",
}


def _scope_label(scope: str) -> str:
    return _SCOPE_LABELS.get(scope, scope)


def _coverage(analysis, coverage_note):
    """What this report did NOT look at. Printed before anything else.

    `capped` no longer means only "it reached its spending cap" -- since the
    `prepared` guard in `cmd_finish` (bin/security/cli.py), it also covers a
    `done` close downgraded because the deterministic phases never ran at
    all. Naming a spending cap here would be a flat lie for that second case,
    and this line cannot tell the two apart -- the wording therefore says
    only what is true of BOTH: the analysis is incomplete and stopped short
    of the whole scope. The specific cause belongs to `coverage_note`, printed
    right after, which is where `cmd_finish` puts it ("The deterministic
    phases never ran for this analysis: ..."). Kept word-for-word identical to
    the sentence `bin/dashboard.html` prints for the same state, so the
    downloaded file and the screen never disagree.
    """
    parts = []
    if analysis["state"] == "capped":
        parts.append("This analysis is INCOMPLETE: it stopped before "
                     "covering the whole scope.")
    elif analysis["state"] == "failed":
        parts.append("This analysis is INCOMPLETE: it did not finish.")
    if coverage_note:
        parts.append(coverage_note)
    return parts


# The `by` column of a phase that had no producer -- `scope`, or any phase
# where nothing looked. An em dash and not an empty cell: a blank there reads
# as a value the renderer failed to print, where "—" reads as the fact that
# there was nobody to name.
_NO_PRODUCER = "—"


def _phase_rows(analysis):
    """(name, status, by) per phase, ready to print, or [] for an analysis
    that has no structured coverage.

    `[]` IS THE WHOLE COMPATIBILITY STORY. Every analysis written before the
    `coverage` column existed has '' in it, and every renderer below draws
    nothing whatsoever for an empty list -- so an old report is byte-identical
    to what it was, and a new one gains a table above prose that was going to
    be printed anyway. See security/coverage.py's own `decode`, which answers
    `[]` for a malformed document too rather than raising inside a download.
    """
    return [(str(p.get("name", "")), str(p.get("status", "")),
             str(p.get("by") or _NO_PRODUCER))
            for p in coverage.phases_of(analysis)]


def as_json(analysis, findings, coverage_note):
    """The machine-readable format, and the one place `scope` is ALWAYS a key.

    The two formats a human reads render nothing when the value is absent, so
    they cannot be parsed for it. This one is: something consuming the JSON has
    to be able to tell "this analysis predates the column" from "this finding
    is not a dependency" without special-casing a missing key, so the key is
    always present and the empty string carries that distinction. Rows read
    from the ledger have it already (the column is NOT NULL with a '' default);
    the `setdefault` is for a caller assembling findings some other way.
    """
    rows = []
    for f in findings:
        row = dict(f)
        row.setdefault("scope", "")
        rows.append(row)
    return json.dumps({
        "analysis": dict(analysis),
        # AN OBJECT, and `phases` is ALWAYS a key in it -- the same rule
        # `scope` follows on a finding above, for the same reason. The two
        # formats a human reads print nothing when there is nothing to print,
        # so they cannot be parsed for an absence; this one has to let a
        # consumer tell "this analysis predates the column" (an empty list)
        # from "this consumer is reading an older report format" (no key at
        # all) without special-casing either. `notes` is what this key used to
        # BE -- the prose, unchanged, in the same order.
        "coverage": {"notes": _coverage(analysis, coverage_note),
                     "phases": coverage.phases_of(analysis)},
        "summary": _summary(findings),
        "findings": rows,
    }, indent=2, sort_keys=True)


def as_markdown(analysis, findings, coverage_note):
    s = _summary(findings)
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(analysis["started"]))
    out = [f"# Security analysis — {analysis['project']} / {analysis['repo']}",
           "",
           f"- **Branch:** `{analysis['branch']}` at `{analysis['commit_sha'][:12]}`",
           f"- **Profile:** {analysis['profile']}",
           f"- **Run at:** {when}",
           ""]
    # THE TABLE COMES FIRST, AND THAT ORDER IS THE POINT OF IT. The prose
    # below is every gap this analysis has, sentence by sentence, and on a
    # real run it is about two thousand characters of it -- true throughout
    # and unreadable as a block. Nine lines of "who looked, who did not, and
    # with what" answer the question a reader actually opens the file with;
    # the paragraph is then there for the one who asks why.
    rows = _phase_rows(analysis)
    if rows:
        out += ["## Coverage", "",
                "| Phase | Status | By |", "| --- | --- | --- |"]
        # `|` escaped, not stripped: these three values come from a closed
        # vocabulary this module writes, but they are read back out of a
        # database column, and a stray pipe would silently eat the rest of a
        # row rather than showing up as the odd value it is.
        out += ["| " + " | ".join(c.replace("|", "\\|") for c in row) + " |"
                for row in rows]
        out.append("")
    for note in _coverage(analysis, coverage_note):
        out += [f"> **{note}**", ""]
    out += ["## Checklist", ""]
    out += [f"- {state}: {s['by_state'][state]}" for state in STATES]
    out += [f"- {state}: {s['by_state'][state]}" for state in _unknown_states(s["by_state"])]
    out += ["", "## Open findings by severity", ""]
    out += [f"- {sev}: {s['by_severity'][sev]}" for sev in SEVERITIES]
    if s["accepted_in_severity"]:
        n = s["accepted_in_severity"]
        out += ["", f"_(includes {n} accepted risk{'s' if n != 1 else ''})_"]
    out += ["", "## Findings", ""]
    for f in findings:
        out += [f"### [{f['severity']}] {f['title']} — `{f['state']}`", "",
                f"**Rule:** `{f['rule']}` ({f['category']})"]
        if f.get("cwe"):
            out.append(f"  - Class: {f['cwe']}"
                       + (f" · OWASP {f['owasp']}" if f.get("owasp") else ""))
        if f.get("scope"):
            out.append(f"  - Scope: {_scope_label(f['scope'])}")
        out.append("")
        for occ in f["occurrences"]:
            out.append(f"- `{occ['file']}`" + (f":{occ['line']}" if occ["line"] else ""))
        out += ["", f["rationale"], "", f"**Remediation:** {f['remediation']}", ""]
    return "\n".join(out)


_CSS = """body{font:15px/1.55 -apple-system,system-ui,sans-serif;max-width:60rem;
margin:2rem auto;padding:0 1rem;color:#1a1a1a}
h1,h2,h3{line-height:1.25}.note{background:#fff4e5;border-left:4px solid #d97706;
padding:.75rem 1rem;margin:1rem 0}.f{border:1px solid #e5e5e5;border-radius:6px;
padding:1rem;margin:1rem 0}.critical{border-left:4px solid #dc2626}
.high{border-left:4px solid #ea580c}.medium{border-left:4px solid #ca8a04}
.low{border-left:4px solid #6b7280}.info{border-left:4px solid #9ca3af}
.cls{color:#4b5563;font-size:.9em}
code{background:#f4f4f5;padding:.1em .35em;
border-radius:3px}@media print{.f{break-inside:avoid}}
.cov{border-collapse:collapse;margin:1rem 0}
.cov th,.cov td{border:1px solid #e5e5e5;padding:.3rem .6rem;text-align:left}
.cov th{background:#f4f4f5;font-weight:600}
.cov .cov-ok{color:#15803d}.cov .cov-warn{color:#b45309}.cov .cov-gap{color:#b91c1c}"""

# The CSS class a status cell carries, DELIBERATELY NOT SPELLED LIKE THE
# STATUS. The class used to be the status word itself, and the test that
# checked a `skipped` row was rendered passed on a page with no such row --
# the word was in the stylesheet's `.cov .skipped`. None of these three
# contains the status it colours, so a test that finds the word in the output
# has found it in a cell. A status this table does not know gets no class at
# all: a word with no colour is what an unknown status should look like, and
# a class attribute built from an unknown value would be a second sink beside
# the text.
_STATUS_CLASS = {coverage.RAN: "cov-ok", coverage.WARNING: "cov-warn",
                 coverage.SKIPPED: "cov-gap"}


def as_html(analysis, findings, coverage_note):
    e = html.escape
    s = _summary(findings)
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(analysis["started"]))
    parts = [f"<!doctype html><meta charset=utf-8><title>Security analysis — "
             f"{e(analysis['project'])}</title><style>{_CSS}</style>",
             f"<h1>Security analysis — {e(analysis['project'])} / {e(analysis['repo'])}</h1>",
             f"<p>Branch <code>{e(analysis['branch'])}</code> at "
             f"<code>{e(analysis['commit_sha'][:12])}</code> · profile "
             f"{e(analysis['profile'])} · {e(when)}</p>"]
    # Before the prose, for the reason `as_markdown` gives at length -- and
    # pinned there by test_html_opens_with_the_phase_table_before_the_prose,
    # which reads the two tags' positions rather than trusting this comment.
    # The status picks the cell's class through `_STATUS_CLASS`, so a reader
    # scanning the table sees three colours rather than three words, and the
    # class is one of three literals this module owns rather than a value
    # read out of a database column.
    rows = _phase_rows(analysis)
    if rows:
        parts.append('<h2>Coverage</h2><table class="cov">'
                     "<tr><th>Phase</th><th>Status</th><th>By</th></tr>")
        for name, status, by in rows:
            cls = _STATUS_CLASS.get(status)
            cell = (f'<td class="{cls}">{e(status)}</td>' if cls
                    else f"<td>{e(status)}</td>")
            parts.append(f"<tr><td>{e(name)}</td>{cell}<td>{e(by)}</td></tr>")
        parts.append("</table>")
    for note in _coverage(analysis, coverage_note):
        parts.append(f'<p class="note">{e(note)}</p>')
    parts.append("<h2>Checklist</h2><ul>")
    parts += [f"<li>{st}: {s['by_state'][st]}</li>" for st in STATES]
    parts += [f"<li>{e(st)}: {s['by_state'][st]}</li>" for st in _unknown_states(s["by_state"])]
    parts.append("</ul><h2>Open findings by severity</h2><ul>")
    parts += [f"<li>{sev}: {s['by_severity'][sev]}</li>" for sev in SEVERITIES]
    parts.append("</ul>")
    if s["accepted_in_severity"]:
        n = s["accepted_in_severity"]
        parts.append(f'<p class="note">Includes {n} accepted risk{"s" if n != 1 else ""}.</p>')
    parts.append("<h2>Findings</h2>")
    for f in findings:
        locs = "".join(
            f"<li><code>{e(o['file'])}{':' + e(str(o['line'])) if o['line'] else ''}</code></li>"
            for o in f["occurrences"])
        cls = (f'<p class="cls">{e(f["cwe"])}'
               + (f" · OWASP {e(f['owasp'])}" if f.get("owasp") else "")
               + "</p>") if f.get("cwe") else ""
        # Absent renders NOTHING, exactly as `cwe` does above: every
        # non-dependency finding carries '' here, and a "Scope: —" line on all
        # of them would be a column of dashes a reader learns to skip.
        scope = (f'<p class="cls">Scope: {e(_scope_label(f["scope"]))}</p>'
                 if f.get("scope") else "")
        parts.append(
            f'<div class="f {e(f["severity"])}">'
            f"<h3>[{e(f['severity'])}] {e(f['title'])} — {e(f['state'])}</h3>"
            f"<p>Rule <code>{e(f['rule'])}</code> ({e(f['category'])})</p>"
            f"{cls}{scope}"
            f"<ul>{locs}</ul><p>{e(f['rationale'])}</p>"
            f"<p><strong>Remediation:</strong> {e(f['remediation'])}</p></div>")
    return "".join(parts)


# --------------------------------------------------------- consolidated
# EVERY finding of a project, across branches, in one document -- the other
# three renderers above answer "what did this analysis find"; this one answers
# "what is there to fix, and where". Its reader is an agent with no context,
# which is what sets its shape: the branch on every finding (without it there
# is no way to know where to apply a fix), the commit each branch was analysed
# at (so the agent can tell whether the code it is reading is the code that
# was read), and a header that says what the document does NOT contain before
# the reader can be misled by its silence.

def _consolidated_meta_lines(project, groups, meta):
    """The header, as a list of lines. Every number a reader needs to know
    whether to trust the list, before the list."""
    total = sum(len(g["open"]) + len(g["resolved"]) for g in groups)
    open_n = sum(len(g["open"]) for g in groups)
    res_n = total - open_n
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(meta.get("at") or time.time()))
    out = [f"- **Exported:** {when}",
           f"- **Branches:** {len(groups)}",
           f"- **Findings:** {open_n} open" + (f", {res_n} resolved (listed last)" if res_n else "")]
    # THE FILTERS THE SCREEN HAD ON, SAID OUT LOUD. Someone who narrowed the
    # page to Critical and then exported gets every severity in the file; the
    # page already promises that ("Downloads always contain every recorded
    # finding, whatever the severity floor shows") but the promise lives on
    # the page, not in the file, and the file is what the agent reads.
    # WORST FIRST, AND ONLY WHAT IS OPEN. "3 open" does not say whether to
    # start now or after lunch; "1 critical, 1 high" does. Resolved findings
    # are left out of this line on purpose -- they are not work.
    counts = {}
    for g in groups:
        for f in g["open"]:
            counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    if counts:
        out.append("- **Open by severity:** "
                   + " · ".join(f"{sev} {counts[sev]}" for sev in SEVERITIES if counts.get(sev)))
    # WHAT IS ALREADY DONE SOMEWHERE ELSE, up front. An agent handed 79
    # findings of which 20 have a fix on another branch should know before it
    # starts which 20 -- and the header is where it looks first.
    merged = sum(1 for g in groups for f in g["open"]
                 if (f.get("fixed_elsewhere") or {}).get("in_this_branch") is True)
    pending = sum(1 for g in groups for f in g["open"]
                  if (f.get("fixed_elsewhere") or {}).get("in_this_branch") is False)
    if merged or pending:
        bits = []
        if merged:
            bits.append(f"{merged} whose fix is already in the branch (re-analyse before touching them)")
        if pending:
            bits.append(f"{pending} fixed on another branch but not yet in this one")
        out.append("- **Fixed elsewhere:** " + "; ".join(bits))
    shown = meta.get("shown_on_screen")
    if shown is not None and shown != open_n:
        out.append(f"- **The screen was showing {shown} of these.** Filters and the"
                   " project's severity floor are NOT applied to this document:"
                   " it carries everything recorded.")
    else:
        out.append("- Filters and the project's severity floor are not applied to"
                   " this document: it carries everything recorded.")
    return out


def _consolidated_groups(rows, branch_meta):
    """`rows` (queries.finding_rows, every page) grouped by branch, each group
    split into open and resolved and each list ordered.

    ORDER IS PART OF THE CONTRACT: branch alphabetically, then severity worst
    first, then fingerprint. The last key is not decoration -- without a total
    order, two exports of an unchanged project differ in the order of two
    equally severe findings, and the first thing anyone does with two of these
    files is diff them.
    """
    sev_rank = {s: i for i, s in enumerate(SEVERITIES)}
    by_branch = {}
    for r in rows:
        by_branch.setdefault(r["branch"], []).append(r)
    groups = []
    for br in sorted(set(list(by_branch) + list(branch_meta))):
        items = sorted(by_branch.get(br, []),
                       key=lambda r: (sev_rank.get(r["severity"], len(SEVERITIES)),
                                      r["fingerprint"]))
        m = branch_meta.get(br, {})
        groups.append({"branch": br, "analysis": m,
                       "open": [r for r in items if r["state"] not in RESOLVED_STATES],
                       "resolved": [r for r in items if r["state"] in RESOLVED_STATES]})
    return groups


def _consolidated_finding_md(f, branch):
    """One finding, with everything an agent needs to act and nothing it does
    not. The fingerprint leads because it is the identity that survives
    branches and analyses, and it is what the agent quotes back when it
    reports what it fixed."""
    out = [f"#### [{f['severity']}] {f['title']}", "",
           f"- **Fingerprint:** `{f['fingerprint']}`",
           f"- **Branch:** `{branch}`",
           f"- **State:** {f['state']} · **Rule:** `{f['rule']}` ({f['category']})"]
    if f.get("cwe"):
        out.append(f"- **Class:** {f['cwe']}"
                   + (f" · OWASP {f['owasp']}" if f.get("owasp") else ""))
    if f.get("scope"):
        out.append(f"- **Scope:** {_scope_label(f['scope'])}")
    out += _fixed_elsewhere_md(f)
    # WHERE, before WHY. An agent opens files; a location it can pass straight
    # to an editor is worth more than a paragraph it has to parse for one.
    if f.get("occurrences"):
        out.append("- **Where:**")
        out += [f"    - `{o['file']}`" + (f":{o['line']}" if o.get("line") else "")
                for o in f["occurrences"]]
    if f.get("rationale"):
        out += ["", f["rationale"]]
    if f.get("remediation"):
        out += ["", f"**Remediation:** {f['remediation']}"]
    out.append("")
    return out


def _fixed_elsewhere_md(f):
    """One line, or none. Three sentences for three facts, and the one that
    matters most -- "the fix is already here, re-analyse" -- is the one an
    agent must read before it starts editing."""
    fe = f.get("fixed_elsewhere")
    if not fe:
        return []
    where = f"`{fe.get('branch', '?')}`" + (f" at `{fe['commit'][:12]}`" if fe.get("commit") else "")
    if fe.get("in_this_branch") is True:
        return [f"- **Fixed elsewhere:** fixed on {where}, and that commit is ALREADY in this"
                " branch — very likely resolved here too; re-analyse this branch before"
                " doing anything."]
    if fe.get("in_this_branch") is False:
        return [f"- **Fixed elsewhere:** fixed on {where}, not yet in this branch — see"
                " that fix before writing a new one."]
    return [f"- **Fixed elsewhere:** fixed on {where}; whether it is in this branch could"
            f" not be determined ({fe.get('unknown_reason', 'unknown')})."]


def consolidated_as_markdown(project, groups, meta):
    """Every finding of `project`, by branch, for a reader with no context."""
    out = [f"# Findings — {project}", ""]
    out += _consolidated_meta_lines(project, groups, meta)
    out += ["",
            "Each finding below names the branch it was found on and the commit that"
            " branch was analysed at. Apply a fix on that branch; a fix made"
            " elsewhere is not recorded against this finding until that branch is"
            " analysed again.",
            ""]
    for g in groups:
        a = g["analysis"] or {}
        at = f" at `{a['commit_sha'][:12]}`" if a.get("commit_sha") else ""
        prof = f" · {a['profile']}" if a.get("profile") else ""
        out += [f"## `{g['branch']}`{at}{prof}", ""]
        if not g["open"] and not g["resolved"]:
            # A CLEAN BRANCH IS SAID, NEVER OMITTED. An agent that does not see
            # a branch cannot tell "nothing to do here" from "nobody looked",
            # and those two call for opposite actions.
            out += ["_No findings recorded on this branch._", ""]
            continue
        if g["open"]:
            out += [f"### Open — {len(g['open'])}", ""]
            for f in g["open"]:
                out += _consolidated_finding_md(f, g["branch"])
        if g["resolved"]:
            out += [f"### Resolved on this branch — {len(g['resolved'])} (no action needed)", ""]
            for f in g["resolved"]:
                out += [f"- [{f['severity']}] {f['title']} — {f['state']}"
                        f" · `{f['fingerprint'][:12]}`"]
            out.append("")
    return "\n".join(out)


def consolidated_as_json(project, groups, meta):
    """The same document for a reader that parses. Same order, same content:
    two renderers over one grouping, never two groupings."""
    doc = {"project": project,
           "exported_at": int(meta.get("at") or time.time()),
           "filters_applied": False,
           "severity_floor_applied": False,
           "shown_on_screen": meta.get("shown_on_screen"),
           "branches": []}
    for g in groups:
        a = g["analysis"] or {}
        doc["branches"].append({
            "branch": g["branch"],
            "analysis_id": a.get("id"),
            "commit_sha": a.get("commit_sha", ""),
            "profile": a.get("profile", ""),
            "open": [_consolidated_finding_json(f, g["branch"]) for f in g["open"]],
            "resolved": [_consolidated_finding_json(f, g["branch"]) for f in g["resolved"]]})
    return json.dumps(doc, indent=2, sort_keys=False)


def _consolidated_finding_json(f, branch):
    return {"fingerprint": f["fingerprint"], "branch": branch,
            "severity": f["severity"], "state": f["state"],
            "category": f["category"], "rule": f["rule"], "title": f["title"],
            "cwe": f.get("cwe", ""), "owasp": f.get("owasp", ""),
            "scope": f.get("scope", ""),
            "occurrences": [{"file": o["file"], "line": o.get("line")}
                            for o in f.get("occurrences", [])],
            "rationale": f.get("rationale", ""),
            "remediation": f.get("remediation", ""),
            "first_seen": f.get("first_seen", 0),
            "analysis_id": f.get("analysis_id"),
            "fixed_elsewhere": f.get("fixed_elsewhere")}


def consolidated_as_html(project, groups, meta):
    """The same document as HTML, for a reader with a browser and no editor.
    Same grouping, same order, same header: one grouping, three renderers."""
    e = html.escape
    lines = _consolidated_meta_lines(project, groups, meta)
    parts = [f"<!doctype html><meta charset=utf-8><title>Findings — {e(project)}</title>"
             f"<style>{_CSS}</style>",
             f"<h1>Findings — {e(project)}</h1>", "<ul>"]
    # The header lines are Markdown-shaped (`- **Label:** value`); strip the
    # emphasis rather than render it, so the two renderers share one source
    # of truth for what the header says.
    for ln in lines:
        parts.append(f"<li>{e(ln.lstrip('- ').replace('**', ''))}</li>")
    parts += ["</ul>",
              "<p>Each finding below names the branch it was found on and the commit"
              " that branch was analysed at. Apply a fix on that branch; a fix made"
              " elsewhere is not recorded against this finding until that branch is"
              " analysed again.</p>"]
    for g in groups:
        a = g["analysis"] or {}
        at = f" at <code>{e(a['commit_sha'][:12])}</code>" if a.get("commit_sha") else ""
        prof = f" · {e(a['profile'])}" if a.get("profile") else ""
        parts.append(f"<h2><code>{e(g['branch'])}</code>{at}{prof}</h2>")
        if not g["open"] and not g["resolved"]:
            parts.append('<p class="note">No findings recorded on this branch.</p>')
            continue
        if g["open"]:
            parts.append(f"<h3>Open — {len(g['open'])}</h3>")
            for f in g["open"]:
                locs = "".join(f"<li><code>{e(o['file'])}</code>"
                               + (f":{int(o['line'])}" if o.get("line") else "") + "</li>"
                               for o in f.get("occurrences", []))
                cls = (f"<p>Class: {e(f['cwe'])}"
                       + (f" · OWASP {e(f['owasp'])}" if f.get("owasp") else "") + "</p>"
                       if f.get("cwe") else "")
                scope = (f"<p>Scope: {e(_scope_label(f['scope']))}</p>" if f.get("scope") else "")
                fe_lines = _fixed_elsewhere_md(f)
                fe = (f'<p class="note">{e(fe_lines[0].lstrip("- ").replace("**", ""))}</p>'
                      if fe_lines else "")
                parts.append(
                    f'<div class="f {e(f["severity"])}"><h4>[{e(f["severity"])}] {e(f["title"])}</h4>'
                    f"<p>Fingerprint <code>{e(f['fingerprint'])}</code> · Branch"
                    f" <code>{e(g['branch'])}</code> · {e(f['state'])}</p>"
                    f"<p>Rule <code>{e(f['rule'])}</code> ({e(f['category'])})</p>"
                    f"{cls}{scope}{fe}"
                    + (f"<ul>{locs}</ul>" if locs else "")
                    + (f"<p>{e(f['rationale'])}</p>" if f.get("rationale") else "")
                    + (f"<p><strong>Remediation:</strong> {e(f['remediation'])}</p>"
                       if f.get("remediation") else "")
                    + "</div>")
        if g["resolved"]:
            parts.append(f"<h3>Resolved on this branch — {len(g['resolved'])} (no action needed)</h3><ul>")
            for f in g["resolved"]:
                parts.append(f"<li>[{e(f['severity'])}] {e(f['title'])} — {e(f['state'])}"
                             f" · <code>{e(f['fingerprint'][:12])}</code></li>")
            parts.append("</ul>")
    return "".join(parts)


def consolidated_sboms(project, entries, meta):
    """One document carrying the SBOM of each branch's latest analysis.

    NOT a merged CycloneDX. Two branches' inventories are two inventories --
    merging them would claim a dependency set no commit ever held -- so this
    wraps them side by side, each under its branch and the analysis it came
    from, and says so in the envelope. A branch whose analysis stored no SBOM
    (no lockfile in the tree) is listed with `sbom: null` rather than left
    out, for the reason the Markdown lists a clean branch: absence has to be
    said, or a reader cannot tell "no inventory" from "not looked at".
    """
    doc = {"project": project,
           "exported_at": int(meta.get("at") or time.time()),
           "format": "one CycloneDX document per branch, side by side; not a merge",
           "branches": [{"branch": en["branch"], "analysis_id": en.get("analysis_id"),
                         "commit_sha": en.get("commit_sha", ""),
                         "sbom": en.get("sbom")}
                        for en in sorted(entries, key=lambda x: x["branch"])]}
    return json.dumps(doc, indent=2)
