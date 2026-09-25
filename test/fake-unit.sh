# test/fake-unit.sh -- sourced by test/fake-claude, test/fake-codex and
# test/fake-opencode: how a stand-in plays ONE UNIT of a security analysis
# (bin/security/orchestrator.py launches each unit as an ordinary run of the
# derived job, with a prompt minted by `agentloop security unit-prompt`).
#
# Played well enough for the engine's judgement (bin/security/units.py) to
# see the unit's job done -- never better: what each kind leaves is what a
# real session's tool calls and ledger writes would leave, and the proof is
# the engine's to draw from them.
#   read    the platform's own reading: fake-claude and fake-opencode emit
#           Read results in their CLI's stream shape; fake-codex has no read
#           tool and calls `agentloop security read` chunk by chunk (see
#           fake_unit_serve_reads). FAKE_READ_NOTHING=1 reads nothing at all;
#           FAKE_SKIP_READ_ONCE=<dir> leaves the LAST range unread the first
#           time a unit at attempt 1 runs
#   triage  re-reports every [scanner] row and every [carried] non-sast row
#           exactly as shown (every location; a scanner row with a
#           confidence), and says a [carried] sast row is gone (`report-gone`)
#           -- but only after reading every file that row is in (the real
#           triage prompt requires it, and the judge fails a `gone` claim
#           closed without it: see fake_unit_triage_gone_specs), through the
#           same proof the platform uses for a read unit. A file already
#           gone from the checkout is its own proof and needs no read.
#   verify  writes a `confirmed` verdict through the door
#   hunt    FAKE_HUNT_FINDING=1 reports one sast finding (so a verify unit is
#           planned); otherwise nothing but the run's ending
#
# The prompt is found by its header on ANY line: run_job puts the project's
# description in front of it when the project has one.

fake_unit_init() { # fake_unit_init <prompt> -> sets FAKE_UNIT_KIND ('' outside a unit)
  FAKE_UNIT_PROMPT="$1"
  FAKE_UNIT_KIND=""
  FAKE_UNIT_AL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/agentloop"
  [ -n "${AL_SECURITY_UNIT_ID:-}" ] || return 0
  FAKE_UNIT_KIND="$(printf '%s\n' "$1" | LC_ALL=C sed -n 's/^SECURITY ANALYSIS [0-9]* · unit \([a-z]*\).*/\1/p' | head -1)"
}

# One "path:first-last" per line: the RANGES block of a read unit's prompt,
# less what FAKE_READ_NOTHING / FAKE_SKIP_READ_ONCE leave out.
fake_unit_ranges() {
  local ranges
  [ -z "${FAKE_READ_NOTHING:-}" ] || return 0
  ranges="$(printf '%s\n' "$FAKE_UNIT_PROMPT" | awk '/^RANGES /{on=1; next} on && /^  [^ ]/{print $1; next} on{exit}')"
  if [ -n "${FAKE_SKIP_READ_ONCE:-}" ] && [ ! -e "$FAKE_SKIP_READ_ONCE/unit-$AL_SECURITY_UNIT_ID" ] \
     && ! printf '%s\n' "$FAKE_UNIT_PROMPT" | grep -q '^SECURITY ANALYSIS [0-9]* · unit .* attempt [0-9]'; then
    mkdir -p "$FAKE_SKIP_READ_ONCE"; : > "$FAKE_SKIP_READ_ONCE/unit-$AL_SECURITY_UNIT_ID"
    ranges="$(printf '%s\n' "$ranges" | sed '$d')"
  fi
  printf '%s\n' "$ranges"
}

# The Codex way of reading: `agentloop security read`, one chunk per call,
# each range from its first line until the footer says the range is behind
# it or the file has ended. The ledger's record of what was served is the
# only proof of reading on that platform (security/evidence.py).
# fake_unit_serve_reads [specs] -- specs is one "path:first-last" per line,
# the same shape fake_unit_ranges and fake_unit_triage_gone_specs both
# produce; omitted defaults to fake_unit_ranges (a read unit's own RANGES).
fake_unit_serve_reads() {
  local specs spec path span from last out next guard
  if [ $# -ge 1 ]; then specs="$1"; else specs="$(fake_unit_ranges)"; fi
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    path="${spec%:*}"; span="${spec##*:}"; from="${span%-*}"; last="${span#*-}"
    guard=0
    while [ "$guard" -lt 1000 ]; do
      guard=$((guard + 1))
      out="$("$FAKE_UNIT_AL" security read --path="$path" --from "$from" 2>&1)" || break
      case "$out" in *"-- end of file"*) break ;; esac
      next="$(printf '%s\n' "$out" | sed -n 's/^-- next: .* --from \([0-9][0-9]*\)$/\1/p' | tail -1)"
      [ -n "$next" ] && [ "$next" -gt "$from" ] || break
      [ "$next" -le "$last" ] || break
      from="$next"
    done
  done <<EOF
$specs
EOF
}

# The rows of a triage unit's prompt, one TSV line each:
# kind, fingerprint, category, rule, severity, title, locations (", "-joined).
_fake_unit_rows() {
  printf '%s\n' "$FAKE_UNIT_PROMPT" | LC_ALL=C awk '
    function emit() { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", kind, fp, cat, rule, sev, title, locs }
    /^  [0-9]+\. \[[a-z]+\] / {
      if (have) emit()
      line = $0; sub(/^  [0-9]+\. \[/, "", line)
      kind = line; sub(/\].*/, "", kind); sub(/^[a-z]+\] /, "", line)
      split(line, a, " · ")
      fp = a[1]; cat = a[2]; sub(/\/.*/, "", cat); rule = a[2]; sub(/^[^\/]*\//, "", rule)
      sev = a[3]; sub(/ .*/, "", sev); locs = a[4]; title = ""
      have = 1; state = 1; next
    }
    have && state == 1 { title = $0; sub(/^     /, "", title); state = 2; next }
    have && state == 2 && /^     locations \([0-9]+\): / {
      locs = $0; sub(/^     locations \([0-9]+\): /, "", locs); state = 3; next
    }
    have && !/^     / { emit(); have = 0 }
    END { if (have) emit() }'
}

# One "path:1-N" per FILE (deduped), among the rows fake_unit_triage is about
# to mark `gone` (a [carried] sast row): what "Read every file the row is in
# first" (the real triage prompt's own instruction, prompts.py's _triage)
# means for the fake. N is the file's own line count, so the read looks like
# what a session that actually opened the file would leave -- the judge only
# asks that the file be among a unit's reads at all (units.py
# _unread_files), not that every line of it was covered, but a whole-file
# read is the honest stand-in for "read the code". A file already gone from
# the checkout is skipped: absence is its own proof (report-gone's own door,
# and the judge, both read a missing file's gone-ness off `root`, never off
# a session's reads -- see _unread_files' docstring).
fake_unit_triage_gone_specs() {
  local kind fp cat rule sev title locs f lines
  { while IFS="$(printf '\t')" read -r kind fp cat rule sev title locs; do
      [ "$kind" = carried ] && [ "$cat" = sast ] || continue
      printf '%s\n' "$locs" | jq -Rr 'split(", ") | .[]' | sed 's/:[0-9]*$//'
    done <<EOF
$(_fake_unit_rows)
EOF
  } | sort -u | while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$PWD/$f" ] || continue
    lines="$(wc -l < "$PWD/$f" 2>/dev/null | tr -d ' ')"
    case "$lines" in ''|0) lines=1 ;; esac
    printf '%s:1-%s\n' "$f" "$lines"
  done
}

fake_unit_triage() {
  local kind fp cat rule sev title locs occ cand
  while IFS="$(printf '\t')" read -r kind fp cat rule sev title locs; do
    [ -n "$fp" ] || continue
    if [ "$kind" = carried ] && [ "$cat" = sast ]; then
      printf '{"reason":"the fake triage read the code and the finding is gone"}' \
        | "$FAKE_UNIT_AL" security report-gone --analysis "$AL_SECURITY_ANALYSIS_ID" --fingerprint "$fp" >/dev/null 2>&1 || true
      continue
    fi
    occ="$(jq -nc --arg l "$locs" '$l | split(", ") | map(
             if test(":[0-9]+$") then {file: sub(":[0-9]+$"; ""), line: (capture(":(?<n>[0-9]+)$").n | tonumber)}
             else {file: .} end)')"
    if [ "$kind" = carried ]; then cand='{}'; else cand='{"confidence":{"score":"high","reason":"the fake triage read it"}}'; fi
    jq -nc --arg fp "$fp" --arg c "$cat" --arg r "$rule" --arg s "$sev" --arg t "$title" \
           --argjson occ "$occ" --argjson cand "$cand" \
      '{fingerprint:$fp, category:$c, rule:$r, severity:$s, title:$t,
        rationale:"the fake triage read it", occurrences:$occ}
       + (if $cand == {} then {} else {candidate:$cand} end)' \
      | "$FAKE_UNIT_AL" security report-finding --analysis "$AL_SECURITY_ANALYSIS_ID" >/dev/null 2>&1 || true
  done <<EOF
$(_fake_unit_rows)
EOF
}

fake_unit_verify() {
  local fp
  fp="$(printf '%s\n' "$FAKE_UNIT_PROMPT" | sed -n 's/.*report-verdict --analysis [0-9]* --fingerprint \([0-9a-f]\{64\}\).*/\1/p' | head -1)"
  [ -n "$fp" ] || return 0
  printf '{"verdict":"confirmed","reason":"the fake verifier read the code and could not disprove it"}' \
    | "$FAKE_UNIT_AL" security report-verdict --analysis "$AL_SECURITY_ANALYSIS_ID" --fingerprint "$fp" >/dev/null 2>&1 || true
}

fake_unit_hunt() {
  [ -n "${FAKE_HUNT_FINDING:-}" ] || return 0
  jq -nc '{fingerprint:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
           category:"sast", rule:"sql-injection", severity:"high", title:"fake",
           rationale:"the fake hunter concatenated a query", occurrences:[{file:"README", line:1}],
           candidate:{trace:[{kind:"entrypoint", file:"README", line:1, scope:"s", description:"input"},
                             {kind:"sink", file:"README", line:1, scope:"s", description:"execute"}],
                      intended_control:"parameterised queries",
                      confidence:{score:"high", reason:"r"}, likelihood:{score:"high", reason:"r"},
                      impact:{score:"high", reason:"r"}}}' \
    | "$FAKE_UNIT_AL" security report-finding --analysis "$AL_SECURITY_ANALYSIS_ID" >/dev/null 2>&1 || true
}

# The ledger side of every kind but `read`, whose reading each stand-in
# writes into its own stream (or serves, on Codex).
fake_unit_act() {
  case "$FAKE_UNIT_KIND" in
    triage) fake_unit_triage ;;
    verify) fake_unit_verify ;;
    hunt)   fake_unit_hunt ;;
  esac
}
