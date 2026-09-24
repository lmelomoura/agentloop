#!/usr/bin/env bash
# End-to-end drive of the session lifecycle.
#
# WHY THIS EXISTS. `selftest` and the pytest suite are both unit-level: they
# call wt_setup, wt_teardown, the classifier and the sweep directly. Nothing
# had ever driven a whole run through the engine -- precheck, worktree, agent,
# classifier, `.ended`, teardown, resume, expiry -- and the defects that cost
# most on the way here were the ones that only appear when those meet.
#
# The one thing it does NOT exercise is the model, and that is deliberate:
# `test/fake-claude` stands in for the CLI and emits the same stream-json shape,
# so the suite stays offline and free. CONFIG and DATA are redirected into a
# sandbox under this directory, so an operator's real jobs, projects and run
# history are never read or written.
set -u

E2E="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$E2E/.." && pwd)"

# ---------------------------------------------------------------- a sandbox
# Everything that lives under ONE sandbox root: the config and data trees the
# engine is pointed at, the stand-ins, the fake remote and the seed checkout,
# and the two config files every scenario starts from. A function rather than
# top-level code because E2E_WORKERS=4 runs one sandbox PER WORKER, side by
# side under this directory -- the scenarios are independent in their data
# (no job is made twice, no scenario reads another's state) and coupled only
# by this root and by `lastrun`, which asks for its own job (run_of).
#
# NOT INDENTED, deliberately: two heredocs below end on a bare `JSON`, and a
# terminator with two spaces in front of it is not a terminator -- the
# heredoc runs on to the next bare `JSON` in the file and swallows every
# helper and scenario in between as file content. bash -n does not notice.
e2e_sandbox() { # e2e_sandbox <root>
ROOT="$1"
rm -rf "$ROOT"; mkdir -p "$ROOT"/{config,data,remote,work,LaunchAgents}
export AGENTLOOP_CONFIG="$ROOT/config"
export AGENTLOOP_DATA="$ROOT/data"
export AGENTLOOP_CLAUDE_BIN="$E2E/fake-claude"
export AGENTLOOP_CODEX_BIN="$E2E/fake-codex"
export CODEX_HOME="$ROOT/codex-home"        # the stand-in's rollouts; never ~/.codex
export AGENTLOOP_LAUNCH_AGENTS_DIR="$ROOT/LaunchAgents"   # an empty dir: installed_config_dir must never read a developer machine's real pinned install
export AGENTLOOP_OPENCODE_BIN="$E2E/fake-opencode"
export AGENTLOOP_PRICING_URL="file://$REPO/test/fixtures/pricing/litellm-sample.json"
mkdir -p "$CODEX_HOME"
git init -q --bare "$ROOT/remote/origin.git"
git init -q "$ROOT/work/app"
git -C "$ROOT/work/app" remote add origin "$ROOT/remote/origin.git"
printf 'seed\n' > "$ROOT/work/app/README"
git -C "$ROOT/work/app" add -A
git -C "$ROOT/work/app" -c user.email=e2e@local -c user.name=e2e commit -qm seed
git -C "$ROOT/work/app" push -q origin HEAD:refs/heads/main
git -C "$ROOT/work/app" branch -q -M main

cat > "$ROOT/config/projects.json" <<JSON
{"projects":[{"name":"sandbox","cwd":"$ROOT/work/app","base":"main",
              "worktree":{"enabled":true},
              "security":{"enabled":true,"model":"claude-opus-5","max_budget_usd":5}}]}
JSON

# What the operator would have switched on in Settings. Explicit rather than
# seeded: the seed is scenario 28's own subject.
cat > "$ROOT/config/platforms.json" <<'JSON'
{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},
              "openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"]},
              "opencode":{"enabled":true,"bin":"","models":["opencode/big-pickle","pdm_ai/glm-5.3-flash"]}}}
JSON
}

AL="$REPO/bin/agentloop"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# ---------------------------------------------------------------- the fixture

mkjob() { # mkjob <id> <mode>
  E2E_JOB="$1"
  printf '{"jobs":[{"id":"%s","project":"sandbox","enabled":false,"prompt":"do the thing",
    "interval_seconds":3600,"permission_mode":"bypassPermissions","max_parallel":1}]}\n' "$1" \
    > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}

dirs() { ls -1 "$ROOT/data/worktrees/$1" 2>/dev/null | grep -v '^\.' ; }
ended() { cat "$ROOT/data/worktrees/$1/$2/.ended" 2>/dev/null; }

# secid <analyze-stdout> -- the analysis id out of whichever shape it came in:
# bash's own `printf '{"analysis_id":%s}'` (--detach, no space), Python's
# `json.dumps` (open-analysis, a space after the colon), or the one line
# `security analyze` prints as it OPENS the analysis -- before the run starts,
# in the foreground and --detach forms alike:
# `analysis N — project/repo @ branch (sha) — job id`.
secid() { printf '%s\n' "$1" | grep -Eo '"analysis_id" *: *[0-9]+|^analysis [0-9]+' | tail -1 | grep -Eo '[0-9]+$'; }
# secstate <project> <analysis-id> -- that one row's state, straight off the
# ledger `security list` reads, never guessed from the run that carried it.
secstate() {
  "$AL" security list --project "$1" 2>/dev/null \
    | jq -r --argjson a "$2" '.[] | select(.id == $a) | .state // empty'
}
# secnote <project> <analysis-id> -- that row's coverage note, the one line a
# reader has to judge the report's blind spots by.
secnote() {
  "$AL" security list --project "$1" 2>/dev/null \
    | jq -r --argjson a "$2" '.[] | select(.id == $a) | .coverage_note // empty'
}

echo
# ------------------------------------------------ helpers, hoisted
# Defined once, before any scenario. They used to sit where the OpenAI and
# OpenCode scenarios begin, so a worker starting at 20 or 38 had no
# mkjob_openai, no lastrun and no mkjob_opencode until scenario 12 or 28
# had run -- which, in its own sandbox, it never had.

# <index><TAB><argument>. `at <n>` is the n-th argument, `idx <word>` its index.
at()  { awk -F'\t' -v i="$1" '$1==i {print $2; exit}' "$argv"; }

idx() { awk -F'\t' -v w="$1" '$2==w {print $1; exit}' "$argv"; }

mkjob_openai() { # mkjob_openai <id> [permission]
  E2E_JOB="$1"
  printf '{"jobs":[{"id":"%s","project":"sandbox","enabled":false,"platform":"openai","model":"gpt-5.6-sol","effort":"high","prompt":"do the thing",
    "interval_seconds":3600,"permission_mode":"%s","max_parallel":1}]}\n' "$1" "${2:-workspace-write}" \
    > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}

# The run of ONE job -- the last recorded for it -- rather than the last line
# of the journal, which is only the same thing while every scenario runs
# alone in one sandbox in sequence. Scenarios read their own run through
# `lastrun`, which asks for the job the last mkjob* made (E2E_JOB); a scenario
# whose run belongs to a job it did not make (a derived security job) sets
# E2E_JOB itself. Keyed on the record's own `"id":"<job>"` -- record_run
# writes `id` first -- and the closing quote keeps j1 from matching j10.
run_of() { grep -F "\"id\":\"$1\"" "$ROOT/data/runs.ndjson" 2>/dev/null | tail -1; }

lastrun() { run_of "$E2E_JOB"; }

# <index><TAB><argument> readers over a recorded argv file
at_in()  { awk -F'\t' -v i="$2" '$1==i {print $2; exit}' "$1"; }

idx_in() { awk -F'\t' -v w="$2" '$2==w {print $1; exit}' "$1"; }

mkjob_opencode() { # mkjob_opencode <id> [permission] [model] [extra-json-fields]
  E2E_JOB="$1"
  printf '{"jobs":[{"id":"%s","project":"sandbox","enabled":false,"platform":"opencode","model":"%s","effort":"high","prompt":"do the thing",
    "interval_seconds":3600,"permission_mode":"%s","max_parallel":1%s}]}\n' "$1" "${3:-pdm_ai/glm-5.3-flash}" "${2:-full-access}" "${4:-}" \
    > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}

# mkjob_acct <id> <account> [platform] -- a job of the sandbox project on one
# of the platform's accounts (the account must be registered first).
mkjob_acct() {
  E2E_JOB="$1"
  jq -nc --arg id "$1" --arg a "$2" --arg p "${3:-anthropic}" \
    '{jobs:[{id:$id, project:"sandbox", enabled:false, prompt:"do the thing", interval_seconds:3600,
             platform:$p, model:(if $p == "openai" then "gpt-5.6-sol" else "claude-opus-5" end),
             permission_mode:(if $p == "openai" then "workspace-write" else "bypassPermissions" end),
             max_parallel:1, account:$a}]}' > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}

scenario_1() {
echo "1. a run that declares a clean ending is torn down and removed"
mkjob j1 complete
FAKE_MODE=complete FAKE_SESSION=sess-clean "$AL" run j1 >/dev/null 2>&1
sleep 2
[ -z "$(dirs j1)" ] && ok "its run directory is gone" || bad "left $(dirs j1)"

echo
}

scenario_2() {
echo "2. a run that never declares an ending keeps its tree, marked open"
mkjob j2 undeclared
FAKE_MODE=undeclared FAKE_SESSION=sess-cut "$AL" run j2 >/dev/null 2>&1
sleep 2
d2="$(dirs j2 | head -1)"
[ -n "$d2" ] && ok "its run directory survives ($d2)" || bad "the directory was removed"
[ "$(ended j2 "$d2")" = "open" ] && ok "and is marked open" || bad "marked '$(ended j2 "$d2")'"
[ "$(cat "$ROOT/data/worktrees/j2/$d2/.session" 2>/dev/null)" = "sess-cut" ] \
  && ok "with the session bound to it" || bad "session not bound"

echo
}

scenario_3() {
echo "3. a resume continues in that same directory, not a fresh one"
FAKE_MODE=complete FAKE_SESSION=sess-cut "$AL" resume j2 sess-cut >/dev/null 2>&1
sleep 2
grep -q "resumed sess-cut in its own tree" "$ROOT/data/tick.log" 2>/dev/null \
  && ok "the tick log says it reattached" || bad "no reattach line in tick.log"
[ -z "$(dirs j2)" ] && ok "and the finished session took its directory with it" \
  || bad "left $(dirs j2)"
# The Precheck tab's note used to call this "RUN FORCED (Run now)": forced it
# is, but nobody pressed Run now -- see scenario 44 for the rest of the rule.
pc3="$(lastrun | jq -r .log)"; pc3="${pc3%.json}.precheck.txt"
grep -q '^RUN FORCED (resume of session sess-cut)' "$pc3" 2>/dev/null \
  && ok "and its precheck note names the session it resumed, not Run now" || bad "note: $(cat "$pc3" 2>/dev/null)"

echo
}

scenario_4() {
echo "4. work on no remote is reported, and the tree is still kept"
mkjob j3 dirty
FAKE_MODE=dirty FAKE_SESSION=sess-dirty "$AL" run j3 >/dev/null 2>&1
sleep 2
d3="$(dirs j3 | head -1)"
[ -n "$d3" ] && ok "the directory survives" || bad "removed despite undelivered work"
grep -q 'UNDELIVERED' "$ROOT/data/runs.ndjson" 2>/dev/null \
  && ok "and the run says UNDELIVERED" || bad "no UNDELIVERED note in the journal"

echo
}

scenario_5() {
echo "5. an open session nobody resumes expires and is reclaimed"
AGENTLOOP_SESSION_TTL=0 "$AL" tick >/dev/null 2>&1
sleep 1
[ -z "$(dirs j3)" ] && ok "the sweep reclaimed it once its ttl was up" \
  || bad "still there: $(dirs j3)"
grep -q 'expired after' "$ROOT/data/tick.log" 2>/dev/null \
  && ok "and said so in the tick log" || bad "nothing in tick.log about the expiry"

echo
}

scenario_6() {
echo "6. a directory from before this version is adopted, not deleted"
mkdir -p "$ROOT/data/worktrees/j4/20200101T000000Z-1/app"
git init -q "$ROOT/data/worktrees/j4/20200101T000000Z-1/app"
echo "work nobody else has" > "$ROOT/data/worktrees/j4/20200101T000000Z-1/app/keep.txt"
touch -t 202001010000 "$ROOT/data/worktrees/j4/20200101T000000Z-1"
"$AL" tick >/dev/null 2>&1
sleep 1
[ -f "$ROOT/data/worktrees/j4/20200101T000000Z-1/app/keep.txt" ] \
  && ok "the pre-upgrade directory and its work survive the first tick" \
  || bad "an upgrade deleted a retained directory"
[ "$(ended j4 20200101T000000Z-1)" = "open" ] \
  && ok "adopted as open, with a fresh clock" || bad "marked '$(ended j4 20200101T000000Z-1)'"

echo
}

scenario_7() {
echo "7. a slot from a previous boot holds nothing"
mkdir -p "$ROOT/data/locks/j5/99999"
echo "$$" > "$ROOT/data/locks/j5/99999/pid"
echo "0"   > "$ROOT/data/locks/j5/99999/boot"
mkdir -p "$ROOT/data/worktrees/j5/stamp-stale"
echo done > "$ROOT/data/worktrees/j5/stamp-stale/.ended"
echo "$ROOT/data/worktrees/j5/stamp-stale" > "$ROOT/data/locks/j5/99999/worktree"
"$AL" tick >/dev/null 2>&1
sleep 1
[ -z "$(dirs j5)" ] && ok "a live pid from an earlier boot does not protect it" \
  || bad "the stale claim kept it alive"

# ------------------------------------------------------- security analysis
# The `sandbox` project's own security block (see the fixture above). Unlike
# 1-7, these drive `agentloop security analyze` rather than `run` -- the
# real path the dashboard's Analyse button takes, over the real run_job and a
# real (fake) agent, not the stubbed run_job the bash-level selftest uses for
# the same three shapes.

echo
}

scenario_8() {
echo "8. a detached security analysis returns fast, and the run closes it once it ends"
t0=$(date +%s)
out8="$(FAKE_MODE=complete FAKE_SESSION=sess-sec-done "$AL" security analyze --detach sandbox anything main quick)"
t1=$(date +%s)
[ "$((t1 - t0))" -lt 5 ] && ok "the command returns in $((t1 - t0))s -- not after the run it started" \
  || bad "--detach blocked for $((t1 - t0))s"
aid8="$(secid "$out8")"
[ -n "$aid8" ] && ok "and prints the analysis id it opened: $aid8" || bad "no analysis id in: $out8"
w=0
while [ "$w" -lt 90 ] && [ "$(secstate sandbox "$aid8")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid8")" = "done" ] \
  && ok "and the row closes done once the detached run actually finishes (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid8")' after ${w}s"
# The Precheck tab's note used to read "RUN FORCED (Run now)" over "(no
# precheck configured — every due tick runs the agent)" for this run: both
# false for a derived job, which no tick ever launches and nobody pressed
# Run now for -- see scenario 44 for the rest of the rule.
# secstate above reads the ledger, which the analysis itself closes the
# moment it ends; run_of reads runs.ndjson, written separately by run_job's
# own record_run -- the two are not one atomic step, so a row already "done"
# can still be a moment away from having a journal record at all. Bounded,
# not a fixed sleep: wait only as long as it actually takes.
wlog=0
while [ "$wlog" -lt 90 ] && [ -z "$(run_of security-sandbox | jq -r '.log // empty')" ]; do sleep 1; wlog=$((wlog + 1)); done
pc8="$(run_of security-sandbox | jq -r .log)"; pc8="${pc8%.json}.precheck.txt"
grep -q "^SECURITY ANALYSIS $aid8 — launched by" "$pc8" 2>/dev/null && ! grep -q 'every due tick' "$pc8" 2>/dev/null \
  && ok "and the run's precheck note names analysis $aid8 and the command that launched it, never a tick" \
  || bad "note (waited ${wlog}s for the journal record): $(cat "$pc8" 2>/dev/null)"
sleep 1   # let run_job's own teardown release the derived job's slot before the next scenario

echo
}

scenario_9() {
echo "9. an agent that dies on launch still closes its analysis -- failed, not stuck running"
cat > "$ROOT/dead-claude" <<'SH'
#!/usr/bin/env bash
exit 3
SH
chmod +x "$ROOT/dead-claude"
out9="$(AGENTLOOP_CLAUDE_BIN="$ROOT/dead-claude" "$AL" security analyze --detach sandbox anything main quick)"
aid9="$(secid "$out9")"
w=0
while [ "$w" -lt 20 ] && [ "$(secstate sandbox "$aid9")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid9")" = "failed" ] \
  && ok "a claude that exits without a word still closes the row failed (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid9")' after ${w}s"
sleep 1

echo
}

scenario_10() {
echo "10. a row stuck 'running' with no live run cannot brick the button"
sha="$(git -C "$ROOT/work/app" rev-parse HEAD)"
stuck_out="$("$AL" security open-analysis --project sandbox --repo sandbox --branch main \
  --commit "$sha" --profile quick --run-id security-sandbox)"
stuck_id="$(secid "$stuck_out")"
[ "$(secstate sandbox "$stuck_id")" = "running" ] \
  && ok "the stuck row starts out running, exactly like a real one" \
  || bad "open-analysis did not open row $stuck_id running"
# The default grace (120s) would leave a row this young alone -- it may still
# be on its way to acquire_slot -- so the sweep is forced to fire immediately.
AGENTLOOP_SECURITY_STALE_GRACE=0 FAKE_MODE=complete FAKE_SESSION=sess-sec-fresh \
  "$AL" security analyze sandbox anything main quick >/dev/null 2>&1
[ "$(secstate sandbox "$stuck_id")" = "failed" ] \
  && ok "the next analyse's own preflight sweeps it before opening a fresh one" \
  || bad "stuck row $stuck_id left '$(secstate sandbox "$stuck_id")'"

echo
}

scenario_11() {
echo "11. an agent that never ran the deterministic phases cannot close done"
# Nothing engine-side runs `prepare` on Claude Code (on Codex the engine does
# -- scenario 24). An agent that skips its first command
# exits cleanly, so the engine's own close-out closes the row with `success` --
# and the result was a `done` analysis with no findings, no coverage note and
# no banner, which then became the baseline every later analysis is diffed
# against. The whole path is exercised here, over the real run_job: only the
# LEDGER can tell the two apart, and only after the run has ended.
out11="$(FAKE_MODE=complete FAKE_SKIP_PREPARE=1 FAKE_SESSION=sess-sec-noprep \
  "$AL" security analyze --detach sandbox anything main quick)"
aid11="$(secid "$out11")"
w=0
while [ "$w" -lt 20 ] && [ "$(secstate sandbox "$aid11")" = "running" ]; do sleep 1; w=$((w + 1)); done
[ "$(secstate sandbox "$aid11")" = "capped" ] \
  && ok "a run whose agent skipped prepare closes capped, not done (waited ${w}s)" \
  || bad "left '$(secstate sandbox "$aid11")' after ${w}s -- expected capped"
case "$(secnote sandbox "$aid11")" in
  *"deterministic phases never ran"*) ok "and the report says why, in the coverage note" ;;
  *) bad "no coverage note explaining the downgrade: '$(secnote sandbox "$aid11")'" ;;
esac

echo
}

scenario_12() {
echo "12. the analysis is launched with the Agent tool closed and its prompt intact"
# THE ONE SCENARIO THAT READS AN ARGV. Everything above steers `fake-claude` by
# env var and never looks at how it was invoked -- which is why this suite was
# green while every real analysis died at launch: `--disallowedTools` is
# variadic, it sat immediately before the prompt positional, Commander ate the
# prompt as a second tool name, and the real CLI exited with "Input must be
# provided either through stdin or as a prompt argument when using --print".
# Here the derived security job goes down the real `security analyze` path and
# the launch line is read back off the stand-in's own "$@".
argv="$ROOT/launch-argv"
rm -f "$argv"
FAKE_ARGV_OUT="$argv" FAKE_MODE=complete FAKE_SESSION=sess-sec-argv \
  "$AL" security analyze sandbox anything main quick >/dev/null 2>&1
argc="$(awk -F'\t' '$1=="ARGC" {print $2; exit}' "$argv" 2>/dev/null)"
# Since block 4.2 the launch closes NOTHING: the verification phase is
# subagents, and what keeps them honest is the close counting them against the
# verdicts in the ledger, not a flag at launch. `--max-budget-usd` is read
# beside it so an argv that lost every flag fails here rather than passing for
# the wrong reason.
di="$(idx '--disallowedTools' 2>/dev/null)"
mb="$(idx '--max-budget-usd' 2>/dev/null)"
[ -z "${di:-}" ] && [ -n "${mb:-}" ] \
  && ok "the real analysis launch closes no tool, and still carries its budget cap" \
  || bad "unexpected --disallowedTools in the launch argv: $(tr '\n' ' ' < "$argv" 2>/dev/null)"
mi="$(idx '--' 2>/dev/null)"
[ -n "${mi:-}" ] && [ "$((mi + 1))" = "${argc:-0}" ] \
  && ok "and its prompt is the one argument after --, not swallowed by the variadic flag" \
  || bad "the prompt is not a lone positional after -- (-- at '${mi:-none}', argc '${argc:-none}')"

# ------------------------------------------------------- the OpenAI platform
# The same lifecycle over the Codex stand-in: the run goes down a FIFO into
# the normalizer, the classifier reads the normalized stream, the rollout
# under the sandboxed CODEX_HOME exported at the top of this file supplies the
# model that ran.
cp "$REPO/config/pricing.example.json" "$ROOT/config/pricing.json"
# The catalog a slug is validated against, obtained the way a real install
# obtains it: `resolve-models openai` asks the CLI for `debug models`.
"$AL" resolve-models openai >/dev/null 2>&1
jq -e '.openai.models | length > 0' "$ROOT/config/models.json" >/dev/null \
  && ok "resolve-models openai wrote the catalog from the stand-in's debug models" \
  || bad "no openai catalog after resolve-models"
jq -e '([.openai.models[] | select(.visibility=="list") | .slug] | index("gpt-reserve")) == null' \
  "$ROOT/config/models.json" >/dev/null \
  && ok "the hidden gpt-reserve never reaches the visible slug list" \
  || bad "gpt-reserve leaked into the visible models"
jq -e '(.openai.models[] | select(.slug=="gpt-5.6-sol") | .efforts | index("ultra")) != null' \
  "$ROOT/config/models.json" >/dev/null \
  && ok "gpt-5.6-sol's efforts include ultra" \
  || bad "gpt-5.6-sol has no ultra effort"

echo
}

scenario_13() {
echo "13. an OpenAI run goes through the Codex stand-in and reads as a clean success"
mkjob_openai j13
FAKE_MODE=complete FAKE_SESSION=thr-clean "$AL" run j13 >/dev/null 2>&1
sleep 2
[ -z "$(dirs j13)" ] && ok "its run directory is gone (declared ending, nothing undelivered)" || bad "left $(dirs j13)"
[ "$(lastrun | jq -r .status)" = "success" ] \
  && ok "status success: the CLI's stdin line was filtered out of stderr" \
  || bad "status $(lastrun | jq -r .status): $(lastrun | jq -r .note)"
[ "$(lastrun | jq -r .session)" = "thr-clean" ] && ok "the session recorded is the thread id" || bad "session $(lastrun | jq -r .session)"
[ "$(lastrun | jq -r .model_id)" = "gpt-5.6-sol-real" ] \
  && ok "model_id is the model the rollout says ran, not the slug asked for" || bad "model_id $(lastrun | jq -r .model_id)"
[ "$(lastrun | jq -r .platform)" = "openai" ] && ok "the journal names the platform" || bad "platform $(lastrun | jq -r .platform)"
[ "$(lastrun | jq -r .cost_basis)" = "estimated" ] && [ "$(lastrun | jq -r .cost)" = "0.031784" ] \
  && ok "the cost is the estimate from the seeded price table (\$0.031784 for 32,675 in / 28,160 cached / 123 out)" \
  || bad "cost $(lastrun | jq -c '{cost,cost_basis}')"
[ "$(lastrun | jq -r '.tokens.input')" = "32675" ] && [ "$(lastrun | jq -r '.tokens.reasoning')" = "0" ] \
  && ok "the token counts ride on the record" || bad "tokens $(lastrun | jq -c .tokens)"
s13="$(ls "$ROOT"/data/logs/j13/*.stream.ndjson 2>/dev/null | head -1)"
[ -f "$s13.raw" ] && grep -q '"thread.started"' "$s13.raw" \
  && ok "the raw Codex stream is kept beside the normalized one" || bad "no .raw copy"
head -1 "$s13" | jq -e '.subtype=="init" and .platform=="openai"' >/dev/null 2>&1 \
  && ok "the normalized stream opens with the init event" || bad "first line: $(head -1 "$s13")"
[ ! -e "$ROOT"/data/logs/j13/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"
# The sandbox's CODEX_HOME is not ~/.codex: the Default's windows are keyed
# by that home, like any other account's.
jq -e --arg k "openai@$CODEX_HOME" '.[$k].five_hour.utilization == 0.05 and .[$k].five_hour.source == "rollout"' "$ROOT/data/rate-limits.json" >/dev/null 2>&1 \
  && ok "the run's rollout fed the openai usage windows" || bad "rate-limits.json: $(cat "$ROOT/data/rate-limits.json" 2>/dev/null)"

echo
}

scenario_14() {
echo "14. an OpenAI run that never declares an ending keeps its tree, bound to the thread id"
mkjob_openai j14
FAKE_MODE=undeclared FAKE_SESSION=thr-cut "$AL" run j14 >/dev/null 2>&1
sleep 2
d14="$(dirs j14 | head -1)"
[ -n "$d14" ] && [ "$(ended j14 "$d14")" = "open" ] && ok "kept, marked open" || bad "dir '$d14' ended '$(ended j14 "$d14")'"
[ "$(cat "$ROOT/data/worktrees/j14/$d14/.session" 2>/dev/null)" = "thr-cut" ] \
  && ok ".session holds the thread id" || bad ".session not bound to the thread"

echo
}

scenario_15() {
echo "15. a resume of that thread reattaches, and launches as exec resume in the process cwd"
argv15="$ROOT/argv-15"; rm -f "$argv15"
FAKE_ARGV_OUT="$argv15" FAKE_MODE=complete FAKE_SESSION=thr-cut "$AL" resume j14 thr-cut >/dev/null 2>&1
sleep 2
grep -q "resumed thr-cut in its own tree" "$ROOT/data/tick.log" && ok "the tick log says it reattached" || bad "no reattach line"
[ -z "$(dirs j14)" ] && ok "and the finished session took its directory with it" || bad "left $(dirs j14)"
[ "$(at_in "$argv15" 1)" = "exec" ] && [ "$(at_in "$argv15" 2)" = "resume" ] \
  && ok "argv opens with exec resume" || bad "argv: $(tr '\n' ' ' < "$argv15")"
[ -z "$(idx_in "$argv15" -C)" ] && ok "no -C on a resume (exec resume refuses it; the cwd is the process's)" || bad "-C passed to exec resume"
[ -n "$(idx_in "$argv15" sandbox_mode=workspace-write)" ] && ok "the sandbox travels as -c sandbox_mode=…" || bad "no sandbox_mode override"
ti="$(idx_in "$argv15" thr-cut)"; mi="$(idx_in "$argv15" --)"
[ -n "$ti" ] && [ -n "$mi" ] && [ "$ti" -lt "$mi" ] \
  && ok "the thread id precedes --, and the prompt follows it" || bad "thread id at '$ti', -- at '$mi'"

echo
}

scenario_16() {
echo "16. work on no remote is reported for an OpenAI run too"
mkjob_openai j16
FAKE_MODE=dirty FAKE_SESSION=thr-dirty "$AL" run j16 >/dev/null 2>&1
sleep 2
lastrun | grep -q 'UNDELIVERED' && [ -n "$(dirs j16)" ] && ok "UNDELIVERED, and the tree is kept" || bad "no UNDELIVERED note, or tree gone"

echo
}

scenario_17() {
echo "17. the launch line of a fresh OpenAI run, read back off the stand-in's argv"
argv17="$ROOT/argv-17"; rm -f "$argv17"
mkjob_openai j17 read-only
FAKE_ARGV_OUT="$argv17" FAKE_MODE=complete FAKE_SESSION=thr-argv "$AL" run j17 >/dev/null 2>&1
sleep 1
argc17="$(awk -F'\t' '$1=="ARGC" {print $2; exit}' "$argv17")"
[ "$(at_in "$argv17" 1)" = "exec" ] && [ "$(at_in "$argv17" 2)" = "--json" ] && ok "exec --json" || bad "argv: $(tr '\n' ' ' < "$argv17")"
ci="$(idx_in "$argv17" -C)"; cwd17="$(at_in "$argv17" $((ci + 1)))"
# Asserted on the PATH, not with `-d`: this run declares a clean ending, so its
# worktree is torn down by the time the argv is read back here.
case "${ci:+$cwd17}" in
  "$ROOT/data/worktrees/j17/"*) ok "-C names the run's working directory" ;;
  *) bad "-C missing or not the run's worktree: '$cwd17'" ;;
esac
mi="$(idx_in "$argv17" -m)"; [ "$(at_in "$argv17" $((mi + 1)))" = "gpt-5.6-sol" ] && ok "-m carries the slug verbatim" || bad "-m $(at_in "$argv17" $((mi + 1)))"
si="$(idx_in "$argv17" -s)"; [ "$(at_in "$argv17" $((si + 1)))" = "read-only" ] && ok "-s read-only" || bad "-s '$(at_in "$argv17" $((si + 1)))'"
[ -n "$(idx_in "$argv17" approval_policy=never)" ] && ok "-c approval_policy=never, bare" || bad "no bare approval_policy=never"
[ -n "$(idx_in "$argv17" model_reasoning_effort=high)" ] && ok "-c model_reasoning_effort=high, bare" || bad "no bare effort override"
[ -z "$(idx_in "$argv17" --disable)" ] && ok "no --disable flag: it closes nothing (measured)" || bad "--disable was passed"
[ -z "$(idx_in "$argv17" --skip-git-repo-check)" ] && bad "no --skip-git-repo-check" || ok "--skip-git-repo-check"
[ -z "$(idx_in "$argv17" sandbox_workspace_write.network_access=true)" ] \
  && ok "read-only is sealed to the network too: no override" || bad "read-only was given the network"
dd="$(idx_in "$argv17" --)"; [ -n "$dd" ] && [ "$((dd + 1))" = "$argc17" ] \
  && ok "the prompt is the one argument after --" || bad "-- at '$dd', argc $argc17"

echo
}

scenario_17b() {
echo "17b. a workspace-write run gets back the network AND the git directory its commits write to"
argv17b="$ROOT/argv-17b"; rm -f "$argv17b"
mkjob_openai j17b workspace-write
FAKE_ARGV_OUT="$argv17b" FAKE_MODE=complete FAKE_SESSION=thr-argv-net "$AL" run j17b >/dev/null 2>&1
sleep 1
si="$(idx_in "$argv17b" -s)"; [ "$(at_in "$argv17b" $((si + 1)))" = "workspace-write" ] \
  && ok "-s workspace-write" || bad "-s '$(at_in "$argv17b" $((si + 1)))'"
[ -n "$(idx_in "$argv17b" sandbox_workspace_write.network_access=true)" ] \
  && ok "-c sandbox_workspace_write.network_access=true, bare" || bad "no network override: every API this fleet talks to is unreachable"
# The run works in a `git worktree add` checkout, so its commits write into
# $ROOT/work/app/.git -- outside the tree, and denied without this.
wr17b="$(awk -F'\t' '$2 ~ /^sandbox_workspace_write.writable_roots=/ {print $2; exit}' "$argv17b")"
case "$wr17b" in
  *"\"$ROOT/work/app/.git\""*) ok "-c writable_roots names the canonical repo's git directory" ;;
  *) bad "writable_roots is '${wr17b:-missing}'" ;;
esac

echo
}

scenario_18() {
echo "18. a spent OpenAI quota is rate_limited, outside the backoff"
mkjob_openai j18
echo '{"j18":{"fail_streak":2}}' > "$ROOT/data/state.json"
FAKE_MODE=quota FAKE_SESSION=thr-quota "$AL" run j18 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "rate_limited" ] \
  && ok "error / rate_limited" || bad "$(lastrun | jq -c '{status,cause}')"
[ "$(jq -r '.j18.fail_streak' "$ROOT/data/state.json")" = "2" ] && ok "fail_streak untouched" || bad "streak $(jq -r '.j18.fail_streak' "$ROOT/data/state.json")"
[ "$(jq -r --arg k "openai@$CODEX_HOME" '.[$k].five_hour.status' "$ROOT/data/rate-limits.json")" = "usage_limit_reached" ] \
  && ok "and the fuller openai window is marked spent until its reset" || bad "window status $(jq -c . "$ROOT/data/rate-limits.json")"

echo
}

scenario_19() {
echo "19. a stop ends an OpenAI run that will not end by itself"
mkjob_openai j19
FAKE_MODE=hang FAKE_SESSION=thr-hang "$AL" run j19 >/dev/null 2>&1 &
w=0; while [ "$w" -lt 20 ] && ! ls "$ROOT"/data/locks/j19/*/child >/dev/null 2>&1; do sleep 1; w=$((w + 1)); done
sleep 1
"$AL" stop j19 >/dev/null 2>&1
wait
[ "$(lastrun | jq -r .status)" = "stopped" ] && ok "status stopped (waited ${w}s for the slot)" || bad "status $(lastrun | jq -r .status)"
[ ! -e "$ROOT"/data/logs/j19/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"

echo
}

scenario_20() {
echo "20. a run that cannot start is refused in tick.log before it costs a slot"
mkjob_openai j20
FAKE_CODEX_LOGGED_OUT=1 "$AL" run j20 >/dev/null 2>&1
grep -q 'j20: openai is not ready (codex is not signed in' "$ROOT/data/tick.log" && ok "no login → refused" || bad "no login refusal line"
[ ! -d "$ROOT/data/logs/j20" ] && ok "and no log was written" || bad "a run started without a login"
sed -i '' 's/"gpt-5.6-sol"/"gpt-nope"/' "$ROOT/config/jobs.json"
"$AL" run j20 >/dev/null 2>&1
grep -q "j20: model 'gpt-nope' is not in the OpenAI catalog" "$ROOT/data/tick.log" && ok "unknown slug → refused" || bad "no catalog refusal"
mkjob_openai j20
sed -i '' 's/"platform":"openai"/"platform":"openai","interactive":true/' "$ROOT/config/jobs.json"
"$AL" run j20 >/dev/null 2>&1
grep -q "j20: interactive is not available on openai" "$ROOT/data/tick.log" && ok "interactive → refused" || bad "no interactive refusal"
mkjob_openai j20
sed -i '' 's/"platform":"openai"/"platform":"openai","disallowed_tools":"Agent"/' "$ROOT/config/jobs.json"
FAKE_MODE=complete FAKE_SESSION=thr-tools "$AL" run j20 >/dev/null 2>&1
grep -q "j20: disallowed_tools is ignored on openai" "$ROOT/data/tick.log" && ok "disallowed_tools → one line, run goes on" || bad "no ignored-tools line"
sleep 2
[ "$(lastrun | jq -r .status)" = "success" ] && ok "and the run itself went on to finish" || bad "status $(lastrun | jq -r .status)"

echo
}

scenario_21() {
echo "21. the run-end hook learns the platform, the cost basis and the tokens"
mkdir -p "$ROOT/config/hooks"
printf '#!/bin/bash\nprintf "%%s %%s %%s\\n" "$AL_PLATFORM" "$AL_COST_BASIS" "$AL_TOKENS" > "%s/hook-21.out"\n' "$ROOT" > "$ROOT/config/hooks/on-run-end.sh"
chmod +x "$ROOT/config/hooks/on-run-end.sh"
mkjob_openai j21
FAKE_MODE=complete FAKE_SESSION=thr-hook "$AL" run j21 >/dev/null 2>&1
sleep 3
case "$(cat "$ROOT/hook-21.out" 2>/dev/null)" in
  "openai estimated {"*'"input":32675'*) ok "AL_PLATFORM, AL_COST_BASIS and AL_TOKENS reach the hook" ;;
  *) bad "hook saw: $(cat "$ROOT/hook-21.out" 2>/dev/null)" ;;
esac
rm -f "$ROOT/config/hooks/on-run-end.sh"

echo
}

scenario_22() {
echo "22. a session is resumed on the platform it ran on, or not at all"
mkjob_openai j22
FAKE_MODE=undeclared FAKE_SESSION=thr-moved "$AL" run j22 >/dev/null 2>&1
sleep 2
# Moved onto a model Settings switched on (the fixture at the top): the
# stand-in cannot resolve a family, so a bare `opus` would be refused by the
# model gate first, and never reach the resume refusal this scenario is about.
sed -i '' 's/"platform":"openai"/"platform":"anthropic"/; s/"gpt-5.6-sol"/"claude-opus-5"/; s/"workspace-write"/"dontAsk"/; s/"effort":"high"/"effort":"low"/' "$ROOT/config/jobs.json"
# The old run's account was the Default on openai, which carried CODEX_HOME
# as its directory (see account_env_value). Marking THAT directory logged
# out forces the anthropic readiness probe to fail if the resume ever
# adopts it under the new platform -- proof the mismatch refusal below is
# reached honestly, not because the probe happened to pass over a directory
# that just has no claude credentials in it either way.
: > "$CODEX_HOME/.fake-logged-out"
"$AL" resume j22 thr-moved >/dev/null 2>&1
grep -q 'j22: refusing to resume thr-moved — this session belongs to openai; the job now runs on anthropic' "$ROOT/data/tick.log" \
  && ok "the resume is refused, naming both platforms" || bad "no refusal line for the moved job"
grep -q 'j22: anthropic is not ready' "$ROOT/data/tick.log" \
  && bad "the readiness probe ran on the OLD platform's directory: $(grep 'j22: anthropic is not ready' "$ROOT/data/tick.log")" \
  || ok "no 'is not ready' line: the mismatch is the only refusal reached"
[ -n "$(dirs j22)" ] && ok "and the open session's tree is left where it was" || bad "the tree was taken"
rm -f "$CODEX_HOME/.fake-logged-out"

echo
}

scenario_23() {
echo "23. the price table refreshes from the source and names what it could not price"
# The seeded example table prices gpt-5.4-mini and the source does not carry it,
# so its row would simply be KEPT (that rule has its own selftest case). Drop it
# here, so what this scenario asserts is the gap itself: a VISIBLE catalog slug
# with no price at all, named by platforms and in tick.log.
jq 'del(.openai["gpt-5.4-mini"])' "$ROOT/config/pricing.json" > "$ROOT/pricing.seed"
mv "$ROOT/pricing.seed" "$ROOT/config/pricing.json"
: > "$ROOT/data/tick.log"
"$AL" resolve-pricing >/dev/null 2>&1; rp_rc=$?
[ "$rp_rc" -eq 0 ] && ok "resolve-pricing exits 0" || bad "resolve-pricing failed: rc $rp_rc"
jq -e '.openai["gpt-5.6-sol"].cache_write == 5' "$ROOT/config/pricing.json" >/dev/null \
  && ok "gpt-5.6-sol's cache-write price came from the source (5 per 1M)" || bad "sol row $(jq -c '.openai["gpt-5.6-sol"]' "$ROOT/config/pricing.json")"
[ "$(jq -r '._source_url' "$ROOT/config/pricing.json")" = "$AGENTLOOP_PRICING_URL" ] \
  && ok "the table records its source" || bad "source $(jq -r '._source_url' "$ROOT/config/pricing.json")"
[ "$("$AL" platforms | jq -c '.openai.unpriced')" = '["gpt-5.4-mini"]' ] \
  && ok "platforms names the one visible slug the source does not price" || bad "unpriced $("$AL" platforms | jq -c '.openai.unpriced')"
grep -q 'pricing: no price for gpt-5.4-mini' "$ROOT/data/tick.log" && ok "and tick.log says so" || bad "no tick.log line"

echo
}

scenario_24() {
echo "24. a security analysis on OpenAI goes through the Codex stand-in, forbids subagents in words, and closes done"
# A second project, on the openai platform, over the same repository. Its
# derived job takes the block's platform and the platform's security default
# (full-access: the ledger lives outside the worktree).
jq --arg cwd "$ROOT/work/app" '.projects += [{"name":"sandbox-oa","cwd":$cwd,"base":"main","worktree":{"enabled":true},
   "security":{"enabled":true,"platform":"openai","model":"gpt-5.6-sol","max_budget_usd":5}}]' \
   "$ROOT/config/projects.json" > "$ROOT/projects.next" && mv "$ROOT/projects.next" "$ROOT/config/projects.json"
# The stand-in does NOT run prepare here (FAKE_SKIP_PREPARE), so a `done`
# close can only mean the ENGINE ran the deterministic phase before launching
# it -- which is what run_job does on openai. AL_SECURITY_ENGINES=off keeps
# that engine-side prepare off the network, the way `--offline` keeps the
# stand-ins' own; the fixture has no lockfile, so nothing else reaches for
# one either.
argv24="$ROOT/argv-24"; prompt24="$ROOT/prompt-24"; rm -f "$argv24" "$prompt24"
out24="$(AL_SECURITY_ENGINES=off FAKE_SKIP_PREPARE=1 FAKE_ARGV_OUT="$argv24" FAKE_PROMPT_OUT="$prompt24" \
  FAKE_MODE=complete FAKE_SESSION=thr-sec \
  "$AL" security analyze sandbox-oa anything main quick 2>&1)"
aid24="$(secid "$out24")"
[ -n "$aid24" ] && ok "the analysis opened: $aid24" || bad "no analysis id in: $out24"
[ "$(secstate sandbox-oa "$aid24")" = "done" ] \
  && ok "and closed done: the engine ran security prepare before the agent, and the close found nothing untriaged" \
  || bad "state '$(secstate sandbox-oa "$aid24")'"
grep -q 'deterministic phase ran before the agent' "$ROOT/data/tick.log" \
  && ok "the engine ran prepare before launching codex" || bad "no engine-side prepare line in tick.log"
[ "$(at_in "$argv24" 1)" = "exec" ] && ok "it went down the Codex launch line" || bad "argv: $(tr '\n' ' ' < "$argv24" 2>/dev/null)"
mi="$(idx_in "$argv24" -m)"; [ -n "${mi:-}" ] && [ "$(at_in "$argv24" $((mi + 1)))" = "gpt-5.6-sol" ] \
  && ok "-m carries the block's model" || bad "-m '$(at_in "$argv24" $((${mi:-0} + 1)))'"
[ -n "$(idx_in "$argv24" --dangerously-bypass-approvals-and-sandbox)" ] \
  && ok "full-access, the security default on openai" || bad "no bypass flag in the launch line"
[ -z "$(idx_in "$argv24" --disallowedTools)" ] && ok "no --disallowedTools: Codex cannot close a tool by flag" || bad "--disallowedTools was passed to codex"
grep -q 'Do not spawn subagents' "$prompt24" && ok "the prompt forbids subagents in words" || bad "no subagent ban in the prompt"
grep -q 'security-analysis/SKILL.md' "$prompt24" && ok "and names the skill file by path" || bad "the prompt does not name the skill file"
grep -q 'Agent. tool' "$prompt24" && bad "the prompt still speaks of the Agent tool" || ok "and never speaks of the Agent tool"
grep -q 'ALREADY RAN for this analysis' "$prompt24" && ! grep -q 'YOUR FIRST COMMAND' "$prompt24" \
  && ok "the prompt says the deterministic phase already ran" || bad "the prompt still asks the agent to run prepare, or never says the engine did"
E2E_JOB=security-sandbox-oa   # the derived job, which no mkjob made
[ "$(lastrun | jq -r .id)" = "security-sandbox-oa" ] && [ "$(lastrun | jq -r .platform)" = "openai" ] && [ "$(lastrun | jq -r .cost_basis)" = "estimated" ] \
  && ok "the journal has the derived job's run on openai, priced by estimate" || bad "$(lastrun | jq -c '{id,platform,cost_basis}')"
sleep 1

echo
}

scenario_25() {
echo "25. the account the installer pinned is the account the agent signs in as"
# The chain nobody had driven end to end: launchd hands the tick the plist's
# EnvironmentVariables, the engine reads AGENTLOOP_CLAUDE_CONFIG_DIR (and
# discards an ambient CLAUDE_CONFIG_DIR on purpose), and the CLI inherits it.
# The plists used to name only the CLI's variable, so the pin died at the door
# and every scheduled run signed in as the default account instead.
mkjob j25
acct25="$ROOT/account-25"; rm -f "$acct25"
FAKE_ACCOUNT_OUT="$acct25" AGENTLOOP_CLAUDE_CONFIG_DIR="$ROOT/pinned-account" \
  FAKE_MODE=complete FAKE_SESSION=sess-acct "$AL" run j25 >/dev/null 2>&1
[ "$(cat "$acct25" 2>/dev/null)" = "$ROOT/pinned-account" ] \
  && ok "the agent runs under the pinned account" || bad "the agent saw '$(cat "$acct25" 2>/dev/null)'"
# ...and an account nobody pinned stays the CLI's own default, so a run never
# borrows whichever account the shell that started it happened to export.
rm -f "$acct25"
FAKE_ACCOUNT_OUT="$acct25" CLAUDE_CONFIG_DIR="$ROOT/someones-session" \
  FAKE_MODE=complete FAKE_SESSION=sess-acct2 "$AL" run j25 >/dev/null 2>&1
[ -z "$(cat "$acct25" 2>/dev/null)" ] \
  && ok "and an ambient one is not borrowed" || bad "the agent inherited '$(cat "$acct25" 2>/dev/null)'"
sleep 1

echo
}

scenario_26() {
echo "26. a job on a platform switched off in Settings is skipped before it costs a slot"
mkjob j26
"$AL" platform disable anthropic >/dev/null 2>&1
FAKE_MODE=complete FAKE_SESSION=sess-26 "$AL" run j26 >/dev/null 2>&1
grep -q "j26: anthropic is disabled in Settings (agentloop platform enable anthropic), skipped" "$ROOT/data/tick.log" \
  && ok "the refusal is one line in tick.log" || bad "no refusal line: $(tail -3 "$ROOT/data/tick.log")"
[ -z "$(dirs j26)" ] && ok "and no run directory was cut" || bad "a worktree was cut for a refused run"
"$AL" platform enable anthropic >/dev/null 2>&1 || bad "platform enable anthropic failed over the stand-in"
FAKE_MODE=complete FAKE_SESSION=sess-26b "$AL" run j26 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .session)" = "sess-26b" ] && ok "enabled again, the same job runs" || bad "no run after enable: $(lastrun)"

echo
}

scenario_27() {
echo "27. a model switched off in Settings is refused, and the line names what is enabled"
mkjob_openai j27
printf '["gpt-5.6-luna"]' | "$AL" platform set-models openai >/dev/null 2>&1
FAKE_MODE=complete FAKE_SESSION=thr-27 "$AL" run j27 >/dev/null 2>&1
grep -q "j27: model 'gpt-5.6-sol' is not enabled in Settings — openai enables: gpt-5.6-luna, skipped" "$ROOT/data/tick.log" \
  && ok "the refusal names the model and the enabled list" || bad "no model refusal: $(tail -3 "$ROOT/data/tick.log")"
printf '["gpt-5.6-sol"]' | "$AL" platform set-models openai >/dev/null 2>&1

echo
}

scenario_28() {
echo "28. upgrade path: no platforms file and an enabled job -> seeded from it, and the run is unchanged"
mkjob j28
jq '.jobs[0].enabled = true | .jobs[0].model = "claude-opus-5"' "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
# Scenario 24 left "sandbox-oa" behind with its security block still enabled
# on openai, and platforms_seed's own comment says a platform is seeded
# enabled by EITHER an enabled job or an enabled security block -- left as
# is, that block alone would seed openai as enabled, and the assertion below
# would pass for the wrong reason (a leftover, not a fresh read of j28 alone).
jq '(.projects[] | select(.name == "sandbox-oa") | .security.enabled) = false' \
  "$ROOT/config/projects.json" > "$ROOT/projects.next" && mv "$ROOT/projects.next" "$ROOT/config/projects.json"
rm -f "$ROOT/config/platforms.json"
FAKE_MODE=complete FAKE_SESSION=sess-28 "$AL" run j28 >/dev/null 2>&1
sleep 2
jq -e '.platforms.anthropic.enabled == true and (.platforms.anthropic.models | index("claude-opus-5")) != null' "$ROOT/config/platforms.json" >/dev/null 2>&1 \
  && ok "the file was seeded with the enabled job's platform and model" || bad "seed: $(cat "$ROOT/config/platforms.json" 2>/dev/null)"
# The fixture at the top of this file enables openai; the seed, with no
# enabled openai job or project anywhere in this run, must not. This is the
# one observable that tells "seeded fresh" apart from "the fixture survived
# the rm -f above" -- both would pass the anthropic assertion just above.
jq -e '.platforms.openai.enabled == false' "$ROOT/config/platforms.json" >/dev/null 2>&1 \
  && ok "and openai came out disabled — this is the seed, not the fixture surviving the rm" \
  || bad "openai after reseed: $(cat "$ROOT/config/platforms.json" 2>/dev/null)"
[ "$(lastrun | jq -r .session)" = "sess-28" ] && ok "and the job ran as before" || bad "no run: $(lastrun)"

# Scenario 28 just deleted config/platforms.json to drive the fresh-seed path,
# and platforms_seed hardcodes opencode (and, with no openai job or security
# block left enabled at that moment, openai too) disabled -- job-level
# enablement is this task's own run_job, not that seed. Left as scenario 28's
# reseed wrote it, every job below would be refused before it ever reached
# run_job's own gates. Restore the fixture from the top of this file.
cat > "$ROOT/config/platforms.json" <<'JSON'
{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},
              "openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"]},
              "opencode":{"enabled":true,"bin":"","models":["opencode/big-pickle","pdm_ai/glm-5.3-flash"]}}}
JSON

# ------------------------------------------------------- the OpenCode platform
# The same lifecycle over the OpenCode stand-in: the run goes down a FIFO
# into opencode_stream.py, the classifier reads the normalized stream, the
# stand-in's `export` supplies the model that ran, and the permission block
# travels in OPENCODE_CONFIG_CONTENT (read back through FAKE_CONFIG_OUT).
"$AL" resolve-models opencode >/dev/null 2>&1
jq -e '.opencode.models | length == 13' "$ROOT/config/models.json" >/dev/null \
  && ok "resolve-models opencode wrote the catalog from the stand-in's models --verbose" \
  || bad "no opencode catalog after resolve-models"

echo
}

scenario_29() {
echo "29. an OpenCode run goes through the stand-in and reads as a clean success"
mkjob_opencode j29 full-access opencode/big-pickle
FAKE_MODE=complete FAKE_SESSION=ses_clean "$AL" run j29 >/dev/null 2>&1
sleep 2
[ -z "$(dirs j29)" ] && ok "its run directory is gone (declared ending, nothing undelivered)" || bad "left $(dirs j29)"
[ "$(lastrun | jq -r .status)" = "success" ] && ok "status success: nothing on stderr, a result on the stream" || bad "status $(lastrun | jq -r .status): $(lastrun | jq -r .note)"
[ "$(lastrun | jq -r .session)" = "ses_clean" ] && ok "the session recorded is the sessionID" || bad "session $(lastrun | jq -r .session)"
[ "$(lastrun | jq -r .model_id)" = "opencode/big-pickle-real" ] \
  && ok "model_id is the model the export says ran, not the id asked for" || bad "model_id $(lastrun | jq -r .model_id)"
[ "$(lastrun | jq -r .platform)" = "opencode" ] && ok "the journal names the platform" || bad "platform $(lastrun | jq -r .platform)"
[ "$(lastrun | jq -r .cost_basis)" = "none" ] && [ "$(lastrun | jq -r .cost)" = "0" ] \
  && ok "a model the catalog prices at zero records an UNKNOWN cost, never a free one" || bad "cost $(lastrun | jq -c '{cost,cost_basis}')"
[ "$(lastrun | jq -r '.tokens.input')" = "11974" ] && [ "$(lastrun | jq -r '.tokens.cached')" = "15488" ] \
  && ok "the token counts are the sum of the steps" || bad "tokens $(lastrun | jq -c .tokens)"
s29="$(ls "$ROOT"/data/logs/j29/*.stream.ndjson 2>/dev/null | head -1)"
[ -f "$s29.raw" ] && grep -q '"step_start"' "$s29.raw" && ok "the raw OpenCode stream is kept beside the normalized one" || bad "no .raw copy"
head -1 "$s29" | jq -e '.subtype=="init" and .platform=="opencode"' >/dev/null 2>&1 \
  && ok "the normalized stream opens with the init event" || bad "first line: $(head -1 "$s29")"
[ ! -e "$ROOT"/data/logs/j29/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"
# "no opencode block" is also true of a file that does not exist yet -- it
# only exists once an OpenAI run has written its own windows, which in file
# order scenario 13 did, and in a sandbox starting at 27 nothing has. jq on a
# missing file exits 2, which read here as "an opencode block appeared".
{ [ ! -f "$ROOT/data/rate-limits.json" ] || jq -e 'has("opencode") | not' "$ROOT/data/rate-limits.json" >/dev/null 2>&1; } \
  && ok "no usage window was invented for opencode" || bad "rate-limits.json grew an opencode block"

echo
}

scenario_30() {
echo "30. an OpenCode run that never declares an ending keeps its tree, bound to the session"
mkjob_opencode j30
FAKE_MODE=undeclared FAKE_SESSION=ses_cut "$AL" run j30 >/dev/null 2>&1
sleep 2
d30="$(dirs j30 | head -1)"
[ -n "$d30" ] && [ "$(ended j30 "$d30")" = "open" ] && ok "kept, marked open" || bad "dir '$d30' ended '$(ended j30 "$d30")'"
[ "$(cat "$ROOT/data/worktrees/j30/$d30/.session" 2>/dev/null)" = "ses_cut" ] && ok ".session holds the sessionID" || bad ".session not bound"

echo
}

scenario_31() {
echo "31. a resume reattaches, and launches with -s AND --dir on the session's own directory"
argv31="$ROOT/argv-31"; dir31="$ROOT/dir-31"; rm -f "$argv31" "$dir31"
FAKE_ARGV_OUT="$argv31" FAKE_DIR_OUT="$dir31" FAKE_MODE=complete FAKE_SESSION=ses_cut "$AL" resume j30 ses_cut >/dev/null 2>&1
sleep 2
grep -q "resumed ses_cut in its own tree" "$ROOT/data/tick.log" && ok "the tick log says it reattached" || bad "no reattach line"
[ -z "$(dirs j30)" ] && ok "and the finished session took its directory with it" || bad "left $(dirs j30)"
si="$(idx_in "$argv31" -s)"; [ -n "$si" ] && [ "$(at_in "$argv31" $((si + 1)))" = "ses_cut" ] && ok "-s carries the session id" || bad "no -s: $(tr '\n' ' ' < "$argv31")"
case "$(cat "$dir31" 2>/dev/null)" in
  "$ROOT/data/worktrees/j30/$d30/"*) ok "--dir is the kept worktree the session was born in (any other directory hangs for ever: measured)" ;;
  *) bad "--dir on the resume was '$(cat "$dir31" 2>/dev/null)'" ;;
esac
[ -z "$(idx_in "$argv31" --title)" ] && ok "no --title on a resume (the session has one)" || bad "--title passed on a resume"
[ "$(lastrun | jq -r .session)" = "ses_cut" ] && [ "$(lastrun | jq -r .resumed_from)" = "ses_cut" ] && ok "the journal has the same session, resumed" || bad "$(lastrun | jq -c '{session,resumed_from}')"

echo
}

scenario_32() {
echo "32. work on no remote is reported for an OpenCode run too"
mkjob_opencode j32
FAKE_MODE=dirty FAKE_SESSION=ses_dirty "$AL" run j32 >/dev/null 2>&1
sleep 2
lastrun | grep -q 'UNDELIVERED' && [ -n "$(dirs j32)" ] && ok "UNDELIVERED, and the tree is kept" || bad "no UNDELIVERED note, or tree gone"

echo
}

scenario_33() {
echo "33. the launch line and the permission block of a fresh OpenCode run, read back off the stand-in"
argv33="$ROOT/argv-33"; cfg33="$ROOT/cfg-33"; dir33="$ROOT/dir-33"; rm -f "$argv33" "$cfg33" "$dir33"
mkjob_opencode j33 full-access pdm_ai/glm-5.3-flash ',"disallowed_tools":"Agent,Bash(git push *)"'
FAKE_ARGV_OUT="$argv33" FAKE_CONFIG_OUT="$cfg33" FAKE_DIR_OUT="$dir33" FAKE_MODE=complete FAKE_SESSION=ses_argv "$AL" run j33 >/dev/null 2>&1
sleep 1
argc33="$(awk -F'\t' '$1=="ARGC" {print $2; exit}' "$argv33")"
[ "$(at_in "$argv33" 1)" = "run" ] && [ "$(at_in "$argv33" 2)" = "--format" ] && [ "$(at_in "$argv33" 3)" = "json" ] && ok "run --format json" || bad "argv: $(tr '\n' ' ' < "$argv33")"
for f in --pure --auto --print-logs; do [ -n "$(idx_in "$argv33" "$f")" ] && ok "$f" || bad "no $f"; done
li="$(idx_in "$argv33" --log-level)"; [ "$(at_in "$argv33" $((li + 1)))" = "ERROR" ] && ok "--log-level ERROR" || bad "log level"
mi="$(idx_in "$argv33" -m)"; [ "$(at_in "$argv33" $((mi + 1)))" = "pdm_ai/glm-5.3-flash" ] && ok "-m carries the id verbatim" || bad "-m $(at_in "$argv33" $((mi + 1)))"
vi="$(idx_in "$argv33" --variant)"; [ "$(at_in "$argv33" $((vi + 1)))" = "high" ] && ok "--variant high (a variant the catalog lists for this model)" || bad "--variant"
case "$(cat "$dir33" 2>/dev/null)" in
  "$ROOT/data/worktrees/j33/"*) ok "--dir names the run's working directory" ;;
  *) bad "--dir was '$(cat "$dir33" 2>/dev/null)'" ;;
esac
ti="$(idx_in "$argv33" --title)"; case "$(at_in "$argv33" $((ti + 1)))" in "agentloop j33 "*) ok "--title names the job and the stamp" ;; *) bad "title '$(at_in "$argv33" $((ti + 1)))'" ;; esac
[ -z "$(idx_in "$argv33" -s)" ] && ok "no -s on a fresh run" || bad "-s on a fresh run"
dd="$(idx_in "$argv33" --)"; [ -n "$dd" ] && [ "$((dd + 1))" = "$argc33" ] && ok "the prompt is the one argument after --" || bad "-- at '$dd', argc $argc33"
[ "$(jq -r .share "$cfg33")" = "disabled" ] && ok "OPENCODE_CONFIG_CONTENT disables sharing" || bad "config: $(cat "$cfg33")"
[ "$(jq -c .permission "$cfg33")" = '{"task":"deny","bash":{"*":"allow","git push *":"deny"}}' ] \
  && ok "and carries the job's denylist: Agent closed task, Bash(git push *) became a bash rule" || bad "permission: $(jq -c .permission "$cfg33")"
grep -q "j33: disallowed_tools is ignored" "$ROOT/data/tick.log" && bad "the lists were called ignored on opencode" || ok "nothing calls the tool lists ignored: they are translated"
[ "$(lastrun | jq -r .status)" = "success" ] && ok "and the run went on to finish" || bad "status $(lastrun | jq -r .status)"

echo
}

scenario_33b() {
echo "33b. read-only launches with the four denies, and a tool the table does not know is named"
cfg33b="$ROOT/cfg-33b"; rm -f "$cfg33b"
mkjob_opencode j33b read-only pdm_ai/glm-5.3-flash ',"allowed_tools":"Read,Nonesuch"'
FAKE_CONFIG_OUT="$cfg33b" FAKE_MODE=complete FAKE_SESSION=ses_ro "$AL" run j33b >/dev/null 2>&1
sleep 1
[ "$(jq -c '.permission | {edit, write, bash, task, "*": .["*"], read}' "$cfg33b")" = '{"edit":"deny","write":"deny","bash":"deny","task":"deny","*":"deny","read":"allow"}' ] \
  && ok "read-only denies edit, write, bash and task; the allowlist closes the rest and opens read" || bad "permission: $(jq -c .permission "$cfg33b")"
grep -q "j33b: allowed_tools: Nonesuch is not a tool OpenCode has; ignored" "$ROOT/data/tick.log" && ok "the unknown tool name is one line in tick.log" || bad "no note for Nonesuch"

echo
}

scenario_34() {
echo "34. a tool denied by rule during the run is tools_denied, like a --disallowedTools hit on Claude"
mkjob_opencode j34
FAKE_MODE=deny FAKE_SESSION=ses_deny "$AL" run j34 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "tools_denied" ] \
  && ok "error / tools_denied (the stream carried the denial: opencode has that capability, Codex never did)" || bad "$(lastrun | jq -c '{status,cause}')"

echo
}

scenario_35() {
echo "35. a rate limit is rate_limited, outside the backoff, with no window to mark"
mkjob_opencode j35
echo '{"j35":{"fail_streak":2}}' > "$ROOT/data/state.json"
FAKE_MODE=quota FAKE_SESSION=ses_quota "$AL" run j35 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "rate_limited" ] \
  && ok "error / rate_limited (APIError with statusCode 429)" || bad "$(lastrun | jq -c '{status,cause}')"
[ "$(jq -r '.j35.fail_streak' "$ROOT/data/state.json")" = "2" ] && ok "fail_streak untouched" || bad "streak $(jq -r '.j35.fail_streak' "$ROOT/data/state.json")"
{ [ ! -f "$ROOT/data/rate-limits.json" ] || jq -e 'has("opencode") | not' "$ROOT/data/rate-limits.json" >/dev/null 2>&1; } && ok "and still no opencode window: the next run comes at the job's own interval" || bad "an opencode window appeared"

echo
}

scenario_35b() {
echo "35b. an unknown model at run time is an error whose reason is in .err, not on the stream"
mkjob_opencode j35b full-access pdm_ai/glm-5.3-flash ',"max_budget_usd":1'
FAKE_MODE=error FAKE_SESSION=ses_err "$AL" run j35b >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "agent_error" ] \
  && ok "error / agent_error: an UnknownError carries no status" || bad "$(lastrun | jq -c '{status,cause}')"
# A priced model whose run died before its first step has null tokens: the
# cap note blames no price on the model (it has one), it says no step
# reported a cost.
[ "$(lastrun | jq -c .tokens)" = "null" ] && ok "no step_finish, so the tokens are null, not zero" || bad "tokens $(lastrun | jq -c .tokens)"
grep -q 'j35b: max_budget_usd 1 not applied: the cost of this run is unknown (no step reported a cost)' "$ROOT/data/tick.log" \
  && ok "the cap note says no step reported a cost, not no price for a priced model" || bad "cap note: $(grep 'j35b: max_budget' "$ROOT/data/tick.log" | tail -1)"

echo
}

scenario_36() {
echo "36. a stop ends an OpenCode run that will not end by itself"
mkjob_opencode j36 full-access pdm_ai/glm-5.3-flash ',"max_budget_usd":1'
FAKE_MODE=hang FAKE_SESSION=ses_hang "$AL" run j36 >/dev/null 2>&1 &
w=0; while [ "$w" -lt 20 ] && ! ls "$ROOT"/data/locks/j36/*/child >/dev/null 2>&1; do sleep 1; w=$((w + 1)); done
sleep 1
"$AL" stop j36 >/dev/null 2>&1
wait
[ "$(lastrun | jq -r .status)" = "stopped" ] && ok "status stopped (waited ${w}s for the slot)" || bad "status $(lastrun | jq -r .status)"
[ ! -e "$ROOT"/data/logs/j36/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"
lastrun | jq -r .note | grep -q 'not applied' && bad "a stopped run got the cap note" || ok "a stopped run gets no cap note: its cost is unknown because it died, not because the model has no price"

echo
}

scenario_37() {
echo "37. a run that cannot start is refused in tick.log before it costs a slot"
mkjob_opencode j37
FAKE_OPENCODE_NO_MODELS=1 "$AL" run j37 >/dev/null 2>&1
grep -q 'j37: opencode is not ready (no usable provider' "$ROOT/data/tick.log" && ok "no provider → refused" || bad "no provider refusal line"
[ ! -d "$ROOT/data/logs/j37" ] && ok "and no log was written" || bad "a run started without a provider"
mkjob_opencode j37 full-access opencode/does-not-exist
"$AL" run j37 >/dev/null 2>&1
grep -q "j37: model 'opencode/does-not-exist' is not in the OpenCode catalog" "$ROOT/data/tick.log" && ok "unknown id → refused" || bad "no catalog refusal"
mkjob_opencode j37 full-access pdm_ai/glm-5.3-flash ',"interactive":true'
"$AL" run j37 >/dev/null 2>&1
grep -q "j37: interactive is not available on opencode" "$ROOT/data/tick.log" && ok "interactive → refused" || bad "no interactive refusal"
mkjob_opencode j37 workspace-write
"$AL" run j37 >/dev/null 2>&1
grep -q "j37: permission_mode 'workspace-write' is not an OpenCode mode" "$ROOT/data/tick.log" && ok "a Codex mode → refused (there is no sandbox to promise)" || bad "no permission refusal"
argv37x="$ROOT/argv-37x"; rm -f "$argv37x"
printf '#!/bin/bash\nif [ "$1" = "-" ] && { [ "$2" = "full-access" ] || [ "$2" = "read-only" ]; }; then exit 1; fi\nexec python3 "$@"\n' > "$ROOT/pybroken"
chmod +x "$ROOT/pybroken"
mkjob_opencode j37
AGENTLOOP_PYTHON="$ROOT/pybroken" FAKE_ARGV_OUT="$argv37x" "$AL" run j37 >/dev/null 2>&1
grep -q "j37: could not build the OpenCode permission block, skipped" "$ROOT/data/tick.log" && ok "a broken permission block is refused before a slot is spent" || bad "no permission-block refusal line"
[ ! -e "$argv37x" ] && ok "and no argv was ever written" || bad "the CLI launched anyway"
[ ! -d "$ROOT/data/locks/j37" ] && ok "and no lock directory was left" || bad "a lock directory was left"
argv37="$ROOT/argv-37"; rm -f "$argv37"
mkjob_opencode j37
sed -i '' 's/"effort":"high"/"effort":"ultra"/' "$ROOT/config/jobs.json"
FAKE_ARGV_OUT="$argv37" FAKE_MODE=complete FAKE_SESSION=ses_eff "$AL" run j37 >/dev/null 2>&1
sleep 2
grep -q "j37: effort 'ultra' is not a variant of pdm_ai/glm-5.3-flash — launched without an effort" "$ROOT/data/tick.log" \
  && [ -z "$(idx_in "$argv37" --variant)" ] && ok "an effort the model does not list is dropped, said, and the run goes on" || bad "bad effort: $(grep 'j37: effort' "$ROOT/data/tick.log" | tail -1)"
[ "$(lastrun | jq -r .status)" = "success" ] && ok "and finished" || bad "status $(lastrun | jq -r .status)"

echo
}

scenario_38() {
echo "38. the run-end hook learns the platform, the cost basis and the tokens"
mkdir -p "$ROOT/config/hooks"
printf '#!/bin/bash\nprintf "%%s %%s %%s\\n" "$AL_PLATFORM" "$AL_COST_BASIS" "$AL_TOKENS" > "%s/hook-38.out"\n' "$ROOT" > "$ROOT/config/hooks/on-run-end.sh"
chmod +x "$ROOT/config/hooks/on-run-end.sh"
mkjob_opencode j38
FAKE_MODE=complete FAKE_SESSION=ses_hook FAKE_COST=0.0002 "$AL" run j38 >/dev/null 2>&1
sleep 3
case "$(cat "$ROOT/hook-38.out" 2>/dev/null)" in
  "opencode reported {"*'"input":11974'*) ok "AL_PLATFORM, AL_COST_BASIS and AL_TOKENS reach the hook" ;;
  *) bad "hook saw: $(cat "$ROOT/hook-38.out" 2>/dev/null)" ;;
esac
rm -f "$ROOT/config/hooks/on-run-end.sh"

echo
}

scenario_39() {
echo "39. a model the catalog prices records the CLI's own cost, reported"
mkjob_opencode j39
FAKE_MODE=complete FAKE_SESSION=ses_paid FAKE_COST=0.0002 "$AL" run j39 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .cost_basis)" = "reported" ] && [ "$(lastrun | jq -r .cost)" = "0.0004" ] \
  && ok "cost 0.0004 reported: two steps at 0.0002, the CLI's number, not an estimate" || bad "cost $(lastrun | jq -c '{cost,cost_basis}')"

echo
}

scenario_40() {
echo "40. a per-run cap over an unknown cost says so instead of never firing"
mkjob_opencode j40 full-access opencode/big-pickle ',"max_budget_usd":1'
FAKE_MODE=complete FAKE_SESSION=ses_cap "$AL" run j40 >/dev/null 2>&1
sleep 2
grep -q 'j40: max_budget_usd 1 not applied: the cost of this run is unknown (no price for opencode/big-pickle-real)' "$ROOT/data/tick.log" \
  && ok "tick.log says the cap could not be applied, and why" || bad "no cap note: $(grep 'j40' "$ROOT/data/tick.log" | tail -2)"
lastrun | jq -r .note | grep -q 'max_budget_usd \$1 not applied' && ok "and so does the run's own note" || bad "note: $(lastrun | jq -r .note)"
[ "$(lastrun | jq -r .status)" = "success" ] && ok "without changing the status" || bad "status $(lastrun | jq -r .status)"

echo
}

scenario_41() {
echo "41. a run that never writes a byte is killed at the stall timeout, whatever its CPU does"
# Measured on OpenCode (evidence 35): a hung CLI process burns ~1 CPU second
# every 75 s of idling, which the watchdog's "CPU changed" test reads as
# life for ever. A stream still EMPTY after stall_timeout_seconds is the one
# shape both measured hangs share, and no healthy run of any platform has:
# the first event is written in seconds.
mkjob j41
sed -i '' 's/"max_parallel":1/"max_parallel":1,"stall_timeout_seconds":4/' "$ROOT/config/jobs.json"
AGENTLOOP_WATCHDOG_POLL=2 FAKE_MODE=silent FAKE_SESSION=sess-silent "$AL" run j41 >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "killed" ] \
  && ok "error / killed" || bad "$(lastrun | jq -c '{status,cause}')"
lastrun | jq -r .note | grep -q 'no output at all for 4s' && ok "the note names the rule: no output at all" || bad "note: $(lastrun | jq -r .note)"

echo
}

scenario_41b() {
echo "41b. a run that wrote its first event and then went quiet is still judged by the old rule"
mkjob j41b
sed -i '' 's/"max_parallel":1/"max_parallel":1,"stall_timeout_seconds":4/' "$ROOT/config/jobs.json"
AGENTLOOP_WATCHDOG_POLL=2 FAKE_MODE=hang FAKE_SESSION=sess-quiet "$AL" run j41b >/dev/null 2>&1
sleep 1
lastrun | jq -r .note | grep -q 'no output and no CPU for 4s' && ok "killed by the CPU-and-output rule, not the empty-stream one" || bad "note: $(lastrun | jq -r .note)"
lastrun | jq -r .note | grep -q 'no output at all' && bad "the empty-stream rule fired on a run that had written" || ok "the empty-stream rule never touches a run that wrote a byte"

echo
}

scenario_41c() {
echo "41c. the case that motivated the rule: an OpenCode run whose provider never answers"
mkjob_opencode j41c
sed -i '' 's/"max_parallel":1/"max_parallel":1,"stall_timeout_seconds":4/' "$ROOT/config/jobs.json"
AGENTLOOP_WATCHDOG_POLL=2 FAKE_MODE=silent FAKE_SESSION=ses_silent "$AL" run j41c >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "killed" ] && ok "error / killed" || bad "$(lastrun | jq -c '{status,cause}')"
lastrun | jq -r .note | grep -q 'no output at all for 4s' && ok "the empty-stream rule ended it (measured 34b: the CLI itself never would)" || bad "note: $(lastrun | jq -r .note)"
[ ! -e "$ROOT"/data/logs/j41c/*.raw.fifo ] && ok "and the FIFO was removed" || bad "FIFO left behind"

echo
}

scenario_42() {
echo "42. a security analysis on OpenCode goes through the stand-in, closes task by rule, and closes done"
jq --arg cwd "$ROOT/work/app" '.projects += [{"name":"sandbox-oc","cwd":$cwd,"base":"main","worktree":{"enabled":true},
   "security":{"enabled":true,"platform":"opencode","model":"pdm_ai/glm-5.3-flash","max_budget_usd":5}}]' \
   "$ROOT/config/projects.json" > "$ROOT/projects.next" && mv "$ROOT/projects.next" "$ROOT/config/projects.json"
argv42="$ROOT/argv-42"; prompt42="$ROOT/prompt-42"; cfg42="$ROOT/cfg-42"; rm -f "$argv42" "$prompt42" "$cfg42"
out42="$(AL_SECURITY_ENGINES=off FAKE_SKIP_PREPARE=1 FAKE_ARGV_OUT="$argv42" FAKE_PROMPT_OUT="$prompt42" FAKE_CONFIG_OUT="$cfg42" \
  FAKE_MODE=complete FAKE_SESSION=ses_sec FAKE_COST=0.0002 \
  "$AL" security analyze sandbox-oc anything main quick 2>&1)"
aid42="$(secid "$out42")"
[ -n "$aid42" ] && ok "the analysis opened: $aid42" || bad "no analysis id in: $out42"
[ "$(secstate sandbox-oc "$aid42")" = "done" ] \
  && ok "and closed done: the engine ran security prepare before the agent, and the close found nothing untriaged" \
  || bad "state '$(secstate sandbox-oc "$aid42")'"
grep -q 'security-sandbox-oc: deterministic phase ran before the agent (prepare' "$ROOT/data/tick.log" \
  && ok "the engine ran prepare before launching opencode (prepare_inline is off)" || bad "no engine-side prepare line"
[ "$(at_in "$argv42" 1)" = "run" ] && ok "it went down the OpenCode launch line" || bad "argv: $(tr '\n' ' ' < "$argv42" 2>/dev/null)"
mi="$(idx_in "$argv42" -m)"; [ -n "${mi:-}" ] && [ "$(at_in "$argv42" $((mi + 1)))" = "pdm_ai/glm-5.3-flash" ] \
  && ok "-m carries the block's model" || bad "-m '$(at_in "$argv42" $((${mi:-0} + 1)))'"
# No `task: deny` since block 4.2: the derived job closes no tool, so nothing
# translates into one here. OpenCode still runs no verification (the prompt
# forbids subagents there and the queue is not served) -- what changed is that
# the denial is no longer expressed as a permission rule.
[ "$(jq -r '.permission.task // "unset"' "$cfg42")" = "unset" ] && ok "no task rule: the derived job closes no tool any more" || bad "permission: $(jq -c .permission "$cfg42")"
[ -n "$(idx_in "$argv42" --auto)" ] && [ "$(jq -r '.permission.bash // "open"' "$cfg42")" != "deny" ] \
  && ok "--auto with bash open: full-access, the security default on opencode" || bad "auto/bash: $(idx_in "$argv42" --auto) / $(jq -c .permission "$cfg42")"
grep -q 'The `task` tool is closed for this run' "$prompt42" && ok "the prompt says the task tool is closed, by rule" || bad "no task paragraph in the prompt"
grep -q 'security-analysis/SKILL.md' "$prompt42" && grep -q 'Invoke the `security-analysis` skill' "$prompt42" \
  && ok "and names the skill by name AND by path (the CLI reads ~/.claude/skills: measured)" || bad "the prompt lacks the skill by name or by path"
grep -q 'ALREADY RAN for this analysis' "$prompt42" && ! grep -q 'YOUR FIRST COMMAND' "$prompt42" \
  && ok "the prompt says the deterministic phase already ran" || bad "the prompt still asks the agent to run prepare"
grep -q 'Do not spawn subagents' "$prompt42" && bad "the Codex-only wording leaked into the opencode prompt" || ok "no Codex wording"
E2E_JOB=security-sandbox-oc   # the derived job, which no mkjob made
[ "$(lastrun | jq -r .id)" = "security-sandbox-oc" ] && [ "$(lastrun | jq -r .platform)" = "opencode" ] && [ "$(lastrun | jq -r .cost_basis)" = "reported" ] \
  && ok "the journal has the derived job's run on opencode, with the CLI's own cost" || bad "$(lastrun | jq -c '{id,platform,cost_basis}')"
sleep 1

}

scenario_43() {
echo "43. two runs in ONE shell: the second inherits nothing from the first"
# run_job hands its parts' results back as RJ_* globals (run_refusals,
# run_launch_and_watch, run_classify). cmd_tick detaches every run into its
# own process, so no two runs share a shell today -- which is exactly why no
# other scenario here would notice one carrying over into the next. This
# drives run_job twice in one shell, the way an in-process loop would: the
# engine sourced (`--help` prints and returns), the first run left dirty and
# ends warning with UNDELIVERED on its note, the second clean. An RJ_REASON
# or RJ_STATUS that carried over would land on the second run's record.
cat > "$ROOT/config/jobs.json" <<JSON
{"jobs":[{"id":"j43a","project":"sandbox","enabled":false,"prompt":"do the thing",
          "interval_seconds":3600,"permission_mode":"bypassPermissions","max_parallel":1},
         {"id":"j43b","project":"sandbox","enabled":false,"prompt":"do the thing",
          "interval_seconds":3600,"permission_mode":"bypassPermissions","max_parallel":1}]}
JSON
mkdir -p "$ROOT/config/prechecks"
printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/j43a.sh"; chmod +x "$ROOT/config/prechecks/j43a.sh"
printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/j43b.sh"; chmod +x "$ROOT/config/prechecks/j43b.sh"
# `$0`, not `$1`: the engine finds its siblings (worktree-lib.sh) from $0,
# and a sourced file sees the shell's own $0 -- so the binary's path goes
# in as the command name of `bash -c`, not as an argument.
bash -c '. "$0" --help >/dev/null 2>&1
         FAKE_MODE=dirty    FAKE_SESSION=sess-43a run_job j43a --force >/dev/null 2>&1
         FAKE_MODE=complete FAKE_SESSION=sess-43b run_job j43b --force >/dev/null 2>&1' "$AL"
sleep 2
[ "$(run_of j43a | jq -r .status)" = "warning" ] && run_of j43a | jq -r .note | grep -q 'UNDELIVERED' \
  && ok "the first run ends warning, with its undelivered work on the note" || bad "first: $(run_of j43a | jq -c '{status,note}')"
[ "$(run_of j43b | jq -r .status)" = "success" ] && [ "$(run_of j43b | jq -r .note)" = "" ] && [ "$(run_of j43b | jq -r .cause)" = "" ] \
  && ok "the second, in the same shell, ends success with an empty note: nothing of the first on it" \
  || bad "second: $(run_of j43b | jq -c '{status,note,cause}')"
[ "$(run_of j43b | jq -r .session)" = "sess-43b" ] && ok "and its record is its own (session sess-43b)" \
  || bad "second run's session: $(run_of j43b | jq -r .session)"
echo
}

# The one slot dir under data/locks/j44 that carries BOTH `child` and
# `forced` -- a bare glob across data/locks/j44/*/forced used to read a
# STALE sibling a previous launch's teardown left behind (it still has
# `child`; the teardown had not gone as far as removing the dir yet, and
# `forced` -- written once, at slot creation -- was already gone) instead of
# the launch actually being waited for. Callers wait for an EMPTY directory
# before starting their own launch (see scenario_44 below), so once this
# finds a dir at all, it is that launch's own -- and requiring `forced`
# specifically, not just `child`, also covers the ordinary case where a slot
# writes its own `forced` a moment after its own `child`.
j44_wait_slot() {
  local w2=0 d
  while [ "$w2" -lt 90 ]; do
    for d in "$ROOT"/data/locks/j44/*/; do
      [ -f "${d}child" ] && [ -f "${d}forced" ] && { printf '%s\n' "${d%/}"; return 0; }
    done
    sleep 1; w2=$((w2 + 1))
  done
  return 1
}

scenario_44() {
echo "44. what launched a run is on its slot from the first second, and on its precheck note after"
# The dialog's Trigger row read every live run as "scheduled — precheck
# passed": the record says `forced` only once the run has ended, and until
# then the server had nothing to read and answered false (2026-09-14: a
# security analysis launched from a terminal, shown as scheduled for its
# whole nineteen minutes). The slot says it now, from the first second. The
# precheck note -- the Precheck tab's text -- names the launch for what it
# was: Run now here, the resumed session in scenario 3, the analysis and the
# command in scenario 8, and nothing at all for a tick.
mkjob j44 hang
# A slot dir the PREVIOUS scenario's own teardown has not finished removing
# yet would otherwise be read as THIS launch's -- wait for a clean directory
# before starting it, not just before reading it.
w=0; while [ "$w" -lt 90 ] && [ -n "$(ls "$ROOT/data/locks/j44" 2>/dev/null)" ]; do sleep 1; w=$((w + 1)); done
[ -z "$(ls "$ROOT/data/locks/j44" 2>/dev/null)" ] || bad "a slot from an earlier run is still there after ${w}s: $(ls "$ROOT/data/locks/j44")"
FAKE_MODE=hang FAKE_SESSION=sess-44-now "$AL" run j44 >/dev/null 2>&1 &
j44s="$(j44_wait_slot)"
[ -n "$j44s" ] && [ "$(cat "$j44s/forced" 2>/dev/null)" = "true" ] \
  && ok "Run now, still going: the slot says forced" \
  || bad "slot forced='$(cat "$j44s/forced" 2>/dev/null)' (slot: ${j44s:-none found in time})"
"$AL" stop j44 >/dev/null 2>&1
wait
pc44="$(lastrun | jq -r .log)"; pc44="${pc44%.json}.precheck.txt"
grep -q '^RUN FORCED (Run now)' "$pc44" 2>/dev/null && ok "and its precheck note says Run now" || bad "note: $(cat "$pc44" 2>/dev/null)"
# The same job the way a tick launches it: `_exec` is what cmd_tick hands a
# due job to, and the one launch that is NOT forced -- driven here directly
# rather than through the tick's own due/window logic, which is not what
# this scenario is about. With a precheck this time, so the note has a
# verdict to carry.
jq '.jobs[0].enabled = true | .jobs[0].precheck = "exit 0"' \
  "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
w=0; while [ "$w" -lt 90 ] && [ -n "$(ls "$ROOT/data/locks/j44" 2>/dev/null)" ]; do sleep 1; w=$((w + 1)); done
[ -z "$(ls "$ROOT/data/locks/j44" 2>/dev/null)" ] || bad "a slot from the previous launch is still there after ${w}s: $(ls "$ROOT/data/locks/j44")"
FAKE_MODE=hang FAKE_SESSION=sess-44-tick "$AL" _exec j44 >/dev/null 2>&1 &
j44s="$(j44_wait_slot)"
[ -n "$j44s" ] && [ "$(cat "$j44s/forced" 2>/dev/null)" = "false" ] \
  && ok "a tick's launch, still going: the slot says not forced" \
  || bad "slot forced='$(cat "$j44s/forced" 2>/dev/null)' (slot: ${j44s:-none found in time})"
"$AL" stop j44 >/dev/null 2>&1
wait
[ "$(lastrun | jq -r .session)" = "sess-44-tick" ] && [ "$(lastrun | jq -r .forced)" = "false" ] \
  && ok "and its record says so too" || bad "record: $(lastrun | jq -c '{session,forced,status}')"
pc44="$(lastrun | jq -r .log)"; pc44="${pc44%.json}.precheck.txt"
! grep -q 'RUN FORCED' "$pc44" 2>/dev/null && grep -q 'pass → work found' "$pc44" 2>/dev/null \
  && ok "and its precheck note is the precheck's own verdict, with no launch line" || bad "note: $(cat "$pc44" 2>/dev/null)"
[ -z "$(ls "$ROOT/data/locks/j44" 2>/dev/null)" ] && ok "and no slot outlived either run" || bad "slots left: $(ls "$ROOT/data/locks/j44")"

echo
}

scenario_45() {
echo "45. a tick launches a job that has no schedule window"
# Every scenario above starts its run with `run` or `_exec`; nothing had ever
# driven cmd_tick's own due-job loop, and that loop read tick_plan's tabs with
# IFS=tab -- which bash folds, so a job with no active_days and no
# active_hours came through with its columns shifted (days=interval,
# hours=last_start) and was "outside active_hours" on every tick, silently.
# j45b is config/jobs.example.json's own shape: days set, hours "".
cat > "$ROOT/config/jobs.json" <<JSON
{"jobs":[{"id":"j45a","project":"sandbox","enabled":true,"prompt":"do the thing",
          "interval_seconds":3600,"permission_mode":"bypassPermissions","max_parallel":1},
         {"id":"j45b","project":"sandbox","enabled":true,"prompt":"do the thing",
          "interval_seconds":3600,"permission_mode":"bypassPermissions","max_parallel":1,
          "active_days":[1,2,3,4,5,6,7],"active_hours":""}]}
JSON
FAKE_MODE=complete FAKE_SESSION=sess-45 "$AL" tick >/dev/null 2>&1
grep -q 'j45a: launched detached run' "$ROOT/data/tick.log" && ok "a job with no window at all is launched by the tick" \
  || bad "no launch line for j45a: $(grep 'j45' "$ROOT/data/tick.log" | tail -2)"
grep -q 'j45b: launched detached run' "$ROOT/data/tick.log" && ok "and so is one with days set and hours blank (the example file's shape)" \
  || bad "no launch line for j45b: $(grep 'j45' "$ROOT/data/tick.log" | tail -2)"
# The tick detaches both runs; wait for their records rather than for a child.
w=0; while [ "$w" -lt 20 ] && { [ -z "$(run_of j45a)" ] || [ -z "$(run_of j45b)" ]; }; do sleep 1; w=$((w + 1)); done
[ "$(run_of j45a | jq -r .status)" = "success" ] && [ "$(run_of j45a | jq -r .forced)" = "false" ] \
  && ok "j45a ran to a clean success, not forced (waited ${w}s for the records)" || bad "j45a: $(run_of j45a | jq -c '{status,forced}')"
[ "$(run_of j45b | jq -r .status)" = "success" ] && [ "$(run_of j45b | jq -r .forced)" = "false" ] \
  && ok "and so did j45b" || bad "j45b: $(run_of j45b | jq -c '{status,forced}')"
sleep 1   # let both detached runs finish their own teardown before the next scenario

echo
}

scenario_46() {
echo "46. an analysis of the second repo of a project runs in that repo alone, at its branch"
# The project's cwd is `app`; the analysis names `api`, at a branch only `api`
# has. Every declared repo used to be cut from the analysed branch, so this was
# refused at `app` ("no base ref resolvable") -- and at a branch both repos
# have, the run was in `app` whatever repo was named: `prepare` and the agent
# read app's code into a report filed under api.
# No job of its own, but a jobs file all the same: a derived job is read
# through it, and an earlier scenario's is not this one's to lean on.
printf '{"jobs":[]}\n' > "$ROOT/config/jobs.json"
git init -q --bare "$ROOT/remote/api.git"
git init -q "$ROOT/work/api"
git -C "$ROOT/work/api" remote add origin "$ROOT/remote/api.git"
printf 'api\n' > "$ROOT/work/api/API"
git -C "$ROOT/work/api" add -A
git -C "$ROOT/work/api" -c user.email=e2e@local -c user.name=e2e commit -qm api
git -C "$ROOT/work/api" push -q origin HEAD:refs/heads/main
git -C "$ROOT/work/api" checkout -q -b feat/api-only
printf 'only here\n' > "$ROOT/work/api/ONLY"
git -C "$ROOT/work/api" add -A
git -C "$ROOT/work/api" -c user.email=e2e@local -c user.name=e2e commit -qm only
git -C "$ROOT/work/api" push -q origin HEAD:refs/heads/feat/api-only
git -C "$ROOT/work/api" fetch -q origin
sha46="$(git -C "$ROOT/work/api" rev-parse feat/api-only)"
jq --arg app "$ROOT/work/app" --arg api "$ROOT/work/api" \
  '.projects += [{name:"multi", cwd:$app, worktree:{enabled:true},
                  repos:[{name:"app", path:$app, base:"main"}, {name:"api", path:$api, base:"main"}],
                  security:{enabled:true, model:"claude-opus-5", max_budget_usd:5}}]' \
  "$ROOT/config/projects.json" > "$ROOT/config/projects.next" \
  && mv "$ROOT/config/projects.next" "$ROOT/config/projects.json"
cwd46="$ROOT/cwd46"
rm -f "$cwd46"
out46="$(FAKE_CWD_OUT="$cwd46" FAKE_MODE=complete FAKE_SESSION=sess-sec-multi \
  "$AL" security analyze multi api feat/api-only quick 2>&1)"
aid46="$(secid "$out46")"
at46() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$cwd46" 2>/dev/null; }
case "$(at46 PWD)" in
  */security-multi/*/api) ok "the agent is launched in a worktree of api, the repo the analysis named" ;;
  *) bad "the agent ran in '$(at46 PWD)' -- $(printf '%s' "$out46" | head -1)" ;;
esac
[ "$(at46 HEAD)" = "$sha46" ] \
  && ok "cut from feat/api-only, a branch app does not have" \
  || bad "the worktree was at '$(at46 HEAD)', want $sha46"
[ "$(at46 MANIFEST | jq -r '[.primary, (.repos | map(.name) | join(","))] | join(" ")' 2>/dev/null)" = "api api" ] \
  && ok "and the run is api alone: nothing else was cut" \
  || bad "manifest: $(at46 MANIFEST)"
[ "$("$AL" security list --project multi 2>/dev/null \
      | jq -r --argjson a "${aid46:-0}" '.[] | select(.id == $a) | [.state, .repo, .commit_sha] | join(" ")')" \
    = "done api $sha46" ] \
  && ok "and analysis $aid46 closes done, filed under api at that commit" \
  || bad "analysis row: $("$AL" security list --project multi 2>/dev/null | jq -c --argjson a "${aid46:-0}" '.[] | select(.id == $a) | {state, repo, commit_sha}')"

echo
}

scenario_47() {
echo "47. a job on a registered Claude account launches in that account's directory, and so does its precheck"
mkdir -p "$ROOT/accounts/claude-a"
"$AL" platform account-add anthropic "Client A" "$ROOT/accounts/claude-a" >/dev/null 2>&1 || bad "account-add over the stand-in failed"
mkjob_acct j47 client-a
jq --arg pc "printf '%s' \"\${CLAUDE_CONFIG_DIR-<unset>}\" > $ROOT/pc-47; exit 0" '.jobs[0].precheck = $pc' \
  "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
acct47="$ROOT/account-47"; rm -f "$acct47" "$ROOT/pc-47" "$ROOT/data/rate-limits.json"
FAKE_ACCOUNT_OUT="$acct47" FAKE_MODE=complete FAKE_SESSION=sess-47 FAKE_RATE_LIMIT_EVENT=1 "$AL" run j47 >/dev/null 2>&1
sleep 1
[ "$(cat "$acct47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "the agent runs with CLAUDE_CONFIG_DIR set to the account's directory" || bad "the agent saw '$(cat "$acct47" 2>/dev/null)'"
[ "$(cat "$ROOT/pc-47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "and so does its precheck" || bad "the precheck saw '$(cat "$ROOT/pc-47" 2>/dev/null)'"
[ "$(lastrun | jq -r '[.account, .account_dir] | join(" ")')" = "client-a $ROOT/accounts/claude-a" ] \
  && ok "the journal records the account and the directory the run used" || bad "record: $(lastrun | jq -c '{account, account_dir}')"
# run_job's own Claude capture key: the run's rate_limit_event lands in this
# account's block (rl_key), never the bare platform one -- fake-claude never
# emitted one at all until FAKE_RATE_LIMIT_EVENT above gave it one to capture.
[ "$(jq -r --arg k "anthropic@$ROOT/accounts/claude-a" '.[$k].seven_day.utilization' "$ROOT/data/rate-limits.json" 2>/dev/null)" = "0.98" ] \
  && [ "$(jq -r 'has("anthropic")' "$ROOT/data/rate-limits.json" 2>/dev/null)" = "false" ] \
  && ok "the run's usage reading lands in anthropic@<account dir>, not the bare anthropic block" \
  || bad "rate-limits after an account run: $(cat "$ROOT/data/rate-limits.json" 2>/dev/null)"
rm -f "$ROOT/data/rate-limits.json"
rm -f "$ROOT/pc-47"
"$AL" check j47 >/dev/null 2>&1
[ "$(cat "$ROOT/pc-47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "agentloop check runs the precheck on the same account too" || bad "check saw '$(cat "$ROOT/pc-47" 2>/dev/null)'"
rm -f "$ROOT/pc-47"
"$AL" precheck j47 >/dev/null 2>&1
[ "$(cat "$ROOT/pc-47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "and so does agentloop precheck, standalone" || bad "precheck saw '$(cat "$ROOT/pc-47" 2>/dev/null)'"

echo
}

scenario_48() {
echo "48. a job on a registered Codex account launches with that CODEX_HOME, and its rollout is read from there"
mkdir -p "$ROOT/accounts/codex-a"
"$AL" platform account-add openai "Client A" "$ROOT/accounts/codex-a" >/dev/null 2>&1 || bad "openai account-add failed"
mkjob_acct j48 client-a openai
acct48="$ROOT/account-48"; rm -f "$acct48"
FAKE_ACCOUNT_OUT="$acct48" FAKE_MODE=complete FAKE_SESSION=thr-48 "$AL" run j48 >/dev/null 2>&1
sleep 1
[ "$(cat "$acct48" 2>/dev/null)" = "$ROOT/accounts/codex-a" ] \
  && ok "the Codex CLI runs with CODEX_HOME set to the account's home" || bad "codex saw '$(cat "$acct48" 2>/dev/null)'"
ls "$ROOT"/accounts/codex-a/sessions/*/*/*/rollout-*-thr-48.jsonl >/dev/null 2>&1 \
  && ok "the stand-in wrote its rollout under that home" || bad "no rollout under the account's home"
[ "$(lastrun | jq -r .model_id)" = "gpt-5.6-sol-real" ] \
  && ok "and model_id came from it: the rollout was looked for where the run wrote it" || bad "model_id $(lastrun | jq -r .model_id)"

echo
}

scenario_49() {
echo "49. an account on the CLI's own directory runs with CLAUDE_CONFIG_DIR unset, even under a pin"
# Claude Code reads its credentials from another Keychain entry the moment
# CLAUDE_CONFIG_DIR is set at all -- even to ~/.claude (measured, 2.1.280) --
# so an account there must reach the CLI with the variable gone. A home of
# its own for the engine: ~/.claude is the sandbox's.
home49="$ROOT/home-49"; mkdir -p "$home49/.claude" "$ROOT/pinned-49"
HOME="$home49" AGENTLOOP_CLAUDE_CONFIG_DIR="$ROOT/pinned-49" \
  "$AL" platform account-add anthropic "Home" "~/.claude" >/dev/null 2>&1 || bad "account-add of ~/.claude under a pin failed"
mkjob_acct j49 home
acct49="$ROOT/account-49"; rm -f "$acct49"
HOME="$home49" AGENTLOOP_CLAUDE_CONFIG_DIR="$ROOT/pinned-49" FAKE_ACCOUNT_OUT="$acct49" \
  FAKE_MODE=complete FAKE_SESSION=sess-49 "$AL" run j49 >/dev/null 2>&1
sleep 1
[ -f "$acct49" ] && [ -z "$(cat "$acct49")" ] \
  && ok "the agent ran with no CLAUDE_CONFIG_DIR at all: not the pin, not ~/.claude" || bad "the agent saw '$(cat "$acct49" 2>/dev/null)'"
[ "$(lastrun | jq -r '[.account, .account_dir] | join("|")')" = "home|" ] \
  && ok "and the journal says so: the account, and no directory to export" || bad "record: $(lastrun | jq -c '{account, account_dir}')"

echo
}

scenario_50() {
echo "50. a job on an account with no session, or one Settings does not have, is refused before a slot"
mkdir -p "$ROOT/accounts/claude-out"; : > "$ROOT/accounts/claude-out/.fake-logged-out"
"$AL" platform account-add anthropic "Signed Out" "$ROOT/accounts/claude-out" >/dev/null 2>&1 || bad "account-add failed"
mkjob_acct j50 signed-out
FAKE_MODE=complete FAKE_SESSION=sess-50 "$AL" run j50 >/dev/null 2>&1
grep -qF "j50: anthropic is not ready (claude is not signed in in $ROOT/accounts/claude-out (run: CLAUDE_CONFIG_DIR=$ROOT/accounts/claude-out claude auth login)), skipped" "$ROOT/data/tick.log" \
  && ok "no session: the refusal names the account's directory and the login to run" || bad "no refusal line: $(tail -3 "$ROOT/data/tick.log")"
# dirs() alone does not prove this: FAKE_MODE=complete removes its own
# worktree once a run finishes, so an empty tree also describes a run that
# launched and was cleaned up. A log directory and a journal record are not
# cleaned up that way -- their absence is what actually proves no slot ran.
[ ! -d "$ROOT/data/logs/j50" ] && [ -z "$(run_of j50)" ] && [ -z "$(dirs j50)" ] \
  && ok "and no run directory, log or journal record was left behind" \
  || bad "log dir: $(ls -d "$ROOT/data/logs/j50" 2>&1); record: $(run_of j50); dirs j50: $(dirs j50)"
mkjob_acct j50c ghost
"$AL" run j50c >/dev/null 2>&1
grep -qF "j50c: account 'ghost' is not an account of anthropic in Settings, skipped" "$ROOT/data/tick.log" \
  && ok "an account Settings does not have is refused by name" || bad "no ghost refusal: $(tail -3 "$ROOT/data/tick.log")"
# check must refuse the same unregistered account before it even asks whether
# the job has a precheck -- j50c has none yet (mkjob_acct sets no precheck
# field), so this is the plain "account not known" route the OpenCode one
# below (j50e) is not: every platform's accounts gate check the same way.
out50c0="$("$AL" check j50c 2>&1)"; rc50c0=$?
[ "$rc50c0" -ne 0 ] && [ "$out50c0" = "j50c: account 'ghost' is not an account of anthropic in Settings" ] \
  && ok "agentloop check refuses an unregistered account before it even asks whether there is a precheck" \
  || bad "check j50c with no precheck: rc=$rc50c0 out='$out50c0'"
# The standalone probes must refuse the same unregistered account, before
# ever touching the precheck script -- not silently ask the CLI's default.
jq --arg pc "printf '%s' \"\${CLAUDE_CONFIG_DIR-<unset>}\" > $ROOT/pc-50c; exit 0" '.jobs[0].precheck = $pc' \
  "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
rm -f "$ROOT/pc-50c"
out50c="$("$AL" check j50c 2>&1)"; rc50c=$?
[ "$rc50c" -ne 0 ] && [ "$out50c" = "j50c: account 'ghost' is not an account of anthropic in Settings" ] && [ ! -f "$ROOT/pc-50c" ] \
  && ok "agentloop check refuses the unregistered account before the precheck runs" \
  || bad "check j50c: rc=$rc50c out='$out50c' pc50c='$(cat "$ROOT/pc-50c" 2>/dev/null)'"
rm -f "$ROOT/pc-50c"
out50cp="$("$AL" precheck j50c 2>&1)"; rc50cp=$?
[ "$rc50cp" -ne 0 ] && [ "$out50cp" = "j50c: account 'ghost' is not an account of anthropic in Settings" ] && [ ! -f "$ROOT/pc-50c" ] \
  && ok "agentloop precheck refuses it too, before running anything" \
  || bad "precheck j50c: rc=$rc50cp out='$out50cp' pc50c='$(cat "$ROOT/pc-50c" 2>/dev/null)'"
# The two gates the selftest can only see in run_refusals' own source (no
# scenario ever tripped them for real): a directory gone after registration,
# and OpenCode -- which has no accounts at all -- naming one anyway.
mkdir -p "$ROOT/accounts/claude-missing"
"$AL" platform account-add anthropic "Missing Dir" "$ROOT/accounts/claude-missing" >/dev/null 2>&1 || bad "account-add (missing-dir fixture) failed"
rm -rf "$ROOT/accounts/claude-missing"
mkjob_acct j50d missing-dir
"$AL" run j50d >/dev/null 2>&1
grep -qF "j50d: account 'Missing Dir' is missing its directory ($ROOT/accounts/claude-missing), skipped" "$ROOT/data/tick.log" \
  && ok "a registered account whose directory disappeared is refused by name" || bad "no missing-dir refusal: $(tail -3 "$ROOT/data/tick.log")"
mkjob_opencode j50e
jq '.jobs[0].account = "nope"' "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
"$AL" run j50e >/dev/null 2>&1
grep -qF "j50e: OpenCode has no accounts (account 'nope'), skipped" "$ROOT/data/tick.log" \
  && ok "an OpenCode job naming an account is refused: OpenCode has none" || bad "no opencode-account refusal: $(tail -3 "$ROOT/data/tick.log")"
# check must refuse an OpenCode job's account with the launch gate's own
# sentence, not the generic "is not an account of" one -- and before it even
# asks whether the job has a precheck: j50e has none, and every due tick
# would be refused just the same.
out50e="$("$AL" check j50e 2>&1)"; rc50e=$?
[ "$rc50e" -ne 0 ] && [ "$out50e" = "j50e: OpenCode has no accounts (account 'nope')" ] \
  && ok "agentloop check refuses an OpenCode account with its own sentence, even with no precheck" \
  || bad "check j50e: rc=$rc50e out='$out50e'"
jq --arg pc "printf '%s' \"\${CLAUDE_CONFIG_DIR-<unset>}\" > $ROOT/pc-50e; exit 0" '.jobs[0].precheck = $pc' \
  "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
rm -f "$ROOT/pc-50e"
out50ep="$("$AL" precheck j50e 2>&1)"; rc50ep=$?
[ "$rc50ep" -ne 0 ] && [ "$out50ep" = "j50e: OpenCode has no accounts (account 'nope')" ] && [ ! -f "$ROOT/pc-50e" ] \
  && ok "agentloop precheck refuses it with the same sentence, before running anything" \
  || bad "precheck j50e: rc=$rc50ep out='$out50ep' pc50e='$(cat "$ROOT/pc-50e" 2>/dev/null)'"
mkjob j50b
FAKE_MODE=complete FAKE_SESSION=sess-50b "$AL" run j50b >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .session)" = "sess-50b" ] && ok "a job on the Default account runs as before" || bad "the Default job did not run: $(lastrun)"

echo
}

scenario_51() {
echo "51. a resume signs in where its session was created, whatever the job says now"
mkdir -p "$ROOT/accounts/claude-r1" "$ROOT/accounts/claude-r2"
"$AL" platform account-add anthropic "R1" "$ROOT/accounts/claude-r1" >/dev/null 2>&1
"$AL" platform account-add anthropic "R2" "$ROOT/accounts/claude-r2" >/dev/null 2>&1
mkjob_acct j51 r1
FAKE_MODE=undeclared FAKE_SESSION=sess-51 "$AL" run j51 >/dev/null 2>&1
sleep 2
printf 'r2' | "$AL" set-field j51 account >/dev/null 2>&1 || bad "set-field account r2 failed"
# No job names R1 any more (j51 is now on r2) -- removing it from Settings
# proves the resume below signs in with the recorded directory even though
# the account id itself no longer exists there to be looked up.
"$AL" platform account-remove anthropic r1 >/dev/null 2>&1
[ $? -eq 0 ] && ok "R1 can be removed from Settings now that no job names it" || bad "account-remove r1 failed"
acct51="$ROOT/account-51"; rm -f "$acct51"
FAKE_ACCOUNT_OUT="$acct51" FAKE_MODE=complete FAKE_SESSION=sess-51 "$AL" resume j51 sess-51 >/dev/null 2>&1
sleep 2
[ "$(cat "$acct51" 2>/dev/null)" = "$ROOT/accounts/claude-r1" ] \
  && ok "the resume ran on R1, where sess-51 lives, though the job now names R2" || bad "the resume saw '$(cat "$acct51" 2>/dev/null)'"
[ "$(lastrun | jq -r .account)" = "r1" ] && ok "and its record names R1 too" || bad "resume record: $(lastrun | jq -c '{account, account_dir}')"
# A pre-feature record -- no `account` key at all, as from before this
# feature existed -- grants no exemption: run_job only skips the id gate
# when it actually read an account off THIS session's own record, so a job
# naming an id Settings does not have is still refused, exactly like a
# plain run.
mkjob_acct j51c ghost
printf '{"id":"j51c","platform":"anthropic","session":"sess-51c"}\n' >> "$ROOT/data/runs.ndjson"
"$AL" resume j51c sess-51c >/dev/null 2>&1
grep -qF "j51c: account 'ghost' is not an account of anthropic in Settings, skipped" "$ROOT/data/tick.log" \
  && ok "a resume of a record with no account key gets no exemption: an unregistered id is still refused" \
  || bad "no refusal for the unexempted resume: $(tail -3 "$ROOT/data/tick.log")"

echo
}

scenario_52() {
echo "52. one account's spent window holds its own scheduled runs back, not another account's"
mkdir -p "$ROOT/accounts/claude-rl"
"$AL" platform account-add anthropic "Limited" "$ROOT/accounts/claude-rl" >/dev/null 2>&1 || bad "account-add failed"
soon52="$(( $(date +%s) + 3600 ))"
jq -n --arg k "anthropic@$ROOT/accounts/claude-rl" --argjson r "$soon52" \
  '{($k): {five_hour: {status:"allowed", utilization:0.97, resets_at:$r, overage:null, seen_at:0}}}' > "$ROOT/data/rate-limits.json"
mkjob_acct j52 limited
"$AL" _exec j52 >/dev/null 2>&1
grep -qF "j52: usage limit reached — the anthropic five_hour window of Limited is 97% used" "$ROOT/data/tick.log" \
  && ok "a scheduled run on the spent account is held back, and the line names the account" || bad "no hold line: $(tail -3 "$ROOT/data/tick.log")"
mkjob j52b
FAKE_MODE=complete FAKE_SESSION=sess-52b "$AL" _exec j52b >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .session)" = "sess-52b" ] && ok "while a scheduled run on the Default account goes ahead" || bad "the Default run was held: $(tail -3 "$ROOT/data/tick.log")"
rm -f "$ROOT/data/rate-limits.json"

echo
}


# ---------------------------------------------------------------- the runner
# The scenarios in file order. E2E_WORKERS=4, the default, runs the four
# static lists below side by side, one sandbox each, and prints the four
# outputs in list order -- never interleaved, which is unreadable the day
# something fails. E2E_WORKERS=1 runs them all in one sandbox, in file order,
# with the output every reader of this file has always seen: bisect with it.
# The default moved to 4 only after ten consecutive four-worker runs passed
# clean (2026-09-13, 84-89 s each, 181/181): a parallel suite that fails one
# time in ten teaches everybody to press "retry", and from then on protects
# nothing.
#
# THE LISTS ARE CONTIGUOUS RANGES OF THE FILE ORDER, on purpose. Four
# scenarios depend on an earlier one's sandbox state (3 resumes 2's run, 15
# resumes 14's and reads 12's `mi`, 31 resumes 30's), and a contiguous range
# preserves every such order without anyone having to find the rest. They
# were balanced on measured durations (2026-09-13: 312 s in all, the two
# security analyses 37 s each, most others 4-5 s): 79 / 82 / 72 / 78 s. A new
# scenario goes at the END of the file and into the LAST list, or, if it is
# heavy, wherever it keeps the lists within a few seconds of each other --
# and the count assertion below fails if it is forgotten from every list.
E2E_ALL="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 17b 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 33b 34 35 35b 36 37 38 39 40 41 41b 41c 42 43 44 45 46 47 48 49 50 51 52"
E2E_LIST_1="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 17b 18 19"
E2E_LIST_2="20 21 22 23 24 25 26"
E2E_LIST_3="27 28 29 30 31 32 33 33b 34 35 35b 36 37"
E2E_LIST_4="38 39 40 41 41b 41c 42 43 44 45 46 47 48 49 50 51 52"

# What a sandbox needs BEFORE the scenarios that use a platform's catalog: the
# price table, and the two catalogs resolved from the stand-ins. These used to
# be done in passing by scenario 12 (openai) and scenario 28 (opencode), and
# every later scenario leaned on that without saying so -- which held only
# while all of them ran in one sandbox in file order, and broke the moment a
# worker started at 20 or 38. Done here, per sandbox, and still done again by
# 12 and 28 where they always were: both are idempotent, and 28 in
# particular deletes and reseeds platforms.json around its own resolve.
e2e_catalogs() {
  cp "$REPO/config/pricing.example.json" "$ROOT/config/pricing.json"
  "$AL" resolve-models openai >/dev/null 2>&1
  "$AL" resolve-models opencode >/dev/null 2>&1
}

e2e_run_list() { # e2e_run_list <root> <ids...> -> runs them in order in that sandbox
  local root="$1"; shift
  e2e_sandbox "$root"
  e2e_catalogs
  local sid
  for sid in "$@"; do "scenario_$sid"; done
}

E2E_WORKERS="${E2E_WORKERS:-4}"
case "$E2E_WORKERS" in 1|4) ;; *) echo "E2E_WORKERS must be 1 or 4 (got $E2E_WORKERS)" >&2; exit 2 ;; esac

# every scenario is in exactly one list -- a scenario added to the file and
# forgotten from the lists would silently never run
_listed="$(printf "%s\n" $E2E_LIST_1 $E2E_LIST_2 $E2E_LIST_3 $E2E_LIST_4 | sort)"
_all="$(printf "%s\n" $E2E_ALL | sort)"
if [ "$_listed" != "$_all" ]; then
  echo "the worker lists and the scenario set disagree:" >&2
  diff <(printf "%s\n" "$_all") <(printf "%s\n" "$_listed") >&2 || true
  exit 2
fi

if [ "$E2E_WORKERS" = 1 ]; then
  trap 'rm -rf "$E2E/sandbox"' EXIT
  e2e_run_list "$E2E/sandbox" $E2E_ALL
else
  trap 'rm -rf "$E2E"/sandbox-[1-4] "$E2E"/e2e-out-[1-4] "$E2E"/e2e-rc-[1-4]' EXIT
  _pids=""
  for _w in 1 2 3 4; do
    eval "_list=\$E2E_LIST_$_w"
    # a subshell: pass/fail are its own and come back through a file, because
    # a child cannot hand a variable to its parent
    ( e2e_run_list "$E2E/sandbox-$_w" $_list > "$E2E/e2e-out-$_w" 2>&1
      printf "%s %s\n" "$pass" "$fail" > "$E2E/e2e-rc-$_w" ) &
    _pids="$_pids $!"
  done
  for _p in $_pids; do wait "$_p"; done
  pass=0; fail=0
  for _w in 1 2 3 4; do
    cat "$E2E/e2e-out-$_w"
    read -r _p _f < "$E2E/e2e-rc-$_w"
    pass=$((pass + _p)); fail=$((fail + _f))
  done
fi

echo
printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
