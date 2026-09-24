# The offline suite, carried out of bin/agentloop so that file is the engine
# and not half test code. SOURCED, never executed: these checks call the
# engine's own functions -- job_get, num, now_epoch, platform_check, resolve
# -- in the engine's own shell, which a separate process would not have.
# `agentloop selftest` sources this at the moment the verb runs, so a tick
# never parses what it will never run.
#
# check_ui_artifact and check_ui_artifacts travel with the suite: they report
# through its own `ok`/`bad`, which exist only inside cmd_selftest, so they
# were never callable from anywhere else.

# One artifact's two freshness questions, asked the same way for each. This
# was written out once, inline, for bin/static/security.js; a second and third
# artifact copied three times over is three places for the next fix to reach
# two of.
#
# bin/static/security.js, bin/static/app.js and bin/static/app.css are
# COMMITTED: installing agentloop needs jq, python3 and curl, never Node.
# The price of that is a build output in git, which can be forgotten — and a
# stale artifact is a dashboard silently running last week's code, with
# nothing on screen to say so.
# TWO questions, and only the first of them used to be asked. `ui-sources`
# answers "was this built from the sources sitting next to it" -- the
# forgot-to-rebuild case. `ui-bundle` answers "and is this still what that
# build produced, AS THIS FILE" -- nothing hashed the committed bytes, so
# code injected straight into the artifact, with every source and every
# toolchain file untouched, passed this check without a word. A mangled
# merge conflict inside a generated file is that same shape, and nobody
# reads a generated file to find one.
#
# `ui-bundle` binds the artifact's own name into that hash (build/ui-bundle-
# digest.sh, called below exactly as build/build-ui.sh calls it) so a
# stamp only ever verifies against the file it was written for. Without
# that, `cp bin/static/app.js bin/static/app.css` leaves app.css holding a
# body that genuinely IS what its stamp describes -- app.js's body, stamp
# and all -- so a digest blind to which file it was asked about reports it
# clean while the dashboard would load JavaScript as a stylesheet.
#
# Both stamps are read with an EXACTLY-ONE rule rather than `tail -1`. That
# was the second hole: appending a second `/* ui-sources: ... */` line
# carrying a freshly computed digest satisfied the old reader while the real
# stamp, the one describing the bytes above it, sat ignored one line up.
#
# The captured value is anchored to `[0-9a-f]\{64\}`, the fixed SHA-256
# shape, not `.*`. A block comment can be CLOSED AND REOPENED mid-line,
# which `//` cannot: one physical line shaped
# `/* ui-bundle: <real hash> */<injected code>/* ui-bundle: <fake hash> */`
# used to count and extract as a single well-formed stamp while
# build/ui-bundle-digest.sh's equally greedy strip deleted that whole line
# -- injected code included -- before hashing, so the tampered bundle
# hashed identically to the untampered one. A line carrying anything past
# the 64 hex characters now fails to match at all, so it stays in the body
# and the ordinary hash-mismatch branch below catches it.
check_ui_artifact() { # <path relative to BASE_DIR>
  local _rel="$1" _bundle="$BASE_DIR/$1" _stamp _want _bstamp _bwant _ns _nb
  if [ ! -f "$_bundle" ]; then
    bad "$_rel is missing — run build/build-ui.sh"; return
  fi
  _ns="$(grep -c '^/\* ui-sources: [0-9a-f]\{64\} \*/$' "$_bundle" || true)"
  _nb="$(grep -c '^/\* ui-bundle: [0-9a-f]\{64\} \*/$' "$_bundle" || true)"
  _stamp="$(sed -n 's|^/\* ui-sources: \([0-9a-f]\{64\}\) \*/$|\1|p' "$_bundle")"
  _bstamp="$(sed -n 's|^/\* ui-bundle: \([0-9a-f]\{64\}\) \*/$|\1|p' "$_bundle")"
  _want="$(bash "$BASE_DIR/build/ui-digest.sh" 2>/dev/null)"
  _bwant="$(bash "$BASE_DIR/build/ui-bundle-digest.sh" "$_bundle" 2>/dev/null)"
  if [ "${_ns:-0}" != "1" ] || [ "${_nb:-0}" != "1" ]; then
    bad "$_rel carries ${_ns:-0} ui-sources and ${_nb:-0} ui-bundle stamps — exactly one of each is expected; run build/build-ui.sh"
  elif [ -z "$_want" ] || [ -z "$_bwant" ]; then
    bad "could not fingerprint ui/ or $_rel — is shasum on PATH?"
  elif [ "$_stamp" != "$_want" ]; then
    bad "$_rel is stale — run build/build-ui.sh"
  elif [ "$_bstamp" != "$_bwant" ]; then
    bad "$_rel has been MODIFIED since it was built — its body no longer hashes to its own stamp; rebuild with build/build-ui.sh and check what changed"
  else
    ok "$_rel matches the sources it was built from, and has not been touched since"
  fi
}

# check_ui_artifact one file at a time is only as complete as whoever calls
# it: `bin/static/` is not three fixed names, it is whatever static_asset()
# will serve and _build_id() will hash -- any .js/.css dropped in there is
# live and cache-busted whether or not this function was ever told about it.
# Iterating the directory itself, instead of restating its current contents
# as a list of literals, is what makes a fourth artifact (Phases 2 and 3 are
# exactly the phases expected to add one) impossible to add without also
# making it pass this check.
check_ui_artifacts() {
  local _f
  for _f in "$BASE_DIR"/bin/static/*.js "$BASE_DIR"/bin/static/*.css; do
    [ -f "$_f" ] || continue
    check_ui_artifact "bin/static/${_f##*/}"
  done
}

cmd_selftest() { # offline checks of the logic that can kill a run or lose money
  local pass=0 fail=0 tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/alselftest.XXXXXX")"
  # CODEX_BIN/CLAUDE_BIN/OPENCODE_BIN (the globals platform_bin() falls back
  # to) were computed from these at load time; the suite below points at its
  # own stand-ins by assigning those globals directly, or by prefixing a
  # subprocess explicitly (cfg_al). An AGENTLOOP_*_BIN exported by the
  # invoking shell must not reach platform_bin() here.
  AGENTLOOP_CLAUDE_BIN=""; AGENTLOOP_CODEX_BIN=""; AGENTLOOP_OPENCODE_BIN=""
  # installed_config_dir / account_default_dir read $PLIST_PATH, which is
  # derived from this: unlike CONFIG/DATA (redirected per block below, each
  # block wants its own) this needs no per-block isolation, only to never be
  # the operator's own ~/Library/LaunchAgents. Exported once, for the whole
  # suite, so it reaches every block that calls the engine in-process AND
  # every one that shells out to a real `agentloop` subprocess (pc_al and
  # its kin) alike -- a developer machine whose live install is pinned must
  # never leak that account into a fake run here.
  mkdir -p "$tmp/LaunchAgents"
  export AGENTLOOP_LAUNCH_AGENTS_DIR="$tmp/LaunchAgents"
  ok()   { pass=$(( pass + 1 )); printf '  ok    %s\n' "$1"; }
  bad()  { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$1"; }
  want() { # want <label> <expected 0|1> <actual-rc>
    [ "$2" -eq "$3" ] && ok "$1" || bad "$1"
  }
  size_of() { num "$(wc -c < "${1:-/nonexistent}" 2>/dev/null)"; }

  # The suite exercises wt_setup/wt_teardown/wt_provision for real, and those
  # write through log_tick and the provisioning hooks. Pointed at the live data
  # dir they append fake jobs (j1..j9, "provision up failed for repoA") to the
  # very tick.log the dashboard parses for its 24h activity counts — the test
  # suite inventing jobs in production history. Shadow the whole data dir, at
  # FUNCTION scope so every helper these tests call sees it too (bash is
  # dynamically scoped), and prove at the end that nothing leaked.
  local _real_tick="$TICK_LOG" _real_exec="$DATA_DIR/exec.log"
  local _tick0 _exec0
  _tick0="$(size_of "$_real_tick")"; _exec0="$(size_of "$_real_exec")"
  local DATA_DIR="$tmp/data"
  local TICK_LOG="$DATA_DIR/tick.log"
  local LOG_DIR="$DATA_DIR/logs" LOCK_DIR="$DATA_DIR/locks"
  local WORKTREES_DIR="$DATA_DIR/worktrees" RUNS_FILE="$DATA_DIR/runs.ndjson"
  # The platforms file is read by every gate below through PLATFORMS_FILE,
  # which was computed from the REAL config dir at load time. Shadowed here
  # so a scenario that redirects JOBS_FILE alone can never seed or read the
  # operator's own config/platforms.json; the guard at the end proves it.
  local _real_pf="$PLATFORMS_FILE" _pf0
  _pf0="$(stat -f %m "$PLATFORMS_FILE" 2>/dev/null || echo none)"
  local PLATFORMS_FILE="$tmp/platforms.json"
  # Permissive on purpose: the scenarios below launch runs on every model
  # their fixtures name, and Settings is not what any of them is testing. A
  # block that IS testing Settings writes a file of its own (pf_env, pc_al,
  # dplat, sec_env below).
  "$JQ" -n '{platforms:{
    anthropic:{enabled:true, bin:"", models:["opus","sonnet","haiku","fable","claude-opus-5","claude-sonnet-5","claude-opus-4-8","claude-fable-5-1","claude-haiku-4-5-20251001"]},
    openai:{enabled:true, bin:"", models:["gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna","gpt-5.5","gpt-a","gpt-b"]},
    opencode:{enabled:false, bin:"", models:[]}}}' > "$PLATFORMS_FILE"
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$WORKTREES_DIR"

  echo "num() — a number from a command is always an integer"
  # This is the exact shape that once produced "0\n0" and killed live agents.
  local n; n="$(num "$(grep -c 'nothing' /dev/null 2>/dev/null)")"
  [ "$n" = "0" ] && ok "grep -c with no match yields 0" || bad "grep -c with no match yielded '$n'"
  [ "$(num '')" = "0" ]        && ok "empty  -> 0"        || bad "empty"
  [ "$(num '  7 ')" = "7" ]    && ok "spaces trimmed"     || bad "spaces"
  [ "$(num 'x9')" = "0" ]      && ok "garbage -> 0"       || bad "garbage"
  [ "$(num '' 5)" = "5" ]      && ok "fallback honoured"  || bad "fallback"
  # and it must be usable in arithmetic without aborting
  ( [ "$(num 'x')" -lt 1 ] ) >/dev/null 2>&1 && ok "usable in [ -lt ]" || bad "not usable in [ -lt ]"

  echo "turn_is_over() — only a finished, quiet turn may end a run"
  printf '%s\n' '{"type":"system"}' '{"type":"assistant","message":{}}' > "$tmp/working.ndjson"
  printf '%s\n' '{"type":"system"}' '{"type":"result","subtype":"success"}' > "$tmp/done.ndjson"
  printf '%s\n' '{"type":"result"}' '{"type":"assistant","message":{}}' > "$tmp/resumed.ndjson"
  : > "$tmp/empty.ndjson"
  printf '%s\n' '{"type":"result"}' '{"trunca' > "$tmp/cut.ndjson"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"the word result appears here"}]}}' > "$tmp/decoy.ndjson"
  turn_is_over "$tmp/working.ndjson"; want "mid-work run is NOT killable"        1 $?
  turn_is_over "$tmp/done.ndjson";    want "answered run is killable"            0 $?
  turn_is_over "$tmp/resumed.ndjson"; want "work after a result is NOT killable" 1 $?
  turn_is_over "$tmp/empty.ndjson";   want "empty transcript is NOT killable"    1 $?
  turn_is_over "$tmp/cut.ndjson";     want "truncated tail ignored"              0 $?
  turn_is_over "$tmp/decoy.ndjson";   want "the word 'result' in text is not an event" 1 $?
  turn_is_over "$tmp/missing.ndjson"; want "missing file is NOT killable"        1 $?

  echo "session_from_stream() — the session id is read from the transcript's first event"
  # Absence has to be caught explicitly: a missing function prints to stderr and
  # yields an EMPTY stdout, which is exactly what the negative assertions below
  # accept. Without this line, deleting the reader outright would leave two of
  # the three still reporting ok.
  type session_from_stream >/dev/null 2>&1 \
    && ok "the reader is defined" || bad "session_from_stream does not exist"
  printf '%s\n' \
    '{"type":"system","subtype":"init","session_id":"sess-abc123"}' \
    '{"type":"assistant","message":{}}' > "$tmp/s1.ndjson"
  got="$(session_from_stream "$tmp/s1.ndjson")"
  [ "$got" = "sess-abc123" ] && ok "the init event's session is found" \
    || bad "read '$got'"

  # A fixed byte window would silently lose this one for good: the transcript is
  # append-only, so a first event that does not fit never starts fitting.
  { printf '{"type":"system","subtype":"init","session_id":"sess-big","tools":['
    i=0; while [ "$i" -lt 900 ]; do printf '"a-tool-with-a-long-name-%s",' "$i"; i=$((i+1)); done
    printf '"last"]}\n'
    printf '%s\n' '{"type":"assistant","message":{}}'
  } > "$tmp/s4.ndjson"
  [ "$(wc -c < "$tmp/s4.ndjson" | tr -d ' ')" -gt 8192 ] \
    && ok "the fixture init event really is over 8 KB" || bad "the fixture is too small to prove anything"
  got="$(session_from_stream "$tmp/s4.ndjson")"
  [ "$got" = "sess-big" ] && ok "an init event bigger than 8 KB is still read" \
    || bad "read '$got' from a large init event"
  printf '%s\n' '{"type":"assistant","message":{}}' > "$tmp/s2.ndjson"
  got="$(session_from_stream "$tmp/s2.ndjson")"
  [ -z "$got" ] && ok "a transcript with no session yet reports nothing" \
    || bad "invented a session '$got'"
  : > "$tmp/s3.ndjson"
  got="$(session_from_stream "$tmp/s3.ndjson")"
  [ -z "$got" ] && ok "an empty transcript reports nothing" || bad "read '$got' from nothing"

  echo "platforms — the table run_job asks instead of naming a binary"
  platform_known openai;      want "openai is a known platform"        0 $?
  platform_known anthropic;   want "anthropic is a known platform"     0 $?
  platform_known gemini;      want "an unknown platform is refused"    1 $?
  platform_known opencode;    want "opencode is a known platform now"   0 $?
  platform_planned opencode;  want "and no longer a planned one"         1 $?
  [ "$PLATFORMS" = "anthropic openai opencode" ] && [ -z "$PLATFORMS_PLANNED" ] && ok "the registry runs three platforms and plans none" || bad "PLATFORMS='$PLATFORMS' PLANNED='$PLATFORMS_PLANNED'"
  local _oc_caps="" _cap
  for _cap in interactive tool_lists denials budget_flag cost_reported stream_rate_limits families prepare_inline; do
    platform_caps opencode "$_cap" && _oc_caps="$_oc_caps $_cap"
  done
  [ "$_oc_caps" = " tool_lists denials cost_reported" ] && ok "opencode has tool_lists, denials and cost_reported, and nothing else" || bad "opencode caps:$_oc_caps"
  platform_caps anthropic prepare_inline; want "anthropic runs security prepare inside the agent" 0 $?
  platform_caps openai prepare_inline;    want "openai does not (the engine runs it first)"  1 $?
  [ "$(platform_permissions opencode | tr '\n' ' ')" = "full-access read-only " ] && ok "the two opencode modes" || bad "opencode modes: $(platform_permissions opencode | tr '\n' ' ')"
  platform_permission_ok opencode read-only;       want "read-only is an opencode mode"        0 $?
  platform_permission_ok opencode workspace-write; want "workspace-write is not (no sandbox)"  1 $?
  [ "$(platform_default_permission opencode job)" = "full-access" ] && [ "$(platform_default_permission opencode security)" = "full-access" ] \
    && ok "full-access is the opencode default for a job and for security" || bad "opencode defaults: $(platform_default_permission opencode job) / $(platform_default_permission opencode security)"
  platform_caps anthropic interactive; want "anthropic has interactive" 0 $?
  local _cap; local _openai_caps=0
  for _cap in interactive tool_lists denials budget_flag cost_reported stream_rate_limits families; do
    platform_caps openai "$_cap" && _openai_caps=$((_openai_caps + 1))
  done
  [ "$_openai_caps" -eq 0 ] && ok "openai has none of the seven capabilities" || bad "openai claims $_openai_caps capabilities"
  platform_permission_ok openai workspace-write; want "workspace-write is an openai mode"   0 $?
  platform_permission_ok openai dontAsk;         want "dontAsk is not an openai mode"        1 $?
  platform_permission_ok anthropic dontAsk;      want "dontAsk is an anthropic mode"         0 $?
  [ "$(platform_default_permission openai job)" = "workspace-write" ] && [ "$(platform_default_permission openai security)" = "full-access" ] \
    && ok "openai defaults: workspace-write for a job, full-access for an analysis" || bad "openai default permissions"
  # Every run here is headless, so the default has to be a mode that can use a
  # tool without an allowlist. dontAsk is not one, and a job that lands on it
  # spends a session discovering that.
  [ "$(platform_default_permission anthropic job)" = "bypassPermissions" ] && [ "$(platform_default_permission anthropic security)" = "bypassPermissions" ] \
    && ok "anthropic defaults to bypassPermissions for both, the only mode that works headless" || bad "anthropic default permissions"
  [ -n "$(permission_inert_warning anthropic dontAsk '')" ] \
    && ok "permission_inert_warning: dontAsk with no allowlist is called out" || bad "dontAsk with no allowlist passed silently"
  [ -z "$(permission_inert_warning anthropic dontAsk 'Bash,Read')" ] \
    && ok "and stays quiet once the job says which tools it may use" || bad "an allowlisted dontAsk was warned about"
  [ -z "$(permission_inert_warning anthropic bypassPermissions '')" ] && [ -z "$(permission_inert_warning openai read-only '')" ] \
    && ok "and never fires for a mode it does not describe" || bad "the inert warning fired for the wrong mode"
  platform_effort_ok anthropic opus ultra;   want "ultra is not an anthropic effort"          1 $?
  platform_effort_ok anthropic opus "";      want "an empty effort is always fine"            0 $?

  echo "config/platforms.json — seeded from what is in use, read by every gate"
  local pf="$tmp/pf"; mkdir -p "$pf"
  pf_env() { PLATFORMS_FILE="$pf/platforms.json"; JOBS_FILE="$pf/jobs.json"; PROJECTS_FILE="$pf/projects.json"; MODELS_FILE="$pf/models.json"; }
  cat > "$pf/jobs.json" <<'JSON'
{"jobs":[{"id":"a1","model":"claude-opus-5","prompt":"x"},
         {"id":"a2","model":"opus","prompt":"x"},
         {"id":"off","enabled":false,"model":"claude-sonnet-5","prompt":"x"},
         {"id":"o1","platform":"openai","model":"gpt-5.6-luna","prompt":"x"},
         {"id":"p1","project":"P","prompt":"x"}]}
JSON
  cat > "$pf/projects.json" <<'JSON'
{"projects":[{"name":"P","platform":"openai","model":"gpt-5.6-sol",
              "security":{"enabled":true,"platform":"anthropic","model":"claude-fable-5-1"}}]}
JSON
  "$JQ" -n '{resolved:{opus:{id:"claude-opus-5", at:1}},
             openai:{at:1, source:"fixture", models:[
               {slug:"gpt-5.6-luna", visibility:"list", priority:1},
               {slug:"gpt-5.6-sol",  visibility:"list", priority:2}]}}' > "$pf/models.json"
  type platforms_ensure >/dev/null 2>&1 && ok "the platforms file reader is defined" || bad "platforms_ensure does not exist"
  ( pf_env; platforms_ensure )
  [ -f "$pf/platforms.json" ] && ok "a missing platforms file is written on first use" || bad "platforms_ensure wrote nothing"
  ( pf_env; platform_enabled anthropic ); want "anthropic is enabled: enabled jobs run on it" 0 $?
  ( pf_env; platform_enabled openai );    want "openai is enabled: an enabled job and a project's jobs run on it" 0 $?
  # opencode is seeded exactly like the other two now: `enabled` asks only
  # whether something switched-on runs there. A fresh fixture, not $pf --
  # $pf/platforms.json was already written above by platforms_ensure, and
  # that call is a no-op once the file exists.
  local pfoc="$tmp/pfoc"; mkdir -p "$pfoc"
  printf '{"jobs":[{"id":"oc","platform":"opencode","model":"opencode/big-pickle","enabled":true,"prompt":"x"}]}\n' > "$pfoc/jobs.json"
  pfoc_env() { PLATFORMS_FILE="$pfoc/platforms.json"; JOBS_FILE="$pfoc/jobs.json"; PROJECTS_FILE="$pfoc/projects.json"; MODELS_FILE="$pfoc/models.json"; }
  ( pfoc_env; platforms_ensure )
  ( pfoc_env; platform_enabled opencode ); want "opencode is seeded enabled when an enabled job runs on it" 0 $?
  [ "$( pfoc_env; platform_models_enabled opencode | tr '\n' ' ' )" = "opencode/big-pickle " ] \
    && ok "and the seed carries the model that job names" || bad "opencode models seeded: '$( pfoc_env; platform_models_enabled opencode | tr '\n' ' ' )'"
  got="$( pf_env; platform_models_enabled anthropic | tr '\n' ' ' )"
  [ "$got" = "claude-opus-5 claude-sonnet-5 claude-fable-5-1 " ] \
    && ok "anthropic's models: the ids in use, a family resolved through the cache, a switched-off job's model too, no repeats" \
    || bad "anthropic models: '$got'"
  got="$( pf_env; platform_models_enabled openai | tr '\n' ' ' )"
  [ "$got" = "gpt-5.6-luna gpt-5.6-sol " ] && ok "openai's models: the job's own and the one inherited from the project" || bad "openai models: '$got'"
  ( pf_env; platform_model_enabled anthropic opus );            want "a family counts as enabled when its cached id is" 0 $?
  ( pf_env; platform_model_enabled anthropic claude-sonnet-5 ); want "the model of a job switched off is seeded too — parking a job is not un-configuring it" 0 $?
  ( pf_env; platform_model_enabled anthropic claude-haiku-5 );  want "a model no job names at all is not enabled" 1 $?
  # The reverse of the family case: the seed writes a bare family (opus) when
  # the cache had not resolved it yet, and a job naming the explicit id the
  # cache later resolves it to has to count as switched on too.
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["opus"]}}}\n' > "$pf/platforms-family.json"
  ( pf_env; PLATFORMS_FILE="$pf/platforms-family.json"; platform_model_enabled anthropic claude-opus-5 ); want "an explicit id counts as enabled when the family it resolves from is" 0 $?
  ( pf_env; platform_usable anthropic ); want "usable: enabled with a model" 0 $?
  [ "$( pf_env; platform_jobs_on openai | tr '\n' ' ' )" = "o1 p1 " ] \
    && ok "platform_jobs_on lists the jobs of a platform" || bad "jobs on openai: $( pf_env; platform_jobs_on openai | tr '\n' ' ' )"
  [ "$( pf_env; platform_jobs_on anthropic claude-fable-5-1 )" = "security:P" ] \
    && ok "and a security block, by its project" || bad "block: $( pf_env; platform_jobs_on anthropic claude-fable-5-1 )"
  # Two questions, two answers: "who is configured to use this" (the count the
  # Settings page shows) and "who would run right now" (what a switch-off
  # skips). The third argument is what tells them apart.
  [ "$( pf_env; platform_jobs_on anthropic | tr '\n' ' ' )" = "a1 a2 off security:P " ] \
    && ok "platform_jobs_on lists a job switched off too — it is configured to use the platform" \
    || bad "jobs on anthropic: $( pf_env; platform_jobs_on anthropic | tr '\n' ' ' )"
  [ "$( pf_env; platform_jobs_on anthropic "" on | tr '\n' ' ' )" = "a1 a2 security:P " ] \
    && ok "and the third argument narrows it to the ones actually switched on" \
    || bad "enabled jobs on anthropic: $( pf_env; platform_jobs_on anthropic "" on | tr '\n' ' ' )"
  got="$( pf_env; platform_affected_note anthropic )"
  case "$got" in "3 enabled jobs (a1, a2, security:P) run on anthropic and will be skipped"*)
      ok "and the switch-off sentence still counts only the enabled ones — nobody skips a job nobody enabled" ;;
    *) bad "affected note: '$got'" ;; esac

  # A job with no model runs on its platform's default -- the seed has to
  # credit that default, not an empty model, or every no-model job upgrades
  # to "enabled but refused".
  local pf3="$tmp/pf3"; mkdir -p "$pf3"
  printf '{"jobs":[{"id":"nodef","prompt":"x"}]}\n' > "$pf3/jobs.json"
  printf '{"resolved":{"opus":{"id":"claude-opus-5","at":1}}}\n' > "$pf3/models.json"
  p3_env() { PLATFORMS_FILE="$pf3/platforms.json"; JOBS_FILE="$pf3/jobs.json"; PROJECTS_FILE="$pf3/projects.json"; MODELS_FILE="$pf3/models.json"; }
  got="$( p3_env; platform_models_enabled anthropic | tr '\n' ' ' )"
  [ "$got" = "claude-opus-5 " ] \
    && ok "a job with no model contributes the anthropic default (opus), resolved through the cache" || bad "no-model job's contributed model: '$got'"
  [ "$( p3_env; platform_jobs_on anthropic claude-opus-5 )" = "nodef" ] \
    && ok "and it shows up under platform_jobs_on for that effective model" || bad "jobs on anthropic claude-opus-5: $( p3_env; platform_jobs_on anthropic claude-opus-5 )"

  # A model invalid for its own platform (an openai job naming an anthropic
  # family) is treated the same as no model at all: the platform's default.
  local pf4="$tmp/pf4"; mkdir -p "$pf4"
  printf '{"jobs":[{"id":"badmodel","platform":"openai","model":"opus","prompt":"x"}]}\n' > "$pf4/jobs.json"
  "$JQ" -n '{resolved:{opus:{id:"claude-opus-5", at:1}},
             openai:{at:1, source:"fixture", models:[
               {slug:"gpt-a", visibility:"list", priority:1},
               {slug:"gpt-b", visibility:"list", priority:2}]}}' > "$pf4/models.json"
  p4_env() { PLATFORMS_FILE="$pf4/platforms.json"; JOBS_FILE="$pf4/jobs.json"; PROJECTS_FILE="$pf4/projects.json"; MODELS_FILE="$pf4/models.json"; }
  got="$( p4_env; platform_models_enabled openai | tr '\n' ' ' )"
  [ "$got" = "gpt-a " ] \
    && ok "an openai job naming a model invalid there (opus) contributes the openai default instead" || bad "invalid-model job's contributed model: '$got'"
  [ "$( p4_env; platform_jobs_on openai gpt-a )" = "badmodel" ] \
    && ok "and platform_jobs_on matches it against that effective model too" || bad "jobs on openai gpt-a: $( p4_env; platform_jobs_on openai gpt-a )"

  # Without ANY openai catalog ($ocat == []), the old valid() rejected every
  # openai slug -- so effective() replaced even a job's OWN configured model
  # with the (also empty) openai default, and it vanished from the seed. A
  # job that today is merely skipped until `resolve-models openai` runs would
  # be refused for good once a later task's gate reads this file. No catalog
  # means "cannot validate", not "invalid" -- the configured slug is kept.
  local pf6="$tmp/pf6"; mkdir -p "$pf6"
  printf '{"jobs":[{"id":"o1","platform":"openai","model":"gpt-5.6-luna","prompt":"x"}]}\n' > "$pf6/jobs.json"
  printf '{"resolved":{}}\n' > "$pf6/models.json"
  p6_env() { PLATFORMS_FILE="$pf6/platforms.json"; JOBS_FILE="$pf6/jobs.json"; PROJECTS_FILE="$pf6/projects.json"; MODELS_FILE="$pf6/models.json"; }
  got="$( p6_env; platform_models_enabled openai | tr '\n' ' ' )"
  [ "$got" = "gpt-5.6-luna " ] \
    && ok "no openai catalog at all: the configured slug is kept, not dropped for the empty default" \
    || bad "no-catalog openai model: '$got'"

  # The reported defect, at its extreme: EVERY job on a platform is parked.
  # The seed used to skip them all, so the upgrade wrote an empty model list
  # and switching one of those jobs back on landed straight on a refusal --
  # and the Settings page showed the models as used by nobody, which made
  # switching them off look free. The models are seeded; `enabled` is the one
  # thing that still asks whether anyone is actually running.
  local pf7="$tmp/pf7"; mkdir -p "$pf7"
  cat > "$pf7/jobs.json" <<'JSON'
{"jobs":[{"id":"parked","enabled":false,"model":"claude-sonnet-5","prompt":"x"},
         {"id":"parked-o","enabled":false,"platform":"openai","model":"gpt-x","prompt":"x"}]}
JSON
  printf '{"projects":[{"name":"Q","security":{"enabled":false,"model":"claude-fable-5-1"}}]}\n' > "$pf7/projects.json"
  "$JQ" -n '{resolved:{}, openai:{at:1, source:"fixture", models:[{slug:"gpt-x", visibility:"list", priority:1}]}}' > "$pf7/models.json"
  p7_env() { PLATFORMS_FILE="$pf7/platforms.json"; JOBS_FILE="$pf7/jobs.json"; PROJECTS_FILE="$pf7/projects.json"; MODELS_FILE="$pf7/models.json"; }
  got="$( p7_env; platform_models_enabled anthropic | tr '\n' ' ' )"
  [ "$got" = "claude-sonnet-5 claude-fable-5-1 " ] \
    && ok "only parked jobs: the seed still lists their models, the disabled security block's included" \
    || bad "parked-only anthropic models: '$got'"
  [ "$( p7_env; platform_models_enabled openai | tr '\n' ' ' )" = "gpt-x " ] \
    && ok "and the parked openai job's slug too" || bad "parked-only openai models: '$( p7_env; platform_models_enabled openai | tr '\n' ' ' )'"
  ( p7_env; platform_enabled anthropic ); want "but the platform stays switched off: nobody is running on it" 1 $?
  ( p7_env; platform_usable anthropic );  want "and so it is not usable either" 1 $?
  [ "$( p7_env; platform_jobs_on anthropic | tr '\n' ' ' )" = "parked security:Q " ] \
    && ok "platform_jobs_on names the parked job and block — this is the count the Settings page shows" \
    || bad "parked jobs on anthropic: '$( p7_env; platform_jobs_on anthropic | tr '\n' ' ' )'"
  [ -z "$( p7_env; platform_jobs_on anthropic "" on )" ] \
    && ok "and none of them is switched on" || bad "enabled parked jobs: '$( p7_env; platform_jobs_on anthropic "" on )'"
  [ -z "$( p7_env; platform_affected_note anthropic )" ] \
    && ok "so a switch-off has nothing to warn about — a job nobody enabled is not skipped" \
    || bad "parked-only affected note: '$( p7_env; platform_affected_note anthropic )'"

  # An empty (0-byte) models.json used to make every read of it fail (jq -c
  # on empty input prints nothing but still exits 0, so --argjson resolved
  # "" blew up) -- the seed must still work with no cache at all.
  local pf5="$tmp/pf5"; mkdir -p "$pf5"
  printf '{"jobs":[{"id":"e1","prompt":"x"}]}\n' > "$pf5/jobs.json"
  : > "$pf5/models.json"
  ( PLATFORMS_FILE="$pf5/platforms.json"; JOBS_FILE="$pf5/jobs.json"; PROJECTS_FILE="$pf5/projects.json"; MODELS_FILE="$pf5/models.json"; platforms_ensure )
  want "an empty models.json still seeds" 0 $?
  [ -f "$pf5/platforms.json" ] && ok "and the file exists" || bad "platforms_ensure with an empty models.json wrote nothing"
  [ "$( PLATFORMS_FILE="$pf5/platforms.json"; JOBS_FILE="$pf5/jobs.json"; PROJECTS_FILE="$pf5/projects.json"; MODELS_FILE="$pf5/models.json"; platform_models_enabled anthropic )" = "opus" ] \
    && ok "and platform_models_enabled anthropic still prints opus (no cache: the family stays as it is)" \
    || bad "anthropic models with no cache: '$( PLATFORMS_FILE="$pf5/platforms.json"; JOBS_FILE="$pf5/jobs.json"; PROJECTS_FILE="$pf5/projects.json"; MODELS_FILE="$pf5/models.json"; platform_models_enabled anthropic )'"

  # a fresh install: only the two disabled example jobs -> nothing enabled, and the file still lists the three platforms
  local pf2="$tmp/pf2"; mkdir -p "$pf2"; cp "$BASE_DIR/config/jobs.example.json" "$pf2/jobs.json"
  ( PLATFORMS_FILE="$pf2/platforms.json"; JOBS_FILE="$pf2/jobs.json"; PROJECTS_FILE="$pf2/projects.json"; MODELS_FILE="$pf2/models.json"
    platforms_ensure; platform_usable anthropic ); want "a fresh install enables nothing" 1 $?
  "$JQ" -e '.platforms | keys == ["anthropic","openai","opencode"]' "$pf2/platforms.json" >/dev/null 2>&1 \
    && ok "and still lists the three platforms" || bad "seed keys: $("$JQ" -c '.platforms | keys' "$pf2/platforms.json" 2>/dev/null)"
  # an invalid file: nothing enabled, a reason, and never rewritten
  printf '{oops' > "$pf2/platforms.json"
  ( PLATFORMS_FILE="$pf2/platforms.json"; platform_enabled anthropic ); want "an invalid file enables nothing" 1 $?
  [ -n "$( PLATFORMS_FILE="$pf2/platforms.json"; platforms_error )" ] && ok "and platforms_error names it" || bad "no error for an invalid file"
  ( PLATFORMS_FILE="$pf2/platforms.json"; write_platforms '.platforms.anthropic.enabled = true' ) >/dev/null 2>&1; want "write_platforms refuses to write over an invalid file" 1 $?
  [ "$(cat "$pf2/platforms.json")" = "{oops" ] && ok "and left it exactly as it was" || bad "the invalid file was rewritten"
  ( pf_env; write_platforms '.platforms = "nope"' ) >/dev/null 2>&1; want "a filter that drops .platforms is discarded" 1 $?
  ( pf_env; write_platforms '.platforms.openai.enabled = false' ) >/dev/null 2>&1; want "a good filter writes" 0 $?
  ( pf_env; platform_enabled openai ); want "and the write is read back" 1 $?

  echo "platform_bin() / platform_check() — where the CLI is, and whether it is signed in"
  local pb="$tmp/pb" _pc; mkdir -p "$pb/bin"
  printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$pb/bin/codex"; chmod +x "$pb/bin/codex"
  printf '{"platforms":{"openai":{"enabled":true,"bin":"%s","models":[]}}}\n' "$pb/bin/codex" > "$pb/platforms.json"
  type platform_check >/dev/null 2>&1 && ok "platform_check is defined" || bad "platform_check does not exist"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=/env/codex; platform_bin openai )" = "/env/codex" ] \
    && ok "platform_bin: the environment override wins" || bad "env: $( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=/env/codex; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin openai )" = "$pb/bin/codex" ] \
    && ok "platform_bin: then the file's bin" || bad "file: $( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/detected/codex; platform_bin openai )" = "/detected/codex" ] \
    && ok "platform_bin: then the detected default" || bad "auto: $( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/detected/codex; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin_source openai )" = "file" ] \
    && [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; platform_bin_source openai )" = "auto" ] \
    && [ "$( AGENTLOOP_CODEX_BIN=/env/codex; platform_bin_source openai )" = "env" ] \
    && ok "platform_bin_source names the layer that answered" || bad "bin_source"
  _pc="$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_check openai )"
  printf '%s' "$_pc" | "$JQ" -e --arg b "$pb/bin/codex" \
    '.platform == "openai" and .supported == true and .ready == true and .bin == $b and .bin_found == true and .bin_source == "file" and .version == "codex-cli 9.9.9"' >/dev/null 2>&1 \
    && ok "platform_check openai: found, version read, signed in through the stand-in" || bad "check openai: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_HOME_DIR="$HOME/.codex"; CODEX_BIN="$BASE_DIR/test/fake-codex"; FAKE_CODEX_LOGGED_OUT=1 platform_check openai )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|codex is not signed in (run: codex login)|" ] \
    && ok "platform_check openai: signed out, with today's sentence" || bad "signed out: $_pc"
  [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/nonexistent; platform_ready openai )" = "codex not found at /nonexistent — set the path in Settings (or AGENTLOOP_CODEX_BIN); install: npm i -g @openai/codex, then codex login" ] \
    && ok "platform_ready: a missing binary names the path, the setting and the install command" || bad "not found: $( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/nonexistent; platform_ready openai )"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .account, .version' | tr '\n' '|')" = "true|fake@example.org · max plan|2.1.258 (Claude Code)|" ] \
    && ok "platform_check anthropic: the account and plan come from claude auth status" || bad "check anthropic: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; FAKE_CLAUDE_LOGGED_OUT=1 platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|claude is not signed in (run: claude auth login)|" ] \
    && ok "platform_check anthropic: signed out says how to sign in" || bad "anthropic signed out: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=/pinned/home; PLIST_PATH=/nonexistent; FAKE_CLAUDE_LOGGED_OUT=1 platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.reason')" = "claude is not signed in in /pinned/home (run: CLAUDE_CONFIG_DIR=/pinned/home claude auth login)" ] \
    && ok "and names the pinned account directory when there is one" || bad "pinned signed out: $_pc"
  printf '#!/bin/sh\necho "2.0.0 (Claude Code)"\n' > "$pb/bin/oldclaude"; chmod +x "$pb/bin/oldclaude"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$pb/bin/oldclaude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .account' | tr '\n' '|')" = "true|unknown — claude auth status needs Claude Code 2.1+|" ] \
    && ok "a CLI without \`auth status\` counts as ready, and says the account is unknown" || bad "old cli: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN=/nonexistent; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.supported, .ready, .bin_found, .reason' | tr '\n' '|')" = "true|false|false|opencode not found at /nonexistent — set the path in Settings (or AGENTLOOP_OPENCODE_BIN); install: brew install opencode (or: npm i -g opencode-ai)|" ] \
    && ok "platform_check opencode: supported now, and not found says how to install it" || bad "opencode missing: $_pc"
  printf '#!/bin/sh\ncase "$1" in --version) echo "1.18.30";; esac\nexit 0\n' > "$pb/bin/opencode"; chmod +x "$pb/bin/opencode"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN="$pb/bin/opencode"; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .bin_found, .version, .reason' | tr '\n' '|')" = "false|true|1.18.30|no usable provider: run opencode auth login, or configure one in ~/.config/opencode/opencode.json|" ] \
    && ok "platform_check opencode: found and versioned, not ready while no model is listed, with the reason" || bad "opencode found: $_pc"
  # A CLI that never answers (--version is quick; anything else hangs for ever,
  # the shape of the measured 34b hang) must read as a timeout, never as "no
  # usable provider" -- OPENCODE_DEADLINE=1 keeps this assertion fast.
  printf '#!/bin/sh\ncase "$1" in --version) echo 1.18.30;; *) exec sleep 600;; esac\n' > "$pb/bin/opencode-hang"; chmod +x "$pb/bin/opencode-hang"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-hang"; OPENCODE_DEADLINE=1; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|opencode models timed out after 1 s (the CLI hung; measured: a provider that never answers hangs it for ever)|" ] \
    && ok "platform_check opencode: a CLI past its deadline reads as a timeout, never as no usable provider" || bad "opencode hang: $_pc"
  # An outright failure (rc 3, no output) is a third fact, distinct from both
  # a timeout and an empty catalog -- it must name the rc and the command.
  printf '#!/bin/sh\ncase "$1" in --version) echo 1.18.30;; *) exit 3;; esac\n' > "$pb/bin/opencode-broken"; chmod +x "$pb/bin/opencode-broken"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-broken"; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|opencode models failed (rc 3) — see: $pb/bin/opencode-broken models --pure|" ] \
    && ok "platform_check opencode: a CLI that fails outright is not read as no usable provider" || bad "opencode broken: $_pc"
  # `--version` is bounded too: a CLI that never answers its first question
  # reads as a timeout with no version, and nothing else is asked of it.
  printf '#!/bin/sh\nexec sleep 600\n' > "$pb/bin/opencode-hang-version"; chmod +x "$pb/bin/opencode-hang-version"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-hang-version"; OPENCODE_DEADLINE=1; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .bin_found, .version, .reason' | tr '\n' '|')" = "false|true||opencode --version timed out after 1 s (the CLI hung)|" ] \
    && ok "platform_check: a --version past its deadline reads as a timeout, with no version" || bad "version hang: $_pc"
  # `auth list` past its deadline: the account says the credentials are
  # unknown -- "0 credentials" is the CLI's own line, kept only when the
  # command answered with it (a hung CLI does not have no credentials).
  printf '#!/bin/sh\ncase "$1" in --version) echo 1.18.30;; models) exec "%s" models --pure;; *) exec sleep 600;; esac\n' "$BASE_DIR/test/fake-opencode" > "$pb/bin/opencode-auth-hang"; chmod +x "$pb/bin/opencode-auth-hang"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-auth-hang"; OPENCODE_DEADLINE=1; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .account' | tr '\n' '|')" = "true|credentials unknown · providers: opencode, pdm_ai|" ] \
    && ok "platform_check opencode: an auth list past its deadline says credentials unknown, and the platform is still ready" || bad "auth hang: $_pc"
  [ "$(platform_check martian | "$JQ" -r .reason)" = "unknown platform martian" ] && ok "an unlisted platform is answered, never a crash" || bad "unlisted"

  echo "the OpenCode catalog — resolve_models_opencode over the stand-in, and the readers"
  local _oc; _oc="$tmp/oc"; mkdir -p "$_oc/config" "$_oc/data"
  ( CONFIG_DIR="$_oc/config"; MODELS_FILE="$_oc/config/models.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    resolve_models_opencode >/dev/null 2>&1 ) ; want "resolve-models opencode exits 0 over the stand-in" 0 $?
  "$JQ" -e '.opencode.models | length == 13' "$_oc/config/models.json" >/dev/null 2>&1 \
    && ok "the block carries the 13 models the stand-in lists" || bad "opencode block: $("$JQ" -c '.opencode | {at, source, n: (.models | length)}' "$_oc/config/models.json")"
  "$JQ" -e '.opencode.models[] | select(.id == "pdm_ai/openai/gpt-oss-120b") | .provider == "pdm_ai" and .name == "openai/gpt-oss-120b"' \
    "$_oc/config/models.json" >/dev/null 2>&1 && ok "a slash inside the model id splits at the FIRST slash" || bad "gpt-oss row: $("$JQ" -c '.opencode.models[] | select(.id | test("gpt-oss"))' "$_oc/config/models.json")"
  "$JQ" -e '.opencode.models[] | select(.id == "pdm_ai/glm-5.3-flash") | .priced == true and .cost.input == 0.033011 and .cost.output == 0.139816 and .tools == true and .reasoning == true and (.variants == ["non-think","high","max"]) and .context == 197144' \
    "$_oc/config/models.json" >/dev/null 2>&1 && ok "a priced model carries its price, its variants ranked low to high, its tools and its context" || bad "glm row: $("$JQ" -c '.opencode.models[] | select(.id == "pdm_ai/glm-5.3-flash")' "$_oc/config/models.json")"
  # The CLI lists variants in the order the provider config wrote them (the
  # stand-in has max, high, non-think on one model and low, medium, high,
  # max, non-think on another, from the same operator); the ladder reads low
  # to high on the page, so the block ranks every name the vocabulary knows.
  "$JQ" -e '.opencode.models[] | select(.id == "pdm_ai/DeepSeek-V4-Flash-MB3") | .variants == ["non-think","low","medium","high","max"]' \
    "$_oc/config/models.json" >/dev/null 2>&1 && ok "a ladder written in no order comes out ranked: non-think, low, medium, high, max" || bad "deepseek row: $("$JQ" -c '.opencode.models[] | select(.id == "pdm_ai/DeepSeek-V4-Flash-MB3") | .variants' "$_oc/config/models.json")"
  "$JQ" -e '.opencode.models[] | select(.id == "opencode/muse-spark-1.2-contributor-free") | .variants == ["minimal","low","medium","high","xhigh"]' \
    "$_oc/config/models.json" >/dev/null 2>&1 && ok "a ladder the CLI already lists low to high is unchanged" || bad "muse row: $("$JQ" -c '.opencode.models[] | select(.id == "opencode/muse-spark-1.2-contributor-free") | .variants' "$_oc/config/models.json")"
  "$JQ" -e '.opencode.models[] | select(.id == "opencode/big-pickle") | .priced == false and .variants == [] and .status == "active"' \
    "$_oc/config/models.json" >/dev/null 2>&1 && ok "a zero-cost model is UNPRICED, not free, and a model without variants offers no effort" || bad "big-pickle row: $("$JQ" -c '.opencode.models[] | select(.id == "opencode/big-pickle")' "$_oc/config/models.json")"
  [ "$("$JQ" -r '.opencode.source, .opencode.version' "$_oc/config/models.json" | tr '\n' '|')" = "opencode models --verbose|1.18.30|" ] \
    && ok "the block says where it came from and which CLI answered" || bad "source/version: $("$JQ" -c '.opencode | {source, version}' "$_oc/config/models.json")"
  ( MODELS_FILE="$_oc/config/models.json"
    [ "$(opencode_catalog_ids | grep -c .)" = "13" ] || exit 1
    [ "$(opencode_catalog_visible | head -1)" = "opencode/big-pickle" ] || exit 2
    [ "$(opencode_catalog_efforts pdm_ai/glm-5.3-flash | tr '\n' ' ')" = "non-think high max " ] || exit 3
    [ -z "$(opencode_catalog_efforts opencode/big-pickle)" ] || exit 4
    opencode_catalog_priced pdm_ai/glm-5.3-flash || exit 5
    opencode_catalog_priced opencode/big-pickle && exit 6
    opencode_catalog_tools pdm_ai/glm-5.3-flash || exit 7
    opencode_catalog_all_efforts | grep -qx 'non-think' || exit 8
    exit 0 ); want "the readers: ids, visible, efforts per model, priced, tools, the union of efforts" 0 $?
  # measurement 36: `opencode models --verbose` crosses the 64 KiB pipe wall
  # the same way `export` does, once a catalog is large enough (55+ models).
  # FAKE_MODELS_PAD=80 pushes the stand-in's output well past 64 KiB, in an
  # isolated config dir so it cannot touch the 13-model catalog above.
  local _ocpad; _ocpad="$tmp/oc-pad"; mkdir -p "$_ocpad/config"
  ( CONFIG_DIR="$_ocpad/config"; MODELS_FILE="$_ocpad/config/models.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    FAKE_MODELS_PAD=80; export FAKE_MODELS_PAD
    resolve_models_opencode >/dev/null 2>&1 ); want "resolve-models opencode exits 0 over a catalog past 64 KiB" 0 $?
  "$JQ" -e '.opencode.models | length == 93' "$_ocpad/config/models.json" >/dev/null 2>&1 \
    && ok "a catalog of 93 models (past the 64 KiB pipe wall) resolves in full, none cut" \
    || bad "padded opencode block: $("$JQ" -c '.opencode | {n: (.models | length)}' "$_ocpad/config/models.json")"
  "$JQ" -e '[.opencode.models[] | select(.id | startswith("pad/"))] | length == 80' "$_ocpad/config/models.json" >/dev/null 2>&1 \
    && ok "all 80 padded ids made it through, 13 + 80" \
    || bad "padded ids: $("$JQ" -c '[.opencode.models[].id | select(startswith("pad/"))] | length' "$_ocpad/config/models.json")"
  ( CONFIG_DIR="$_oc/config"; MODELS_FILE="$_oc/config/models.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_OPENCODE_NO_MODELS=1; export FAKE_OPENCODE_NO_MODELS
    resolve_models_opencode >/dev/null 2>&1 )
  "$JQ" -e '(.opencode.models | length) == 13 and (.opencode.stale_reason | length) > 0' "$_oc/config/models.json" >/dev/null 2>&1 \
    && ok "a refresh that lists nothing keeps the catalog it had, stamped stale" || bad "after an empty refresh: $("$JQ" -c '.opencode | {n: (.models | length), stale_reason}' "$_oc/config/models.json")"
  ( CONFIG_DIR="$_oc/config"; MODELS_FILE="$_oc/config/models.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    resolve_models_opencode >/dev/null 2>&1 )
  "$JQ" -e '.opencode | has("stale_reason") | not' "$_oc/config/models.json" >/dev/null 2>&1 \
    && ok "and the next good refresh clears the stamp" || bad "stamp survived a good refresh"
  # Same hang stand-in as platform_check above: a CLI that never answers
  # "models --verbose --pure" must keep the catalog it had, stamped as a
  # timeout rather than as an empty list -- OPENCODE_DEADLINE=1 doubles to 2 s.
  ( CONFIG_DIR="$_oc/config"; MODELS_FILE="$_oc/config/models.json"; AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-hang"; OPENCODE_DEADLINE=1
    resolve_models_opencode >/dev/null 2>&1 )
  "$JQ" -e '(.opencode.models | length) == 13 and .opencode.stale_reason == "opencode models --verbose timed out after 2 s"' "$_oc/config/models.json" >/dev/null 2>&1 \
    && ok "resolve_models_opencode: a CLI past its deadline keeps the catalog, stamped as a timeout" \
    || bad "after a hung refresh: $("$JQ" -c '.opencode | {n: (.models | length), stale_reason}' "$_oc/config/models.json")"
  ( CONFIG_DIR="$_oc/config"; MODELS_FILE="$_oc/config/none.json"; AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN=/nonexistent
    resolve_models_opencode >/dev/null 2>&1 )
  [ "$("$JQ" -r '.opencode.available, .opencode.reason' "$_oc/config/none.json" | tr '\n' '|')" = "false|opencode not installed|" ] \
    && ok "without the binary the block says so" || bad "no-binary block: $("$JQ" -c .opencode "$_oc/config/none.json")"

  echo "opencode effort and model — validated against the catalog, because the CLI validates nothing"
  ( MODELS_FILE="$_oc/config/models.json"
    [ "$(platform_efforts opencode pdm_ai/glm-5.3-flash | tr '\n' ' ')" = "non-think high max " ] || exit 1
    [ -z "$(platform_efforts opencode opencode/big-pickle)" ] || exit 2
    platform_effort_ok opencode pdm_ai/glm-5.3-flash high || exit 3
    platform_effort_ok opencode pdm_ai/glm-5.3-flash "" || exit 4
    platform_effort_ok opencode pdm_ai/glm-5.3-flash ultra && exit 5
    platform_effort_ok opencode opencode/big-pickle low && exit 6
    platform_model_ok opencode pdm_ai/glm-5.3-flash || exit 7
    platform_model_ok opencode pdm_ai/openai/gpt-oss-120b || exit 8
    platform_model_ok opencode opencode/does-not-exist && exit 9
    [ "$(platform_catalog_ids opencode | grep -c .)" = "13" ] || exit 10
    exit 0 ); want "efforts are the model's variants, empty is fine, a model without variants takes none, the id must be in the catalog" 0 $?

  echo "opencode_config_content() — the permission block a run is launched with"
  local _cc
  _cc="$(opencode_config_content full-access "" "" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .)" = '{"share":"disabled","permission":{}}' ] \
    && ok "full-access with no lists: share disabled and an empty block (--auto approves the rest)" || bad "full-access block: $_cc"
  _cc="$(opencode_config_content read-only "" "" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .permission)" = '{"edit":"deny","write":"deny","bash":"deny","task":"deny"}' ] \
    && ok "read-only denies edit, write, bash and task" || bad "read-only block: $_cc"
  _cc="$(opencode_config_content full-access "" "Agent,Bash(git push *),WebFetch" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .permission)" = '{"task":"deny","bash":{"*":"allow","git push *":"deny"},"webfetch":"deny"}' ] \
    && ok "a denylist: Agent closes task, Bash(pattern) is a bash pattern, a plain name closes the tool" || bad "denylist block: $_cc"
  _cc="$(opencode_config_content full-access "Read,Grep,Bash(git *)" "" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .permission)" = '{"*":"deny","read":"allow","grep":"allow","bash":{"*":"deny","git *":"allow"}}' ] \
    && ok "an allowlist: everything else denied, the named tools and the bash pattern allowed" || bad "allowlist block: $_cc"
  _cc="$(opencode_config_content full-access "Read,Edit(*.md)" "Read,Edit(*.py)")"
  [ "$(printf '%s\n' "$_cc" | head -1 | "$JQ" -c .permission)" = '{"*":"deny","read":"deny","edit":"deny"}' ] \
    && ok "deny wins over allow; a pattern on a non-bash tool widens a deny and is dropped from an allow" || bad "both lists: $(printf '%s\n' "$_cc" | head -1)"
  printf '%s\n' "$_cc" | tail -n +2 | grep -q 'Edit(\*.md) ignored' && ok "and the dropped allow pattern is named in a note" || bad "no note for the dropped pattern: $(printf '%s\n' "$_cc" | tail -n +2)"
  _cc="$(opencode_config_content read-only "" "Nonesuch")"
  printf '%s\n' "$_cc" | tail -n +2 | grep -q "Nonesuch" && ok "an unknown tool name is named in a note, not translated" || bad "no note for Nonesuch"
  printf '%s\n' "$_cc" | head -1 | "$JQ" -e '.permission | has("nonesuch") | not' >/dev/null 2>&1 && ok "and never reaches the block" || bad "Nonesuch reached the block"
  # Read-only keeps bash closed whatever the allowlist says. A bash pattern
  # allowed by rule used to reopen a whole shell with no OS sandbox behind
  # it (measured 19, 20), and `Bash(*)` overwrote the deny outright.
  _cc="$(opencode_config_content read-only "Bash(*)" "")"
  [ "$(printf '%s\n' "$_cc" | head -1 | "$JQ" -r '.permission.bash')" = "deny" ] \
    && ok "read-only with Bash(*) allowed keeps bash: deny" || bad "read-only Bash(*): $(printf '%s\n' "$_cc" | head -1)"
  printf '%s\n' "$_cc" | tail -n +2 | grep -qx 'allowed_tools: Bash(\*) ignored (read-only keeps bash closed)' \
    && ok "and the dropped entry is named in a note" || bad "no note for Bash(*): $(printf '%s\n' "$_cc" | tail -n +2)"
  _cc="$(opencode_config_content read-only "Bash(git log *)" "")"
  [ "$(printf '%s\n' "$_cc" | head -1 | "$JQ" -r '.permission.bash')" = "deny" ] \
    && printf '%s\n' "$_cc" | tail -n +2 | grep -qx 'allowed_tools: Bash(git log \*) ignored (read-only keeps bash closed)' \
    && ok "read-only with Bash(git log *) allowed: bash stays deny, with the note" || bad "read-only Bash(git log *): $_cc"
  _cc="$(opencode_config_content full-access "Bash(git log *)" "" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .permission.bash)" = '{"*":"deny","git log *":"allow"}' ] \
    && ok "full-access with the same allow: the allowlist shape measured in 37a" || bad "full-access Bash(git log *): $_cc"
  # Claude Code's prefix form `cmd:*` is not a glob: to OpenCode the `:*`
  # matches a literal colon and nothing else, so a denylist carried over
  # from an Anthropic job was inert in silence. It becomes the glob `cmd*`.
  _cc="$(opencode_config_content full-access "" "Bash(git push:*)")"
  [ "$(printf '%s\n' "$_cc" | head -1 | "$JQ" -c .permission.bash)" = '{"*":"allow","git push*":"deny"}' ] \
    && ok "a denied Bash(git push:*) is the bash glob git push*" || bad "prefix deny: $(printf '%s\n' "$_cc" | head -1)"
  printf '%s\n' "$_cc" | tail -n +2 | grep -q 'disallowed_tools: Bash(git push:\*) is the bash pattern "git push\*" (translated from Claude Code' \
    && ok "and the note says it was translated from the prefix form" || bad "no translation note: $(printf '%s\n' "$_cc" | tail -n +2)"
  _cc="$(opencode_config_content full-access "Bash(git log:*)" "" | head -1)"
  [ "$(printf '%s' "$_cc" | "$JQ" -c .permission.bash)" = '{"*":"deny","git log*":"allow"}' ] \
    && ok "an allowed Bash(git log:*) is the bash glob git log*" || bad "prefix allow: $_cc"

  # The opencode refusal block's own guard (in run_job, before acquire_slot)
  # refuses the launch when this comes back with an empty first line, rather
  # than set OPENCODE_CONFIG_CONTENT to nothing and let the CLI fall back to
  # its own defaults (sharing ON, nothing read-only). The heredoc above
  # always prints a JSON first line for any permission/allowed/disallowed
  # input -- the only way it comes back empty is the interpreter itself
  # failing -- so that is exercised here directly. Not through run_job with a
  # GLOBALLY broken interpreter: platform_ready's own probe (run_bounded,
  # same $PYTHON) runs first and would fail there instead, on the unrelated
  # reason "not ready", never reaching this guard at all -- the e2e suite
  # drives the guard itself with a $PYTHON that only fails the one call
  # shape opencode_config_content uses (see test/e2e.test.sh, scenario 37).
  local _ccbroken
  _ccbroken="$(PYTHON=/no/such/python-interpreter opencode_config_content full-access "" "" 2>/dev/null)"
  [ -z "$_ccbroken" ] \
    && ok "a broken interpreter leaves opencode_config_content answering nothing — what run_job's opencode refusal block refuses the launch on" \
    || bad "opencode_config_content still answered over a broken PYTHON: $_ccbroken"

  echo "platform_argv_opencode() — the measured launch line, for a fresh run and a resume"
  local _av _flag
  platform_argv_opencode "" /tmp/w pdm_ai/glm-5.3-flash high "PROMPT" "agentloop j1 20260912-120000"
  _av="$(printf '%s\n' "${PLATFORM_ARGV[@]}")"
  [ "${PLATFORM_ARGV[0]}" = "run" ] && [ "${PLATFORM_ARGV[1]}" = "--format" ] && [ "${PLATFORM_ARGV[2]}" = "json" ] && ok "run --format json first" || bad "argv starts ${PLATFORM_ARGV[*]}"
  for _flag in --pure --auto --print-logs; do
    printf '%s\n' "$_av" | grep -qx -- "$_flag" && ok "$_flag on every launch" || bad "no $_flag"
  done
  printf '%s\n' "$_av" | grep -A1 -x -- '--log-level' | grep -qx 'ERROR' && ok "--log-level ERROR: the reason of an UnknownError lands in .err, nothing else does" || bad "log level"
  printf '%s\n' "$_av" | grep -A1 -x -- '-m' | grep -qx 'pdm_ai/glm-5.3-flash' && ok "-m carries the id verbatim" || bad "-m"
  printf '%s\n' "$_av" | grep -A1 -x -- '--variant' | grep -qx 'high' && ok "--variant carries the effort" || bad "--variant"
  printf '%s\n' "$_av" | grep -A1 -x -- '--dir' | grep -qx '/tmp/w' && ok "--dir is the run's cwd" || bad "--dir"
  printf '%s\n' "$_av" | grep -A1 -x -- '--title' | grep -qx 'agentloop j1 20260912-120000' && ok "--title on a fresh run (one model call saved per session)" || bad "--title"
  printf '%s\n' "$_av" | grep -qx -- '-s' && bad "-s on a fresh run" || ok "no -s on a fresh run"
  [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 2))]}" = "--" ] && [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 1))]}" = "PROMPT" ] \
    && ok "-- then the prompt, last" || bad "the prompt is not the lone argument after --"
  platform_argv_opencode "" /tmp/w opencode/big-pickle "" "P" "t"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '--variant' && bad "an empty effort still emitted --variant" || ok "an empty effort emits no --variant"
  platform_argv_opencode ses_abc /tmp/kept opencode/big-pickle "" "P" "t"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -A1 -x -- '-s' | grep -qx 'ses_abc' && ok "a resume carries -s with the session id" || bad "no -s on the resume"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -A1 -x -- '--dir' | grep -qx '/tmp/kept' && ok "and --dir with the session's own directory (measured: any other directory hangs for ever)" || bad "no --dir on the resume"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '--title' && bad "--title on a resume (the session has one)" || ok "no --title on a resume"

  echo "platform_normalizer() — the launch asks for one instead of naming a platform"
  [ "$(platform_normalizer openai)" = "$BIN_DIR/platforms/openai_stream.py" ] && ok "openai has its normalizer" || bad "openai normalizer: $(platform_normalizer openai)"
  [ "$(platform_normalizer opencode)" = "$BIN_DIR/platforms/opencode_stream.py" ] && ok "opencode has its normalizer" || bad "opencode normalizer: $(platform_normalizer opencode)"
  [ -z "$(platform_normalizer anthropic)" ] && ok "anthropic has none: the CLI speaks stream-json itself" || bad "anthropic got a normalizer"

  echo "turn_is_over() — over a normalized OpenCode stream"
  "$PYTHON" -u "$BIN_DIR/platforms/opencode_stream.py" --model opencode/big-pickle --permission full-access --cwd /tmp \
    < "$BASE_DIR/test/fixtures/opencode/03-tool-use.jsonl" > "$tmp/oc-a.ndjson" 2>/dev/null
  turn_is_over "$tmp/oc-a.ndjson"; want "a finished OpenCode turn is over" 0 $?
  grep -v '"reason":"stop"' "$BASE_DIR/test/fixtures/opencode/03-tool-use.jsonl" \
    | "$PYTHON" -u "$BIN_DIR/platforms/opencode_stream.py" --model opencode/big-pickle --permission full-access --cwd /tmp > "$tmp/oc-b.ndjson" 2>/dev/null
  turn_is_over "$tmp/oc-b.ndjson"; want "an OpenCode turn cut before its last step is not" 1 $?
  [ "$(session_from_stream "$tmp/oc-a.ndjson")" = "ses_f69f73155ffeAHgrtVv1sVFbr7" ] \
    && ok "session_from_stream reads the sessionID off the first line" || bad "session $(session_from_stream "$tmp/oc-a.ndjson")"

  echo "opencode_export_model() — the model that ran, read from opencode export"
  mkdir -p "$tmp/ocx"
  [ "$( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_RAN_MODEL=pdm_ai/glm-5.3-flash-real; export FAKE_RAN_MODEL; opencode_export_model "$tmp/ocx" ses_x1 )" = "pdm_ai/glm-5.3-flash-real" ] \
    && ok "provider/model out of info.model" || bad "export model: $( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; opencode_export_model "$tmp/ocx" ses_x1 )"
  [ -z "$( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; opencode_export_model "$tmp/does-not-exist" ses_x1 )" ] \
    && ok "no directory, no answer (never a hang: the CLI needs the session's directory)" || bad "export answered without a directory"
  # measurement 36: a real 35-turn session's export is 264,607 bytes, and a
  # pipe loses everything past 65,536; FAKE_EXPORT_PAD proves the helper
  # reads it from a file instead, and that the file is gone once it is done.
  ( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_RAN_MODEL=opencode/big-pickle-real; FAKE_EXPORT_PAD=300000
    export FAKE_RAN_MODEL FAKE_EXPORT_PAD
    [ "$(opencode_export_model "$tmp/ocx" ses_x1)" = "opencode/big-pickle-real" ] || exit 1
    [ -z "$(find "$DATA_DIR" -maxdepth 1 -name '.opencode-export.*' 2>/dev/null)" ] || exit 2
    exit 0 ); want "an export past 64 KiB (padded to 300000 bytes) still resolves the model, and its temp file is gone after" 0 $?
  # With a base (the run's stream file, from platform_finish) the export
  # goes to <base>.export beside the run's own log, not to data/, and is
  # gone after the read: a kill mid-export leaves the transcript next to
  # the run it belongs to.
  # DATA_DIR points nowhere here on purpose: the mktemp fallback cannot
  # answer, so only the <base>.export path can produce the model.
  ( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_RAN_MODEL=pdm_ai/based; export FAKE_RAN_MODEL
    DATA_DIR="$tmp/ocx/nowhere"
    [ "$(opencode_export_model "$tmp/ocx" ses_x1 "$tmp/ocx/r1.stream.ndjson")" = "pdm_ai/based" ] || exit 1
    [ ! -e "$tmp/ocx/r1.stream.ndjson.export" ] || exit 2
    [ -z "$(find "$DATA_DIR" -maxdepth 1 -name '.opencode-export.*' 2>/dev/null)" ] || exit 3
    exit 0 ); want "with a base the export is read from <base>.export, removed after, and nothing lands under data/" 0 $?
  ( AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_RAN_MODEL=opencode/big-pickle-real; export FAKE_RAN_MODEL
    platform_finish opencode "$tmp/ocx/none.ndjson" ses_x2 j1 "$tmp/ocx"; [ "$PF_MODEL_ID" = "opencode/big-pickle-real" ] ); want "platform_finish opencode sets PF_MODEL_ID from the export" 0 $?
  # opencode-hang (above: --version answers, anything else hangs) times the
  # export out through the same run_bounded a genuinely wedged CLI would hit;
  # the close has to say WHICH kind of nothing this is, not the same "gave no
  # model" a malformed export or a missing rollout would print.
  ( AGENTLOOP_OPENCODE_BIN="$pb/bin/opencode-hang"; OPENCODE_DEADLINE=1
    platform_finish opencode "$tmp/ocx/none.ndjson" ses_hang j1 "$tmp/ocx"
    [ -z "$PF_MODEL_ID" ] && grep -q 'j1: opencode export timed out after 1 s' "$TICK_LOG" ); \
    want "an export past its deadline says timed out, not gave no model" 0 $?

  echo "platform_check opencode — ready when the CLI lists a model, and who the account is"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .version, .account' | tr '\n' '|')" = "true|1.18.30|0 credentials · providers: opencode, pdm_ai|" ] \
    && ok "ready, versioned, and the account names the credentials and the providers" || bad "opencode check: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; FAKE_OPENCODE_NO_MODELS=1; export FAKE_OPENCODE_NO_MODELS; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|no usable provider: run opencode auth login, or configure one in ~/.config/opencode/opencode.json|" ] \
    && ok "with no model listed it is not ready, and says what to do" || bad "no-provider check: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"; platform_check opencode nope )"
  printf '%s' "$_pc" | "$JQ" -e --arg r "OpenCode has no accounts (account 'nope')" \
      '.ready == false and .account_id == "nope" and .account_dir == "" and .reason == $r' >/dev/null 2>&1 \
    && ok "platform_check opencode <id>: a non-default id is refused, not silently echoed back as though it were checked" || bad "opencode check with id: $_pc"

  echo "run_bounded() — a command past its deadline is killed and reads as 124"
  run_bounded 1 sleep 5; want "a 5 s sleep under a 1 s deadline exits 124" 124 $?
  [ "$(run_bounded 5 echo bounded-ok)" = "bounded-ok" ] && ok "a command inside the deadline passes its stdout through" || bad "run_bounded ate the output"
  # A grandchild that inherits stdout (the shape of a bun-spawned opencode
  # helper process) must die too, not only the direct child -- 601, not 600,
  # keeps this assertion from matching a sleep some other case left behind.
  run_bounded 1 sh -c 'sleep 601 & sleep 601'; want "a hung process group under a 1 s deadline exits 124" 124 $?
  [ "$(ps -ax -o command= | grep -c '^sleep 601$')" = "0" ] \
    && ok "and no sleep 601 process is left running in its group" || bad "leaked sleep 601 count: $(ps -ax -o command= | grep -c '^sleep 601$')"
  # macOS answers EPERM, not ESRCH, to a killpg that reaches a group whose
  # members are all on their way out (seen on the CI runner: a traceback and
  # rc 1 instead of 124). Forced here through a sitecustomize, so the case
  # does not depend on catching that instant.
  mkdir -p "$tmp/rb-eperm"
  cat > "$tmp/rb-eperm/sitecustomize.py" <<'PY'
import os, signal
_real_killpg = os.killpg
def _killpg(pgid, sig):
    if sig == signal.SIGKILL:
        raise PermissionError(1, "Operation not permitted")
    return _real_killpg(pgid, sig)
os.killpg = _killpg
PY
  PYTHONPATH="$tmp/rb-eperm" run_bounded 1 sh -c 'sleep 602 & sleep 602' 2>/dev/null
  want "a group that answers EPERM to the final SIGKILL still exits 124" 124 $?
  # A grandchild that IGNORES the TERM while the direct child goes on it
  # used to outlive the deadline: the KILL was only ever sent when the
  # direct child itself sat out the grace. Checked by pid (the grandchild
  # writes its own) rather than through `ps -ax`, which a sandboxed shell
  # does not see every process through.
  local _gcpid="$tmp/grandchild.pid" _gcw=0
  rm -f "$_gcpid"
  run_bounded 1 sh -c "sh -c 'echo \$\$ > $_gcpid; trap \"\" TERM; exec sleep 602' & sleep 602"; want "a TERM-proof grandchild under a 1 s deadline still exits 124" 124 $?
  while [ "$_gcw" -lt 20 ] && [ -s "$_gcpid" ] && kill -0 "$(cat "$_gcpid")" 2>/dev/null; do sleep 0.1; _gcw=$((_gcw + 1)); done
  if [ -s "$_gcpid" ] && ! kill -0 "$(cat "$_gcpid")" 2>/dev/null; then ok "and the grandchild that ignored the TERM went with its group on the KILL"
  else bad "the TERM-proof grandchild (pid $(cat "$_gcpid" 2>/dev/null)) outlived the deadline"; kill -9 "$(cat "$_gcpid" 2>/dev/null)" 2>/dev/null; fi

  echo "anthropic_catalog_ids() — the Settings list, every family newest first"
  # The fixture is every id the scan finds in the real CLI 2.1.280 binary,
  # laid out in the order the list must show; tests/test_platforms_api.py
  # holds the dashboard's picker to the same file. The stand-in binary
  # carries them alphabetically, NUL between, so the order can only come
  # from the sort. Compared as raw number lists, the shorter list won:
  # claude-opus-5 listed above claude-opus-5-5, and a date sorted as a minor.
  LC_ALL=C sort "$BASE_DIR/test/fixtures/claude-cli-model-ids-newest-first.txt" | tr '\n' '\000' > "$tmp/idblob"
  got="$( CLAUDE_BIN="$tmp/idblob"; MODELS_FILE="$tmp/no-models.json"; JOBS_FILE="$tmp/no-jobs.json"; PROJECTS_FILE="$tmp/no-projects.json"
          anthropic_catalog_ids | tr '\n' ' ' )"
  [ "$got" = "$(tr '\n' ' ' < "$BASE_DIR/test/fixtures/claude-cli-model-ids-newest-first.txt")" ] \
    && ok "newest first: a missing minor is 0, and a date only orders the snapshots of one version" \
    || bad "anthropic_catalog_ids: $got"

  echo "agentloop platform … — the commands the Settings page is made of"
  local pc="$tmp/pc" out rc _pm _pl; mkdir -p "$pc/config" "$pc/data"
  printf '{"jobs":[{"id":"u1","model":"claude-opus-5","prompt":"x"},{"id":"u2","platform":"openai","model":"gpt-a","prompt":"x"}]}\n' > "$pc/config/jobs.json"
  printf '{"projects":[]}\n' > "$pc/config/projects.json"
  "$JQ" -n '{resolved:{opus:{id:"claude-opus-5",at:1}}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-a", display_name:"A", description:"da", visibility:"list", priority:6, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-b", display_name:"B", description:"db", visibility:"list", priority:7, efforts:["low"], default_effort:"low", deprecated_by:"", retires_at:""}]}}' \
    > "$pc/config/models.json"
  printf '{"openai":{"gpt-a":{"input":4,"cached_input":0.4,"output":20,"source":"manual"}}}\n' > "$pc/config/pricing.json"
  # `platform models openai` refreshes for real (resolve_models_openai, unconditional
  # by design) -- so fake-codex's `debug models` has to answer with THIS catalog, not
  # its own fixture, or the refresh would clobber config/models.json's seed above with
  # unrelated slugs. Raw shape: what `codex debug models` itself returns, the same
  # shape as test/fixtures/codex/models-catalog.stripped.json.
  printf '{"models":[{"slug":"gpt-a","display_name":"A","description":"da","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"visibility":"list","priority":6},{"slug":"gpt-b","display_name":"B","description":"db","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"}],"visibility":"list","priority":7}]}' \
    > "$pc/catalog.json"
  # opencode is not under test here, and platform_check/platform models now
  # actually run its binary (Task 3) -- pointed at nothing, same as the two
  # above, so an operator's real opencode install is never reached.
  pc_al() { AGENTLOOP_CONFIG="$pc/config" AGENTLOOP_DATA="$pc/data" AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" \
            AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" AGENTLOOP_CLAUDE_CONFIG_DIR="" CODEX_HOME="$pc/codex-home" \
            AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode \
            FAKE_CODEX_MODELS_JSON="$pc/catalog.json" "$BIN_DIR/agentloop" "$@"; }
  # pc_al's own twin, pointed at a codex that is not there, for the "a failed
  # refresh must not clobber the catalog" assertion below.
  pc_al_nocodex() { AGENTLOOP_CONFIG="$pc/config" AGENTLOOP_DATA="$pc/data" AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" \
            AGENTLOOP_CODEX_BIN=/nonexistent/codex AGENTLOOP_CLAUDE_CONFIG_DIR="" CODEX_HOME="$pc/codex-home" \
            FAKE_CODEX_MODELS_JSON="$pc/catalog.json" "$BIN_DIR/agentloop" "$@"; }
  # Round 4: pc_al is exactly the shape "the problem" names -- a real
  # subprocess, HOME left ambient -- so it is the block that proves
  # AGENTLOOP_LAUNCH_AGENTS_DIR actually isolates one. platform_check
  # computes account_dir (the Default's, here) before it ever touches the
  # binary, so neither case below needs the fake claude to answer anything.
  la_pin="$pc/la-pin"; mkdir -p "$la_pin" "$pc/la-acct"
  "$PYTHON" - "$la_pin/$PLIST_LABEL.plist" "$pc/la-acct" <<'PY'
import plistlib, sys
plistlib.dump({"EnvironmentVariables": {"AGENTLOOP_CLAUDE_CONFIG_DIR": sys.argv[2]}}, open(sys.argv[1], "wb"))
PY
  got="$(AGENTLOOP_LAUNCH_AGENTS_DIR="$la_pin" pc_al platform check anthropic 2>/dev/null | "$JQ" -r .account_dir)"
  [ "$got" = "$pc/la-acct" ] && ok "a plist pinned inside AGENTLOOP_LAUNCH_AGENTS_DIR is what a real agentloop subprocess reads" \
    || bad "platform check account_dir with a pinned knob dir: '$got' (want '$pc/la-acct')"
  la_empty="$pc/la-empty"; mkdir -p "$la_empty"
  got="$(AGENTLOOP_LAUNCH_AGENTS_DIR="$la_empty" pc_al platform check anthropic 2>/dev/null | "$JQ" -r .account_dir)"
  [ -z "$got" ] && ok "and an empty AGENTLOOP_LAUNCH_AGENTS_DIR directory reads no pin at all -- never the developer machine's own ~/Library/LaunchAgents" \
    || bad "platform check account_dir with an empty knob dir: '$got' (want empty)"
  # The help is a heredoc that expands: a backticked word in it ran as a
  # command -- `security` is the macOS Keychain tool, whose own usage landed
  # in ours -- and a shell error went to stderr with the text it stood for gone.
  out="$(pc_al help 2>&1 >/dev/null)"
  [ -z "$out" ] && ok "agentloop help prints no shell error of its own" || bad "help stderr: $out"
  out="$(pc_al help 2>/dev/null)"
  case "$out" in
    *"agentloop platform check <platform> [id]"*"agentloop platform account-add <platform> <name> <dir>"*"agentloop platform account-edit <platform> <id> <name> <dir>"*"agentloop platform account-remove <platform> <id>"*)
      ok "and names each platform verb with the arguments it takes" ;;
    *) bad "help: $out" ;;
  esac
  pc_al platform check openai | "$JQ" -e '.ready == true' >/dev/null 2>&1; want "platform check prints platform_check's JSON" 0 $?
  pc_al platform check martian >/dev/null 2>&1; want "platform check refuses an unlisted platform" 1 $?
  # the seed happened on that first read: both platforms in use are enabled with their models
  "$JQ" -e '.platforms.anthropic.enabled == true and .platforms.anthropic.models == ["claude-opus-5"] and .platforms.openai.models == ["gpt-a"]' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "the first command seeded config/platforms.json from the jobs in use" || bad "seed: $(cat "$pc/config/platforms.json")"
  out="$(pc_al platform disable openai 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && "$JQ" -e '.platforms.openai.enabled == false' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "platform disable writes enabled:false" || bad "disable: rc=$rc $out"
  case "$out" in *"1 enabled job (u2) runs on openai and will be skipped until it is enabled again"*) ok "and says which enabled jobs will be skipped" ;; *) bad "disable note: $out" ;; esac
  out="$(FAKE_CODEX_LOGGED_OUT=1 pc_al platform enable openai 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && "$JQ" -e '.platforms.openai.enabled == false' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "platform enable refuses while the check fails, and writes nothing" || bad "enable while signed out: rc=$rc $out"
  # pc_al runs the engine with CODEX_HOME pointed at a scratch home: the
  # Default IS that home, and the sentence names it -- then says what enable
  # checks, and how the refusal is lifted.
  [ "$out" = "cannot enable openai: codex is not signed in in $pc/codex-home (run: CODEX_HOME=$pc/codex-home codex login) — enable checks the Default account, the one the catalog refreshes run on: sign it in" ] \
    && ok "and says why, naming the home it checked, and how to lift it" || bad "enable refusal: $out"
  pc_al platform enable openai >/dev/null 2>&1; want "platform enable writes once the check passes" 0 $?
  "$JQ" -e '.platforms.openai.enabled == true' "$pc/config/platforms.json" >/dev/null 2>&1 && ok "and the file says so" || bad "enable not written"
  out="$(pc_al platform enable opencode 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "cannot enable opencode: opencode not found at /nonexistent/opencode — set the path in Settings (or AGENTLOOP_OPENCODE_BIN); install: brew install opencode (or: npm i -g opencode-ai)" ] \
    && ok "platform enable refuses a platform whose binary is missing, with that reason alone: no session was ever asked about" \
    || bad "enable without a binary: rc=$rc $out"
  pc_al platform set-bin openai /nonexistent/codex >/dev/null 2>&1; want "set-bin refuses a path that is not executable" 1 $?
  pc_al platform set-bin openai "$BASE_DIR/test/fake-codex" >/dev/null 2>&1; want "set-bin accepts an executable" 0 $?
  [ "$("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")" = "$BASE_DIR/test/fake-codex" ] && ok "and writes it" || bad "bin not written"
  pc_al platform set-bin openai "test/fake-codex" >/dev/null 2>&1; want "set-bin accepts a relative path" 0 $?
  [ "$("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")" = "$BASE_DIR/test/fake-codex" ] \
    && ok "and stores it made absolute against the cwd, not as typed" || bad "relative bin not absolutized: $("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")"
  pc_al platform set-bin openai "" >/dev/null 2>&1
  [ "$("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")" = "" ] && ok "set-bin with nothing goes back to detection" || bad "bin not cleared"
  _pm="$(pc_al platform models openai 2>/dev/null)"
  printf '%s' "$_pm" | "$JQ" -e '.platform == "openai" and .stale == false and (.models | map(.v)) == ["gpt-a","gpt-b"] and .models[0].enabled == true and .models[1].enabled == false and .models[0].price.input == 4 and .models[1].price == null and .models[0].efforts == ["low","high"]' >/dev/null 2>&1 \
    && ok "platform models: the catalog in priority order, each slug with enabled, efforts and price" || bad "models openai: $_pm"
  # A refresh that fails (codex missing) must not empty the catalog the launch
  # gate reads: it should keep serving the last good one, marked stale.
  _pm="$(pc_al_nocodex platform models openai 2>/dev/null)"
  printf '%s' "$_pm" | "$JQ" -e '.stale == true and (.reason | test("refresh failed")) and (.models | map(.v)) == ["gpt-a","gpt-b"]' >/dev/null 2>&1 \
    && ok "platform models: a failed refresh keeps the old catalog and says stale" || bad "models openai failed refresh: $_pm"
  "$JQ" -e '.openai.models | length == 2' "$pc/config/models.json" >/dev/null 2>&1 \
    && ok "and config/models.json still carries the pre-refresh catalog" || bad "models.json after failed refresh: $(cat "$pc/config/models.json")"
  # The tick's own path (`_resolve_models` -> cmd_resolve_models ->
  # resolve_models_openai, with no `platform models` around it): a good
  # refresh carries no stale stamp, a failed one keeps the catalog and
  # stamps when and why.
  pc_al resolve-models openai >/dev/null 2>&1
  "$JQ" -e '(.openai.models | length == 2) and ((.openai | has("stale_reason")) | not) and ((.openai | has("stale_at")) | not)' "$pc/config/models.json" >/dev/null 2>&1 \
    && ok "resolve-models openai: a successful refresh carries no stale stamp" || bad "after a good refresh: $(cat "$pc/config/models.json")"
  out="$(pc_al_nocodex resolve-models openai 2>&1)"
  "$JQ" -e '(.openai.models | length == 2) and (.openai.stale_reason == "codex not installed") and (.openai.stale_at | type == "number")' "$pc/config/models.json" >/dev/null 2>&1 \
    && ok "resolve-models openai: a failed refresh keeps the catalog and stamps stale_at/stale_reason" || bad "after a failed refresh: $(cat "$pc/config/models.json")"
  case "$out" in *"openai -> kept the previous catalog (codex not installed)"*) ok "and says it kept the previous catalog" ;; *) bad "kept line: $out" ;; esac
  _pm="$(pc_al platform models anthropic 2>/dev/null)"
  printf '%s' "$_pm" | "$JQ" -e '.platform == "anthropic" and (.models | map(.v) | index("claude-opus-5")) != null and (.models[] | select(.v == "claude-opus-5") | .enabled) == true' >/dev/null 2>&1 \
    && ok "platform models anthropic: the ids in use are listed and flagged" || bad "models anthropic: $_pm"
  pc_al platform models opencode | "$JQ" -e '.models == [] and .stale == true and (.reason | length) > 0' >/dev/null 2>&1; want "platform models opencode without the binary: an empty, stale list with the reason" 0 $?
  printf '["gpt-zzz"]' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models refuses an id outside the catalog" 1 $?
  printf 'not json' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models refuses anything but a JSON list" 1 $?
  printf '' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models refuses empty stdin" 1 $?
  [ "$("$JQ" -c '.platforms.openai.models' "$pc/config/platforms.json")" = '["gpt-a"]' ] \
    && ok "and leaves the file unchanged" || bad "set-models empty stdin wrote: $(cat "$pc/config/platforms.json")"
  printf '["gpt-a","gpt-a"]' | pc_al platform set-models openai >/dev/null 2>&1
  [ "$("$JQ" -c '.platforms.openai.models' "$pc/config/platforms.json")" = '["gpt-a"]' ] \
    && ok "set-models dedupes a repeated id before writing" || bad "set-models dedupe wrote: $(cat "$pc/config/platforms.json")"
  out="$(printf '["gpt-b"]' | pc_al platform set-models openai 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.platforms.openai.models' "$pc/config/platforms.json")" = '["gpt-b"]' ] \
    && ok "set-models writes the list it was given" || bad "set-models: rc=$rc $out"
  case "$out" in *"1 enabled job (u2) runs on openai with gpt-a and will be skipped until it is enabled again"*) ok "and names the jobs whose model was switched off" ;; *) bad "set-models note: $out" ;; esac
  # an id already enabled may stay even when the catalog no longer carries it
  "$JQ" '.platforms.openai.models = ["gpt-gone","gpt-b"]' "$pc/config/platforms.json" > "$pc/pf.next"; mv "$pc/pf.next" "$pc/config/platforms.json"
  printf '["gpt-gone","gpt-a"]' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models keeps an already-enabled id the catalog dropped" 0 $?
  _pl="$(pc_al platforms 2>/dev/null)"
  printf '%s' "$_pl" | "$JQ" -e '(keys | sort) == ["anthropic","openai","opencode"] and .opencode.supported == true and .openai.supported == true
      and .openai.enabled == true and .openai.usable == true and .openai.models_enabled == ["gpt-gone","gpt-a"] and .openai.bin_source == "env"
      and .openai.jobs_on_platform == 1 and .openai.jobs_using == {"gpt-a": 1} and .anthropic.jobs_using == {"claude-opus-5": 1}
      and .openai.jobs_on_platform_enabled == 1 and .openai.jobs_using_enabled == {"gpt-a": 1}
      and .anthropic.jobs_on_platform_enabled == 1 and .anthropic.jobs_using_enabled == {"claude-opus-5": 1}
      and .opencode.usable == false and (.opencode.models_enabled == [])
      and .opencode.supported == true and (.opencode | has("unpriced"))' >/dev/null 2>&1 \
    && ok "platforms: the three platforms, each with enabled, usable, bin_source, models_enabled and both counts of the jobs using them" || bad "platforms: $_pl"
  # Every job in the fixture above is switched on, so the two maps come out
  # identical there and a filter that had lost its `select(.on)` would read
  # exactly like one that kept it. Park a job and the pair has to disagree.
  cp "$pc/config/jobs.json" "$pc/jobs.orig"
  "$JQ" '.jobs += [{"id":"u3","platform":"openai","model":"gpt-a","enabled":false,"prompt":"x"}]' "$pc/jobs.orig" > "$pc/config/jobs.json"
  _pl="$(pc_al platforms 2>/dev/null)"
  printf '%s' "$_pl" | "$JQ" -e '.openai.jobs_on_platform == 2 and .openai.jobs_using == {"gpt-a": 2}
      and .openai.jobs_on_platform_enabled == 1 and .openai.jobs_using_enabled == {"gpt-a": 1}' >/dev/null 2>&1 \
    && ok "and a parked job counts in jobs_using but never in jobs_using_enabled" || bad "platforms with a parked job: $_pl"
  cp "$pc/jobs.orig" "$pc/config/jobs.json"
  printf '{oops' > "$pc/config/platforms.json"
  pc_al platforms 2>/dev/null | "$JQ" -e '._error | test("not a valid platforms file")' >/dev/null 2>&1; want "platforms carries _error when the file is unreadable" 0 $?
  pc_al platform enable openai >/dev/null 2>&1; want "and enable refuses to write over it" 1 $?

  # The catalog readers, over a models.json of this test's own.
  mkdir -p "$tmp/cat"
  "$JQ" -n '{resolved:{}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-b", visibility:"list", priority:7, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-a", visibility:"list", priority:6, efforts:["low","high","ultra"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-hidden", visibility:"hide", priority:3, efforts:["low"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-old", visibility:"list", priority:23, efforts:["low"], default_effort:"low", deprecated_by:"gpt-b", retires_at:"2026-08-31T19:00:00Z"}]}}' \
    > "$tmp/cat/models.json"
  # Each of these runs inside a SUBSHELL, because MODELS_FILE must not leak
  # into the rest of the suite. That used to mean a bad() in here bumped a
  # $fail that vanished with the subshell -- FAIL printed, the gate never saw
  # it, and `selftest` exited 0 regardless. ok()/bad() are redefined for the
  # length of the subshell to count into _upass/_ufail (discarded with it) and
  # print exactly what they always printed; the parent replays those lines
  # verbatim and then asserts, on its OWN real ok/bad, that the RESULT line
  # the subshell prints last says bad=0 and the expected ok=count.
  local _catout
  _catout="$(
    MODELS_FILE="$tmp/cat/models.json"
    # Settings lists the slugs in the order they were switched on, and that
    # order -- not the catalog priority -- is what the default follows.
    PLATFORMS_FILE="$tmp/cat/platforms.json"
    printf '{"platforms":{"openai":{"enabled":true,"bin":"","models":["gpt-b","gpt-a"]}}}\n' > "$PLATFORMS_FILE"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    [ "$(platform_default_model openai)" = "gpt-b" ] && ok "the default openai model is the first one switched on in Settings, whatever the catalog priority says" || bad "default $(platform_default_model openai)"
    platform_model_ok openai gpt-hidden; want "a hidden slug is accepted when written"      0 $?
    platform_model_ok openai gpt-nope;   want "a slug outside the catalog is refused"       1 $?
    platform_effort_ok openai gpt-a ultra; want "ultra is fine where the catalog lists it"  0 $?
    platform_effort_ok openai gpt-b ultra; want "and refused where it does not"             1 $?
    [ "$(openai_catalog_successor gpt-old)" = "gpt-b" ] && ok "a deprecated slug names its successor" || bad "successor $(openai_catalog_successor gpt-old)"
    [ -z "$(openai_catalog_successor gpt-a)" ] && ok "a live slug names none" || bad "live slug has a successor"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_catout" | grep -v '^RESULT '
  printf '%s\n' "$_catout" | grep -qx 'RESULT ok=7 bad=0' \
    && ok "openai catalog reader over models.json: all 7 assertions reach the gate" \
    || bad "openai catalog reader over models.json did not: $(printf '%s\n' "$_catout" | tail -1)"

  local _noneout
  _noneout="$(
    MODELS_FILE="$tmp/cat/none.json"
    # Settings has a slug switched on; the catalog file does not exist.
    PLATFORMS_FILE="$tmp/cat/none-platforms.json"
    printf '{"platforms":{"openai":{"enabled":true,"bin":"","models":["gpt-a"]}}}\n' > "$PLATFORMS_FILE"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    platform_model_ok openai gpt-a; want "without a catalog every slug is refused" 1 $?
    [ "$(platform_default_model openai)" = "gpt-a" ] && ok "and the default model is still what Settings switched on: it needs no catalog" || bad "default without a catalog: $(platform_default_model openai)"
    platform_effort_ok openai gpt-a ultra; want "but the effort vocabulary falls back to the union" 0 $?
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_noneout" | grep -v '^RESULT '
  printf '%s\n' "$_noneout" | grep -qx 'RESULT ok=3 bad=0' \
    && ok "openai catalog reader with no catalog file: all 3 assertions reach the gate" \
    || bad "openai catalog reader with no catalog file did not: $(printf '%s\n' "$_noneout" | tail -1)"

  # resolve_models_openai() itself -- the writer, over the real fixture (the
  # same one `test/fake-codex debug models` prints), and the recovery paths
  # nothing above exercises: a written .resolved surviving an .openai-only
  # refresh, and no-codex producing available:false rather than a crash.
  local _rmout
  _rmout="$(
    mkdir -p "$tmp/rm"
    CODEX_BIN="$BASE_DIR/test/fake-codex"
    CONFIG_DIR="$tmp/rm"
    MODELS_FILE="$tmp/rm/models.json"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }

    resolve_models_openai >/dev/null

    [ "$("$JQ" -r '.openai.source' "$MODELS_FILE")" = "codex debug models" ] \
      && ok "resolve_models_openai: .openai.source is codex debug models" \
      || bad "source '$("$JQ" -r '.openai.source' "$MODELS_FILE")'"
    [ "$(num "$("$JQ" -r '.openai.models | length' "$MODELS_FILE")")" = "7" ] \
      && ok "resolve_models_openai: the catalog carries all 7 models" \
      || bad "model count '$("$JQ" -r '.openai.models | length' "$MODELS_FILE")'"
    [ "$(openai_catalog_visible | tr '\n' ' ')" = "gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4-mini " ] \
      && ok "resolve_models_openai: openai_catalog_visible lists the priority order" \
      || bad "visible order '$(openai_catalog_visible | tr '\n' ' ')'"
    openai_catalog_slugs | grep -qxF gpt-reserve
    want "resolve_models_openai: the hidden gpt-reserve is still in openai_catalog_slugs" 0 $?
    openai_catalog_visible | grep -qxF gpt-reserve
    want "resolve_models_openai: but not in openai_catalog_visible" 1 $?
    [ "$(openai_catalog_default_effort gpt-5.6-sol)" = "low" ] \
      && ok "resolve_models_openai: gpt-5.6-sol's default effort is low" \
      || bad "default effort '$(openai_catalog_default_effort gpt-5.6-sol)'"
    [ "$(openai_catalog_efforts gpt-5.6-sol | tail -1)" = "ultra" ] \
      && ok "resolve_models_openai: gpt-5.6-sol's efforts end with ultra" \
      || bad "last effort '$(openai_catalog_efforts gpt-5.6-sol | tail -1)'"
    [ "$(num "$(openai_catalog_efforts gpt-5.6-sol | wc -l)")" = "6" ] \
      && ok "resolve_models_openai: gpt-5.6-sol has 6 effort levels" \
      || bad "sol effort count '$(num "$(openai_catalog_efforts gpt-5.6-sol | wc -l)")'"
    [ "$(num "$(openai_catalog_efforts gpt-5.5 | wc -l)")" = "4" ] \
      && ok "resolve_models_openai: gpt-5.5 has 4 effort levels" \
      || bad "5.5 effort count '$(num "$(openai_catalog_efforts gpt-5.5 | wc -l)")'"
    [ "$(openai_catalog_successor gpt-5.4-mini)" = "gpt-5.6-luna" ] \
      && ok "resolve_models_openai: gpt-5.4-mini's successor is gpt-5.6-luna" \
      || bad "successor '$(openai_catalog_successor gpt-5.4-mini)'"
    _retires="$("$JQ" -r '.openai.models[] | select(.slug == "gpt-5.4-mini") | .retires_at' "$MODELS_FILE")"
    [ "${_retires#2026-08-31}" != "$_retires" ] \
      && ok "resolve_models_openai: gpt-5.4-mini's retires_at starts 2026-08-31" \
      || bad "retires_at '$_retires'"
    [ "$(openai_catalog_all_efforts | tr '\n' ' ')" = "low medium high xhigh max ultra " ] \
      && ok "resolve_models_openai: openai_catalog_all_efforts unions the visible models' efforts" \
      || bad "all efforts '$(openai_catalog_all_efforts | tr '\n' ' ')'"

    # .resolved must survive a write that only ever touches .openai.
    "$JQ" -n '{resolved:{opus:{id:"x", at:1}}}' > "$MODELS_FILE"
    resolve_models_openai >/dev/null
    [ "$("$JQ" -r '.resolved.opus.id' "$MODELS_FILE")" = "x" ] \
      && ok "resolve_models_openai: .resolved survives a refresh of .openai" \
      || bad ".resolved.opus.id '$("$JQ" -r '.resolved.opus.id' "$MODELS_FILE")'"

    # No codex at all: available:false with a reason, never a crash.
    CODEX_BIN=/nonexistent
    MODELS_FILE="$tmp/rm/no-codex.json"
    resolve_models_openai >/dev/null
    [ "$("$JQ" -r '.openai.available' "$MODELS_FILE")" = "false" ] \
      && ok "resolve_models_openai: no codex -> .openai.available is false" \
      || bad "available '$("$JQ" -r '.openai.available' "$MODELS_FILE")'"
    [ "$("$JQ" -r '.openai.reason' "$MODELS_FILE")" = "codex not installed" ] \
      && ok "resolve_models_openai: no codex -> .openai.reason says so" \
      || bad "reason '$("$JQ" -r '.openai.reason' "$MODELS_FILE")'"

    # models_stale ages the openai block from the last ATTEMPT: a kept
    # catalog (old .at, fresh stale_at) is not refreshed again on the next
    # tick, which would spend the anthropic probing pass every minute.
    MODELS_FILE="$tmp/rm/stale.json"
    "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{opus:{id:"x", at:$now}}, openai:{at:1, models:[]}}' > "$MODELS_FILE"
    models_stale; want "models_stale: an openai block older than MODELS_TTL is stale" 0 $?
    "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{opus:{id:"x", at:$now}}, openai:{at:1, models:[], stale_at:$now, stale_reason:"codex not installed"}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    models_stale; want "models_stale: a kept catalog with a fresh stale_at is not" 1 $?

    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_rmout" | grep -v '^RESULT '
  printf '%s\n' "$_rmout" | grep -qx 'RESULT ok=17 bad=0' \
    && ok "resolve_models_openai over the fixture catalog: all 17 assertions reach the gate" \
    || bad "resolve_models_openai over the fixture catalog did not: $(printf '%s\n' "$_rmout" | tail -1)"

  echo "accounts — the sign-ins Settings registers beside each platform's Default"
  local ac="$tmp/ac" _aj
  mkdir -p "$ac/config" "$ac/data" "$ac/fakehome/.claude" "$ac/fakehome/.claude-a" "$ac/fakehome/.claude-b" "$ac/fakehome/.claude-c" "$ac/fakehome/.claude-file" "$ac/fakehome/.codex-a" "$ac/codex-home"
  printf '{"jobs":[{"id":"ja","project":"P","prompt":"x","model":"claude-opus-5"},{"id":"jo","platform":"openai","model":"gpt-a","prompt":"x"}]}\n' > "$ac/config/jobs.json"
  printf '{"projects":[{"name":"P","cwd":"%s"}]}\n' "$ac" > "$ac/config/projects.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-a"]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$ac/config/platforms.json"
  # A home of its own: `~` in a directory, the Default's ~/.claude, the plist
  # the pin is read back from and ~/.claude/skills all hang off HOME, and
  # none of them may be the operator's.
  ac_al() { HOME="$ac/fakehome" AGENTLOOP_CONFIG="$ac/config" AGENTLOOP_DATA="$ac/data" \
            AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" \
            AGENTLOOP_CLAUDE_CONFIG_DIR="" CODEX_HOME="$ac/codex-home" AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode \
            "$BIN_DIR/agentloop" "$@"; }
  ac_refused() { # ac_refused <label> <expected substring> <platform args...>
    local _l="$1" _w="$2" _o _r; shift 2
    _o="$(ac_al platform "$@" 2>&1)"; _r=$?
    case "$_o" in *"$_w"*) [ "$_r" -ne 0 ] && ok "$_l" || bad "$_l: rc=$_r" ;; *) bad "$_l: $_o" ;; esac
  }
  _aj="$(ac_al platform accounts anthropic 2>/dev/null)"
  printf '%s' "$_aj" | "$JQ" -e --arg h "$ac/fakehome/.claude" 'length == 1 and .[0].id == "default" and .[0].name == "Default"
      and .[0].builtin == true and .[0].dir == $h and .[0].account_dir == "" and .[0].check.ready == true
      and .[0].used_by == {jobs: ["ja"], projects: ["P"], security: []}' >/dev/null 2>&1 \
    && ok "platform accounts: the Default alone, on the CLI's own directory, with who runs on it" || bad "accounts before any: $_aj"
  out="$(ac_al platform account-add anthropic "Client A" "~/.claude-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Client A' added on anthropic (id client-a) — signed in as fake@example.org · max plan" ] \
    && ok "account-add registers it, names its id and whom it is signed in as" || bad "account-add: rc=$rc $out"
  [ "$("$JQ" -c '.platforms.anthropic.accounts' "$ac/config/platforms.json")" = '[{"id":"client-a","name":"Client A","dir":"~/.claude-a"}]' ] \
    && ok "and the file keeps the directory as it was typed" || bad "file: $(cat "$ac/config/platforms.json")"
  [ "$(readlink "$ac/fakehome/.claude-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
    && ok "and the skills are linked into that account's own skills directory" || bad "skills in the account: $(ls "$ac/fakehome/.claude-a" 2>&1)"
  : > "$ac/fakehome/.claude-file/skills"
  out="$(ac_al platform account-add anthropic "Filed" "~/.claude-file" 2>&1)"; rc=$?
  case "$out" in
    "account 'Filed' added on anthropic (id filed) — signed in as fake@example.org · max plan; "*" skill(s) could not be linked into $ac/fakehome/.claude-file/skills (agentloop skills install)")
      [ "$rc" -eq 0 ] && ok "and says when an account's own skills could not be linked (its skills path is a plain file)" || bad "rc=$rc $out" ;;
    *) bad "skills suffix missing: rc=$rc $out" ;;
  esac
  ac_al platform account-remove anthropic filed >/dev/null 2>&1   # done with it: keeps the later "only it leaves the file" count exact
  ac_refused "an account needs a name" "an account needs a name" account-add anthropic "" "~/.claude-a"
  ac_refused "an account needs a directory" "an account needs a directory" account-add anthropic "NeedsDir" ""
  ac_refused "a name already used is refused, whatever its case" "an account named 'client a' already exists on anthropic" account-add anthropic "client a" "~/.claude-b"
  ac_refused "a directory another account has is refused, trailing slash or not" "$ac/fakehome/.claude-a is already the directory of the account 'Client A'" account-add anthropic "Other" "$ac/fakehome/.claude-a/"
  ac_refused "a relative directory is refused" "the directory must be absolute or start with ~/ (got 'relative/dir')" account-add anthropic "Rel" "relative/dir"
  ac_refused "a directory that does not exist says how to create it" "$ac/fakehome/.claude-none does not exist — create it by signing in: CLAUDE_CONFIG_DIR=$ac/fakehome/.claude-none claude auth login" account-add anthropic "None" "~/.claude-none"
  ac_refused "the Default's own directory is refused" "$ac/fakehome/.claude is the Default account's directory" account-add anthropic "Home" "~/.claude"
  ac_refused "Default is not a name an account can take" "Default is the install's own account — choose another name" account-add anthropic "default" "~/.claude-b"
  ac_refused "OpenCode has no accounts" "OpenCode has no accounts — its credentials are the providers configured in opencode itself" account-add opencode "X" "~/.claude-b"
  out="$(ac_al platform account-add anthropic "Client-A" "~/.claude-b" 2>&1)"
  case "$out" in *"(id client-a-2)"*) ok "an id already taken gets a numbered suffix" ;; *) bad "suffix: $out" ;; esac
  : > "$ac/fakehome/.claude-b/.fake-logged-out"
  _aj="$(ac_al platform check anthropic client-a-2 2>/dev/null)"
  printf '%s' "$_aj" | "$JQ" -e --arg d "$ac/fakehome/.claude-b" '.ready == false and .account_id == "client-a-2" and .account_dir == $d
      and .reason == ("claude is not signed in in " + $d + " (run: CLAUDE_CONFIG_DIR=" + $d + " claude auth login)")' >/dev/null 2>&1 \
    && ok "platform check <p> <id> checks that account's own directory" || bad "check client-a-2: $_aj"
  _aj="$(ac_al platform accounts anthropic 2>/dev/null)"
  printf '%s' "$_aj" | "$JQ" -e --arg d "$ac/fakehome/.claude-b" \
      '(.[] | select(.id == "client-a-2")) as $e
       | $e.dir == "~/.claude-b" and $e.account_dir == $d and $e.builtin == false and $e.check.ready == false
       and $e.used_by == {jobs:[], projects:[], security:[]}' >/dev/null 2>&1 \
    && ok "platform accounts: a registered, logged-out account shows its typed dir, its exported dir, and that nobody uses it" || bad "accounts client-a-2: $_aj"
  printf 'a@example.org' > "$ac/fakehome/.claude-a/.fake-email"
  [ "$(ac_al platform check anthropic client-a 2>/dev/null | "$JQ" -r .account)" = "a@example.org · max plan" ] \
    && ok "and says whom that directory is signed in as" || bad "check client-a: $(ac_al platform check anthropic client-a 2>&1)"
  [ "$(ac_al platform check anthropic nope 2>/dev/null | "$JQ" -r '.ready, .account_dir, .reason' | tr '\n' '|')" = "false||account 'nope' is not an account of anthropic in Settings|" ] \
    && ok "an id Settings does not have is not ready, and says so, and exports nothing for account_dir" || bad "check nope: $(ac_al platform check anthropic nope 2>&1)"
  out="$(ac_al platform account-edit anthropic client-a "Client Alpha" "~/.claude-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Client Alpha' saved on anthropic — signed in as a@example.org · max plan" ] \
    && [ "$("$JQ" -r '.platforms.anthropic.accounts[0] | "\(.id) \(.name)"' "$ac/config/platforms.json")" = "client-a Client Alpha" ] \
    && ok "account-edit renames it and keeps its id" || bad "edit: rc=$rc $out"
  out="$(ac_al platform account-edit anthropic client-a "Client Alpha" "~/.claude-c" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Client Alpha' saved on anthropic — signed in as fake@example.org · max plan" ] \
    && [ "$(readlink "$ac/fakehome/.claude-c/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
    && ok "account-edit moving an account to a new, existing directory relinks the skills there too" || bad "edit relink: rc=$rc $out $(ls "$ac/fakehome/.claude-c" 2>&1)"
  ac_refused "the Default is not edited here" "the Default account is the install's own — it is not edited here" account-edit anthropic default "X" "~/.claude-b"
  ac_refused "an unknown id is not edited" "no account 'nope' on anthropic" account-edit anthropic nope "X" "~/.claude-b"
  "$JQ" '.jobs[0].account = "client-a"' "$ac/config/jobs.json" > "$ac/jobs.next" && mv "$ac/jobs.next" "$ac/config/jobs.json"
  ac_refused "an account in use is not removed, and the refusal names who uses it" "'Client Alpha' is used by ja — move them to another account first" account-remove anthropic client-a
  "$JQ" 'del(.jobs[0].account)' "$ac/config/jobs.json" > "$ac/jobs.next" && mv "$ac/jobs.next" "$ac/config/jobs.json"
  printf '{oops' > "$ac/config/jobs.json"
  ac_refused "account-remove refuses when jobs.json cannot be read, rather than assuming nobody uses it" "cannot tell who uses 'Client Alpha': $ac/config/jobs.json does not parse — fix it first" account-remove anthropic client-a
  printf '{"jobs":[{"id":"ja","project":"P","prompt":"x","model":"claude-opus-5"},{"id":"jo","platform":"openai","model":"gpt-a","prompt":"x"}]}\n' > "$ac/config/jobs.json"
  out="$(ac_al platform account-remove anthropic client-a 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'client-a' removed from anthropic" ] \
    && [ "$("$JQ" -c '[.platforms.anthropic.accounts[].id]' "$ac/config/platforms.json")" = '["client-a-2"]' ] \
    && ok "once nobody uses it, it is removed, and only it leaves the file" || bad "remove: rc=$rc $out $(cat "$ac/config/platforms.json")"
  ac_refused "the Default is never removed" "the Default account is the install's own — it cannot be removed" account-remove anthropic default
  ac_refused "an unknown id is not removed" "no account 'nope' on anthropic" account-remove anthropic nope
  out="$(ac_al platform account-add openai "Client A" "~/.codex-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Client A' added on openai (id client-a) — Logged in using ChatGPT" ] \
    && ok "an OpenAI account has its own list: the same name and id are free there" || bad "openai add: rc=$rc $out"
  : > "$ac/fakehome/.codex-a/.fake-logged-out"
  [ "$(ac_al platform check openai client-a 2>/dev/null | "$JQ" -r .reason)" = "codex is not signed in in $ac/fakehome/.codex-a (run: CODEX_HOME=$ac/fakehome/.codex-a codex login)" ] \
    && ok "and its check runs codex login status in that CODEX_HOME" || bad "openai check: $(ac_al platform check openai client-a 2>&1)"
  [ "$(readlink "$ac/fakehome/.codex-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
    && ok "and the skills are linked into its home too" || bad "codex account skills: $(ls "$ac/fakehome/.codex-a" 2>&1)"
  ac_refused "a Codex home that does not exist says how to create it" "$ac/fakehome/.codex-none does not exist — create it and sign in: mkdir -p $ac/fakehome/.codex-none && CODEX_HOME=$ac/fakehome/.codex-none codex login" account-add openai "N" "~/.codex-none"
  # A directory a shell would split at a space, or end at a quote, is quoted
  # in the command a refusal or a check suggests -- only there, and only
  # then: the plain directories above read exactly as typed. Pasted, the
  # command has to sign in the very directory the account has.
  ac_refused "a directory with a space is quoted in the login it suggests, and only there" \
    "$ac/fakehome/My Claude does not exist — create it by signing in: CLAUDE_CONFIG_DIR='$ac/fakehome/My Claude' claude auth login" account-add anthropic "Spaced" "~/My Claude"
  ac_refused "and in the Codex one, both times it is named" \
    "$ac/fakehome/My Codex does not exist — create it and sign in: mkdir -p '$ac/fakehome/My Codex' && CODEX_HOME='$ac/fakehome/My Codex' codex login" account-add openai "SpacedC" "~/My Codex"
  mkdir -p "$ac/fakehome/Client A's"
  out="$(ac_al platform account-add anthropic "Quoted" "~/Client A's" 2>&1)"; rc=$?
  : > "$ac/fakehome/Client A's/.fake-logged-out"
  _aj="$(ac_al platform check anthropic quoted 2>/dev/null | "$JQ" -r .reason)"
  [ "$rc" -eq 0 ] && [ "$_aj" = "claude is not signed in in $ac/fakehome/Client A's (run: CLAUDE_CONFIG_DIR='$ac/fakehome/Client A'\''s' claude auth login)" ] \
    && ok "a registered account's check quotes its directory in the login, a quote inside it included" || bad "quoted check: rc=$rc $out / $_aj"
  got="$( claude() { printf '%s' "$CLAUDE_CONFIG_DIR"; }; eval "$(printf '%s' "$_aj" | sed -n 's/.*(run: \(.*\))$/\1/p')" )"
  [ "$got" = "$ac/fakehome/Client A's" ] \
    && ok "and that login, pasted into a shell, names exactly the account's directory" || bad "pasted login -> '$got'"
  ac_al platform account-remove anthropic quoted >/dev/null 2>&1
  # platform enable asks about the Default alone -- the account the model
  # probes run on -- so its refusal says what it checked and both ways out.
  out="$(FAKE_CLAUDE_LOGGED_OUT=1 ac_al platform enable anthropic 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "cannot enable anthropic: claude is not signed in (run: claude auth login) — enable checks the Default account, the one the model probes run on: sign it in, or pin the install to another Claude account (AGENTLOOP_CLAUDE_CONFIG_DIR=<its directory> agentloop install)" ] \
    && ok "platform enable refuses a Default with no session, and names both ways out: sign it in, or pin the install to another account" \
    || bad "enable anthropic signed out: rc=$rc $out"
  mkdir -p "$ac/fakehome/.claude-pin"; : > "$ac/fakehome/.claude-pin/.fake-logged-out"
  out="$(HOME="$ac/fakehome" AGENTLOOP_CONFIG="$ac/config" AGENTLOOP_DATA="$ac/data" \
         AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" \
         AGENTLOOP_CLAUDE_CONFIG_DIR="~/.claude-pin" CODEX_HOME="$ac/codex-home" AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode \
         "$BIN_DIR/agentloop" platform enable anthropic 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "cannot enable anthropic: claude is not signed in in $ac/fakehome/.claude-pin (run: CLAUDE_CONFIG_DIR=$ac/fakehome/.claude-pin claude auth login) — enable checks the Default account, the one the model probes run on: sign it in, or pin the install to another Claude account (AGENTLOOP_CLAUDE_CONFIG_DIR=<its directory> agentloop install)" ] \
    && ok "and on a pinned install the Default it names is the pin" \
    || bad "enable anthropic, pinned and signed out: rc=$rc $out"
  # A pin that normalizes to the CLI's own directory must still leave the
  # variable UNSET (account_env_value), not set it to that same path: the
  # fake only honours the marker when CLAUDE_CONFIG_DIR is actually set, so
  # ready here proves it was left unset.
  : > "$ac/fakehome/.claude/.fake-logged-out"
  out="$(HOME="$ac/fakehome" AGENTLOOP_CONFIG="$ac/config" AGENTLOOP_DATA="$ac/data" \
         AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" \
         AGENTLOOP_CLAUDE_CONFIG_DIR="$ac/fakehome/.claude/" CODEX_HOME="$ac/codex-home" AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode \
         "$BIN_DIR/agentloop" platform check anthropic 2>/dev/null)"
  [ "$(printf '%s' "$out" | "$JQ" -r .ready)" = "true" ] && [ "$(printf '%s' "$out" | "$JQ" -r .account_dir)" = "" ] \
    && ok "a pin that normalizes to the CLI's own directory still runs with CLAUDE_CONFIG_DIR unset, and exports nothing" || bad "pin equals default: $out"
  rm -f "$ac/fakehome/.claude/.fake-logged-out"
  [ "$( HOME=/Users/me; account_env_value anthropic "/Users/me/.claude/" )" = "" ] \
    && [ "$( HOME=/Users/me; account_env_value anthropic "~/.claude-x///" )" = "/Users/me/.claude-x" ] \
    && [ "$( HOME=/Users/me; account_env_value openai "~/.codex" )" = "" ] \
    && [ "$( HOME=/Users/me; account_env_value openai "" )" = "" ] \
    && ok "account_env_value: the CLI's own directory (and nothing) is no value at all; any other is normalized" || bad "account_env_value"
  ( account_norm_dir "rel/dir" >/dev/null ); want "account_norm_dir refuses a relative path" 1 $?
  ( account_norm_dir "/" >/dev/null ); want "and the root" 1 $?
  [ "$(account_slug "  Client Á / Nº 2 ")" = "client-n-2" ] && [ "$(account_slug "!!!")" = "account" ] \
    && ok "account_slug: lower case, dashes, nothing at the ends, a fallback for nothing" || bad "slug: $(account_slug "  Client Á / Nº 2 ") / $(account_slug "!!!")"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"ok","name":"Ok","dir":"/x"},{"id":"","name":"n","dir":"/y"},"junk",{"id":"default","name":"D","dir":"/z"},{"id":"n","name":"N"},{"id":"a b","name":"S","dir":"/s"},{"id":"*","name":"G","dir":"/g"}]}}}\n' > "$ac/malformed.json"
  [ "$( PLATFORMS_FILE="$ac/malformed.json"; accounts_json anthropic )" = '[{"id":"ok","name":"Ok","dir":"/x"}]' ] \
    && [ "$( PLATFORMS_FILE="$ac/malformed.json"; accounts_json opencode )" = '[]' ] \
    && ok "accounts_json keeps only well-formed entries whose id is account_slug's own alphabet, never one called default, and OpenCode has none" || bad "malformed: $( PLATFORMS_FILE="$ac/malformed.json"; accounts_json anthropic )"

  echo "claude_config_dir — install turns what is left of it into accounts"
  local ccd="$tmp/ccd" _mig
  mkdir -p "$ccd/cfg" "$ccd/data" "$ccd/fakehome/.claude" "$ccd/fakehome/old-elsewhere" "$ccd/old-acct" "$ccd/orphan-p" "$ccd/orphan-s" "$ccd/old-acct2" "$ccd/old-acct3"
  cat > "$ccd/cfg/projects.json" <<JSON
{"projects":[{"name":"Old1","cwd":"$ccd","claude_config_dir":"$ccd/old-acct/"},
             {"name":"Old2","cwd":"$ccd","security":{"enabled":false,"claude_config_dir":"$ccd/old-acct"}},
             {"name":"Old3","cwd":"$ccd","claude_config_dir":"~/.claude"},
             {"name":"Old4","cwd":"$ccd","platform":"openai","claude_config_dir":"$ccd/old-acct"},
             {"name":"Old5","cwd":"$ccd","claude_config_dir":"$ccd/missing"},
             {"name":"Old6","cwd":"$ccd","claude_config_dir":"~/old-elsewhere"},
             {"name":"Old7","cwd":"$ccd","account":"already-p","claude_config_dir":"$ccd/orphan-p",
              "security":{"enabled":false,"account":"already-s","claude_config_dir":"$ccd/orphan-s"}}]}
JSON
  printf '{"jobs":[]}\n' > "$ccd/cfg/jobs.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-a"]}}}\n' > "$ccd/cfg/platforms.json"
  ccd_env() {
    HOME="$ccd/fakehome"; PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""
    CONFIG_DIR="$ccd/cfg"; PROJECTS_FILE="$ccd/cfg/projects.json"; JOBS_FILE="$ccd/cfg/jobs.json"
    PLATFORMS_FILE="$ccd/cfg/platforms.json"; DATA_DIR="$ccd/data"
  }
  _mig="$( ( ccd_env; accounts_migrate_legacy ) 2>&1 )"
  case "$_mig" in *"registered the Claude account 'old-acct' ($ccd/old-acct) from projects.json"*) ok "a directory no account has becomes one, named after the directory" ;; *) bad "migration: $_mig" ;; esac
  [ "$("$JQ" -c '[.projects[] | {n: .name, a: (.account // null), s: ((.security // {}).account // null), c: (has("claude_config_dir") or ((.security // {}) | has("claude_config_dir")))}]' "$ccd/cfg/projects.json")" \
      = '[{"n":"Old1","a":"old-acct","s":null,"c":false},{"n":"Old2","a":null,"s":"old-acct","c":false},{"n":"Old3","a":null,"s":null,"c":false},{"n":"Old4","a":null,"s":null,"c":true},{"n":"Old5","a":null,"s":null,"c":true},{"n":"Old6","a":"old-elsewhere","s":null,"c":false},{"n":"Old7","a":"already-p","s":"already-s","c":false}]' ] \
    && ok "each level takes the account (the Default's own directory takes nothing), and the old field goes" \
    || bad "migrated: $("$JQ" -c '.projects' "$ccd/cfg/projects.json")"
  case "$_mig" in *"claude_config_dir on Old4 (project) left in place — that level runs on openai"*) ok "a level that does not run on Anthropic keeps the field, and says why" ;; *) bad "Old4: $_mig" ;; esac
  case "$_mig" in *"claude_config_dir on Old5 (project) left in place — $ccd/missing does not exist"*) ok "and so does a directory that is gone" ;; *) bad "Old5: $_mig" ;; esac
  case "$_mig" in *"registered the Claude account 'old-elsewhere' ($ccd/fakehome/old-elsewhere) from projects.json"*) ok "a directory written with ~ is registered too, named after it" ;; *) bad "Old6: $_mig" ;; esac
  [ "$("$JQ" -r '.platforms.anthropic.accounts[] | select(.name=="old-elsewhere") | .dir' "$ccd/cfg/platforms.json")" = "~/old-elsewhere" ] \
    && ok "and the stored directory is what projects.json had (~ kept, not expanded; account_add trims the trailing slash)" \
    || bad "old-elsewhere dir: $("$JQ" -c '.platforms.anthropic.accounts' "$ccd/cfg/platforms.json")"
  case "$_mig" in *"claude_config_dir on Old7 (project) dropped — it already runs on the account 'already-p'"*) ok "a level that already has an account drops the field instead of registering a new one" ;; *) bad "Old7 project: $_mig" ;; esac
  case "$_mig" in *"claude_config_dir on Old7 (security) dropped — it already runs on the account 'already-s'"*) ok "and the same for a security block" ;; *) bad "Old7 security: $_mig" ;; esac
  [ "$("$JQ" '[.platforms.anthropic.accounts[]? | select(.name=="orphan-p" or .name=="orphan-s")] | length' "$ccd/cfg/platforms.json")" = "0" ] \
    && ok "and no account is registered for a directory that level never runs on" \
    || bad "orphan accounts leaked into platforms.json: $("$JQ" -c '.platforms.anthropic.accounts' "$ccd/cfg/platforms.json")"
  got="$( ( ccd_env; legacy_config_dir_warning ) )"
  case "$got" in
    *"WARNING: projects.json: claude_config_dir on Old4 is not read — accounts live in Settings › Platforms; pick one in the project editor (saving the project drops the field)"*)
      ok "status and install still name what the migration could not convert" ;;
    *) bad "warning: '$got'" ;;
  esac
  [ -z "$( ( ccd_env; accounts_migrate_legacy ) 2>&1 | grep -v 'left in place' )" ] \
    && ok "a second pass converts nothing twice" || bad "second pass: $( ( ccd_env; accounts_migrate_legacy ) 2>&1 )"
  # project-set is the only cleanup a level the migration left in place ever
  # gets afterwards -- it has to drop the field at both levels on every save,
  # not just leave it alone, or the warning above never clears.
  "$JQ" --arg d "$ccd/old-acct" '(.projects[] | select(.name=="Old4")) |= (.security = {enabled:false, claude_config_dir:$d})' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  out="$( ( ccd_env; printf '{"name":"Old4"}' | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *"claude_config_dir on Old4 dropped — it is not read; pick the account in the project editor"*)
      [ "$rc" -eq 0 ] && ok "project-set drops a claude_config_dir the migration left in place, and says so" || bad "project-set Old4: rc=$rc $out" ;;
    *) bad "project-set Old4: rc=$rc $out" ;;
  esac
  [ "$("$JQ" -c '.projects[] | select(.name=="Old4") | {p: .platform, c: has("claude_config_dir"), sc: ((.security|objects)//{} | has("claude_config_dir")), se: ((.security|objects)//{}).enabled}' "$ccd/cfg/projects.json")" \
      = '{"p":"openai","c":false,"sc":false,"se":false}' ] \
    && ok "and the field is gone at both levels, the rest of the project kept" \
    || bad "Old4 after project-set: $("$JQ" -c '.projects[] | select(.name=="Old4")' "$ccd/cfg/projects.json")"
  # Old8 is added only NOW, after both explicit accounts_migrate_legacy calls
  # above -- nothing has touched it yet, so only cmd_project_set's OWN
  # internal call (not a prior migration pass) can be what converts it.
  "$JQ" --arg c "$ccd" --arg d "$ccd/old-acct2" '.projects += [{"name":"Old8","cwd":$c,"claude_config_dir":$d}]' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  out="$( ( ccd_env; printf '{"name":"Old8","description":"x"}' | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *"registered the Claude account 'old-acct2' ($ccd/old-acct2) from projects.json"*"claude_config_dir on Old8 (project) is now the account 'old-acct2'"*)
      [ "$rc" -eq 0 ] && ok "a save converts a leftover claude_config_dir exactly as install would, before anything else it does" || bad "project-set Old8: rc=$rc $out" ;;
    *) bad "project-set Old8: rc=$rc $out" ;;
  esac
  [ "$("$JQ" -c '.projects[] | select(.name=="Old8") | {a: .account, c: has("claude_config_dir"), d: .description}' "$ccd/cfg/projects.json")" \
      = '{"a":"old-acct2","c":false,"d":"x"}' ] \
    && ok "and the project ends with the account, no claude_config_dir, and the rest of the save still applied" \
    || bad "Old8 after project-set: $("$JQ" -c '.projects[] | select(.name=="Old8")' "$ccd/cfg/projects.json")"
  # The dashboard never sends Old8's shape. saveProject sends EVERY level's
  # account, "" for a level whose editor showed none -- and that is exactly
  # the level a leftover claude_config_dir has not been turned into an
  # account yet. The save's own conversion fills the level first; the ""
  # merged over it afterwards used to leave the project on the Default, the
  # new account registered with nothing pointing at it, and the printed "is
  # now the account" false. Old13 is the other half: a level whose save picks
  # an account of its own never needed its directory registered at all.
  mkdir -p "$ccd/old-acct4" "$ccd/old-acct5" "$ccd/old-acct6"
  "$JQ" --arg c "$ccd" --arg d4 "$ccd/old-acct4" --arg d5 "$ccd/old-acct5" --arg d6 "$ccd/old-acct6" \
      '.projects += [{"name":"Old11","cwd":$c,"claude_config_dir":$d4},
                     {"name":"Old12","cwd":$c,"security":{"enabled":false,"claude_config_dir":$d5}},
                     {"name":"Old13","cwd":$c,"claude_config_dir":$d6}]' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  ccd_page_save() { # ccd_page_save <project> <account> <security.account> -> the partial saveProject (bin/dashboard.html) sends
    "$JQ" -nc --arg n "$1" --arg c "$ccd" --arg a "$2" --arg s "$3" '
      {name:$n, cwd:$c, platform:"anthropic", account:$a, worktree:{enabled:"auto"}, repos:[], base:"",
       security:{enabled:false, platform:"", account:$s, model:"", effort:"", permission_mode:"bypassPermissions",
                 default_profile:"standard", max_budget_usd:"", daily_budget_usd:"", min_severity:"low", ignore_paths:""}}'
  }
  out="$( ( ccd_env; ccd_page_save Old11 "" "" | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *"claude_config_dir on Old11 (project) is now the account 'old-acct4'"*)
      [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old11") | {a: .account, c: has("claude_config_dir")}' "$ccd/cfg/projects.json")" = '{"a":"old-acct4","c":false}' ] \
        && ok "a save from the page keeps the account its own conversion gave the project, over the \"\" the page sends for it" \
        || bad "Old11 after a page save: rc=$rc out=$out now=$("$JQ" -c '.projects[] | select(.name=="Old11")' "$ccd/cfg/projects.json")" ;;
    *) bad "Old11 page save: rc=$rc $out" ;;
  esac
  out="$( ( ccd_env; ccd_page_save Old12 "" "" | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *"claude_config_dir on Old12 (security) is now the account 'old-acct5'"*)
      [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old12") | {a: .account, s: .security.account, c: (.security | has("claude_config_dir")), m: .security.min_severity}' "$ccd/cfg/projects.json")" = '{"a":"","s":"old-acct5","c":false,"m":"low"}' ] \
        && ok "and so does its security block, over the \"\" sent for security.account -- the rest of the block still saved" \
        || bad "Old12 after a page save: rc=$rc out=$out now=$("$JQ" -c '.projects[] | select(.name=="Old12")' "$ccd/cfg/projects.json")" ;;
    *) bad "Old12 page save: rc=$rc $out" ;;
  esac
  out="$( ( ccd_env; ccd_page_save Old13 "old-acct" "" | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *registered*|*"is now the account"*) bad "Old13: a level whose save picks its own account still had its directory registered: $out" ;;
    *"claude_config_dir on Old13 (project) dropped — this save sets the account 'old-acct'"*)
      [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old13") | {a: .account, c: has("claude_config_dir")}' "$ccd/cfg/projects.json")" = '{"a":"old-acct","c":false}' ] \
        && [ "$("$JQ" '[.platforms.anthropic.accounts[] | select(.name == "old-acct6")] | length' "$ccd/cfg/platforms.json")" = "0" ] \
        && ok "a save that picks an account of its own wins, and its leftover directory is dropped, never registered as an orphan -- worded as THIS save setting it, not as already running on it" \
        || bad "Old13 after a page save: rc=$rc out=$out now=$("$JQ" -c '.projects[] | select(.name=="Old13")' "$ccd/cfg/projects.json") accounts=$("$JQ" -c '.platforms.anthropic.accounts' "$ccd/cfg/platforms.json")" ;;
    *) bad "Old13 page save: rc=$rc $out" ;;
  esac

  # Old14 is the other misleading case the same message used to have: the
  # operator CLEARS a stored account (the page sends "" for a level that
  # already had one) -- not this save's own doing, and not what Old7 tests
  # (no save at all). The old wording named the account being removed as
  # though it still ran on it; the level actually ends on the Default (or,
  # for security, inherits), and never registers a fresh orphan for the
  # leftover directory either.
  mkdir -p "$ccd/old-acct9" "$ccd/old-acct10"
  "$JQ" --arg c "$ccd" --arg d9 "$ccd/old-acct9" --arg d10 "$ccd/old-acct10" \
      '.projects += [{"name":"Old14","cwd":$c,"account":"old-clear-p","claude_config_dir":$d9,
                       "security":{"enabled":false,"account":"old-clear-s","claude_config_dir":$d10}}]' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  out="$( ( ccd_env; ccd_page_save Old14 "" "" | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *registered*|*"is now the account"*|*"already runs on"*) bad "Old14: a cleared account should not be named as still running, nor its directory registered: $out" ;;
    *"claude_config_dir on Old14 (project) dropped — this save leaves the project on the Default account"*)
      ok "clearing a stored project account is worded as landing on the Default, not as still running on the account being removed" ;;
    *) bad "Old14 project wording: rc=$rc $out" ;;
  esac
  case "$out" in
    *"claude_config_dir on Old14 (security) dropped — this save clears the account, the analysis inherits"*)
      [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old14") | {a: .account, c: has("claude_config_dir"), s: .security.account, sc: (.security | has("claude_config_dir"))}' "$ccd/cfg/projects.json")" = '{"a":"","c":false,"s":"","sc":false}' ] \
        && ok "and the same for its security block, worded as inheriting, and both leftover directories dropped, neither registered" \
        || bad "Old14 after clearing: rc=$rc out=$out now=$("$JQ" -c '.projects[] | select(.name=="Old14")' "$ccd/cfg/projects.json")" ;;
    *) bad "Old14 security wording: rc=$rc $out" ;;
  esac

  # Old15 (round 2, finding 1): a CLI project-set that never mentions
  # .account or security.account at all -- `.account // ""` upstream reads a
  # MISSING key exactly like an empty one, which used to print the Old14
  # wording ("this save leaves the project on the Default account") even
  # though this save never touches the account and the stored one survives
  # untouched. "keep-p"/"keep-s" are registered first so the UNRELATED
  # unknown-account cleanup further down in project-set has nothing to do.
  mkdir -p "$ccd/keep-p-dir" "$ccd/keep-s-dir" "$ccd/old-acct11" "$ccd/old-acct12"
  ( ccd_env; account_add anthropic "keep-p" "$ccd/keep-p-dir" ) >/dev/null
  ( ccd_env; account_add anthropic "keep-s" "$ccd/keep-s-dir" ) >/dev/null
  "$JQ" --arg c "$ccd" --arg d11 "$ccd/old-acct11" --arg d12 "$ccd/old-acct12" \
      '.projects += [{"name":"Old15","cwd":$c,"account":"keep-p","claude_config_dir":$d11,
                       "security":{"enabled":false,"account":"keep-s","claude_config_dir":$d12}}]' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  out="$( ( ccd_env; printf '{"name":"Old15","description":"cli-touch"}' | cmd_project_set ) 2>&1 )"; rc=$?
  case "$out" in
    *registered*|*"is now the account"*|*"leaves the project"*|*"clears the account"*) bad "Old15: a save that never sent the account keys should not reword or touch them: $out" ;;
    *"claude_config_dir on Old15 (project) dropped — it already runs on the account 'keep-p'"*)
      ok "a CLI save that never sends .account keeps the old, still-true wording for the project level" ;;
    *) bad "Old15 project wording: rc=$rc $out" ;;
  esac
  case "$out" in
    *"claude_config_dir on Old15 (security) dropped — it already runs on the account 'keep-s'"*)
      [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old15") | {a: .account, c: has("claude_config_dir"), s: .security.account, sc: (.security | has("claude_config_dir")), d: .description}' "$ccd/cfg/projects.json")" = '{"a":"keep-p","c":false,"s":"keep-s","sc":false,"d":"cli-touch"}' ] \
        && ok "and the same for security -- both accounts survive exactly as stored, only the leftover directories and the rest of the save applied" \
        || bad "Old15 after a keyless save: rc=$rc out=$out now=$("$JQ" -c '.projects[] | select(.name=="Old15")' "$ccd/cfg/projects.json")" ;;
    *) bad "Old15 security wording: rc=$rc $out" ;;
  esac

  # Fix round 3: accounts_migrate_legacy now runs only after every refusal
  # gate has cleared, only for the project actually being saved, and only
  # when platforms.json is valid -- before this fix it ran first, unscoped,
  # so a REFUSED save could still register a new account and rewrite an
  # unrelated project's leftover claude_config_dir (or, with platforms.json
  # unreadable, die with an unrelated error instead of refusing plainly).
  "$JQ" --arg c "$ccd" --arg d "$ccd/old-acct3" \
      '.projects += [{"name":"Old9","cwd":$c,"claude_config_dir":$d}, {"name":"Old10","cwd":$c}]' \
      "$ccd/cfg/projects.json" > "$ccd/cfg/projects.json.next" && mv "$ccd/cfg/projects.json.next" "$ccd/cfg/projects.json"
  local snap1 snap2
  snap1="$(cksum < "$ccd/cfg/projects.json") / $(cksum < "$ccd/cfg/platforms.json")"
  out="$( ( ccd_env; printf '{}' | cmd_project_set ) 2>&1 )"; rc=$?
  snap2="$(cksum < "$ccd/cfg/projects.json") / $(cksum < "$ccd/cfg/platforms.json")"
  case "$out" in
    *registered*|*"is now the account"*) bad "project-set {}: migrated anyway: $out" ;;
    *) [ "$rc" -ne 0 ] && [ "$snap1" = "$snap2" ] \
         && ok "a refused project-set ({}) touches nothing, not even another project's leftover claude_config_dir" \
         || bad "project-set {}: rc=$rc snap1=[$snap1] snap2=[$snap2] out=$out" ;;
  esac
  out="$( ( ccd_env; printf '{"name":"Old7","account":"nonexistent-xyz"}' | cmd_project_set ) 2>&1 )"; rc=$?
  snap2="$(cksum < "$ccd/cfg/projects.json") / $(cksum < "$ccd/cfg/platforms.json")"
  case "$out" in
    *registered*|*"is now the account"*) bad "project-set Old7 bad account: migrated anyway: $out" ;;
    *) [ "$rc" -ne 0 ] && [ "$snap1" = "$snap2" ] \
         && ok "a refused save of an existing project with a bad sent account touches nothing either" \
         || bad "project-set Old7 bad account: rc=$rc snap1=[$snap1] snap2=[$snap2] out=$out" ;;
  esac
  out="$( ( ccd_env; printf '{"name":"Old9","account":"nonexistent-xyz"}' | cmd_project_set ) 2>&1 )"; rc=$?
  snap2="$(cksum < "$ccd/cfg/projects.json") / $(cksum < "$ccd/cfg/platforms.json")"
  case "$out" in
    *registered*|*"is now the account"*) bad "project-set Old9 bad account: migrated anyway: $out" ;;
    *) [ "$rc" -ne 0 ] && [ "$snap1" = "$snap2" ] \
         && ok "a refused save of the SAME project carrying the leftover field changes nothing either" \
         || bad "project-set Old9 bad account: rc=$rc snap1=[$snap1] snap2=[$snap2] out=$out" ;;
  esac
  out="$( ( ccd_env; printf '{"name":"Old10","description":"touched"}' | cmd_project_set ) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$("$JQ" -r '.projects[] | select(.name=="Old9") | has("claude_config_dir")' "$ccd/cfg/projects.json")" = "true" ] \
    && ok "a successful save of one project does not touch another project's leftover claude_config_dir" \
    || bad "project-set Old10: rc=$rc out=$out Old9=$("$JQ" -c '.projects[] | select(.name=="Old9")' "$ccd/cfg/projects.json")"
  cp "$ccd/cfg/platforms.json" "$ccd/cfg/platforms.json.bak"
  printf 'not json\n' > "$ccd/cfg/platforms.json"
  out="$( ( ccd_env; printf '{"name":"Old9","description":"kept-too"}' | cmd_project_set ) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[] | select(.name=="Old9") | {c: has("claude_config_dir"), d: .description}' "$ccd/cfg/projects.json")" = '{"c":true,"d":"kept-too"}' ] \
    && ok "with platforms.json unreadable, a save still applies its other fields and keeps the leftover claude_config_dir" \
    || bad "project-set Old9 over broken platforms.json: rc=$rc out=$out Old9=$("$JQ" -c '.projects[] | select(.name=="Old9")' "$ccd/cfg/projects.json")"
  mv "$ccd/cfg/platforms.json.bak" "$ccd/cfg/platforms.json"

  echo "job_account() — its own, else its project's on the same platform, else the Default"
  local ja="$tmp/jacct"; mkdir -p "$ja/a" "$ja/b" "$ja/c" "$ja/prechecks"
  cat > "$ja/platforms.json" <<JSON
{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"],"accounts":[{"id":"a","name":"A","dir":"$ja/a"},{"id":"b","name":"B","dir":"$ja/b"}]},
              "openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"],"accounts":[{"id":"c","name":"C","dir":"$ja/c"}]}}}
JSON
  cat > "$ja/projects.json" <<'JSON'
{"projects":[{"name":"PA","account":"a","security":{"enabled":false,"account":"b"}},
             {"name":"PN"},
             {"name":"PO","platform":"openai","account":"c"},
             {"name":"PS","account":"a","security":{"enabled":true,"model":"claude-opus-5"}},
             {"name":"PX","account":"a","security":{"enabled":true,"platform":"openai","model":"gpt-5.6-sol"}},
             {"name":"PZ","account":"a","security":{"enabled":true,"model":"claude-opus-5","account":"zz"}},
             {"name":"PB","account":"a","security":{"enabled":true,"model":"claude-opus-5","account":"b"}},
             {"name":"PD","account":"a","security":{"enabled":true,"model":"claude-opus-5","account":"default"}},
             {"name":"PC","security":{"enabled":true,"model":"claude-opus-5","account":"b,a"}},
             {"name":"PDel","platform":"openai"}]}
JSON
  cat > "$ja/jobs.json" <<'JSON'
{"jobs":[{"id":"own","project":"PA","account":"b","prompt":"x"},
         {"id":"inherits","project":"PA","prompt":"x"},
         {"id":"explicit-same","project":"PA","platform":"anthropic","prompt":"x"},
         {"id":"other-platform","project":"PA","platform":"openai","prompt":"x"},
         {"id":"none","project":"PN","prompt":"x"},
         {"id":"loose","prompt":"x"},
         {"id":"codex-inherits","project":"PO","prompt":"x"},
         {"id":"reproject","project":"PA","account":"b","prompt":"x"},
         {"id":"deljob","project":"PDel","account":"c","prompt":"x"}]}
JSON
  printf '{"resolved":{},"openai":{"at":1,"source":"fixture","models":[{"slug":"gpt-5.6-sol","visibility":"list","priority":1,"efforts":["low"],"default_effort":"low","deprecated_by":"","retires_at":""}]}}\n' > "$ja/models.json"
  ja_env() { PLATFORMS_FILE="$ja/platforms.json"; PROJECTS_FILE="$ja/projects.json"; JOBS_FILE="$ja/jobs.json"
             MODELS_FILE="$ja/models.json"; CONFIG_DIR="$ja"; DATA_DIR="$ja/data"; HOME="$ja"; PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""; }
  got="$( ja_env; for j in own inherits explicit-same other-platform none loose codex-inherits; do printf '%s=%s ' "$j" "$(job_account "$j")"; done )"
  [ "$got" = "own=b inherits=a explicit-same=a other-platform=default none=default loose=default codex-inherits=c " ] \
    && ok "job_account: its own; the project's on the same platform, whether or not the job names it; else default" || bad "job_account: $got"
  # PX's own platform is unset (anthropic) and its account is a; PS's block
  # inherits a (same platform); PX's block runs on openai, so it does not.
  # PZ/PB/PD each now have their OWN project account ('a') too, distinct from
  # what their block names -- proving the derived job reads the BLOCK's
  # account, not the project's, whenever the block has one of its own.
  [ "$( ja_env; account_users anthropic a | tr '\n' ' ' )" = "inherits explicit-same project:PA project:PS project:PX project:PZ project:PB project:PD security:PS " ] \
    && ok "account_users follows the same rule: the jobs, then the projects, then the blocks" || bad "users of a: $( ja_env; account_users anthropic a | tr '\n' ' ' )"
  [ "$( ja_env; account_users anthropic b | tr '\n' ' ' )" = "own reproject security:PA security:PB " ] \
    && ok "and counts a security block by the account it resolves to" || bad "users of b: $( ja_env; account_users anthropic b | tr '\n' ' ' )"
  [ "$( ja_env; job_get "$(security_job_id PS)" '.account' '' )" = "a" ] \
    && ok "an analysis on the project's platform inherits the project's account" || bad "derived PS: $( ja_env; job_get "$(security_job_id PS)" '.account' '' )"
  [ "$( ja_env; job_get "$(security_job_id PX)" '.account' '' )" = "default" ] \
    && ok "one on another platform runs on that platform's Default" || bad "derived PX: $( ja_env; job_get "$(security_job_id PX)" '.account' '' )"
  # PZ's project carries account 'a' (a REAL, known account) -- so 'default'
  # below can only come from REJECTING the block's own 'zz'; a bug that read
  # the block as empty and fell through to the project's would answer 'a'
  # here instead, wrongly, and this is the assertion that would catch it.
  [ "$( ja_env; job_get "$(security_job_id PZ)" '.account' '' 2>/dev/null )" = "default" ] \
    && ok "an account the platform does not have falls back to the Default" || bad "derived PZ: $( ja_env; job_get "$(security_job_id PZ)" '.account' '' 2>&1 )"
  [ "$( ja_env; job_get "$(security_job_id PB)" '.account' '' )" = "b" ] \
    && ok "a block's own account reaches the derived job even though its project has a different one" || bad "derived PB: $( ja_env; job_get "$(security_job_id PB)" '.account' '' )"
  [ "$( ja_env; job_get "$(security_job_id PD)" '.account' '' )" = "default" ] \
    && ok "and a block naming default is still WRITTEN on the derived job, not left absent to re-inherit the project's" || bad "derived PD: $( ja_env; job_get "$(security_job_id PD)" '.account' '' )"
  # PC's block names 'b,a' -- a value no real account id can be, but one a
  # hand edit of projects.json can still write. The row this reads used to be
  # comma-joined: read back, a value that itself carries a comma shifts every
  # field after it, and here it can land on 'b' -- a REAL, registered
  # account -- so the bad value would pass account_known silently and the
  # analysis would run on 'b' with no warning.
  [ "$( ja_env; job_get "$(security_job_id PC)" '.account' '' 2>/dev/null )" = "default" ] \
    && ok "a block account with a comma in it is rejected whole, not split into a real one" || bad "derived PC: $( ja_env; job_get "$(security_job_id PC)" '.account' '' 2>&1 )"
  grep -q "security: project 'PC' names an account anthropic does not have ('b,a') -- using the Default account" "$ja/data/security/derivation-warnings.txt" 2>/dev/null \
    && ok "and the derivation warning is issued for it, same as any other unknown account" || bad "no warning for PC: $(cat "$ja/data/security/derivation-warnings.txt" 2>/dev/null)"

  echo "set-field, create and project-set — the account is one of the level's own platform"
  out="$( (ja_env; printf 'b' | cmd_set_field inherits account) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; job_get inherits '.account' '' )" = "b" ] \
    && ok "set-field account takes an id of the job's platform" || bad "set-field b: rc=$rc $out"
  out="$( (ja_env; printf 'c' | cmd_set_field inherits account) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "and refuses one of another platform, naming what this one has" || bad "set-field c: rc=$rc $out"
  ( ja_env; printf '' | cmd_set_field inherits account ) >/dev/null 2>&1
  [ -z "$( ja_env; job_get inherits '.account' '' )" ] && ok "empty clears it: the job inherits again" || bad "not cleared"
  out="$( (ja_env; printf 'openai' | cmd_set_field own platform) 2>&1 )"; rc=$?
  case "$out" in *"account 'b' is not an account of openai — cleared, the job inherits"*)
      [ -z "$( ja_env; job_get own '.account' '' )" ] && ok "a platform change clears an account the new platform does not have, and says so" || bad "account survived" ;;
    *) bad "platform change: rc=$rc $out" ;; esac
  # reproject has no platform of its own (job_platform inherits its
  # project's) -- moving it from PA (anthropic) to PO (openai) changes its
  # EFFECTIVE platform exactly like the platform arm's own move does above,
  # and its own account 'b' is left stranded the same way.
  out="$( (ja_env; printf 'PO' | cmd_set_field reproject project) 2>&1 )"; rc=$?
  case "$out" in *"account 'b' is not an account of openai — cleared, the job inherits"*)
      [ "$rc" -eq 0 ] && [ -z "$( ja_env; job_get reproject '.account' '' )" ] \
        && ok "changing a job's project clears an account its new effective platform does not have too" \
        || bad "account survived a project change: rc=$rc $out" ;;
    *) bad "project change: rc=$rc $out" ;; esac
  out="$( (ja_env; printf '{"id":"made","project":"PA","account":"c","prompt":"x"}' | cmd_create) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "create: account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "create refuses an account of another platform" || bad "create c: rc=$rc $out"
  out="$( (ja_env; printf '{"id":"made","project":"PA","account":"b","prompt":"x"}' | cmd_create) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; job_get made '.account' '' )" = "b" ] \
    && ok "and keeps one of its own" || bad "create b: rc=$rc $out"
  out="$( (ja_env; printf '{"name":"PA","account":"zz"}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "project-set: account 'zz' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "project-set refuses an account the platform does not have" || bad "project-set zz: rc=$rc $out"
  out="$( (ja_env; printf '{"name":"PA","security":{"account":"c"}}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "project-set: security.account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "and a block account the block's platform does not have" || bad "project-set sec c: rc=$rc $out"
  # made (created just above) has no platform of its own either, and its
  # account 'b' is only valid while PA runs on anthropic -- the project's
  # platform change below has to strand it exactly as own's own move did,
  # even though nothing here names made's job directly.
  out="$( (ja_env; printf '{"name":"PA","platform":"openai"}' | cmd_project_set) 2>&1 )"; rc=$?
  case "$out" in *"account 'a' is not an account of openai — cleared, the project runs on the Default account"*"security.account 'b' is not an account of openai — cleared, the analysis inherits"*"job made: account 'b' is not an account of openai — cleared, the job inherits"*)
      "$JQ" -e '.projects[] | select(.name == "PA") | (has("account") | not) and ((.security | has("account")) | not)' "$ja/projects.json" >/dev/null 2>&1 \
        && [ -z "$( ja_env; job_get made '.account' '' )" ] \
        && ok "a platform change clears the stored accounts it leaves behind, at both levels and every job of it, and says so" \
        || bad "stale accounts kept: $("$JQ" -c '.projects[0]' "$ja/projects.json") made=$( ja_env; job_get made '.account' '' )" ;;
    *) bad "project platform change: rc=$rc $out" ;; esac
  out="$( (ja_env; printf '{"name":"PO","security":{"account":"c"}}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; security_get PO '.account' '' )" = "c" ] \
    && ok "a block that inherits the project's openai takes an openai account" || bad "PO block: rc=$rc $out"

  echo "cmd_project_delete() — a deleted project's jobs stop inheriting its platform too"
  out="$( ( ja_env; cmd_project_delete PDel ) 2>&1 )"; rc=$?
  case "$out" in *"job deljob: account 'c' is not an account of anthropic — cleared, the job inherits"*)
      [ "$rc" -eq 0 ] && [ -z "$( ja_env; job_get deljob '.account' '' )" ] \
        && ok "a deleted project's job falls back to anthropic and loses an account that platform does not have" \
        || bad "deljob after delete: rc=$rc $out" ;;
    *) bad "project-delete: rc=$rc $out" ;;
  esac

  echo "project-set, set-field project and set-field platform — a platforms.json that cannot be read clears no account"
  local pv="$tmp/pv"; mkdir -p "$pv"
  printf 'not json\n' > "$pv/platforms.json"
  cat > "$pv/projects.json" <<'JSON'
{"projects":[{"name":"BadP","account":"ghost","security":{"enabled":false,"account":"ghost2"}}]}
JSON
  cat > "$pv/jobs.json" <<'JSON'
{"jobs":[{"id":"badjob","project":"BadP","account":"ghost3","prompt":"x"}]}
JSON
  pv_env() { PLATFORMS_FILE="$pv/platforms.json"; PROJECTS_FILE="$pv/projects.json"; JOBS_FILE="$pv/jobs.json"
             CONFIG_DIR="$pv"; DATA_DIR="$pv/data"; HOME="$pv"; PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""; }
  out="$( (pv_env; printf '{"name":"BadP","description":"kept"}' | cmd_project_set) 2>&1 )"; rc=$?
  case "$out" in *"is not an account of"*) bad "project-set spoke about an account with a broken platforms.json: $out" ;;
    *) [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.projects[0] | {a: .account, sa: .security.account, d: .description}' "$pv/projects.json")" = '{"a":"ghost","sa":"ghost2","d":"kept"}' ] \
         && ok "an unreadable platforms.json clears no stored account on project-set, and says nothing about it" \
         || bad "project-set over broken platforms.json: rc=$rc out=$out state=$("$JQ" -c '.projects[0]' "$pv/projects.json")" ;;
  esac
  out="$( (pv_env; printf 'x' | cmd_set_field badjob project) 2>&1 )"; rc=$?
  case "$out" in *"is not an account of"*) bad "set-field project spoke about an account with a broken platforms.json: $out" ;;
    *) [ "$rc" -eq 0 ] && [ "$("$JQ" -r '.jobs[0].account' "$pv/jobs.json")" = "ghost3" ] \
         && ok "and re-projecting a job over the same broken file leaves its own account alone too" \
         || bad "set-field project over broken platforms.json: rc=$rc out=$out state=$("$JQ" -c '.jobs[0]' "$pv/jobs.json")" ;;
  esac
  out="$( (pv_env; printf '' | cmd_set_field badjob platform) 2>&1 )"; rc=$?
  case "$out" in *"is not an account of"*) bad "set-field platform (empty) spoke about an account with a broken platforms.json: $out" ;;
    *) [ "$rc" -eq 0 ] && [ "$("$JQ" -r '.jobs[0].account' "$pv/jobs.json")" = "ghost3" ] \
         && ok "clearing a job's own platform to inherit, over the same broken file, leaves its account alone too" \
         || bad "set-field platform (empty) over broken platforms.json: rc=$rc out=$out state=$("$JQ" -c '.jobs[0]' "$pv/jobs.json")" ;;
  esac

  echo "resolve_pricing_openai() — the price table refreshes itself from the source, never inventing a number"
  local _prout
  _prout="$(
    mkdir -p "$tmp/pr"
    CODEX_BIN="$BASE_DIR/test/fake-codex"
    # opencode pinned off: cmd_platforms below walks every platform, opencode
    # included, and must never reach the real CLI on this machine.
    AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN=/nonexistent
    CONFIG_DIR="$tmp/pr"
    MODELS_FILE="$tmp/pr/models.json"
    PRICING_FILE="$tmp/pr/pricing.json"
    TICK_LOG="$tmp/pr/tick.log"
    AGENTLOOP_PRICING_URL="file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    resolve_models_openai >/dev/null                     # the catalog the slugs come from (fake-codex)
    # A table with one row the source does not carry (gpt-5.4-mini) and one the
    # operator wrote by hand (gpt-5.5, deliberately wrong so a rewrite would show).
    "$JQ" -n '{openai:{"gpt-5.4-mini":{input:0.75,cached_input:0.075,output:4.5,cache_write:0,source:"litellm",at:1},
                       "gpt-5.4-nano":{input:1,cached_input:1,output:1,cache_write:1,source:"litellm",at:1},
                       "gpt-5.5":{input:9,cached_input:9,output:9,cache_write:0,source:"manual"}}}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -eq 0 ] && ok "resolve_pricing_openai: a good source returns 0" || bad "rc $_rc"
    pr() { "$JQ" -r "$1" "$PRICING_FILE"; }
    [ "$(pr '.openai["gpt-5.6-sol"] | [.input,.cached_input,.output,.cache_write] | join(" ")')" = "4 0.4 20 5" ] \
      && ok "resolve_pricing_openai: gpt-5.6-sol is 4 / 0.4 / 20 per 1M, cache write 5 (per-token × 1M)" \
      || bad "sol row '$(pr '.openai["gpt-5.6-sol"]')'"
    [ "$(pr '.openai["gpt-5.6-luna"] | [.input,.cached_input,.output,.cache_write] | join(" ")')" = "0.2 0.02 1.2 0" ] \
      && ok "resolve_pricing_openai: gpt-5.6-luna keeps its small numbers exact and cache write 0 when the source lists none" \
      || bad "luna row '$(pr '.openai["gpt-5.6-luna"]')'"
    # gpt-5.4-nano at the source has its cache prices as STRINGS, not numbers
    # (a malformed row): the merge must treat a non-number cache field as
    # absent, not hand it to per_m as though it were a real price.
    [ "$(pr '.openai["gpt-5.4-nano"] | [.input,.cached_input,.cache_write,.output,.cached_input_assumed] | join(" ")')" = "0.2 0.2 0 1.25 true" ] \
      && ok "resolve_pricing_openai: a cache price that is a string, not a number, is treated as absent, never as null" \
      || bad "nano row '$(pr '.openai["gpt-5.4-nano"]')'"
    [ "$(pr '.openai["gpt-5.6-sol"].source')" = "litellm" ] && [ "$(num "$(pr '.openai["gpt-5.6-sol"].at')")" -gt 1 ] \
      && ok "resolve_pricing_openai: a written row names its source and when" || bad "source/at '$(pr '.openai["gpt-5.6-sol"] | [.source,.at]')'"
    [ "$(pr '.openai["gpt-5.5"] | [.input,.source] | join(" ")')" = "9 manual" ] \
      && ok "resolve_pricing_openai: a manual row is never overwritten" || bad "manual row '$(pr '.openai["gpt-5.5"]')'"
    [ "$(pr '.openai["gpt-5.4-mini"] | [.input,.at] | join(" ")')" = "0.75 1" ] \
      && ok "resolve_pricing_openai: a slug the source lacks keeps its last row" || bad "kept row '$(pr '.openai["gpt-5.4-mini"]')'"
    [ "$(pr '.openai["gpt-reserve"] // "absent"')" = "absent" ] \
      && ok "resolve_pricing_openai: an entry of another provider is not a price" || bad "gpt-reserve was priced: $(pr '.openai["gpt-reserve"]')"
    [ "$(num "$(pr '._refreshed_at // 0')")" -gt 1 ] && [ "$(pr '._source_url')" = "$AGENTLOOP_PRICING_URL" ] \
      && ok "resolve_pricing_openai: the table records when and where from" || bad "meta '$(pr '[._refreshed_at,._source_url]')'"
    [ -z "$(pricing_unpriced)" ] && ok "pricing_unpriced: every visible slug has a price (the kept row counts)" || bad "unpriced '$(pricing_unpriced | tr '\n' ' ')'"
    # gpt-5.5 has no cache_read in the sample: the manual row shields it here, so
    # test the fallback on a fresh table.
    "$JQ" -n '{openai:{}}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null
    [ "$(pr '.openai["gpt-5.5"] | [.input,.cached_input,.cached_input_assumed] | join(" ")')" = "5 5 true" ] \
      && ok "resolve_pricing_openai: no cache price at the source → charged at the input rate, and said so" \
      || bad "5.5 row '$(pr '.openai["gpt-5.5"]')'"
    [ "$(pricing_unpriced | tr '\n' ' ')" = "gpt-5.4-mini " ] \
      && ok "pricing_unpriced: names the visible slug that has no row" || bad "unpriced '$(pricing_unpriced | tr '\n' ' ')'"
    grep -q 'pricing: no price for gpt-5.4-mini' "$TICK_LOG" \
      && ok "resolve_pricing_openai: and tick.log says so" || bad "no tick.log line: $(cat "$TICK_LOG" 2>/dev/null)"
    # A table whose .openai is not an object, or whose row is not one, is
    # repaired by the next refresh instead of killing every refresh from here
    # on with a jq type error over a file nobody is watching.
    "$JQ" -n '{openai:{"gpt-5.6-sol":7}}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null 2>&1; _rc=$?
    [ "$_rc" -eq 0 ] && [ "$(pr '.openai["gpt-5.6-sol"].input')" = "4" ] \
      && ok "resolve_pricing_openai: a row that is not an object is replaced by a real row, not a jq error" \
      || bad "scalar row: rc $_rc, sol '$(pr '.openai["gpt-5.6-sol"]')'"
    "$JQ" -n '{openai:[1,2]}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null 2>&1; _rc=$?
    [ "$_rc" -eq 0 ] && [ "$(pr '.openai | type')" = "object" ] && [ "$(pr '.openai["gpt-5.6-sol"].input')" = "4" ] \
      && ok "resolve_pricing_openai: an .openai that is an array is rebuilt as an object of priced rows" \
      || bad "array .openai: rc $_rc, .openai is '$(pr '.openai | type')'"
    # A price that MOVED is in the log, one line per number that changed, with
    # a flag when it moved by 3x or more: a silent change is a bill nobody
    # predicted. A row that did not exist before is logged whole.
    "$JQ" -n '{openai:{"gpt-5.6-sol":{input:40,cached_input:0.4,output:20,cache_write:5,source:"litellm",at:1}}}' > "$PRICING_FILE"
    : > "$TICK_LOG"
    resolve_pricing_openai >/dev/null
    grep -q 'pricing: gpt-5.6-sol input 40 -> 4 — check the source' "$TICK_LOG" \
      && ok "resolve_pricing_openai: a changed price is logged, and a move of 3x or more is flagged" \
      || bad "no change line: $(grep 'pricing:' "$TICK_LOG" 2>/dev/null | tr '\n' '|')"
    grep -q 'pricing: gpt-5.6-terra priced: input 2 cached 0.2 output 12 cache_write 2.5' "$TICK_LOG" \
      && ok "resolve_pricing_openai: a row that did not exist before is logged with all four numbers" \
      || bad "no priced line: $(grep 'pricing:' "$TICK_LOG" 2>/dev/null | tr '\n' '|')"
    # Failure keeps the table exactly as it was, and says so.
    _before="$(cat "$PRICING_FILE")"
    AGENTLOOP_PRICING_URL="file:///nonexistent/dir/prices.json" resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -ne 0 ] && [ "$(cat "$PRICING_FILE")" = "$_before" ] \
      && ok "resolve_pricing_openai: an unreachable source returns 1 and leaves the table untouched" || bad "unreachable: rc $_rc, changed=$([ "$(cat "$PRICING_FILE")" = "$_before" ] && echo no || echo yes)"
    grep -q 'pricing: refresh from file:///nonexistent/dir/prices.json failed.*table unchanged, last refreshed [0-9]*h ago' "$TICK_LOG" \
      && ok "resolve_pricing_openai: the failure is in tick.log, with a plain hour count for a table refreshed before" || bad "no failure line: $(cat "$TICK_LOG" 2>/dev/null)"
    printf 'not json\n' > "$tmp/pr/junk.txt"
    AGENTLOOP_PRICING_URL="file://$tmp/pr/junk.txt" resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -ne 0 ] && [ "$(cat "$PRICING_FILE")" = "$_before" ] \
      && ok "resolve_pricing_openai: a source that is not a JSON object returns 1 and leaves the table untouched" || bad "junk: rc $_rc"
    # A table that is corrupt (or missing) to begin with must not be reseeded
    # to an empty object before the fetch: a fetch that then fails would
    # otherwise report success at leaving the table alone, over a table that
    # was in fact just emptied.
    printf 'not json either' > "$tmp/pr/corrupt.json"
    PRICING_FILE="$tmp/pr/corrupt.json" AGENTLOOP_PRICING_URL="file:///nonexistent/dir/prices.json" resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -ne 0 ] && [ "$(cat "$tmp/pr/corrupt.json")" = "not json either" ] \
      && ok "resolve_pricing_openai: a corrupt table is left exactly as it was when the fetch then fails, never reseeded first" \
      || bad "corrupt: rc $_rc, content '$(cat "$tmp/pr/corrupt.json" 2>/dev/null)'"
    # A table that was never refreshed says so in plain words in the log, not
    # a huge hour count computed from a zero timestamp.
    printf '{"openai":{}}\n' > "$tmp/pr/never.json"
    PRICING_FILE="$tmp/pr/never.json" AGENTLOOP_PRICING_URL="file:///nonexistent/dir/prices.json" resolve_pricing_openai >/dev/null
    grep -q 'pricing: refresh from file:///nonexistent/dir/prices.json failed.*table unchanged, never refreshed' "$TICK_LOG" \
      && ok "resolve_pricing_openai: a table that was never refreshed says so, not a huge number of hours" \
      || bad "no never-refreshed line: $(tail -3 "$TICK_LOG" 2>/dev/null)"
    # A CONFIG_DIR that cannot hold a temp file is a silent-failure path: it
    # must log and refuse, not just return 1 with nothing to show for it.
    CONFIG_DIR="$tmp/pr/absent-parent-for-mktemp" PRICING_FILE="$tmp/pr/mktempfail.json" resolve_pricing_openai >/dev/null 2>&1; _rc=$?
    [ "$_rc" -ne 0 ] && grep -q 'pricing: cannot write under .*absent-parent-for-mktemp — refresh skipped' "$TICK_LOG" \
      && ok "resolve_pricing_openai: a CONFIG_DIR it cannot write under is logged and refused, not crashed past" \
      || bad "mktemp failure: rc $_rc, log: $(tail -3 "$TICK_LOG" 2>/dev/null)"
    # The source of the URL: env, else the _source_url of the table, else the
    # default. (No apostrophe in a comment inside a $( ): bash reads it as an
    # opening quote and the parse of the whole file goes wrong.)
    ( unset AGENTLOOP_PRICING_URL; [ "$(pricing_source_url)" = "file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json" ] ) \
      && ok "pricing_source_url: without the env override, the table's _source_url is used" || bad "url '$(unset AGENTLOOP_PRICING_URL; pricing_source_url)'"
    ( unset AGENTLOOP_PRICING_URL; "$JQ" 'del(._source_url)' "$PRICING_FILE" > "$PRICING_FILE.x"; PRICING_FILE="$PRICING_FILE.x"; [ "$(pricing_source_url)" = "$PRICING_SOURCE_DEFAULT" ] ) \
      && ok "pricing_source_url: and the default when the table has none" || bad "default url"
    # platforms carries the freshness and the gap.
    _pl="$(cmd_platforms 2>/dev/null)"
    [ "$(num "$(printf '%s' "$_pl" | "$JQ" -r '.openai.pricing_at // 0')")" -gt 1 ] \
      && ok "cmd_platforms: openai.pricing_at is the table's refresh time" || bad "pricing_at '$(printf '%s' "$_pl" | "$JQ" -c '.openai.pricing_at')'"
    [ "$(printf '%s' "$_pl" | "$JQ" -c '.openai.unpriced')" = '["gpt-5.4-mini"]' ] \
      && ok "cmd_platforms: openai.unpriced names the visible slug without a price" || bad "unpriced '$(printf '%s' "$_pl" | "$JQ" -c '.openai.unpriced')'"
    # opencode pinned off above: prove it held, so the leak this guards
    # against cannot come back silently.
    [ "$(printf '%s' "$_pl" | "$JQ" -r '.opencode.bin_found')" = "false" ] \
      && ok "cmd_platforms: opencode.bin_found is false, the pin held" || bad "opencode.bin_found '$(printf '%s' "$_pl" | "$JQ" -c '.opencode.bin_found')'"
    printf 'RESULT ok=%s bad=%s\n' "$_upass" "$_ufail"
  )"
  printf '%s\n' "$_prout" | grep -v '^RESULT '
  printf '%s\n' "$_prout" | grep -qx 'RESULT ok=28 bad=0' \
    && ok "resolve_pricing_openai: all 28 refresh assertions passed" \
    || bad "resolve_pricing_openai over the sample source did not: $(printf '%s\n' "$_prout" | tail -1)"

  echo "cmd_skills() — links into the Claude skills root, and into the Codex home only when that home exists"
  local _skout
  _skout="$(
    mkdir -p "$tmp/skl/claude" "$tmp/skl/codexhome"
    USER_SKILLS="$tmp/skl/claude"
    CODEX_HOME_DIR="$tmp/skl/nocodex"            # does not exist: this machine never ran the Codex CLI
    CODEX_SKILLS="$CODEX_HOME_DIR/skills"
    # No pin and no plist: the Default is ~/.claude, whose root is USER_SKILLS.
    # One registered account whose directory exists, one whose does not.
    PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""
    PLATFORMS_FILE="$tmp/skl/platforms.json"
    mkdir -p "$tmp/skl/acct-a"
    printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"a","name":"A","dir":"%s"},{"id":"gone","name":"Gone","dir":"%s"}]}}}\n' \
      "$tmp/skl/acct-a" "$tmp/skl/acct-gone" > "$PLATFORMS_FILE"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    cmd_skills install >/dev/null
    [ "$(readlink "$tmp/skl/claude/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "cmd_skills install: security-analysis is linked under the Claude root" \
      || bad "claude link: '$(readlink "$tmp/skl/claude/security-analysis" 2>/dev/null)'"
    [ ! -e "$tmp/skl/nocodex" ] \
      && ok "cmd_skills install: no Codex home, so no Codex skills directory is invented" \
      || bad "created $tmp/skl/nocodex"
    [ "$(readlink "$tmp/skl/acct-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "cmd_skills install: every registered account's directory gets the links too" \
      || bad "account link: '$(readlink "$tmp/skl/acct-a/skills/security-analysis" 2>/dev/null)'"
    [ ! -e "$tmp/skl/acct-gone" ] \
      && ok "cmd_skills install: an account directory that does not exist is not invented" \
      || bad "created $tmp/skl/acct-gone"
    CODEX_HOME_DIR="$tmp/skl/codexhome"
    CODEX_SKILLS="$CODEX_HOME_DIR/skills"
    _st="$(cmd_skills status)"
    printf '%s\n' "$_st" | grep -q 'MISSING  security-analysis' \
      && ok "cmd_skills status: with a Codex home, its root reports the skill missing" || bad "status: $_st"
    printf '%s\n' "$_st" | grep -qF 'run `agentloop skills install`' \
      && ok "cmd_skills status: and says how to fix it" || bad "no nag line in: $_st"
    printf '%s\n' "$_st" | grep -qF 'OpenCode reads ~/.claude/skills too' \
      && ok "cmd_skills status: says OpenCode reads the same link" || bad "no OpenCode line in: $_st"
    cmd_skills install >/dev/null
    [ "$(readlink "$tmp/skl/codexhome/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "cmd_skills install: security-analysis is linked under the Codex root too" \
      || bad "codex link: '$(readlink "$tmp/skl/codexhome/skills/security-analysis" 2>/dev/null)'"
    _st="$(cmd_skills status)"
    printf '%s\n' "$_st" | grep -q 'MISSING\|DIVERGED' \
      && bad "status after install still reports: $_st" \
      || ok "cmd_skills status: clean after install, on both roots"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_skout" | grep -v '^RESULT '
  printf '%s\n' "$_skout" | grep -qx 'RESULT ok=9 bad=0' \
    && ok "cmd_skills over two scratch roots: all 9 assertions reach the gate" \
    || bad "cmd_skills over two scratch roots did not: $(printf '%s\n' "$_skout" | tail -1)"

  echo "status_platforms_block() — one line per platform, with the Codex facts a refused run needs"
  local _spout
  _spout="$(
    mkdir -p "$tmp/sp"
    printf '#!/bin/bash\necho "2.1.0 (Claude Code)"\n' > "$tmp/sp/claude"; chmod +x "$tmp/sp/claude"
    CLAUDE_BIN="$tmp/sp/claude"
    AGENTLOOP_CLAUDE_CONFIG_DIR=""                # no pin from the shell and no plist from ~/Library:
    PLIST_PATH=/nonexistent                       # installed_config_dir answers nothing, the CLI default
    CODEX_BIN="$BASE_DIR/test/fake-codex"
    CODEX_HOME_DIR="$HOME/.codex"                 # the Codex Default is the CLI home itself: its sentences name no directory
    # An AGENTLOOP_*_BIN exported by the invoking shell must never win over the stand-ins above.
    AGENTLOOP_CLAUDE_BIN=""; AGENTLOOP_CODEX_BIN=""; AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    CONFIG_DIR="$tmp/sp"
    MODELS_FILE="$tmp/sp/models.json"
    PRICING_FILE="$tmp/sp/pricing.json"
    PLATFORMS_FILE="$tmp/sp/platforms.json"
    JOBS_FILE="$tmp/sp/jobs.json"
    PROJECTS_FILE="$tmp/sp/projects.json"
    TICK_LOG="$tmp/sp/tick.log"
    cp "$BASE_DIR/config/pricing.example.json" "$PRICING_FILE"
    printf '{"jobs":[]}\n' > "$tmp/sp/jobs.json"
    printf '{"projects":[]}\n' > "$tmp/sp/projects.json"
    printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"]},"opencode":{"enabled":true,"bin":"","models":[]}}}\n' > "$tmp/sp/platforms.json"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    resolve_models_openai >/dev/null
    resolve_models_opencode >/dev/null
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^anthropic : enabled — 2.1.0 (Claude Code), unknown — claude auth status needs Claude Code 2.1+; 1 of 1 models enabled$' \
      && ok "status_platforms_block: the Claude line carries enabled, version, account and the model count" \
      || bad "anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex-cli 0.148.0, Logged in using ChatGPT; 1 of 5 models enabled; catalog [0-9]*m ago (5 models); prices [0-9]*[mhd] ago; unpriced: none$' \
      && ok "status_platforms_block: the Codex line adds catalog age and size, price age, unpriced" \
      || bad "openai line: $(printf '%s\n' "$_b" | sed -n 2p)"
    printf '%s\n' "$_b" | grep -q '^opencode  : enabled — 1.18.30, 0 credentials · providers: opencode, pdm_ai; 0 of 13 models enabled; catalog [0-9]*m ago (13 models); unpriced: none$' \
      && ok "the opencode line adds the account's providers, the catalog age and size, and the enabled models still unpriced" \
      || bad "opencode line: $(printf '%s\n' "$_b" | sed -n 3p)"
    # The pin the install carries, by either route (the variable; the plist a
    # previous install wrote), never the CLAUDE_CONFIG_DIR of this process.
    _b="$(AGENTLOOP_CLAUDE_CONFIG_DIR=/pinned/home status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^anthropic : enabled — 2.1.0 (Claude Code), unknown — claude auth status needs Claude Code 2.1+ (in /pinned/home); 1 of 1 models enabled$' \
      && ok "status_platforms_block: a pinned account directory is named" \
      || bad "pinned anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict><key>Label</key><string>x</string>' \
      '<key>EnvironmentVariables</key><dict><key>CLAUDE_CONFIG_DIR</key><string>/plist/home</string></dict>' \
      '</dict></plist>' > "$tmp/sp/tick.plist"
    _b="$(PLIST_PATH="$tmp/sp/tick.plist" status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '(in /plist/home); 1 of 1 models enabled$' \
      && ok "status_platforms_block: the account a previous install wrote into the plist is named" \
      || bad "plist-pinned anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    # A pin that IS the CLI default account, just spelled with a trailing
    # slash, is the same account either way -- named as the engine resolves
    # it (account_default_dir), never as written.
    _b="$(AGENTLOOP_CLAUDE_CONFIG_DIR=/pinned/home/ status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '(in /pinned/home); 1 of 1 models enabled$' \
      && ok "status_platforms_block: a pin with a trailing slash is named normalized, not raw" \
      || bad "trailing-slash anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    # A table with no stamp at all (hand-written), and one visible slug dropped.
    # Captured first, never piped straight into grep -q: under pipefail a grep
    # that stops at its match hands the block a SIGPIPE on the lines still to
    # come (opencode follows openai), and the pipeline reads as a failure.
    "$JQ" 'del(.openai["gpt-5.4-mini"]) | del(._refreshed_at, ._checked_at)' "$PRICING_FILE" > "$PRICING_FILE.next"; mv "$PRICING_FILE.next" "$PRICING_FILE"
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q 'prices never refreshed; unpriced: gpt-5.4-mini$' \
      && ok "status_platforms_block: an unstamped table says so, and an unpriced visible slug is named" \
      || bad "after the edit: $(printf '%s\n' "$_b" | sed -n 2p)"
    _b="$(FAKE_CODEX_LOGGED_OUT=1 status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex is not signed in (run: codex login)$' \
      && ok "status_platforms_block: signed out reads as platform_ready's own sentence" \
      || bad "signed-out line: $(printf '%s\n' "$_b" | sed -n 2p)"
    CODEX_BIN=/nonexistent
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex not found at /nonexistent — set the path in Settings (or AGENTLOOP_CODEX_BIN); install: npm i -g @openai/codex, then codex login$' \
      && ok "status_platforms_block: no codex reads as not found, never a crash" \
      || bad "no-codex line: $(printf '%s\n' "$_b" | sed -n 2p)"
    write_platforms '.platforms.anthropic.enabled = false' >/dev/null 2>&1
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^anthropic : disabled — ' \
      && ok "status_platforms_block: a platform switched off says disabled" || bad "disabled line: $(printf '%s\n' "$_b" | sed -n 1p)"
    mkdir -p "$tmp/sp/acct-a"
    CLAUDE_BIN="$BASE_DIR/test/fake-claude"
    write_platforms '.platforms.anthropic.enabled = true' >/dev/null 2>&1
    write_platforms --arg d "$tmp/sp/acct-a" '.platforms.anthropic.accounts = [{id:"a", name:"Client A", dir:$d}]' >/dev/null 2>&1
    printf 'a@example.org' > "$tmp/sp/acct-a/.fake-email"
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -qF "            account Client A ($tmp/sp/acct-a) — signed in as a@example.org · max plan; used by 0; $(skills_missing "$tmp/sp/acct-a/skills") skill(s) not linked there (agentloop skills install)" \
      && ok "status_platforms_block: one line per registered account, under its platform" \
      || bad "account line: $(printf '%s\n' "$_b" | grep account)"
    # The account lines do not depend on the platform readiness check above:
    # a Default with no session must still say which accounts exist and
    # whether each one of them is ready, or an operator staring at "not
    # ready" cannot tell whether every account is down too.
    _b="$(FAKE_CLAUDE_LOGGED_OUT=1 status_platforms_block)"
    printf '%s\n' "$_b" | grep -qF "            account Client A ($tmp/sp/acct-a)" \
      && ok "status_platforms_block: the account lines still print when the platform's Default is not ready" \
      || bad "no account line with the Default down: $(printf '%s\n' "$_b" | grep account)"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_spout" | grep -v '^RESULT '
  printf '%s\n' "$_spout" | grep -qx 'RESULT ok=12 bad=0' \
    && ok "status_platforms_block over the stand-ins: all 12 assertions reach the gate" \
    || bad "status_platforms_block did not: $(printf '%s\n' "$_spout" | tail -1)"
  got="$(age_label "$(( $(now_epoch) + 600 ))")"
  [ "$got" = "0m ago" ] \
    && ok "age_label: a stamp from the future reads 0m ago, never a negative age" \
    || bad "a stamp 10 minutes ahead read '$got'"

  # cmd_resolve_models must hand the caller resolve_models_openai's status:
  # `agentloop resolve-models openai` exiting 0 after failing to write the
  # catalog is a silent no-op an operator (or install.sh) cannot notice. The
  # subshells exist only to shadow CODEX_BIN/CONFIG_DIR/MODELS_FILE -- the
  # assertion is on $? out here, where a bad() still counts.
  mkdir -p "$tmp/rmrc"
  ( CODEX_BIN=/nonexistent; CONFIG_DIR="$tmp/rmrc"; MODELS_FILE="$tmp/rmrc/models.json"
    cmd_resolve_models openai ) >/dev/null 2>&1
  want "resolve-models openai: no codex is a written available:false, not a failure" 0 $?
  ( CODEX_BIN=/nonexistent; CONFIG_DIR="$tmp/rmrc"; MODELS_FILE="$tmp/rmrc/nodir/x/models.json"
    cmd_resolve_models openai ) >/dev/null 2>&1
  want "resolve-models openai: a catalog that could not be written exits non-zero" 1 $?

  echo "cmd_resolve_pricing() — will not race the daily job or a second resolve-pricing"
  # Take the _models lock by hand, the way acquire_lock itself would (a pid
  # file and a boot file under LOCK_DIR/_models), shadowed to a private
  # directory under $tmp so this cannot collide with any other lock the rest
  # of the suite takes or leaves behind.
  mkdir -p "$tmp/prlock/_models"
  echo $$ > "$tmp/prlock/_models/pid"
  boot_id > "$tmp/prlock/_models/boot"
  _lockout="$(
    LOCK_DIR="$tmp/prlock" CONFIG_DIR="$tmp/pr" MODELS_FILE="$tmp/pr/models.json" \
    PRICING_FILE="$tmp/pr/pricing.json" TICK_LOG="$tmp/pr/tick.log" \
    AGENTLOOP_PRICING_URL="file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json" \
    cmd_resolve_pricing 2>&1
  )"
  _lockrc=$?
  [ "$_lockrc" -ne 0 ] && printf '%s' "$_lockout" | grep -q 'pricing: another refresh is running (the daily job or a second resolve-pricing) — try again in a minute' \
    && ok "cmd_resolve_pricing: refused while the _models lock is held, naming why" \
    || bad "held: rc=$_lockrc out='$_lockout'"
  rm -rf "$tmp/prlock/_models"
  LOCK_DIR="$tmp/prlock" CONFIG_DIR="$tmp/pr" MODELS_FILE="$tmp/pr/models.json" \
    PRICING_FILE="$tmp/pr/pricing.json" TICK_LOG="$tmp/pr/tick.log" \
    AGENTLOOP_PRICING_URL="file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json" \
    cmd_resolve_pricing >/dev/null 2>&1
  want "cmd_resolve_pricing: once the lock is released, the refresh proceeds" 0 $?

  echo "platform_stderr_filter() — exactly the CLI's one known line, nothing else"
  printf 'Reading additional input from stdin...\nsomething real\n' > "$tmp/e1.err"
  platform_stderr_filter openai "$tmp/e1.err"
  [ "$(cat "$tmp/e1.err")" = "something real" ] && ok "the known line goes, the rest stays" || bad "left: $(cat "$tmp/e1.err")"
  printf 'Reading additional input from stdin...\n' > "$tmp/e2.err"
  platform_stderr_filter openai "$tmp/e2.err"
  [ ! -s "$tmp/e2.err" ] && ok "a stderr that was only that line is now empty" || bad "not emptied"
  printf 'Reading additional input from stdin... and more\n' > "$tmp/e3.err"
  platform_stderr_filter openai "$tmp/e3.err"
  [ -s "$tmp/e3.err" ] && ok "a line that merely contains the phrase is kept" || bad "a longer line was removed"
  printf 'Reading additional input from stdin...\n' > "$tmp/e4.err"
  platform_stderr_filter anthropic "$tmp/e4.err"
  [ -s "$tmp/e4.err" ] && ok "anthropic stderr is never touched" || bad "anthropic stderr was filtered"
  local _se='timestamp=2026-09-13T18:05:46.820Z level=ERROR run=5284a776 message="stream error" providerID=pdm_ai modelID=GLM-5.3-NVFP4 session.id=ses_x small=false agent=build mode=primary error.error="AI_APICallError: Cannot connect to API: The socket connection was closed unexpectedly"'
  printf '%s\n%s\n' "$_se" "$_se" > "$tmp/e5.err"
  : > "$tmp/e5.tick"
  TICK_LOG="$tmp/e5.tick" platform_stderr_filter opencode "$tmp/e5.err" job-x
  [ ! -s "$tmp/e5.err" ] && ok "opencode: a stderr of retried stream errors only is emptied (measured 38)" || bad "left: $(cat "$tmp/e5.err")"
  grep -q 'job-x: opencode logged 2 stream error(s)' "$tmp/e5.tick" && ok "and tick.log carries the count" || bad "tick: $(cat "$tmp/e5.tick")"
  printf '%s\ntimestamp=2026-09-13T18:05:47.000Z level=ERROR run=5284a776 message="tool failed" tool=bash\n' "$_se" > "$tmp/e6.err"
  TICK_LOG="$tmp/e5.tick" platform_stderr_filter opencode "$tmp/e6.err"
  [ "$(cat "$tmp/e6.err")" = 'timestamp=2026-09-13T18:05:47.000Z level=ERROR run=5284a776 message="tool failed" tool=bash' ] && ok "opencode: any other ERROR line stays" || bad "left: $(cat "$tmp/e6.err")"
  printf 'level=INFO message="stream error"\n' > "$tmp/e7.err"
  platform_stderr_filter opencode "$tmp/e7.err"
  [ -s "$tmp/e7.err" ] && ok "opencode: only the CLI's own ERROR log line shape is removed" || bad "a non-matching line was removed"

  echo "platform_argv_openai() — the measured launch line, for a fresh run and a resume"
  platform_argv_openai "" /tmp/w gpt-a high workspace-write "PROMPT"
  local _av; _av="$(printf '%s\n' "${PLATFORM_ARGV[@]}")"
  [ "${PLATFORM_ARGV[0]}" = "exec" ] && [ "${PLATFORM_ARGV[1]}" = "--json" ] && ok "exec --json first" || bad "argv starts ${PLATFORM_ARGV[0]} ${PLATFORM_ARGV[1]}"
  printf '%s\n' "$_av" | grep -qx -- '-C' && ok "-C on a fresh run" || bad "no -C"
  printf '%s\n' "$_av" | grep -qx -- 'model_reasoning_effort=high' && ok "the effort override is bare" || bad "effort override missing or quoted"
  printf '%s\n' "$_av" | grep -qx -- 'approval_policy=never' && ok "approval_policy=never travels with a sandboxed mode" || bad "no approval_policy"
  printf '%s\n' "$_av" | grep -qx -- 'sandbox_workspace_write.network_access=true' \
    && ok "workspace-write opens the network back up (measured: sealed without this)" || bad "workspace-write left without network"
  printf '%s\n' "$_av" | grep -qx -- '--disable' && bad "--disable is passed and closes nothing" || ok "no --disable flag"
  [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 2))]}" = "--" ] && [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 1))]}" = "PROMPT" ] \
    && ok "-- then the prompt, last" || bad "the prompt is not the lone argument after --"
  platform_argv_openai "" /tmp/w gpt-a "" full-access "P"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '--dangerously-bypass-approvals-and-sandbox' \
    && ok "full-access is the bypass flag" || bad "full-access not translated"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '-s' && bad "-s alongside the bypass flag" || ok "and no -s beside it"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'network_access' \
    && bad "full-access carries a sandbox override it has no sandbox for" || ok "and no network override: full-access has no sandbox"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'model_reasoning_effort' && bad "an empty effort still emitted an override" || ok "an empty effort emits no override"
  platform_argv_openai thr-1 /tmp/w gpt-a low read-only "P"
  [ "${PLATFORM_ARGV[0]}" = "exec" ] && [ "${PLATFORM_ARGV[1]}" = "resume" ] && ok "a resume is exec resume" || bad "resume argv ${PLATFORM_ARGV[*]}"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '-C' && bad "-C on a resume (exec resume refuses it)" || ok "no -C on a resume"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- 'sandbox_mode=read-only' && ok "the sandbox is a -c override on a resume" || bad "no sandbox_mode on the resume"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'network_access' \
    && bad "read-only was given the network" || ok "read-only stays sealed to the network too"
  [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 3))]}" = "thr-1" ] && ok "the thread id sits right before --" || bad "thread id misplaced"
  # Last, because these REPLACE the argv every assertion above reads.
  platform_argv_openai thr-2 /tmp/w gpt-a low workspace-write "P"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- 'sandbox_workspace_write.network_access=true' \
    && ok "and a resumed workspace-write run keeps its network" || bad "the resume lost the network override"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'writable_roots' \
    && bad "writable_roots emitted with no roots to declare" || ok "no writable_roots when the caller names none"
  platform_argv_openai "" /tmp/w gpt-a low workspace-write "P" "$(printf '/a b/.git\n/c/.git\n')"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qxF -- 'sandbox_workspace_write.writable_roots=["/a b/.git","/c/.git"]' \
    && ok "the git dirs are declared writable, as a TOML array jq quoted" || bad "writable_roots: $(printf '%s\n' "${PLATFORM_ARGV[@]}" | grep writable_roots)"
  platform_argv_openai "" /tmp/w gpt-a low read-only "P" "$(printf '/a/.git\n')"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'writable_roots' \
    && bad "read-only was handed a writable root" || ok "read-only writes nowhere, roots or no roots"

  echo "openai_writable_roots() — the git directory a worktree checkout really writes to"
  local _wrout
  _wrout="$(
    mkdir -p "$tmp/wr"
    git init -q "$tmp/wr/repo"
    printf 'seed\n' > "$tmp/wr/repo/README"
    git -C "$tmp/wr/repo" add -A
    git -C "$tmp/wr/repo" -c user.email=t@local -c user.name=t commit -qm seed
    mkdir -p "$tmp/wr/run"
    git -C "$tmp/wr/repo" worktree add -q -b wrbranch "$tmp/wr/run/repo" >/dev/null 2>&1
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    _real="$(cd "$tmp/wr/repo/.git" && pwd -P)"
    [ "$(openai_writable_roots "$tmp/wr/run/repo")" = "$_real" ] \
      && ok "a worktree checkout resolves to the canonical repo's git directory" \
      || bad "got '$(openai_writable_roots "$tmp/wr/run/repo")' want '$_real'"
    [ "$(openai_writable_roots "$tmp/wr/run/repo" "$tmp/wr/run" | wc -l | tr -d ' ')" = "1" ] \
      && ok "the same repo listed twice is declared once" \
      || bad "duplicates: $(openai_writable_roots "$tmp/wr/run/repo" "$tmp/wr/run" | tr '\n' ' ')"
    mkdir -p "$tmp/wr/plain"
    [ -z "$(openai_writable_roots "$tmp/wr/plain")" ] \
      && ok "a directory that is no repo declares nothing" || bad "a non-repo produced a root"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_wrout" | grep -v '^RESULT '
  printf '%s\n' "$_wrout" | grep -qx 'RESULT ok=3 bad=0' \
    && ok "openai_writable_roots over a real worktree: all 3 assertions reach the gate" \
    || bad "openai_writable_roots did not: $(printf '%s\n' "$_wrout" | tail -1)"

  echo "platform_finish() — the model that ran comes from the rollout"
  mkdir -p "$tmp/ch/sessions/2026/09/05"
  cp "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" "$tmp/ch/sessions/2026/09/05/rollout-2026-09-05T13-49-58-01a071d5-47b0-7343-bcbd-216945ef7927.jsonl"
  # Same subshell-counting fix as the catalog readers above -- see that
  # comment. CODEX_HOME_DIR and RATE_LIMIT_FILE stay shadowed HERE, inside the
  # subshell: a later task makes platform_finish write the rate-limit file,
  # and the real one must never be touched by this suite.
  local _pfout
  _pfout="$(
    CODEX_HOME_DIR="$tmp/ch"; RATE_LIMIT_FILE="$tmp/ch/rate-limits.json"   # T7 makes this write the gate; never the real file
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    platform_finish openai /dev/null 01a071d5-47b0-7343-bcbd-216945ef7927 selftest
    [ "$PF_MODEL_ID" = "gpt-5.6-sol" ] && ok "turn_context.model is read" || bad "PF_MODEL_ID '$PF_MODEL_ID'"
    platform_finish openai /dev/null thr-missing selftest
    [ -z "$PF_MODEL_ID" ] && grep -q 'no codex rollout for thread thr-missing' "$TICK_LOG" \
      && ok "a missing rollout leaves model_id alone and says so in tick.log" || bad "missing rollout: '$PF_MODEL_ID'"
    platform_finish anthropic /dev/null sess-x selftest
    [ -z "$PF_MODEL_ID" ] && ok "a no-op on anthropic" || bad "anthropic set PF_MODEL_ID"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_pfout" | grep -v '^RESULT '
  printf '%s\n' "$_pfout" | grep -qx 'RESULT ok=3 bad=0' \
    && ok "platform_finish: all 3 assertions reach the gate" \
    || bad "platform_finish did not: $(printf '%s\n' "$_pfout" | tail -1)"

  echo "turn_is_over() — over a normalized OpenAI stream"
  "$PYTHON" -u "$BIN_DIR/platforms/openai_stream.py" --model gpt-5.6-sol --permission read-only --cwd /tmp \
    < "$BASE_DIR/test/fixtures/codex/02-tool-use.jsonl" > "$tmp/oa.ndjson" 2>/dev/null
  turn_is_over "$tmp/oa.ndjson"; want "a finished Codex turn is over" 0 $?
  grep -v turn.completed "$BASE_DIR/test/fixtures/codex/02-tool-use.jsonl" \
    | "$PYTHON" -u "$BIN_DIR/platforms/openai_stream.py" --model gpt-5.6-sol --permission read-only --cwd /tmp > "$tmp/ob.ndjson" 2>/dev/null
  turn_is_over "$tmp/ob.ndjson"; want "a Codex turn cut before its end is not" 1 $?
  [ "$(session_from_stream "$tmp/oa.ndjson")" = "01a071d5-47b0-7343-bcbd-216945ef7927" ] \
    && ok "session_from_stream reads the thread id off the first line" || bad "session $(session_from_stream "$tmp/oa.ndjson")"

  echo "configuration — platform is a field, and model, effort and permission_mode are validated on it"
  mkdir -p "$tmp/cfg/config" "$tmp/cfg/data"
  printf '{"projects":[{"name":"oa","cwd":"/tmp","platform":"openai"}]}\n' > "$tmp/cfg/config/projects.json"
  "$JQ" -n '{resolved:{}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-a", display_name:"A", description:"", visibility:"list", priority:6, efforts:["low","high","ultra"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-b", display_name:"B", description:"", visibility:"list", priority:7, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""}]},
    opencode:{at:1, source:"fixture", version:"1.18.30", models:[
      {id:"opencode/big-pickle", provider:"opencode", name:"Big Pickle", cost:{input:0,output:0,cache_read:0,cache_write:0}, priced:false, context:200000, output_limit:32000, variants:[], tools:true, reasoning:true, status:"active"},
      {id:"pdm_ai/glm-5.3-flash", provider:"pdm_ai", name:"glm-5.3-flash", cost:{input:0.033011,output:0.139816,cache_read:0,cache_write:0}, priced:true, context:197144, output_limit:65000, variants:["max","high","non-think"], tools:true, reasoning:true, status:"active"},
      {id:"pdm_ai/vision", provider:"pdm_ai", name:"vision", cost:{input:0,output:0,cache_read:0,cache_write:0}, priced:false, context:262000, output_limit:65000, variants:[], tools:false, reasoning:false, status:"active"}]}}' \
    > "$tmp/cfg/config/models.json"
  printf '{"jobs":[{"id":"cj","enabled":false,"cwd":"/tmp","prompt":"p","model":"opus","effort":"max","permission_mode":"dontAsk"}]}\n' \
    > "$tmp/cfg/config/jobs.json"
  "$JQ" -n '{platforms:{anthropic:{enabled:true,bin:"",models:["opus"]},
                        openai:{enabled:true,bin:"",models:["gpt-a","gpt-b"]},
                        opencode:{enabled:false,bin:"",models:[]}}}' > "$tmp/cfg/config/platforms.json"
  cfg_al()  { AGENTLOOP_CONFIG="$tmp/cfg/config" AGENTLOOP_DATA="$tmp/cfg/data" AGENTLOOP_CODEX_BIN=/nonexistent \
              AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode" "$BIN_DIR/agentloop" "$@"; }
  cfg_job() { "$JQ" -r --arg id "$1" ".jobs[] | select(.id==\$id) | $2" "$tmp/cfg/config/jobs.json"; }
  printf 'gemini' | cfg_al set-field cj platform >/dev/null 2>&1; want "an unknown platform is refused" 1 $?
  out="$(printf 'openai' | cfg_al set-field cj platform 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cfg_job cj .platform)" = "openai" ] && ok "platform openai is written" || bad "platform openai: rc=$rc $out"
  [ "$(cfg_job cj .model)" = "gpt-a" ] && ok "a model the new platform does not know is rewritten to its default" || bad "model $(cfg_job cj .model)"
  [ "$(cfg_job cj '.effort // "cleared"')" = "cleared" ] && ok "an effort that model does not offer is cleared" || bad "effort $(cfg_job cj .effort)"
  [ "$(cfg_job cj .permission_mode)" = "workspace-write" ] && ok "a permission mode of the other platform is rewritten to the default" || bad "permission $(cfg_job cj .permission_mode)"
  case "$out" in *"rewritten to gpt-a"*"cleared"*"rewritten to workspace-write"*) ok "and each rewrite is printed" ;; *) bad "rewrites not printed: $out" ;; esac
  out="$(printf 'gpt-zzz' | cfg_al set-field cj model 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"unknown OpenAI model"*"gpt-a gpt-b"*"resolve-models openai"*) ok "a slug outside the catalog is refused, naming the catalog and the refresh command" ;;
      *) bad "refusal text: $out" ;;
    esac
  else
    bad "a slug outside the catalog was accepted"
  fi
  printf 'gpt-b' | cfg_al set-field cj model >/dev/null 2>&1; want "a catalog slug is accepted" 0 $?
  printf 'ultra' | cfg_al set-field cj effort >/dev/null 2>&1; want "ultra is refused where the model lacks it" 1 $?
  printf 'high'  | cfg_al set-field cj effort >/dev/null 2>&1; want "high is accepted" 0 $?
  printf 'dontAsk' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "an anthropic mode is refused on openai" 1 $?
  printf 'full-access' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "full-access is accepted" 0 $?
  out="$(printf 'anthropic' | cfg_al set-field cj platform 2>&1)"
  # The round trip a real job took: anthropic (bypassPermissions) -> openai
  # (full-access) -> anthropic. It has to come back able to use a tool. It came
  # back on dontAsk instead, and the next run of that job died `tools_denied`
  # after burning a session on it.
  [ "$(cfg_job cj .model)" = "opus" ] && [ "$(cfg_job cj .permission_mode)" = "bypassPermissions" ] && [ "$(cfg_job cj .effort)" = "high" ] \
    && ok "back to anthropic: the rewrite lands on a mode that can work headless, a valid effort kept" || bad "back to anthropic: $(cfg_job cj '{model,effort,permission_mode}')"
  printf '' | cfg_al set-field cj platform >/dev/null 2>&1
  [ "$(cfg_job cj '.platform // "absent"')" = "absent" ] && ok "an empty platform clears the field (the job inherits)" || bad "platform not cleared"
  # create: the defaults follow the platform the job will run on
  printf '{"id":"oj","platform":"openai","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job oj .platform)" = "openai" ] && [ "$(cfg_job oj .model)" = "gpt-a" ] && [ "$(cfg_job oj .permission_mode)" = "workspace-write" ] \
    && ok "create with platform openai defaults to its model and permission" || bad "create openai: $(cfg_job oj '{platform,model,permission_mode}')"
  printf '{"id":"aj","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job aj '.platform // "absent"')" = "absent" ] && [ "$(cfg_job aj .model)" = "opus" ] && [ "$(cfg_job aj .permission_mode)" = "bypassPermissions" ] \
    && ok "create without a platform is anthropic, and writes no platform key" || bad "create default: $(cfg_job aj '{platform,model,permission_mode}')"
  printf '{"id":"pj","project":"oa","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job pj '.platform // "absent"')" = "absent" ] && [ "$(cfg_job pj .model)" = "gpt-a" ] && [ "$(cfg_job pj .permission_mode)" = "workspace-write" ] \
    && ok "create under an openai project inherits the platform and takes its defaults" || bad "create under project: $(cfg_job pj '{platform,model,permission_mode}')"
  printf '{"id":"xj","platform":"openai","model":"opus","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a model the platform does not know" 1 $?
  printf '{"id":"ej","platform":"openai","effort":"max","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses an effort the model does not offer" 1 $?
  # the operator's own choice, on top of the CLI's (cj is back on anthropic
  # after the round trip above: put it on openai first, or the CLI's own
  # "not an openai model" refusal fires before Settings gets a say)
  printf 'openai' | cfg_al set-field cj platform >/dev/null 2>&1
  printf '["gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  out="$(printf 'gpt-a' | cfg_al set-field cj model 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"model 'gpt-a' is not enabled in Settings — openai enables: gpt-b"*) ok "set-field model refuses a catalog slug switched off in Settings, naming what is on" ;; *) bad "refusal: $out" ;; esac
  [ "$rc" -eq 0 ] && bad "a switched-off model was accepted"
  printf '["gpt-a","gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  "$JQ" '.platforms.openai.enabled = false' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  out="$(printf 'openai' | cfg_al set-field cj platform 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"openai is not enabled in Settings — enable it there, or: agentloop platform enable openai"*) ok "set-field platform refuses a platform disabled in Settings" ;; *) bad "refusal: $out" ;; esac
  printf 'opencode' | cfg_al set-field cj platform >/dev/null 2>&1; want "set-field platform refuses a platform not enabled in Settings" 1 $?
  printf '{"id":"dj","platform":"openai","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a disabled platform" 1 $?
  "$JQ" '.platforms.openai.enabled = true' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  printf '{"id":"dj","platform":"openai","model":"gpt-b","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create accepts an enabled model on an enabled platform" 0 $?
  printf '["gpt-a"]' | cfg_al platform set-models openai >/dev/null 2>&1
  printf '{"id":"ej2","platform":"openai","model":"gpt-b","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a model switched off in Settings" 1 $?
  printf '["gpt-a","gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  # The launch-time twin of the create-time gate above: with nothing enabled
  # for openai, `dj` (model gpt-b, still on openai from the round trip above)
  # is skipped naming Settings as the cause. cfg_al's AGENTLOOP_CODEX_BIN
  # points nowhere, so a gate that failed to fire here would fall through to
  # the CLI readiness check instead and log "not ready" -- proving this gate
  # runs before that one, not just that SOME refusal happened.
  printf '[]' | cfg_al platform set-models openai >/dev/null 2>&1
  : > "$tmp/cfg/data/tick.log"
  cfg_al run dj >/dev/null 2>&1
  grep -q "dj: no model is enabled for openai in Settings, skipped" "$tmp/cfg/data/tick.log" \
    && ok "run: no model enabled on openai is skipped naming Settings, not codex readiness" \
    || bad "tick.log: $(cat "$tmp/cfg/data/tick.log" 2>/dev/null)"
  printf '["gpt-a","gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  printf '{"name":"np","platform":"openai","security":{"enabled":true,"model":"gpt-zzz"}}' | cfg_al project-set >/dev/null 2>&1; want "project-set refuses a security model that is not enabled" 1 $?
  printf '{"name":"np","platform":"openai","security":{"enabled":true,"platform":"anthropic","model":"opus"}}' | cfg_al project-set >/dev/null 2>&1; want "project-set accepts an enabled security model on the block's own platform" 0 $?
  "$JQ" '.platforms.anthropic.models = []' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  printf '{"name":"np2","platform":"anthropic"}' | cfg_al project-set >/dev/null 2>&1; want "project-set refuses a platform that is enabled but has no model switched on" 1 $?
  # The inherit case of set-field platform: cj (openai, gpt-a, no project)
  # would inherit anthropic, which has nothing switched on right now -- the
  # rewrite has no default to land on, so it is refused before anything is
  # written, never a job whose model is the empty string.
  out="$(printf '' | cfg_al set-field cj platform 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"no model is enabled for anthropic in Settings — switch one on there first"*)
        [ "$(cfg_job cj .platform)" = "openai" ] && [ "$(cfg_job cj .model)" = "gpt-a" ] \
          && ok "set-field platform '' refuses to inherit a platform with no model on, and writes nothing" \
          || bad "refused, but the job was touched: $(cfg_job cj '{platform,model}')" ;;
      *) bad "inherit refusal text: $out" ;;
    esac
  else
    bad "inheriting a platform with no model on was accepted: $(cfg_job cj '{platform,model}')"
  fi
  "$JQ" '.platforms.anthropic.models = ["opus"]' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  [ "$( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model openai )" = "gpt-a" ] \
    && ok "platform_default_model is the first model switched on" || bad "default: $( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model openai )"
  [ -z "$( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model opencode )" ] && ok "and nothing for a platform with none" || bad "opencode default not empty"

  # project-set is the only door a project's platform is written through;
  # refuse an unknown one there, before any write -- the alternative
  # (accepting it and relying on every reader to normalise afterwards) is
  # exactly what let a job get emptied below.
  before_px="$(cat "$tmp/cfg/config/projects.json")"
  out="$(printf '{"name":"px","cwd":"/tmp","platform":"gemini"}' | cfg_al project-set 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && [ "$(cat "$tmp/cfg/config/projects.json")" = "$before_px" ] \
    && ok "project-set refuses an unknown platform, and writes nothing" \
    || bad "project-set gemini: rc=$rc out=$out"

  # opencode is still disabled in this fixture's platforms.json at this point
  # (turned on below, for the "configuration -- opencode" cases) -- project-set
  # is the only door a project's platform is set through, so it has to gate
  # opencode's usability exactly like it gates openai's.
  out="$(printf '{"name":"pj-oc-off","cwd":"/tmp","platform":"opencode"}' | cfg_al project-set 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"is not enabled in Settings"*) ok "project-set refuses platform opencode while it is disabled in Settings" ;; *) bad "refusal text: $out" ;; esac
  [ "$rc" -eq 0 ] && bad "project-set accepted platform opencode while disabled in Settings"

  # A project this corrupt can now only exist by a hand-edit (project-set
  # itself refuses it, just above) -- standing in for a projects.json older
  # than that guard, or edited by hand. A job that inherits from it must not
  # be emptied, and creating one under it must not be refused either: both
  # run on anthropic, same as a job with no project at all.
  "$JQ" '.projects += [{"name":"corrupt","cwd":"/tmp","platform":"gemini"}]' \
      "$tmp/cfg/config/projects.json" > "$tmp/cfg/config/projects.json.next" \
    && mv "$tmp/cfg/config/projects.json.next" "$tmp/cfg/config/projects.json"
  printf '{"id":"cej","project":"corrupt","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job cej '.platform // "absent"')" = "absent" ] && [ "$(cfg_job cej .model)" = "opus" ] && [ "$(cfg_job cej .permission_mode)" = "bypassPermissions" ] \
    && ok "create under a project with an unknown platform treats it as anthropic, not a refusal" \
    || bad "create under corrupt project: $(cfg_job cej '{platform,model,permission_mode}')"
  "$JQ" '.jobs += [{"id":"gj","enabled":false,"cwd":"/tmp","project":"corrupt","prompt":"p","model":"gpt-b","permission_mode":"full-access"}]' \
      "$tmp/cfg/config/jobs.json" > "$tmp/cfg/config/jobs.json.next" \
    && mv "$tmp/cfg/config/jobs.json.next" "$tmp/cfg/config/jobs.json"
  out="$(printf '' | cfg_al set-field gj platform 2>&1)"
  [ "$(cfg_job gj .model)" = "opus" ] && [ "$(cfg_job gj .permission_mode)" = "bypassPermissions" ] \
    && ok "clearing a job's platform under that same corrupt project rewrites to anthropic, not empty" \
    || bad "gj after clearing platform: $(cfg_job gj '{model,permission_mode}')"
  case "$out" in *anthropic*) ok "and the rewrites name anthropic, not the unknown platform" ;; *) bad "rewrites: $out" ;; esac

  # The registry-against-jq invariant: every platform PLATFORMS actually runs
  # has to be known to PLATFORMS_JQ too, with its own model -- this is how the
  # job counter miscredited an opencode job to anthropic/opus in an earlier
  # delivery (known() had no opencode branch, so it fell through to the
  # anthropic default). The loop walks $PLATFORMS itself, not a literal list,
  # so a FOURTH platform with no branch in the jq fails HERE, by name.
  echo "PLATFORMS_JQ — every platform the registry runs is known to the jq, with its own model"
  local _pj _pjm
  for _pj in $PLATFORMS; do
    case "$_pj" in anthropic) _pjm="claude-opus-5" ;; openai) _pjm="gpt-a" ;; opencode) _pjm="pdm_ai/glm-5.3-flash" ;; *) _pjm="" ;; esac
    [ "$( JOBS_FILE="$tmp/cfg/config/jobs.json"; PROJECTS_FILE="$tmp/cfg/config/projects.json"; MODELS_FILE="$tmp/cfg/config/models.json"
          platforms_jq opus gpt-a pdm_ai/glm-5.3-flash '($p | known), (valid($p; $m) | tostring), effective($p; $m)' -r --arg p "$_pj" --arg m "$_pjm" | tr '\n' '|' )" = "$_pj|true|$_pjm|" ] \
      && ok "$_pj: known keeps it, valid accepts its model, effective keeps its model" \
      || bad "$_pj through PLATFORMS_JQ: $( JOBS_FILE="$tmp/cfg/config/jobs.json"; PROJECTS_FILE="$tmp/cfg/config/projects.json"; MODELS_FILE="$tmp/cfg/config/models.json"; platforms_jq opus gpt-a pdm_ai/glm-5.3-flash '($p | known), (valid($p; $m) | tostring), effective($p; $m)' -r --arg p "$_pj" --arg m "$_pjm" | tr '\n' '|' )"
  done

  echo "configuration — opencode is a value of platform, validated like the other two"
  # Switched on here, for these cases only -- the existing "refuses a platform
  # not enabled in Settings" case above ran against opencode disabled (the
  # fixture's base state) and must keep failing for that reason, so the base
  # fixture is left untouched; opencode is turned on right before its own cases.
  "$JQ" '.platforms.opencode = {enabled:true, bin:"", models:["pdm_ai/glm-5.3-flash","opencode/big-pickle"]}' \
      "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  printf 'opencode' | cfg_al set-field cj platform >/dev/null 2>&1; want "set-field platform opencode is accepted when Settings switched it on" 0 $?
  [ "$(cfg_job cj '.platform, .model, .permission_mode' | tr '\n' '|')" = "opencode|pdm_ai/glm-5.3-flash|full-access|" ] \
    && ok "and the model and the mode were rewritten to the platform's defaults (the first enabled model, full-access)" || bad "after the move: $(cfg_job cj '{platform,model,effort,permission_mode}')"
  printf 'opencode/big-pickle' | cfg_al set-field cj model >/dev/null 2>&1; want "set-field model takes an enabled catalog id" 0 $?
  # Captured first, never piped straight into grep -q: under `set -uo
  # pipefail` (top of file) a pipeline's status is its last NONZERO exit, so
  # `cfg_al | grep -q ...` reads as failure on cfg_al's die exit(1) even when
  # grep matches (its own 0 does not win).
  out="$(printf 'opencode/nope' | cfg_al set-field cj model 2>&1)"
  printf '%s' "$out" | grep -q "unknown OpenCode model 'opencode/nope' — the catalog lists: opencode/big-pickle pdm_ai/glm-5.3-flash pdm_ai/vision" \
    && ok "an id outside the catalog is refused, naming the catalog" || bad "no catalog refusal: $out"
  printf 'high' | cfg_al set-field cj effort >/dev/null 2>&1; want "an effort a model without variants does not offer is refused" 1 $?
  out="$(printf 'high' | cfg_al set-field cj effort 2>&1)"
  printf '%s' "$out" | grep -qF "this model offers no effort levels (leave it empty)" \
    && ok "and says the model offers no effort levels at all, not an empty list with nothing in it" || bad "no-effort refusal: $out"
  printf 'pdm_ai/glm-5.3-flash' | cfg_al set-field cj model >/dev/null 2>&1
  printf 'high' | cfg_al set-field cj effort >/dev/null 2>&1; want "and accepted on a model that lists it" 0 $?
  printf 'read-only' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "read-only is an opencode mode" 0 $?
  printf 'workspace-write' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "workspace-write is not" 1 $?
  printf 'anthropic' | cfg_al set-field cj platform >/dev/null 2>&1
  [ "$(cfg_job cj .permission_mode)" = "bypassPermissions" ] && ok "moving back rewrites read-only to the anthropic default" || bad "mode after the move back: $(cfg_job cj .permission_mode)"
  printf '{"id":"oc-new","platform":"opencode","prompt":"x","interval_seconds":60}' | cfg_al create >/dev/null 2>&1; want "create with platform opencode" 0 $?
  [ "$(cfg_job oc-new '.model, .permission_mode' | tr '\n' '|')" = "pdm_ai/glm-5.3-flash|full-access|" ] \
    && ok "a created opencode job takes the platform's defaults" || bad "created: $(cfg_job oc-new '{model,permission_mode}')"
  # project-set is the door cmd_set_field and cmd_create above do not open --
  # a project's OWN platform, and its security block's, on opencode now that
  # Settings has it usable.
  out="$(printf '{"name":"pj-oc","cwd":"/tmp","platform":"opencode"}' | cfg_al project-set 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$("$JQ" -r --arg n "pj-oc" '.projects[] | select(.name==$n) | .platform' "$tmp/cfg/config/projects.json")" = "opencode" ] \
    && ok "project-set accepts platform opencode on a project once Settings has it usable" \
    || bad "project-set pj-oc: rc=$rc out=$out"
  out="$(printf '{"name":"pj-oc2","cwd":"/tmp","security":{"enabled":true,"platform":"opencode","model":"pdm_ai/glm-5.3-flash"}}' | cfg_al project-set 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "project-set accepts platform opencode on a security block, with an enabled catalog model" \
    || bad "project-set pj-oc2: rc=$rc out=$out"

  echo "upgrade path — a platforms.json without the opencode key, the file every install has today"
  mkdir -p "$tmp/up/config" "$tmp/up/data"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":false,"bin":"","models":[]}}}\n' > "$tmp/up/config/platforms.json"
  up_al() { AGENTLOOP_CONFIG="$tmp/up/config" AGENTLOOP_DATA="$tmp/up/data" AGENTLOOP_OPENCODE_BIN="$BASE_DIR/test/fake-opencode" \
            AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" "$BIN_DIR/agentloop" "$@"; }
  ( PLATFORMS_FILE="$tmp/up/config/platforms.json"; platforms_valid ); want "the two-key file is still a valid platforms file" 0 $?
  ( PLATFORMS_FILE="$tmp/up/config/platforms.json"; platform_enabled opencode ); want "opencode reads as DISABLED, not as an error and not as enabled by default" 1 $?
  ( PLATFORMS_FILE="$tmp/up/config/platforms.json"; platform_enabled anthropic ); want "and anthropic keeps its state" 0 $?
  [ "$(up_al platforms | "$JQ" -r '.opencode.supported, .opencode.enabled, .opencode.usable' | tr '\n' '|')" = "true|false|false|" ] \
    && ok "platforms lists the card from the registry, disabled, with no key in the file" || bad "platforms over the two-key file: $(up_al platforms | "$JQ" -c .opencode)"
  up_al platform enable opencode >/dev/null 2>&1; want "platform enable opencode writes the key that was not there (the stand-in is ready)" 0 $?
  "$JQ" -e '.platforms.opencode.enabled == true and .platforms.opencode.models == [] and .platforms.anthropic.enabled == true' "$tmp/up/config/platforms.json" >/dev/null 2>&1 \
    && ok "the file now carries the key, enabled, and the other two are untouched" || bad "after enable: $(cat "$tmp/up/config/platforms.json")"
  # set-models validates against platform_catalog_ids, which resolves nothing
  # by itself -- the fresh config has no models.json yet, so the catalog is
  # empty until a real resolve runs, same as a fresh install's first refresh.
  up_al resolve-models opencode >/dev/null 2>&1
  printf '["opencode/big-pickle"]' | up_al platform set-models opencode >/dev/null 2>&1; want "set-models writes into the new key" 0 $?
  [ "$("$JQ" -r '.platforms.opencode.models[0]' "$tmp/up/config/platforms.json")" = "opencode/big-pickle" ] && ok "and the model is on the list" || bad "models: $("$JQ" -c .platforms.opencode "$tmp/up/config/platforms.json")"

  echo "security_prompt() — the platform decides how the skill is named and how subagents are forbidden"
  local _pa _po _pc
  _pa="$(security_prompt P R B quick 7 'x/**' anthropic)"
  _po="$(security_prompt P R B quick 7 'x/**' openai)"
  _pc="$(security_prompt P R B quick 7 'x/**' opencode)"
  [ "$(security_prompt P R B quick 7 'x/**')" = "$_pa" ] \
    && ok "security_prompt: no platform argument reads as anthropic" || bad "the six-argument call differs from anthropic"
  printf '%s\n' "$_pa" | grep -qF 'Invoke the `security-analysis` skill' \
    && ok "security_prompt anthropic: invokes the skill by name" || bad "anthropic head: $(printf '%s\n' "$_pa" | head -1)"
  printf '%s\n' "$_pa" | grep -qF 'You HAVE subagents in this run' \
    && printf '%s\n' "$_pa" | grep -qF 'Use subagents for nothing else' \
    && ok "security_prompt anthropic: says subagents exist, and for what alone" \
    || bad "anthropic prompt lacks the verification paragraph"
  printf '%s\n' "$_po" | grep -qF "Read \`$SKILLS_DIR/security-analysis/SKILL.md\`" \
    && ok "security_prompt openai: names the skill file by path, not by discovery" || bad "openai head: $(printf '%s\n' "$_po" | head -1)"
  printf '%s\n' "$_po" | grep -qF 'ALREADY RAN for this analysis' \
    && ok "security_prompt openai: says the deterministic phase already ran, engine-side" || bad "openai head: $(printf '%s\n' "$_po" | head -1)"
  printf '%s\n' "$_po" | grep -qF 'YOUR FIRST COMMAND' \
    && bad "openai prompt still asks the agent to run prepare" || ok "security_prompt openai: never asks the agent to run prepare"
  printf '%s\n' "$_po" | grep -qF 'Do not spawn subagents' \
    && ok "security_prompt openai: forbids subagents in words (nothing closes them by flag)" || bad "openai prompt lacks the ban"
  printf '%s\n' "$_po" | grep -q 'Agent. tool' \
    && bad "openai prompt still speaks of the Agent tool" || ok "security_prompt openai: never speaks of the Agent tool"
  printf '%s\n' "$_pa" | grep -qF 'security prepare --analysis 7' && printf '%s\n' "$_pa" | grep -qF 'YOUR FIRST COMMAND' \
    && ok "security_prompt anthropic: prepare is still the agent's first command, with the analysis id filled in" || bad "the anthropic prompt lost its prepare line"
  printf '%s\n' "$_pa" | grep -qF 'verify-queue' \
    && printf '%s\n' "$_pa" | grep -qF 'The close counts' \
    && ok "security_prompt anthropic: names the verification phase and that it is counted" \
    || bad "the anthropic prompt does not describe the verification phase"
  printf '%s\n' "$_po" | grep -qF 'Do not spawn subagents' \
    && printf '%s\n' "$_pc" | grep -qF 'there are no subagents' \
    && ok "security_prompt openai/opencode: subagents stay forbidden where verification cannot run" \
    || bad "a platform without verification lost its ban"
  printf '%s\n' "$_pa" | grep -qF "$SKILLS_DIR/security-analysis/references/" \
    && printf '%s\n' "$_po" | grep -qF "$SKILLS_DIR/security-analysis/references/" \
    && printf '%s\n' "$_pc" | grep -qF "$SKILLS_DIR/security-analysis/references/" \
    && ok "security_prompt: every platform is told where the hunting guides are" \
    || bad "security_prompt: a platform's prompt does not name references/"
  printf '%s\n' "$_pc" | grep -qF 'Invoke the `security-analysis` skill' \
    && ok "security_prompt opencode: invokes the skill by name" || bad "opencode head: $(printf '%s\n' "$_pc" | head -1)"
  printf '%s\n' "$_pc" | grep -qF "is \`$SKILLS_DIR/security-analysis/SKILL.md\`" \
    && ok "security_prompt opencode: and by path too, for a machine where the link is missing" || bad "opencode lacks the skill by path: $(printf '%s\n' "$_pc" | sed -n '5,6p')"
  printf '%s\n' "$_pc" | grep -qF 'ALREADY RAN for this analysis' \
    && ok "security_prompt opencode: says the deterministic phase already ran, engine-side" || bad "opencode head: $(printf '%s\n' "$_pc" | head -1)"
  printf '%s\n' "$_pc" | grep -qF 'YOUR FIRST COMMAND' \
    && bad "opencode prompt still asks the agent to run prepare" || ok "security_prompt opencode: never asks the agent to run prepare"
  printf '%s\n' "$_pc" | grep -qF 'The `task` tool is closed for this run' \
    && ok "security_prompt opencode: the task tool is closed for this run, by rule" || bad "opencode prompt lacks the by-rule paragraph"
  printf '%s\n' "$_pc" | grep -qF 'Do not spawn subagents' \
    && bad "the Codex-only wording leaked into the opencode prompt" || ok "security_prompt opencode: never says the Codex-only 'do not spawn subagents'"
  printf '%s\n' "$_pc" | grep -q 'Agent. tool' \
    && bad "opencode prompt still speaks of the Agent tool" || ok "security_prompt opencode: never speaks of the Agent tool"

  echo "security_derived_jobs() — the block's platform, with the same fallback-and-warn as its permission mode"
  mkdir -p "$tmp/dplat/data"
  cat > "$tmp/dplat/projects.json" <<'JSON'
{"projects":[
 {"name":"Oa","cwd":"/tmp/oa","security":{"enabled":true,"platform":"openai","model":"gpt-zzz","effort":"max","permission_mode":"dontAsk"}},
 {"name":"Ob","cwd":"/tmp/ob","platform":"openai","security":{"enabled":true,"model":"gpt-b","effort":"high"}},
 {"name":"Oc","cwd":"/tmp/oc","security":{"enabled":true,"platform":"martian"}},
 {"name":"Oe","cwd":"/tmp/oe","security":{"enabled":true,"model":"claude-sonnet-5"}},
 {"name":"Of","cwd":"/tmp/of","security":{"enabled":true,"platform":"opencode","model":"pdm_ai/glm-5.3-flash","effort":"high"}},
 {"name":"Og","cwd":"/tmp/og","security":{"enabled":true,"platform":"opencode","model":"pdm_ai/vision"}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/dplat/jobs.json"
  # pdm_ai/vision has to be ENABLED too, not just a valid catalog id: Og's
  # point is the tools fallback, which only runs once the model has already
  # cleared the catalog-validity and enabled-in-Settings gates above it --
  # an enabled-but-toolless model is the only way to reach it, rather than
  # tripping the "not enabled in Settings" gate first with different wording.
  "$JQ" -n '{platforms:{anthropic:{enabled:true,bin:"",models:["opus"]},
                        openai:{enabled:true,bin:"",models:["gpt-a","gpt-b"]},
                        opencode:{enabled:true,bin:"",models:["pdm_ai/glm-5.3-flash","opencode/big-pickle","pdm_ai/vision"]}}}' > "$tmp/dplat/platforms.json"
  dplat() { ( JOBS_FILE="$tmp/dplat/jobs.json"; PROJECTS_FILE="$tmp/dplat/projects.json"; DATA_DIR="$tmp/dplat/data"
              PLATFORMS_FILE="$tmp/dplat/platforms.json"
              MODELS_FILE="$tmp/cfg/config/models.json"; job_get "$1" "$2" '' ); }
  [ "$(dplat security-oa .platform)" = "openai" ] && ok "security.platform reaches the derived job" || bad "platform $(dplat security-oa .platform)"
  [ "$(dplat security-oa .model)" = "gpt-a" ] && ok "a model the platform does not know falls back to its default" || bad "model $(dplat security-oa .model)"
  [ "$(dplat security-oa '.effort // "cleared"')" = "cleared" ] && ok "an effort the default model lacks is cleared" || bad "effort $(dplat security-oa .effort)"
  [ "$(dplat security-oa .permission_mode)" = "full-access" ] && ok "an anthropic mode on openai falls back to full-access" || bad "permission $(dplat security-oa .permission_mode)"
  [ "$(dplat security-ob .platform)" = "openai" ] && [ "$(dplat security-ob .model)" = "gpt-b" ] && [ "$(dplat security-ob .effort)" = "high" ] && [ "$(dplat security-ob .permission_mode)" = "full-access" ] \
    && ok "the project's platform is inherited by the block, and valid values are kept" || bad "Ob: $(dplat security-ob '{platform,model,effort,permission_mode}')"
  [ "$(dplat security-oc .platform)" = "anthropic" ] && [ "$(dplat security-oc .model)" = "opus" ] && [ "$(dplat security-oc .permission_mode)" = "bypassPermissions" ] \
    && ok "an unknown platform in the block falls back to anthropic and its defaults" || bad "Oc: $(dplat security-oc '{platform,model,permission_mode}')"
  dplat security-oa .prompt | grep -qF 'security-analysis/SKILL.md' \
    && ok "the derived job on openai carries the by-path prompt" || bad "Oa prompt head: $(dplat security-oa .prompt | head -1)"
  dplat security-ob .prompt | grep -qF 'Do not spawn subagents' \
    && ok "the derived job on an openai PROJECT carries the subagent ban" || bad "Ob prompt lacks the ban"
  dplat security-oc .prompt | grep -qF 'Invoke the `security-analysis` skill' \
    && ok "the derived job that fell back to anthropic carries the by-name prompt" || bad "Oc prompt head: $(dplat security-oc .prompt | head -1)"
  [ "$(dplat security-oe .model)" = "opus" ] && ok "a model switched off in Settings falls back to the first one switched on" || bad "Oe model $(dplat security-oe .model)"
  grep -q "not enabled in Settings ('claude-sonnet-5' on anthropic) -- using opus" "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null \
    && ok "and the derivation warning says so" || bad "no warning for Oe: $(cat "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null)"
  dplat security-of .prompt | grep -qF 'The `task` tool is closed for this run' \
    && ok "the derived job on opencode carries the by-rule paragraph" || bad "Of prompt lacks the task paragraph"
  [ "$(dplat security-of .platform)" = "opencode" ] && [ "$(dplat security-of .model)" = "pdm_ai/glm-5.3-flash" ] && [ "$(dplat security-of .effort)" = "high" ] \
    && [ "$(dplat security-of .permission_mode)" = "full-access" ] && [ -z "$(dplat security-of .disallowed_tools)" ] \
    && ok "an opencode block: platform, model, a variant the model lists, full-access, and no tool closed" || bad "Of: $(dplat security-of '{platform,model,effort,permission_mode,disallowed_tools}')"
  [ "$(dplat security-og .model)" = "pdm_ai/glm-5.3-flash" ] \
    && ok "a model that makes no tool calls falls back to the first enabled model that does" || bad "Og model $(dplat security-og .model)"
  grep -q "names a model that makes no tool calls ('pdm_ai/vision') -- an analysis needs tools; using pdm_ai/glm-5.3-flash" "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null \
    && ok "and the derivation warning says why" || bad "no tools warning: $(cat "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null | tail -2)"
  # The fallback used to pipe platform_models_enabled straight into a `while`
  # whose own stdout fed `head -1`: `head` closes its end after one line, and
  # if the loop found a SECOND tools-capable model before the shell noticed,
  # that printf hit a closed pipe and bash logged "write error: Broken pipe"
  # to stderr -- harmless (the right id still came out; $? was never read)
  # but noisy, ~24 lines of it in one CI run. Predates #77. Og is the one
  # fixture project whose model actually reaches this fallback, so a real
  # stderr capture of the same call the checks above already make is enough.
  dplat security-og .model >/dev/null 2>"$tmp/dplat/og-stderr.txt"
  grep -q "Broken pipe" "$tmp/dplat/og-stderr.txt" 2>/dev/null \
    && bad "the opencode tools fallback still closes its pipe early: $(cat "$tmp/dplat/og-stderr.txt")" \
    || ok "the opencode tools fallback prints no \"write error: Broken pipe\" while picking a model"

  # openai with no catalog resolved yet: platform_default_model answers
  # nothing for it, so the model must come out empty rather than some other
  # broken value, and the warning has to name the actual cause -- not the
  # generic "using " with nothing after it that a blind fallback prints.
  mkdir -p "$tmp/dnocat/data"
  cat > "$tmp/dnocat/projects.json" <<'JSON'
{"projects":[{"name":"Od","cwd":"/tmp/od","security":{"enabled":true,"platform":"openai"}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/dnocat/jobs.json"
  # openai switched on with no model: the derived model has to stay empty
  printf '{"platforms":{"openai":{"enabled":true,"bin":"","models":[]}}}\n' > "$tmp/dnocat/platforms.json"
  dnocat() { ( JOBS_FILE="$tmp/dnocat/jobs.json"; PROJECTS_FILE="$tmp/dnocat/projects.json"; DATA_DIR="$tmp/dnocat/data"
               PLATFORMS_FILE="$tmp/dnocat/platforms.json"
               MODELS_FILE="$tmp/dnocat/no-such-models.json"; job_get "$1" "$2" '' ); }
  [ -z "$(dnocat security-od .model)" ] \
    && ok "openai with no catalog resolved yet: the derived job's model is empty, not a broken slug" \
    || bad "model '$(dnocat security-od .model)'"
  warn="$(cat "$tmp/dnocat/data/security/derivation-warnings.txt" 2>/dev/null)"
  case "$warn" in
    *"no OpenAI catalog is resolved yet"*"resolve-models openai"*)
      ok "and the warning names the missing catalog and the refresh command" ;;
    *) bad "warning: $warn" ;;
  esac

  # A project with no model at all on anthropic -- sdefault comes out empty
  # here too, but there is no catalog to blame it on (only openai has one):
  # the warning must name anthropic and "no model is enabled", never send the
  # operator to refresh a catalog that was never the problem. A separate
  # scratch dir/fixture, like dnocat's own, so dplat and dnocat keep their
  # values.
  mkdir -p "$tmp/dnomodel/data"
  cat > "$tmp/dnomodel/projects.json" <<'JSON'
{"projects":[{"name":"Of","cwd":"/tmp/of","security":{"enabled":true}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/dnomodel/jobs.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[]}}}\n' > "$tmp/dnomodel/platforms.json"
  dnomodel() { ( JOBS_FILE="$tmp/dnomodel/jobs.json"; PROJECTS_FILE="$tmp/dnomodel/projects.json"; DATA_DIR="$tmp/dnomodel/data"
                 PLATFORMS_FILE="$tmp/dnomodel/platforms.json"
                 MODELS_FILE="$tmp/dnomodel/no-such-models.json"; job_get "$1" "$2" '' ); }
  [ -z "$(dnomodel security-of .model)" ] \
    && ok "anthropic with no model enabled: the derived job's model is empty too" \
    || bad "model '$(dnomodel security-of .model)'"
  warn="$(cat "$tmp/dnomodel/data/security/derivation-warnings.txt" 2>/dev/null)"
  case "$warn" in
    *"resolve-models"*) bad "warning sent anthropic to refresh an OpenAI catalog: $warn" ;;
    *"project 'Of' runs on anthropic but no model is enabled for it in Settings"*)
      ok "and the warning names anthropic and the real cause, not a catalog" ;;
    *) bad "warning: $warn" ;;
  esac

  echo "model_alias_baseline() — the init event is found even behind hook events"
  # The probe's first lines belong to whoever has hooks configured: a
  # SessionStart hook in ~/.claude/settings.json puts hook_started and
  # hook_response on the stream BEFORE init, the only event carrying .model.
  # Reading "the first line" therefore reported nothing the moment the
  # operator wired any hook, and every family quietly resolved to itself.
  # The stand-in replays a claude 2.1.258 capture, ids neutralised — the
  # committed sample is test/fixtures/stream-json-hooked-probe.ndjson.
  cat > "$tmp/hooked-claude" <<'EOF'
#!/bin/sh
printf '%s\n' \
  '{"type":"system","subtype":"hook_started","hook_id":"hook-0001","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"uuid-0001","session_id":"sess-hooked"}' \
  '{"type":"system","subtype":"hook_response","hook_id":"hook-0001","hook_name":"SessionStart:startup","hook_event":"SessionStart","output":"","stdout":"","stderr":"","exit_code":0,"outcome":"success","uuid":"uuid-0002","session_id":"sess-hooked"}' \
  '{"type":"system","subtype":"init","cwd":"/tmp/probe","session_id":"sess-hooked","tools":["Task","Bash"],"slash_commands":["compact"],"model":"claude-fable-5-1","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.258","uuid":"uuid-0003"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"session_id":"sess-hooked","uuid":"uuid-0004"}' \
  '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"sess-hooked","total_cost_usd":0,"result":"hi","uuid":"uuid-0005"}'
EOF
  chmod +x "$tmp/hooked-claude"
  got="$(CLAUDE_BIN="$tmp/hooked-claude"; model_alias_baseline fable)"
  [ "$got" = "claude-fable-5-1" ] && ok "hook events ahead of init do not blind the baseline" \
    || bad "a hooked stream read '$got', wanted claude-fable-5-1"
  cat > "$tmp/plain-claude" <<'EOF'
#!/bin/sh
printf '%s\n' \
  '{"type":"system","subtype":"init","cwd":"/tmp/probe","session_id":"sess-plain","tools":["Task","Bash"],"model":"claude-opus-4-8","permissionMode":"default"}' \
  '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"sess-plain","total_cost_usd":0,"result":"hi"}'
EOF
  chmod +x "$tmp/plain-claude"
  got="$(CLAUDE_BIN="$tmp/plain-claude"; model_alias_baseline opus)"
  [ "$got" = "claude-opus-4-8" ] && ok "a hookless stream still reads the same" \
    || bad "a plain stream read '$got', wanted claude-opus-4-8"
  got="$(CLAUDE_BIN="$tmp/no-such-claude"; model_alias_baseline opus)"
  [ -z "$got" ] && ok "a CLI that cannot run reports nothing, so resolve_family can give up" \
    || bad "a missing CLI invented '$got'"
  # The baseline and every probe run a real turn when the CLI has a session:
  # the init event comes first, but the "hi" is still answered. So the turn is
  # the smallest the CLI can make -- no tools, no MCP server, no skill and a
  # one-line system prompt. Measured on haiku: $0.0018, against $0.0226 for
  # the same turn with the operator's whole setup loaded.
  cat > "$tmp/argv-claude" <<'EOF'
#!/bin/sh
echo "--- call" >> "$ARGV_LOG"
for a in "$@"; do printf '[%s]\n' "$a"; done >> "$ARGV_LOG"
case " $* " in
  *" stream-json "*) printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5"}' '{"type":"result","is_error":false,"result":"hi"}' ;;
  *) printf '%s\n' '{"type":"result","is_error":false,"result":"ok"}' ;;
esac
EOF
  chmod +x "$tmp/argv-claude"; : > "$tmp/argv.log"
  ( CLAUDE_BIN="$tmp/argv-claude"; ARGV_LOG="$tmp/argv.log"; export ARGV_LOG
    model_alias_baseline opus >/dev/null; model_probe_ok claude-opus-6 ) >/dev/null 2>&1
  got="$(awk '/^--- call$/ {n++} $0 == "[]" && prev == "[--tools]" {t[n]++} $0 == "[--strict-mcp-config]" {m[n]++}
              $0 == "[--disable-slash-commands]" {s[n]++} $0 == "[--system-prompt]" {p[n]++} {prev = $0}
              END {for (i = 1; i <= n; i++) printf "%d%d%d%d ", t[i], m[i], s[i], p[i]}' "$tmp/argv.log")"
  [ "$got" = "1111 1111 " ] \
    && ok "the baseline and the probe run the smallest turn the CLI makes: no tools, no MCP, no skills, one-line system prompt" \
    || bad "the two calls carried [$got] of --tools \"\", --strict-mcp-config, --disable-slash-commands, --system-prompt (1111 each wanted)"

  echo "resolve_family() — the newest id the API serves this CLI, never one older than its alias"
  # Each scenario is one world for test/fake-claude's probe mode: what the
  # family alias points at in that CLI build, the ids the build recognises,
  # the ids the API serves it, and the ids the API serves only to a newer
  # build. Every probed id lands in $tmp/rf.log in order, so the order and
  # the stop are held too, not just the answer.
  rf() { # rf <family> <alias's id> <ids the CLI knows> <ids the API serves it> [ids gated to a newer CLI] -> the resolution
    : > "$tmp/rf.log"
    ( CLAUDE_BIN="$BASE_DIR/test/fake-claude"
      FAKE_ALIASES="$1=$2" FAKE_CLI_MODELS="$3" FAKE_API_MODELS="$4" FAKE_GATED_MODELS="${5:-}" FAKE_PROBE_LOG="$tmp/rf.log"
      export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS FAKE_GATED_MODELS FAKE_PROBE_LOG
      resolve_family "$1" )
  }
  # A release that skips minors (5 went straight to 5.5) and that the API
  # serves to this CLI build although the build does not know it yet -- the
  # case the resolver exists for. The probe used to ask for 3, 2 and 1 only,
  # and the stderr line the CLI writes for an id it does not recognise made
  # even a served one read as refused.
  got="$(rf opus claude-opus-5 "claude-opus-5 claude-opus-4-8" "claude-opus-5 claude-opus-5-5 claude-opus-4-8")"
  [ "$got" = "claude-opus-5-5" ] && ok "minors skipped on the way up: claude-opus-5 resolves to claude-opus-5-5" \
    || bad "claude-opus-5 with 5.5 served resolved to '$got', wanted claude-opus-5-5"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-opus-7 claude-opus-6 claude-opus-5-9 claude-opus-5-8 claude-opus-5-7 claude-opus-5-6 claude-opus-5-5 " ] \
    && ok "minors are probed highest first, and the first one served ends the search" \
    || bad "probes: $(tr '\n' ' ' < "$tmp/rf.log")"
  # 2026-09-22 as it really was: the API served claude-opus-5-5 only to CLI
  # 2.1.280 or newer, and answered 2.1.258's probe with a 400 naming that
  # version. A model the installed CLI cannot run is no answer -- a launch on
  # it fails the same way -- so the family stays on the alias until
  # `claude update`.
  got="$(rf opus claude-opus-5 "claude-opus-5 claude-opus-4-8" "claude-opus-5 claude-opus-4-8" "claude-opus-5-5")"
  [ "$got" = "claude-opus-5" ] && ok "a release gated to a newer CLI (the API's real 400) is never resolved to" \
    || bad "claude-opus-5 with 5.5 gated to a newer CLI resolved to '$got', wanted claude-opus-5"
  grep -qx 'claude-opus-5-5' "$tmp/rf.log" && ok "though it was asked for, and kept out as a release for a newer CLI" \
    || bad "claude-opus-5-5 was never probed: $(tr '\n' ' ' < "$tmp/rf.log")"
  # The alias already carries a minor (2.1.280: claude-opus-5-5). A lower
  # minor the API still serves must never win, so the probe starts above the
  # baseline's own minor and never even asks for it.
  got="$(rf opus claude-opus-5-5 "claude-opus-5 claude-opus-5-3 claude-opus-5-5" "claude-opus-5 claude-opus-5-3 claude-opus-5-5")"
  [ "$got" = "claude-opus-5-5" ] && ok "a baseline with a minor is never resolved below itself (5-3 served, 5-5 stays)" \
    || bad "claude-opus-5-5 resolved to '$got', wanted claude-opus-5-5"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-opus-7 claude-opus-6 claude-opus-5-9 claude-opus-5-8 claude-opus-5-7 claude-opus-5-6 " ] \
    && ok "and nothing at or below the baseline's minor is probed" || bad "probes: $(tr '\n' ' ' < "$tmp/rf.log")"
  # Today's haiku alias is a dated snapshot. The 8-digit date is not a minor:
  # the baseline is 4.5, so 4-9..4-6 are asked, claude-haiku-4-5 (served,
  # the same model) is not, and the answer stays the id the CLI named.
  local _h="claude-haiku-4-5-20251001 claude-haiku-4-5 claude-haiku-4 claude-haiku-3-5"
  got="$(rf haiku claude-haiku-4-5-20251001 "$_h" "$_h")"
  [ "$got" = "claude-haiku-4-5-20251001" ] && ok "a dated baseline (claude-haiku-4-5-20251001) comes back unchanged" \
    || bad "claude-haiku-4-5-20251001 resolved to '$got'"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-haiku-6 claude-haiku-5 claude-haiku-4-9 claude-haiku-4-8 claude-haiku-4-7 claude-haiku-4-6 " ] \
    && ok "and its date is not read as a minor: 4-9..4-6 are probed, nothing built from the date" \
    || bad "probes: $(tr '\n' ' ' < "$tmp/rf.log")"
  # A dated alias with no minor at all -- `opus` meant claude-opus-4-20250514
  # until claude-opus-4-1 shipped. That baseline is 4.0: read as minor
  # 20250514 it would have probed nothing, and 4.1 would never be found.
  got="$(rf opus claude-opus-4-20250514 "claude-opus-4-20250514" "claude-opus-4-20250514 claude-opus-4-1")"
  [ "$got" = "claude-opus-4-1" ] && ok "a dated baseline with no minor is 4.0: claude-opus-4-20250514 resolves to claude-opus-4-1" \
    || bad "claude-opus-4-20250514 with 4.1 served resolved to '$got', wanted claude-opus-4-1"
  # A CLI a whole major behind (2026-07-24: `opus` still meant
  # claude-opus-4-8). The bare major is found first, then its minors from the
  # top: the baseline's minor 8 belongs to the old major and caps nothing.
  got="$(rf opus claude-opus-4-8 "claude-opus-4-8" "claude-opus-4-8 claude-opus-5 claude-opus-5-5")"
  [ "$got" = "claude-opus-5-5" ] && ok "a new major and its minor are found in one pass (4-8 -> 5-5)" \
    || bad "claude-opus-4-8 with 5 and 5.5 served resolved to '$got', wanted claude-opus-5-5"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-opus-6 claude-opus-5 claude-opus-5-9 claude-opus-5-8 claude-opus-5-7 claude-opus-5-6 claude-opus-5-5 " ] \
    && ok "and the new major's minors are probed from the top" || bad "probes: $(tr '\n' ' ' < "$tmp/rf.log")"
  # What the search leaves for whoever records it, besides the id: RF_ID,
  # the newest release the API keeps for a newer CLI (RF_NEWER, RF_NEEDS,
  # RF_INSTALLED) and, when a probe had no verdict, which one and why
  # (RF_PROBE, RF_FAILED, exit 3). One line per world: rc|id|newer|needs|
  # installed|probe|failed.
  rfx() { # rfx <family> <alias's id> <ids the CLI knows> <ids the API serves it> [gated ids] [ids with no verdict]
    : > "$tmp/rf.log"
    ( CLAUDE_BIN="$BASE_DIR/test/fake-claude"
      FAKE_ALIASES="$1=$2" FAKE_CLI_MODELS="$3" FAKE_API_MODELS="$4" FAKE_GATED_MODELS="${5:-}" FAKE_FAILED_MODELS="${6:-}" FAKE_PROBE_LOG="$tmp/rf.log"
      export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS FAKE_GATED_MODELS FAKE_FAILED_MODELS FAKE_PROBE_LOG
      resolve_family "$1" >/dev/null 2>&1
      echo "$?|${RF_ID-}|${RF_NEWER-}|${RF_NEEDS-}|${RF_INSTALLED-}|${RF_PROBE-}|${RF_FAILED-}" )
  }
  # 2026-09-22 again, now with what the operator lacked that day: the family
  # stays on the alias, and the search says which release waits for
  # `claude update`, which version it needs and which one is installed.
  got="$(rfx opus claude-opus-5 "claude-opus-5 claude-opus-4-8" "claude-opus-5 claude-opus-4-8" "claude-opus-5-5")"
  [ "$got" = "0|claude-opus-5|claude-opus-5-5|2.1.280|2.1.258||" ] \
    && ok "a release kept for a newer CLI is named, with the version it needs and the one installed" \
    || bad "the 2026-09-22 world left '$got'"
  # Probes run newest first, so the first such release met is the newest.
  got="$(rfx opus claude-opus-5 "claude-opus-5" "claude-opus-5" "claude-opus-6 claude-opus-5-5")"
  [ "$got" = "0|claude-opus-5|claude-opus-6|2.1.280|2.1.258||" ] \
    && ok "of two such releases the newer is named (claude-opus-6 over claude-opus-5-5)" \
    || bad "two gated releases left '$got'"
  # No session: the first probe has no verdict, and neither would the next
  # ten. The search stops there, keeps the best id it has (the alias's), and
  # exits 3 with the CLI's own words.
  : > "$tmp/rf.log"
  got="$( CLAUDE_BIN="$BASE_DIR/test/fake-claude"
          FAKE_ALIASES="opus=claude-opus-5-5" FAKE_CLI_MODELS="claude-opus-5-5" FAKE_API_MODELS="claude-opus-5-5" FAKE_CLAUDE_LOGGED_OUT=1 FAKE_PROBE_LOG="$tmp/rf.log"
          export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS FAKE_CLAUDE_LOGGED_OUT FAKE_PROBE_LOG
          resolve_family opus >/dev/null 2>&1
          echo "$?|${RF_ID-}|${RF_NEWER-}|${RF_NEEDS-}|${RF_INSTALLED-}|${RF_PROBE-}|${RF_FAILED-}" )"
  [ "$got" = "3|claude-opus-5-5||||claude-opus-7|Not logged in · Please run /login" ] \
    && ok "a probe with no verdict ends the family's search: exit 3, the alias's id, which probe and why" \
    || bad "a logged-out search left '$got'"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-opus-7 " ] && ok "and nothing is probed after it" \
    || bad "probes after a failed one: $(tr '\n' ' ' < "$tmp/rf.log")"
  # A session that goes mid-pass, after a newer CLI's release was met: the
  # release is still reported -- the 400 was a real answer -- and the
  # search stops at the probe that had none.
  got="$(rfx opus claude-opus-5 "claude-opus-5" "claude-opus-5" "claude-opus-6" "claude-opus-5-8")"
  [ "$got" = "3|claude-opus-5|claude-opus-6|2.1.280|2.1.258|claude-opus-5-8|Not logged in · Please run /login" ] \
    && ok "a release met before the pass was cut short is still named" || bad "a mid-pass failure left '$got'"
  [ "$(tr '\n' ' ' < "$tmp/rf.log")" = "claude-opus-7 claude-opus-6 claude-opus-5-9 claude-opus-5-8 " ] \
    && ok "and the search stopped at the probe with no verdict" || bad "probes: $(tr '\n' ' ' < "$tmp/rf.log")"

  echo "model_probe_ok() — the JSON answer alone decides, whatever the CLI adds on stderr"
  # For every request that goes out for an id it does not recognise, the CLI
  # writes `[claude-code:unrecognized_model] {...}` to stderr -- its own
  # changelog says so, and both refusals captured here carry it -- and an id
  # newer than the CLI is what a probe asks for. Parsed together with the
  # JSON on stdout, that line made jq fail, so a served id the CLI did not
  # know would have read as refused. The answers are the stand-in's captures.
  ( CLAUDE_BIN="$BASE_DIR/test/fake-claude"; FAKE_CLI_MODELS=""; FAKE_API_MODELS="claude-opus-5-5"
    export FAKE_CLI_MODELS FAKE_API_MODELS; model_probe_ok claude-opus-5-5 ) 2>/dev/null
  want "a served id the CLI flags as unrecognized on stderr is accepted" 0 $?
  ( CLAUDE_BIN="$BASE_DIR/test/fake-claude"; FAKE_CLI_MODELS=""; FAKE_API_MODELS="claude-opus-5-5"
    export FAKE_CLI_MODELS FAKE_API_MODELS; model_probe_ok claude-opus-5-3 ) 2>/dev/null
  want "an id the API does not serve (the real 404) is refused" 1 $?
  # Three answers used to read as that same "no such id". The 400 of a
  # release the API keeps for a newer CLI is an id that exists, and the one
  # thing that reaches it is `claude update` -- so it is its own answer, with
  # both versions kept. The 400 names the build that asked; the stand-in
  # plays 2.1.270 here so the installed version is read, not assumed.
  got="$( CLAUDE_BIN="$BASE_DIR/test/fake-claude"; FAKE_CLI_MODELS=""; FAKE_API_MODELS="claude-opus-5"; FAKE_GATED_MODELS="claude-opus-5-5"; FAKE_CLAUDE_VERSION=2.1.270
          export FAKE_CLI_MODELS FAKE_API_MODELS FAKE_GATED_MODELS FAKE_CLAUDE_VERSION
          model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_NEEDS-}|${PROBE_INSTALLED-}|${PROBE_ANSWER-}" )"
  [ "$got" = "2|2.1.280|2.1.270|" ] \
    && ok "an id the API serves only to a newer CLI (the real 400) is its own answer, 2, naming the version required and the one installed" \
    || bad "the 400 of a newer CLI's release read as '$got', wanted '2|2.1.280|2.1.270|'"
  # A 400 that names the version required but not the build that asked: the
  # installed one comes from the CLI itself. The real capture with the build
  # taken out of its sentence, and a stand-in whose --version says 2.1.270.
  "$JQ" -c '.result = "API Error: 400 This model is not supported; version 2.1.280 or newer is required."' \
    "$BASE_DIR/test/fixtures/claude-probe-version-gated.json" > "$tmp/probe-400-nobuild.json"
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "2.1.270 (Claude Code)"; exit 0; fi\ncat "%s"\nexit 1\n' \
    "$tmp/probe-400-nobuild.json" > "$tmp/claude-400-nobuild"; chmod +x "$tmp/claude-400-nobuild"
  got="$( CLAUDE_BIN="$tmp/claude-400-nobuild"; model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_NEEDS-}|${PROBE_INSTALLED-}" )"
  [ "$got" = "2|2.1.280|2.1.270" ] && ok "a 400 that does not name the build asking is read with the version the CLI itself reports" \
    || bad "a 400 with no build in it read as '$got', wanted '2|2.1.280|2.1.270'"
  # The answer is the CLI's result event. More JSON around it -- a notice a
  # later CLI might print, before or after -- must neither blind every probe
  # nor stand in for the answer: the real 404 between two such lines is
  # still a refusal, not "no verdict" and not "served".
  { printf '%s\n' '{"type":"system","subtype":"notice","message":"something new"}'
    cat "$BASE_DIR/test/fixtures/claude-probe-unknown-model.json"
    printf '%s\n' '{"type":"system","subtype":"notice","message":"and something after"}'; } > "$tmp/probe-3objects.json"
  printf '#!/bin/sh\ncat "%s"\nexit 1\n' "$tmp/probe-3objects.json" > "$tmp/claude-3objects"; chmod +x "$tmp/claude-3objects"
  ( CLAUDE_BIN="$tmp/claude-3objects"; model_probe_ok claude-opus-5-3 ) 2>/dev/null
  want "an answer with other JSON objects around it is read by its result event" 1 $?
  # A CLI with no session answers every id alike -- the real capture, taken
  # with no USER in the environment -- so the probe learned nothing about
  # the id. Read as a refusal, every family quietly stayed on its alias and
  # the pass was cached as fresh for a day. The CLI's own words are kept.
  got="$( CLAUDE_BIN="$BASE_DIR/test/fake-claude"; FAKE_CLI_MODELS=""; FAKE_API_MODELS="claude-opus-5-5"; FAKE_CLAUDE_LOGGED_OUT=1
          export FAKE_CLI_MODELS FAKE_API_MODELS FAKE_CLAUDE_LOGGED_OUT
          model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_NEEDS-}|${PROBE_ANSWER-}" )"
  [ "$got" = "3||Not logged in · Please run /login" ] \
    && ok "no session is no verdict (3), even for a served id, and the CLI's answer is kept to say why" \
    || bad "a logged-out probe read as '$got'"
  # The version is what makes a 400 a newer CLI's release. The real capture
  # with its sentence swapped: a 400 that names no version says nothing
  # about the id either.
  "$JQ" -c '.result = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"something else\"}}"' \
    "$BASE_DIR/test/fixtures/claude-probe-version-gated.json" > "$tmp/probe-400.json"
  printf '#!/bin/sh\ncat "%s"\nexit 1\n' "$tmp/probe-400.json" > "$tmp/claude-400"; chmod +x "$tmp/claude-400"
  got="$( CLAUDE_BIN="$tmp/claude-400"; model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_NEEDS-}" )"
  [ "$got" = "3|" ] && ok "a 400 that names no version is no verdict either, never a newer CLI's release" \
    || bad "a 400 with no version read as '$got'"
  # And a CLI that dies without a word: nothing on stdout, exit 1.
  printf '#!/bin/sh\nexit 1\n' > "$tmp/claude-mute"; chmod +x "$tmp/claude-mute"
  got="$( CLAUDE_BIN="$tmp/claude-mute"; model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_ANSWER-}" )"
  [ "$got" = "3|no answer from claude (exit 1)" ] && ok "a CLI that answers nothing is no verdict, and says so with its exit code" \
    || bad "a mute CLI read as '$got'"
  # And one that prints something other than a result event: what it printed
  # is what tick.log gets, not a guess.
  printf '#!/bin/sh\necho "Segmentation fault: 11"\nexit 139\n' > "$tmp/claude-crash"; chmod +x "$tmp/claude-crash"
  got="$( CLAUDE_BIN="$tmp/claude-crash"; model_probe_ok claude-opus-5-5 2>/dev/null; echo "$?|${PROBE_ANSWER-}" )"
  [ "$got" = "3|Segmentation fault: 11" ] && ok "a CLI that prints no result event is no verdict, and its own words are kept" \
    || bad "a CLI with no result event read as '$got'"

  echo "family_refresh() — a pass written down: a newer CLI's release noted and cleared, a pass cut short never fresh"
  # The recorder around resolve_family, for the tick's pass (cmd_resolve_models)
  # and for a launch whose family has expired (effective_model). One scratch
  # config throughout, in a subshell so MODELS_FILE cannot leak: ok/bad count
  # into _upass/_ufail and the RESULT line carries the count out, as in the
  # catalog blocks above. Inside the $( ) below there is no case and no
  # apostrophe in a comment or a message: bash 3.2 reads a case pattern's
  # paren, and a quote in a comment, while it looks for the end of the
  # substitution -- and a pair that cancels out only hides it.
  local _frout
  _frout="$(
    mkdir -p "$tmp/fr"
    CONFIG_DIR="$tmp/fr"; MODELS_FILE="$tmp/fr/models.json"; TICK_LOG="$tmp/fr/tick.log"
    CLAUDE_BIN="$BASE_DIR/test/fake-claude"; FAKE_PROBE_LOG="$tmp/fr/probes.log"; export FAKE_PROBE_LOG
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    ticklines() { grep -c . "$TICK_LOG"; }
    setopus() { "$JQ" --argjson e "$1" '.resolved.opus = $e' "$MODELS_FILE" > "$MODELS_FILE.t" && mv "$MODELS_FILE.t" "$MODELS_FILE"; }
    # The other two catalogs fresh, so only the Claude families decide models_stale here.
    "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{}, openai:{at:$now, models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    : > "$TICK_LOG"

    # 2026-09-22 on 2.1.258: the API keeps claude-opus-5-5 for 2.1.280 or newer.
    FAKE_ALIASES="opus=claude-opus-5 sonnet=claude-sonnet-5" FAKE_CLI_MODELS="claude-opus-5 claude-sonnet-5"
    FAKE_API_MODELS="claude-opus-5 claude-sonnet-5" FAKE_GATED_MODELS="claude-opus-5-5"
    export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS FAKE_GATED_MODELS
    got="$(family_refresh opus)"; rc=$?
    [ "$rc:$got" = "0:claude-opus-5" ] && ok "family_refresh: the family stays on the id this CLI can run" || bad "family_refresh opus: rc=$rc [$got]"
    "$JQ" -e '.resolved.opus | .id == "claude-opus-5" and .at > 0 and .newer.id == "claude-opus-5-5" and .newer.needs == "2.1.280"
              and .newer.installed == "2.1.258" and .newer.cli == "2.1.258" and .newer.at > 0 and (has("failed_at") | not)' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "family_refresh: the release is written next to the resolution -- the id, the version it needs, the one installed as the 400 and --version say, when" \
      || bad "models.json after the pass that met it: $(cat "$MODELS_FILE")"
    [ "$(ticklines)" = 1 ] && grep -qF 'models: opus — claude-opus-5-5 is out and needs Claude Code 2.1.280 (installed 2.1.258): run claude update' "$TICK_LOG" \
      && ok "family_refresh: and tick.log gets one line that says what to run" || bad "tick.log: $(cat "$TICK_LOG")"
    [ "$(models_cache_get opus)" = "claude-opus-5" ] && ok "models_cache_get: that pass finished, so its id is fresh" \
      || bad "cache after the pass: [$(models_cache_get opus)]"

    # The update: 2.1.280, whose alias is claude-opus-5-5, which the API serves it.
    FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION
    FAKE_ALIASES="opus=claude-opus-5-5 sonnet=claude-sonnet-5" FAKE_CLI_MODELS="claude-opus-5 claude-opus-5-5 claude-sonnet-5"
    FAKE_API_MODELS="claude-opus-5 claude-opus-5-5 claude-sonnet-5" FAKE_GATED_MODELS=""
    got="$(family_refresh opus)"; rc=$?
    [ "$rc:$got" = "0:claude-opus-5-5" ] && ok "family_refresh: after the update the family moves to the release" || bad "after the update: rc=$rc [$got]"
    "$JQ" -e '.resolved.opus | .id == "claude-opus-5-5" and (has("newer") | not)' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "family_refresh: and the notice is gone once the CLI is new enough" || bad "models.json after the update: $(cat "$MODELS_FILE")"
    [ "$(ticklines)" = 1 ] && ok "family_refresh: a pass with nothing to act on logs nothing" || bad "tick.log: $(cat "$TICK_LOG")"

    # No session -- the environment of the tick without USER -- once opus has expired.
    "$JQ" --argjson old "$(( $(now_epoch) - MODELS_TTL - 60 ))" '.resolved.opus.at = $old' "$MODELS_FILE" > "$MODELS_FILE.t" && mv "$MODELS_FILE.t" "$MODELS_FILE"
    _old="$("$JQ" -r '.resolved.opus.at' "$MODELS_FILE")"
    FAKE_CLAUDE_LOGGED_OUT=1; export FAKE_CLAUDE_LOGGED_OUT
    got="$(family_refresh opus)"; rc=$?
    [ "$rc:$got" = "3:claude-opus-5-5" ] && ok "family_refresh: a pass cut short keeps the id the family had, and exits 3" || bad "logged out: rc=$rc [$got]"
    "$JQ" -e --argjson old "$_old" '.resolved.opus | .id == "claude-opus-5-5" and .at == $old and .failed_at > 0 and .failures == 1
              and .failed == "Not logged in · Please run /login"' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "family_refresh: and is never written as fresh -- .at stays; when, how many in a row and the answer of the CLI are added" \
      || bad "models.json after a failed pass: $(cat "$MODELS_FILE")"
    [ "$(ticklines)" = 2 ] \
      && grep -qF "models: opus — the probe of claude-opus-7 failed (Not logged in · Please run /login); kept claude-opus-5-5, trying again in 10 min" "$TICK_LOG" \
      && ok "family_refresh: tick.log gets the probe, the answer of the CLI, and when it is tried again" || bad "tick.log: $(cat "$TICK_LOG")"
    [ "$(models_cache_get opus)" = "claude-opus-5-5" ] && ok "models_cache_get: the kept id serves a launch until the retry, with no probe of its own" \
      || bad "cache after a failed pass: [$(models_cache_get opus)]"
    got="$(family_refresh opus)"
    "$JQ" -e '.resolved.opus.failures == 2' "$MODELS_FILE" >/dev/null 2>&1 \
      && grep -qF "kept claude-opus-5-5, trying again in 20 min" "$TICK_LOG" \
      && ok "family_refresh: a second cut pass in a row is counted, and its retry waits twice as long" || bad "second failure: $(cat "$MODELS_FILE"; tail -1 "$TICK_LOG")"
    "$JQ" --argjson t "$(( $(now_epoch) - 2 * MODELS_RETRY - 1 ))" '.resolved.opus.failed_at = $t' "$MODELS_FILE" > "$MODELS_FILE.t" && mv "$MODELS_FILE.t" "$MODELS_FILE"
    [ -z "$(models_cache_get opus)" ] && ok "models_cache_get: once the retry is due, a launch probes again" || bad "cache past the retry: [$(models_cache_get opus)]"
    got="$(effective_model opus)"
    [ "$got" = "claude-opus-5-5" ] && "$JQ" -e --argjson old "$_old" '.resolved.opus | .at == $old and .failures == 3' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "effective_model: a launch whose probe failed runs on the kept id, and caches nothing as fresh" \
      || bad "effective_model logged out: [$got], $(cat "$MODELS_FILE")"

    # A family never resolved before, no session: the id of the alias, and nothing fresh.
    got="$(family_refresh sonnet)"; rc=$?
    [ "$rc:$got" = "3:claude-sonnet-5" ] && "$JQ" -e '.resolved.sonnet | .id == "claude-sonnet-5" and .at == 0 and .failed_at > 0' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "family_refresh: with nothing cached the id of the alias is kept, and .at is 0" || bad "sonnet logged out: rc=$rc [$got], $(cat "$MODELS_FILE")"

    # Of the id the last finished pass found and the best one this pass reached,
    # the newer is kept: never below the alias the CLI names -- the pass an
    # update brings back is often the one that fails -- and never below what a
    # finished pass had already found.
    setopus '{"id":"claude-opus-5","at":1}'
    got="$(family_refresh opus)"
    [ "$got" = "claude-opus-5-5" ] && ok "family_refresh: a pass cut short never leaves the family below the alias the CLI names" \
      || bad "kept [$got] under the alias claude-opus-5-5"
    setopus '{"id":"claude-opus-6","at":1}'
    got="$(family_refresh opus)"
    [ "$got" = "claude-opus-6" ] && ok "family_refresh: nor below the id the last finished pass found" || bad "kept [$got] over claude-opus-6"

    # A session that goes mid-pass after a release for a newer CLI was met:
    # both are written, and both are said.
    unset FAKE_CLAUDE_LOGGED_OUT
    FAKE_CLAUDE_VERSION=2.1.258 FAKE_ALIASES="opus=claude-opus-5" FAKE_CLI_MODELS="claude-opus-5" FAKE_API_MODELS="claude-opus-5"
    FAKE_GATED_MODELS="claude-opus-6" FAKE_FAILED_MODELS="claude-opus-5-8"; export FAKE_FAILED_MODELS
    setopus '{"id":"claude-opus-5","at":1}'
    : > "$TICK_LOG"
    got="$(family_refresh opus)"; rc=$?
    [ "$rc:$got" = "3:claude-opus-5" ] && "$JQ" -e '.resolved.opus | .at == 1 and .failed_at > 0 and .newer.id == "claude-opus-6"
              and .newer.needs == "2.1.280" and .newer.installed == "2.1.258" and .newer.cli == "2.1.258"' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "family_refresh: a release met before the cut is written with the failure" || bad "gate then cut: rc=$rc [$got], $(cat "$MODELS_FILE")"
    [ "$(ticklines)" = 2 ] && grep -qF "models: opus — claude-opus-6 is out and needs Claude Code 2.1.280 (installed 2.1.258): run claude update" "$TICK_LOG" \
      && grep -qF "models: opus — the probe of claude-opus-5-8 failed (Not logged in · Please run /login); kept claude-opus-5, trying again in 10 min" "$TICK_LOG" \
      && ok "family_refresh: and tick.log gets both lines" || bad "tick.log: $(cat "$TICK_LOG")"
    unset FAKE_FAILED_MODELS

    # What agentloop resolve-models prints, and its exit code.
    FAKE_CLAUDE_LOGGED_OUT=1; export FAKE_CLAUDE_LOGGED_OUT
    FAKE_ALIASES="opus=claude-opus-5-5" FAKE_GATED_MODELS=""
    setopus '{"id":"claude-opus-5","at":1}'
    out="$(cmd_resolve_models anthropic 2>&1)"; rc=$?
    [ "$rc" = 1 ] && grep -qF "opus -> claude-opus-5-5 — the probe of claude-opus-7 failed (Not logged in · Please run /login); kept claude-opus-5-5, trying again in 10 min" <<< "$out" \
      && ok "resolve-models: a pass cut short is printed as such, and the command exits 1" || bad "resolve-models logged out: rc=$rc $out"
    unset FAKE_CLAUDE_LOGGED_OUT
    FAKE_ALIASES="opus=claude-opus-5" FAKE_CLI_MODELS="claude-opus-5" FAKE_API_MODELS="claude-opus-5" FAKE_GATED_MODELS="claude-opus-5-5"
    out="$(cmd_resolve_models anthropic 2>&1)"; rc=$?
    [ "$rc" = 0 ] && grep -qF "opus -> claude-opus-5 — claude-opus-5-5 is out and needs Claude Code 2.1.280 (installed 2.1.258): run claude update" <<< "$out" \
      && ok "resolve-models: the release is printed next to the family, and the pass that met it exits 0" || bad "resolve-models gated: rc=$rc $out"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_frout" | grep -v '^RESULT '
  printf '%s\n' "$_frout" | grep -qx 'RESULT ok=21 bad=0' \
    && ok "family_refresh over the probe stand-in: all 21 assertions reach the gate" \
    || bad "family_refresh over the probe stand-in did not: $(printf '%s\n' "$_frout" | tail -1)"

  echo "models_stale() — when the tick runs the pass again, and how much of it"
  # The tick asks this every minute. A catalog past MODELS_TTL is due for the
  # whole pass. A family whose pass a probe cut short is due for the Claude
  # families alone, MODELS_RETRY after the cut and twice as long after each
  # one in a row, never longer than MODELS_TTL -- or a whole MODELS_TTL while
  # Settings keeps Anthropic off. A CLI that changed under a release waiting
  # for it is due at once. MODELS_DUE_SCOPE and MODELS_DUE_WHY say which, for
  # the tick and its log line. Same subshell rules as the block above.
  local _msout
  _msout="$(
    mkdir -p "$tmp/ms/sc/config" "$tmp/ms/sc/data"
    CONFIG_DIR="$tmp/ms"; MODELS_FILE="$tmp/ms/models.json"; PLATFORMS_FILE="$tmp/ms/platforms.json"
    CLAUDE_BIN="$BASE_DIR/test/fake-claude"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["opus"]}}}\n' > "$PLATFORMS_FILE"
    now="$(now_epoch)"
    # mf <jq for .resolved>: the file, with both other catalogs fresh; $now and $ttl are bound.
    mf() { "$JQ" -n --argjson now "$now" --argjson ttl "$MODELS_TTL" "{resolved:($1), openai:{at:\$now, models:[]}, opencode:{at:\$now, models:[]}}" > "$MODELS_FILE"; }
    due() { models_stale; echo "$?|${MODELS_DUE_SCOPE-unset}|${MODELS_DUE_WHY-unset}"; }
    retrying="retrying opus after a failed probe"
    # A CLI that writes down every call it gets, and answers only --version.
    printf '#!/bin/sh\necho "$*" >> "%s"\necho "2.1.280 (Claude Code)"\n' "$tmp/ms/asked.log" > "$tmp/ms/claude-v"; chmod +x "$tmp/ms/claude-v"

    mf '{opus:{id:"claude-opus-5-5", at:$now}}'
    [ "$(due)" = "1||" ] && ok "models_stale: not due while every block is fresh" || bad "all fresh: $(due)"
    mf '{opus:{id:"claude-opus-5-5", at:($now - $ttl - 1)}}'
    [ "$(due)" = "0||cache older than ${MODELS_TTL}s" ] && ok "models_stale: a family past MODELS_TTL is due for the whole pass" || bad "family past the TTL: $(due)"
    "$JQ" -n --argjson now "$now" '{resolved:{opus:{id:"x", at:$now}}, openai:{at:1, models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    [ "$(due)" = "0||cache older than ${MODELS_TTL}s" ] && ok "models_stale: so is an openai catalog past it" || bad "openai past the TTL: $(due)"

    mf '{opus:{id:"claude-opus-5-5", at:1, failed_at:$now, failures:1}}'
    [ "$(due)" = "1||" ] && ok "models_stale: a cut family is not due inside MODELS_RETRY" || bad "inside the retry: $(due)"
    mf "{opus:{id:\"claude-opus-5-5\", at:1, failed_at:(\$now - $MODELS_RETRY - 1), failures:1}}"
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: past it, due for the Claude families alone, and the reason says so" || bad "past the retry: $(due)"
    mf "{opus:{id:\"claude-opus-5-5\", at:1, failed_at:(\$now - $MODELS_RETRY - 1), failures:2}}"
    [ "$(due)" = "1||" ] && ok "models_stale: after a second cut pass in a row, twice as long" || bad "second failure, one wait later: $(due)"
    mf "{opus:{id:\"claude-opus-5-5\", at:1, failed_at:(\$now - 2 * $MODELS_RETRY - 1), failures:2}}"
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: and due once that has passed" || bad "second failure, two waits later: $(due)"
    mf '{opus:{id:"claude-opus-5-5", at:1, failed_at:($now - $ttl + 60), failures:30}}'
    [ "$(due)" = "1||" ] && ok "models_stale: the wait grows up to MODELS_TTL" || bad "thirty failures, under a day: $(due)"
    mf '{opus:{id:"claude-opus-5-5", at:1, failed_at:($now - $ttl - 1), failures:30}}'
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: and never past it" || bad "thirty failures, over a day: $(due)"
    mf '{opus:{id:"claude-opus-5-5", at:($now - 60), failed_at:($now - 700), failures:1}}'
    [ "$(due)" = "1||" ] && ok "models_stale: a cut pass over a family still fresh waits for its MODELS_TTL" || bad "cut over a fresh family: $(due)"
    # The retry names the families it is for: one that failed, not the three
    # whose passes finished.
    mf "{opus:{id:\"claude-opus-5-5\", at:1, failed_at:(\$now - $MODELS_RETRY - 1), failures:1}, sonnet:{id:\"claude-sonnet-5\", at:1, failed_at:\$now, failures:1}}"
    [ "$(models_stale; echo "${MODELS_DUE_FAMILIES-unset}")" = "opus" ] && ok "models_stale: a retry is for the families it is due for, and only those" \
      || bad "families of a retry: [$(models_stale; echo "${MODELS_DUE_FAMILIES-unset}")]"
    # A retry due minutes before the whole pass is folded into it: one round
    # of probes, not two a minute apart.
    "$JQ" -n --argjson now "$now" --argjson ttl "$MODELS_TTL" --argjson r "$MODELS_RETRY" \
      '{resolved:{opus:{id:"claude-opus-5-5", at:1, failed_at:($now - $r - 1), failures:1}}, openai:{at:($now - $ttl + 300), models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    [ "$(due)" = "0||$retrying, the rest of the cache due within 10 min" ] && ok "models_stale: a retry due just before the whole pass is folded into it" \
      || bad "retry just before the whole pass: $(due)"
    "$JQ" -n --argjson now "$now" --argjson ttl "$MODELS_TTL" --argjson r "$MODELS_RETRY" \
      '{resolved:{opus:{id:"claude-opus-5-5", at:1, failed_at:($now - $r - 1), failures:1}}, openai:{at:($now - $ttl + 3 * $r), models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: and one due further ahead of it is not" || bad "retry well before the whole pass: $(due)"

    printf '{"platforms":{"anthropic":{"enabled":false,"bin":"","models":["opus"]}}}\n' > "$PLATFORMS_FILE"
    mf "{opus:{id:\"claude-opus-5-5\", at:1, failed_at:(\$now - $MODELS_RETRY - 1), failures:1}}"
    [ "$(due)" = "1||" ] && ok "models_stale: with Anthropic off in Settings, a cut family waits a whole MODELS_TTL" || bad "Anthropic off, one retry later: $(due)"
    mf '{opus:{id:"claude-opus-5-5", at:1, failed_at:($now - $ttl - 1), failures:1}}'
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: and is due after it" || bad "Anthropic off, a day later: $(due)"
    # A launch goes through effective_model before the gate that refuses it:
    # with Anthropic off, no probe -- not even the alias -- is spent on a run
    # Settings will turn away next.
    : > "$tmp/ms/asked.log"
    got="$( CLAUDE_BIN="$tmp/ms/claude-v"; effective_model opus )"
    [ "$got" = "claude-opus-5-5" ] && [ ! -s "$tmp/ms/asked.log" ] \
      && ok "effective_model: with Anthropic off a launch runs no probe, and names the id the cache holds" \
      || bad "effective_model with Anthropic off: [$got], the CLI got: $(cat "$tmp/ms/asked.log")"
    mf '{opus:{id:"claude-opus-5", at:$now, newer:{id:"claude-opus-5-5", needs:"2.1.280", installed:"2.1.258", cli:"2.1.258", at:$now}}}'
    [ "$( FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due )" = "1||" ] \
      && ok "models_stale: and a changed CLI brings nothing back while Anthropic is off" || bad "Anthropic off, CLI changed: $(FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due)"
    printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["opus"]}}}\n' > "$PLATFORMS_FILE"

    [ "$(due)" = "1||" ] && ok "models_stale: a release waiting on the CLI it was recorded against is not due" || bad "same CLI: $(due)"
    [ "$( FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due )" = "0|anthropic|Claude Code went from 2.1.258 to 2.1.280 while a release waited for it" ] \
      && ok "models_stale: a changed CLI is due at once, for the Claude families, and the reason names both versions" \
      || bad "CLI changed: $(FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due)"
    [ "$( FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; models_stale; echo "[${MODELS_DUE_FAMILIES-unset}]" )" = "[]" ] \
      && ok "models_stale: and for every family, not only the one the release belongs to" \
      || bad "families of a changed CLI: $(FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; models_stale; echo "[${MODELS_DUE_FAMILIES-unset}]")"
    mf '{opus:{id:"claude-opus-5", at:$now, newer:{id:"claude-opus-5-5", needs:"2.1.280", installed:"9.9.9", cli:"2.1.258", at:$now}}}'
    [ "$(due)" = "1||" ] && ok "models_stale: the CLI is compared with what --version said, never with the text of the 400" || bad "400 text unlike --version: $(due)"
    mf '{opus:{id:"claude-opus-5", at:$now, newer:{id:"claude-opus-5-5", needs:"2.1.280", installed:"2.1.258", cli:"", at:$now}}}'
    [ "$( FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due )" = "1||" ] && ok "models_stale: a release recorded with no --version to compare waits for the daily pass" \
      || bad "no cli recorded: $(FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due)"
    mf '{opus:{id:"claude-opus-5", at:$now, failed_at:$now, failures:1, failed:"x", newer:{id:"claude-opus-5-5", needs:"2.1.280", installed:"2.1.258", cli:"2.1.258", at:$now}}}'
    [ "$( FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due )" = "1||" ] \
      && ok "models_stale: a changed CLI waits for the retry after a failed pass, or one that lost its session would relaunch every minute" \
      || bad "changed CLI inside a retry: $(FAKE_CLAUDE_VERSION=2.1.280; export FAKE_CLAUDE_VERSION; due)"

    # The CLI is asked its version only while a release waits for it.
    : > "$tmp/ms/asked.log"
    mf '{opus:{id:"claude-opus-5-5", at:$now}}'
    [ "$( CLAUDE_BIN="$tmp/ms/claude-v"; due )" = "1||" ] && [ ! -s "$tmp/ms/asked.log" ] \
      && ok "models_stale: with nothing waiting the CLI is not run at all" || bad "the CLI was asked: $(cat "$tmp/ms/asked.log")"

    # Hand edits: a family the pass never writes cannot keep it due, and a
    # .resolved that is not an object is due, so the pass rewrites it.
    mf '{opus:{id:"claude-opus-5-5", at:$now}, gpt:{id:"x", at:1}}'
    [ "$(due)" = "1||" ] && ok "models_stale: an entry that is no Claude family is not counted" || bad "a foreign entry: $(due)"
    mf '[]'
    [ "$(due)" = "0||cache older than ${MODELS_TTL}s" ] && ok "models_stale: a .resolved that is not an object is due" || bad "resolved as a list: $(due)"
    models_cache_set opus claude-opus-5-5
    "$JQ" -e '.resolved.opus.id == "claude-opus-5-5"' "$MODELS_FILE" >/dev/null 2>&1 && ok "models_cache_set: and the pass writes it back as one" \
      || bad "resolved after a write over a list: $(cat "$MODELS_FILE")"
    printf 'not json' > "$MODELS_FILE"
    [ "$(due)" = "0||models.json could not be read" ] && ok "models_stale: an unreadable file is due, and says so" || bad "unreadable: $(due)"
    rm -f "$MODELS_FILE"
    [ "$(due)" = "0||no models.json yet" ] && ok "models_stale: so is a missing one" || bad "missing: $(due)"
    # A number written as text reads as 0: the cache is due, never taken for
    # an unreadable file -- that answer came back on every tick, a pass cut
    # short kept the text, and the whole pass ran every minute.
    mf '{opus:{id:"claude-opus-5-5", at:"yesterday", failed_at:"now", failures:"3"}}'
    [ "$(due)" = "0||cache older than ${MODELS_TTL}s" ] && ok "models_stale: a number written as text reads as 0, never as an unreadable file" \
      || bad "numbers as text: $(due)"
    models_cache_fail opus claude-opus-5-5 x "$MODELS_RETRY" >/dev/null
    "$JQ" -e '.resolved.opus | .at == 0 and .failures == 1 and (.failed_at | type) == "number"' "$MODELS_FILE" >/dev/null 2>&1 && [ "$(due)" = "1||" ] \
      && ok "models_cache_fail: writes them back as numbers, and the retry holds" || bad "after a cut pass over text: $(cat "$MODELS_FILE"); $(due)"
    mf "{opus:{id:\"claude-opus-5-5\", at:\"yesterday\", failed_at:(\$now - $MODELS_RETRY - 1), failures:\"3\"}}"
    [ "$(due)" = "0|anthropic|$retrying" ] && ok "models_stale: a cut family with its other stamps as text is retried, never taken for an unreadable file" \
      || bad "cut family, stamps as text: $(due)"
    "$JQ" -n --argjson now "$now" '{resolved:{opus:{id:"x", at:$now}}, openai:{at:"x", models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    [ "$(due)" = "0||cache older than ${MODELS_TTL}s" ] && ok "models_stale: so does an openai stamp written as text" || bad "openai stamp as text: $(due)"

    # The launch the tick makes: the scope and the families reach the detached
    # pass as its arguments, and tick.log says why it runs.
    printf '#!/bin/sh\necho "$*" > "%s"\n' "$tmp/ms/launched" > "$tmp/ms/self"; chmod +x "$tmp/ms/self"
    : > "$tmp/ms/tick.log"
    ( SELF="$tmp/ms/self"; DATA_DIR="$tmp/ms/sc/data"; TICK_LOG="$tmp/ms/tick.log"
      MODELS_DUE_SCOPE="anthropic"; MODELS_DUE_FAMILIES="opus sonnet"; MODELS_DUE_WHY="retrying opus sonnet after a failed probe"
      models_refresh_launch ) >/dev/null 2>&1
    i=0; while [ ! -s "$tmp/ms/launched" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ "$(cat "$tmp/ms/launched" 2>/dev/null)" = "_resolve_models anthropic opus sonnet" ] \
      && grep -qF 'models: refreshing family→id resolutions (retrying opus sonnet after a failed probe)' "$tmp/ms/tick.log" \
      && ok "models_refresh_launch: the scope and the families reach the detached pass, and tick.log says why" \
      || bad "launched [$(cat "$tmp/ms/launched" 2>/dev/null)], tick.log: $(cat "$tmp/ms/tick.log")"
    rm -f "$tmp/ms/launched"
    ( SELF="$tmp/ms/self"; DATA_DIR="$tmp/ms/sc/data"; TICK_LOG="$tmp/ms/tick.log"
      MODELS_DUE_SCOPE=""; MODELS_DUE_FAMILIES=""; MODELS_DUE_WHY="cache older than ${MODELS_TTL}s"
      models_refresh_launch ) >/dev/null 2>&1
    i=0; while [ ! -s "$tmp/ms/launched" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ "$(cat "$tmp/ms/launched" 2>/dev/null)" = "_resolve_models" ] && ok "models_refresh_launch: the whole pass takes no argument" \
      || bad "launched [$(cat "$tmp/ms/launched" 2>/dev/null)]"

    # And the pass itself, run as the tick runs it over a scratch install
    # whose codex stand-in would write an openai catalog and whose price
    # source is the real fixture: the families it was handed, and nothing else.
    AGENTLOOP_CONFIG="$tmp/ms/sc/config" AGENTLOOP_DATA="$tmp/ms/sc/data" AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" \
      AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode AGENTLOOP_CLAUDE_CONFIG_DIR="" \
      AGENTLOOP_PRICING_URL="file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json" CODEX_HOME="$tmp/ms/sc/codex-home" \
      FAKE_ALIASES="opus=claude-opus-5-5 sonnet=claude-sonnet-5" FAKE_CLI_MODELS="claude-opus-5-5" FAKE_API_MODELS="claude-opus-5-5" \
      /bin/bash "$BIN_DIR/agentloop" _resolve_models anthropic opus >/dev/null 2>&1
    "$JQ" -e '(.resolved | keys) == ["opus"] and .resolved.opus.id == "claude-opus-5-5" and (has("openai") | not) and (has("opencode") | not)' \
      "$tmp/ms/sc/config/models.json" >/dev/null 2>&1 && [ ! -e "$tmp/ms/sc/config/pricing.json" ] \
      && ok "_resolve_models anthropic opus: that family alone -- no other family, no other catalog, no price table" \
      || bad "_resolve_models anthropic opus wrote: $(cat "$tmp/ms/sc/config/models.json" 2>/dev/null); config: $(ls "$tmp/ms/sc/config")"
    ( cmd_resolve_models anthropic gpt ) >/dev/null 2>&1
    want "resolve-models anthropic refuses a family it does not know" 1 $?
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_msout" | grep -v '^RESULT '
  printf '%s\n' "$_msout" | grep -qx 'RESULT ok=37 bad=0' \
    && ok "models_stale over scratch caches: all 37 assertions reach the gate" \
    || bad "models_stale over scratch caches did not: $(printf '%s\n' "$_msout" | tail -1)"

  echo "models_lock() — one writer of models.json at a time: two at once both land, a holder that stopped is given up on"
  # Every writer rewrites config/models.json whole -- jq into a temporary
  # file, then mv over it -- and two of them do run at once: the detached pass
  # the tick starts, and a launch whose family expired, which resolves inline
  # (effective_model, family_refresh) outside that pass. Both read the same
  # file and the second mv drops the first update: a resolution, a release
  # waiting for claude update, a failed_at stamp. The jq stand-in below
  # answers one second late whenever its answer goes to a file -- the window
  # between reading models.json and replacing it -- so both writers read
  # before either writes. Same subshell rules as the blocks above.
  local _mwout
  _mwout="$(
    mkdir -p "$tmp/mw/locks"
    CONFIG_DIR="$tmp/mw"; MODELS_FILE="$tmp/mw/models.json"; TICK_LOG="$tmp/mw/tick.log"; LOCK_DIR="$tmp/mw/locks"
    CODEX_BIN="$BASE_DIR/test/fake-codex"; OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    printf '#!/bin/sh\n"%s" "$@"; rc=$?\n[ -f /dev/fd/1 ] && sleep 1\nexit $rc\n' "$JQ" > "$tmp/mw/slowjq"; chmod +x "$tmp/mw/slowjq"
    # No family yet, both other catalogs present and fresh, an empty tick.log.
    seed() { "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{}, openai:{at:$now, models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"; : > "$TICK_LOG"; }
    lines() { sed 's/^[^ ]* //' "$TICK_LOG"; }

    # The pass of the tick finishing opus while a launch writes down the cut pass of sonnet.
    seed
    ( JQ="$tmp/mw/slowjq"; models_cache_set opus claude-opus-5-5 ) & _w1=$!
    ( JQ="$tmp/mw/slowjq"; models_cache_fail sonnet claude-sonnet-5 "Not logged in" "$MODELS_RETRY" >/dev/null ) & _w2=$!
    wait "$_w1" "$_w2"
    "$JQ" -e '.resolved.opus.id == "claude-opus-5-5" and .resolved.sonnet.id == "claude-sonnet-5" and .resolved.sonnet.failed_at > 0
              and (.openai.models | type) == "array" and (.opencode.models | type) == "array"' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "two writers at once both land: the finished pass of opus, the cut pass of sonnet, and the rest of the file" \
      || bad "two writers at once, an update lost: $(cat "$MODELS_FILE")"
    [ ! -e "$LOCK_DIR/.models.lock" ] && [ ! -s "$TICK_LOG" ] && [ -z "$(ls -A "$CONFIG_DIR" | grep '^[.]models[.]')" ] \
      && ok "each write drops the lock after it, gives nothing up, and leaves no temporary file" \
      || bad "after the race: locks [$(ls -A "$LOCK_DIR")] tick.log [$(cat "$TICK_LOG")] config [$(ls -A "$CONFIG_DIR")]"
    # A catalog refresh that failed -- no codex -- stamps the catalog it keeps while a launch writes opus.
    seed
    ( JQ="$tmp/mw/slowjq"; CODEX_BIN=/nonexistent; resolve_models_openai >/dev/null ) & _w1=$!
    ( JQ="$tmp/mw/slowjq"; models_cache_set opus claude-opus-5-5 ) & _w2=$!
    wait "$_w1" "$_w2"
    "$JQ" -e '.openai.stale_reason == "codex not installed" and .openai.stale_at > 0 and .resolved.opus.id == "claude-opus-5-5"' "$MODELS_FILE" >/dev/null 2>&1 \
      && ok "a catalog kept after a failed refresh is stamped, and the family written at the same time lands too" \
      || bad "a stamp and a family at once, an update lost: $(cat "$MODELS_FILE")"

    # A writer that stopped while it held the lock: a live pid, from this boot.
    # Every write waits MODELS_LOCK_WAIT for it and then gives up -- nothing
    # written, one line in tick.log naming what was not -- so neither a launch
    # nor the pass hangs behind it. Every path that writes is asked, all at
    # once in the background: both family records, both catalogs replaced and
    # stamped, and a whole family pass, cut short and finished. Opus, sonnet
    # and fable already hold an id: a cut pass that wrote nothing prints none
    # of its own, and runs on the newer of the id the file holds and the one
    # it reached -- never below either.
    LOCK_GRACE_SECONDS=30; MODELS_LOCK_WAIT=1
    "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{opus:{id:"claude-opus-5-5", at:1}, sonnet:{id:"claude-sonnet-4-6", at:1}, fable:{id:"claude-fable-5", at:1}},
      openai:{at:$now, models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    : > "$TICK_LOG"
    sleep 60 >/dev/null 2>&1 & _holder=$!
    mkdir "$LOCK_DIR/.models.lock"; echo "$_holder" > "$LOCK_DIR/.models.lock/pid"; boot_id > "$LOCK_DIR/.models.lock/boot"
    _before="$(cksum < "$MODELS_FILE")"
    gone="pid $_holder held the lock on models.json for more than 1 s"
    # gives NAME COMMAND...: in the background; its output lands in NAME.out, its exit and seconds in NAME.rc.
    gives() { local n="$1"; shift; ( t0="$(now_epoch)"; "$@" > "$tmp/mw/$n.out" 2>&1; r=$?; echo "$r $(( $(now_epoch) - t0 ))" > "$tmp/mw/$n.rc" ) & _pids="$_pids $!"; }
    # gave NAME: its exit, then bounded -- well short of the minute the holder lives -- or how long it waited.
    gave() { local r e; read -r r e < "$tmp/mw/$1.rc"; [ "$e" -le 20 ] && e=bounded || e="waited ${e}s"; printf '%s|%s' "$r" "$e"; }
    seen() { lines | grep -cxF "$1"; }
    openai_gone()    { local CODEX_BIN=/nonexistent; resolve_models_openai; }
    opencode_empty() { local FAKE_OPENCODE_NO_MODELS=1; export FAKE_OPENCODE_NO_MODELS; resolve_models_opencode; }
    # pass_cut FAMILY ALIAS: a pass with no session, cut at its first probe, having reached the alias.
    pass_cut() {
      local CLAUDE_BIN="$BASE_DIR/test/fake-claude" FAKE_ALIASES="$1=$2" FAKE_CLI_MODELS="$2" FAKE_API_MODELS="$2" FAKE_CLAUDE_LOGGED_OUT=1
      export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS FAKE_CLAUDE_LOGGED_OUT; family_refresh "$1"
    }
    pass_done() {
      local CLAUDE_BIN="$BASE_DIR/test/fake-claude" FAKE_ALIASES="sonnet=claude-sonnet-5" FAKE_CLI_MODELS="claude-sonnet-5" FAKE_API_MODELS="claude-sonnet-5 claude-sonnet-5-5"
      export FAKE_ALIASES FAKE_CLI_MODELS FAKE_API_MODELS; cmd_resolve_models anthropic sonnet
    }
    _pids=""
    gives cset   models_cache_set haiku claude-haiku-4-5
    gives cfail  models_cache_fail fable claude-fable-5-1 x "$MODELS_RETRY"
    gives oa     resolve_models_openai
    gives oakept openai_gone
    gives oc     resolve_models_opencode
    gives ockept opencode_empty
    gives cut    pass_cut opus claude-opus-5
    gives cutup  pass_cut sonnet claude-sonnet-5
    gives fin    pass_done
    wait $_pids
    [ "$(gave cset)" = "1|bounded" ] && [ "$(seen "models: haiku — gave up writing claude-haiku-4-5: $gone")" = 1 ] \
      && ok "models_cache_set: a live holder is waited for MODELS_LOCK_WAIT, then given up on, and tick.log says what was not written" \
      || bad "models_cache_set under a held lock: $(gave cset), tick.log [$(lines)]"
    [ "$(gave cfail)" = "1|bounded" ] && [ ! -s "$tmp/mw/cfail.out" ] && [ "$(seen "models: fable — gave up writing the failed probe: $gone")" = 1 ] \
      && ok "models_cache_fail: the same, and it prints no id -- not even the one the file holds" \
      || bad "models_cache_fail under a held lock: $(gave cfail), printed [$(cat "$tmp/mw/cfail.out")]"
    [ "$(gave oa) $(gave oakept)" = "1|bounded 1|bounded" ] && [ "$(seen "models: openai — gave up writing the catalog: $gone")" = 2 ] \
      && [ "$(cat "$tmp/mw/oa.out" "$tmp/mw/oakept.out" | sort -u)" = "openai -> could not write $MODELS_FILE" ] \
      && ok "resolve_models_openai: the same for a catalog it would replace and one it would stamp, and the refresh says it could not write" \
      || bad "openai under a held lock: $(gave oa) $(gave oakept), printed [$(cat "$tmp/mw/oa.out" "$tmp/mw/oakept.out")]"
    [ "$(gave oc) $(gave ockept)" = "1|bounded 1|bounded" ] && [ "$(seen "models: opencode — gave up writing the catalog: $gone")" = 2 ] \
      && [ "$(cat "$tmp/mw/oc.out" "$tmp/mw/ockept.out" | sort -u)" = "opencode -> could not write $MODELS_FILE" ] \
      && ok "resolve_models_opencode: the same, replaced and stamped" \
      || bad "opencode under a held lock: $(gave oc) $(gave ockept), printed [$(cat "$tmp/mw/oc.out" "$tmp/mw/ockept.out")]"
    [ "$(gave cut)" = "3|bounded" ] && [ "$(cat "$tmp/mw/cut.out")" = "claude-opus-5-5" ] \
      && [ "$(seen "models: opus — gave up writing the failed probe: $gone")" = 1 ] \
      && [ "$(seen "models: opus — the probe of claude-opus-7 failed (Not logged in · Please run /login); kept claude-opus-5-5, not recorded in models.json")" = 1 ] \
      && ok "family_refresh: a cut pass that could not write keeps the newer id the file holds, and promises no retry it did not stamp" \
      || bad "a cut pass under a held lock: $(gave cut), printed [$(cat "$tmp/mw/cut.out")], tick.log [$(lines)]"
    [ "$(gave cutup)" = "3|bounded" ] && [ "$(cat "$tmp/mw/cutup.out")" = "claude-sonnet-5" ] \
      && [ "$(seen "models: sonnet — the probe of claude-sonnet-7 failed (Not logged in · Please run /login); kept claude-sonnet-5, not recorded in models.json")" = 1 ] \
      && ok "family_refresh: and the newer id the pass reached, over an older one in the file" \
      || bad "a cut pass above the file under a held lock: $(gave cutup), printed [$(cat "$tmp/mw/cutup.out")], tick.log [$(lines)]"
    [ "$(gave fin)" = "1|bounded" ] && [ "$(cat "$tmp/mw/fin.out")" = "sonnet -> claude-sonnet-5-5 — not recorded in models.json" ] \
      && [ "$(seen "models: sonnet — gave up writing claude-sonnet-5-5: $gone")" = 1 ] \
      && ok "resolve-models: a finished pass that could not write names what it found, says it was not recorded, and exits 1" \
      || bad "a finished pass under a held lock: $(gave fin), printed [$(cat "$tmp/mw/fin.out")]"
    [ "$(cksum < "$MODELS_FILE")" = "$_before" ] && [ "$(lines | grep -c .)" = 11 ] \
      && ok "and the file is untouched by all nine, with nothing else in tick.log" \
      || bad "after nine writers under a held lock: $(cat "$MODELS_FILE"); tick.log [$(lines)]"
    # Behind the same lock a missing models.json is not created, nor an unreadable one reseeded.
    rm -f "$MODELS_FILE"; : > "$TICK_LOG"; _pids=""
    gives mset models_cache_set haiku claude-haiku-4-5
    gives moa  resolve_models_openai
    gives moc  resolve_models_opencode
    wait $_pids
    [ ! -e "$MODELS_FILE" ] && [ "$(gave mset) $(gave moa) $(gave moc)" = "1|bounded 1|bounded 1|bounded" ] \
      && ok "a missing models.json is not seeded behind the lock, by a family write or by either catalog" \
      || bad "a missing file under a held lock: $(gave mset) $(gave moa) $(gave moc), config [$(ls -A "$CONFIG_DIR")]"
    printf 'not json' > "$MODELS_FILE"; : > "$TICK_LOG"; _pids=""
    gives ioa resolve_models_openai
    gives ioc resolve_models_opencode
    wait $_pids
    [ "$(cat "$MODELS_FILE")" = "not json" ] && [ "$(gave ioa) $(gave ioc)" = "1|bounded 1|bounded" ] \
      && ! grep -q reseeded "$tmp/mw/ioa.out" "$tmp/mw/ioc.out" \
      && ok "nor an unreadable one reseeded" \
      || bad "an unreadable file under a held lock: $(gave ioa) $(gave ioc), now [$(cat "$MODELS_FILE")], printed [$(cat "$tmp/mw/ioa.out" "$tmp/mw/ioc.out")]"

    # A write holds the lock a moment, so one older than LOCK_GRACE_SECONDS is
    # no write, whoever it names -- stopped, a subshell gone under a parent
    # whose pid it recorded, a pid reissued. It is taken, and tick.log says
    # from whom, or every writer after it would give up for good and the
    # whole pass would stay due.
    "$JQ" -n --argjson now "$(now_epoch)" '{resolved:{}, openai:{at:$now, models:[]}, opencode:{at:$now, models:[]}}' > "$MODELS_FILE"
    : > "$TICK_LOG"; touch -t 202001010000 "$LOCK_DIR/.models.lock"; t0="$(now_epoch)"
    models_cache_set haiku claude-haiku-4-5; rc=$?; el=$(( $(now_epoch) - t0 ))
    [ "$rc" = 0 ] && [ "$el" -le 1 ] && "$JQ" -e '.resolved.haiku.id == "claude-haiku-4-5"' "$MODELS_FILE" >/dev/null 2>&1 \
      && [ ! -e "$LOCK_DIR/.models.lock" ] && [ "$(lines | grep -c .)" = 1 ] \
      && lines | grep -q "^models: haiku — took over the lock on models.json from pid $_holder, held for [0-9]* s$" \
      && ok "a lock older than LOCK_GRACE_SECONDS is taken at once, even from a live pid, with a line in tick.log, and dropped after the write" \
      || bad "an old lock with a live holder: rc=$rc in ${el}s, locks [$(ls -A "$LOCK_DIR")] tick.log [$(lines)]"
    kill "$_holder" 2>/dev/null; wait "$_holder" 2>/dev/null
    mkdir "$LOCK_DIR/.models.lock"; echo "$_holder" > "$LOCK_DIR/.models.lock/pid"; boot_id > "$LOCK_DIR/.models.lock/boot"
    : > "$TICK_LOG"; t0="$(now_epoch)"
    models_cache_set opus claude-opus-5-5; rc=$?; el=$(( $(now_epoch) - t0 ))
    [ "$rc" = 0 ] && [ "$el" -le 1 ] && "$JQ" -e '.resolved.opus.id == "claude-opus-5-5"' "$MODELS_FILE" >/dev/null 2>&1 \
      && [ ! -e "$LOCK_DIR/.models.lock" ] && [ ! -s "$TICK_LOG" ] \
      && ok "a young lock whose holder is gone is taken at once too" \
      || bad "after the holder died: rc=$rc in ${el}s, locks [$(ls -A "$LOCK_DIR")] tick.log [$(lines)] $(cat "$MODELS_FILE")"

    # A writer killed between taking the lock and writing its pid leaves a lock
    # with no owner to ask: older than LOCK_GRACE_SECONDS it goes like any old
    # one, while a younger one may be a writer inside that very gap, and is
    # waited for and given up on like a live one.
    mkdir "$LOCK_DIR/.models.lock"; touch -t 202001010000 "$LOCK_DIR/.models.lock"
    : > "$TICK_LOG"; t0="$(now_epoch)"
    models_cache_set fable claude-fable-5-1; rc=$?; el=$(( $(now_epoch) - t0 ))
    [ "$rc" = 0 ] && [ "$el" -le 1 ] && "$JQ" -e '.resolved.fable.id == "claude-fable-5-1"' "$MODELS_FILE" >/dev/null 2>&1 \
      && [ ! -e "$LOCK_DIR/.models.lock" ] && [ "$(lines | grep -c .)" = 1 ] \
      && lines | grep -q "^models: fable — took over the lock on models.json from a writer that never wrote its pid, held for [0-9]* s$" \
      && ok "an old lock left with no pid is taken at once" \
      || bad "an abandoned lock with no pid: rc=$rc in ${el}s, locks [$(ls -A "$LOCK_DIR")] tick.log [$(lines)] $(cat "$MODELS_FILE")"
    mkdir "$LOCK_DIR/.models.lock"; _before="$(cksum < "$MODELS_FILE")"; : > "$TICK_LOG"; _pids=""
    gives young models_cache_set fable claude-fable-5-2
    wait $_pids
    [ "$(gave young)" = "1|bounded" ] && [ "$(cksum < "$MODELS_FILE")" = "$_before" ] \
      && [ "$(lines)" = "models: fable — gave up writing claude-fable-5-2: another writer held the lock on models.json for more than 1 s" ] \
      && ok "a young one is given up on, never taken from a writer that has yet to write its pid" \
      || bad "a fresh lock with no pid: $(gave young), tick.log [$(lines)]"

    # A writer that stalls past the grace loses the lock to the next one, as
    # above. When it comes back it must neither move its file over the one
    # written since, nor drop a lock that another writer holds by then.
    rm -rf "$LOCK_DIR/.models.lock"; : > "$TICK_LOG"
    sleep 60 >/dev/null 2>&1 & _holder=$!
    got="$(
      models_lock opus claude-opus-9 || exit 9
      touch -t 202001010000 "$LOCK_DIR/.models.lock"
      ( models_cache_set haiku claude-haiku-4-6 )
      mkdir "$LOCK_DIR/.models.lock"; echo "$_holder" > "$LOCK_DIR/.models.lock/pid"; boot_id > "$LOCK_DIR/.models.lock/boot"
      _models_rmw --arg id claude-opus-9 '.resolved.opus = {id:$id, at:1}'; echo "rmw=$?"
      models_unlock
      echo "lock=$(cat "$LOCK_DIR/.models.lock/pid" 2>/dev/null)"
    )"
    [ "$got" = "$(printf 'rmw=1\nlock=%s' "$_holder")" ] \
      && "$JQ" -e '.resolved.haiku.id == "claude-haiku-4-6" and .resolved.opus.id != "claude-opus-9"' "$MODELS_FILE" >/dev/null 2>&1 \
      && [ "$(seen "models: opus — gave up writing claude-opus-9: its lock went to another writer while it held it")" = 1 ] \
      && ok "a writer that lost its lock that way writes nothing when it comes back, and leaves the new holder its lock" \
      || bad "a writer robbed of its lock: [$got], $(cat "$MODELS_FILE"), tick.log [$(lines)]"
    kill "$_holder" 2>/dev/null; wait "$_holder" 2>/dev/null
    rm -rf "$LOCK_DIR/.models.lock"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_mwout" | grep -v '^RESULT '
  printf '%s\n' "$_mwout" | grep -qx 'RESULT ok=18 bad=0' \
    && ok "models_lock over scratch writers: all 18 assertions reach the gate" \
    || bad "models_lock over scratch writers did not: $(printf '%s\n' "$_mwout" | tail -1)"

  echo "bind_session() — one shot, atomic, and a no-op without a run dir"
  mkdir -p "$tmp/rd1"
  bind_session "$tmp/rd1" "$tmp/s1.ndjson"
  [ "$(cat "$tmp/rd1/.session" 2>/dev/null)" = "sess-abc123" ] \
    && ok "it writes the session it found" || bad "wrote '$(cat "$tmp/rd1/.session" 2>/dev/null)'"
  # A later transcript must not move a binding that already exists: the run dir
  # belongs to the session that claimed it.
  bind_session "$tmp/rd1" "$tmp/s4.ndjson"
  [ "$(cat "$tmp/rd1/.session" 2>/dev/null)" = "sess-abc123" ] \
    && ok "a second call never rebinds it" || bad "the binding moved"
  [ -z "$(ls "$tmp/rd1"/.session.* 2>/dev/null)" ] \
    && ok "and leaves no temp file behind" || bad "a .session.* temp survived"
  mkdir -p "$tmp/rd2"
  bind_session "$tmp/rd2" "$tmp/s3.ndjson"
  [ ! -f "$tmp/rd2/.session" ] \
    && ok "a transcript with no session writes no file at all" || bad "bound an empty session"
  bind_session "" "$tmp/s1.ndjson"
  want "an empty run dir is a no-op, not a write to /.session" 0 $?
  [ ! -f "/.session" ] && ok "and nothing landed at the filesystem root" || bad "wrote /.session"

  echo "run_launch_and_watch() — the session is bound from BOTH call sites, not just the loop"
  # A structural assertion, deliberately. The two calls look interchangeable to
  # anyone reading them without the timing context, so the realistic way this
  # regresses is somebody deleting the second as a duplicate — and every
  # behavioural test here would still pass, because bind_session itself is
  # fine. What breaks is only which runs reach it: the polling one alone loses
  # every run that dies inside the 30s window, and the post-wait one alone
  # loses every run killed with -9. Both, or the guarantee is gone. Read from
  # run_launch_and_watch, where the launch and its watch live now: the
  # polling call is in its watchdog, the post-wait one right after `wait`.
  got="$(sed -n '/^run_launch_and_watch()/,/^}/p' "$BIN_DIR/agentloop" | grep -c 'bind_session "\$run_dir"')"
  [ "${got:-0}" -ge 2 ] \
    && ok "both bind_session call sites are still there ($got)" \
    || bad "run_launch_and_watch has $got bind_session call sites, expected 2 — see the plan for why each is load-bearing"

  echo "run_classify() — the undelivered-work rule runs LAST, and never on a stopped run"
  # A structural assertion, deliberately. run_job is never invoked directly
  # anywhere in this suite (it needs a mocked agent CLI, a real worktree, a
  # budget cap...), and wt_undelivered_work / undelivered_note are both already
  # exercised on their own, above, so a behavioural test of either would stay
  # green even after the regression this guards against. That regression is
  # precedence: every rule above this one guards on `status = success`, so a
  # future edit that moves it back above BUDGET LIMITED (to sit next to
  # UNDECLARED ENDING, which is where it lived before this was caught in
  # review) would silently disable both of them the moment it sets `warning` —
  # and a guard that let `stopped` through would overwrite an operator's
  # STOPPED record with a less informative one. Both are one-line edits that
  # look like harmless cleanup.
  local budget_at undelivered_at guard_line budget_n undelivered_n case_at
  # The classifier is run_classify now; the indentation the checks below rely
  # on (two spaces = a bare statement of the function's own body) is the same
  # there as it was in run_job.
  got="$(sed -n '/^run_classify()/,/^}/p' "$BIN_DIR/agentloop")"
  # -c (a count), not just -n | head -1: a SECOND "BUDGET LIMITED:" or a
  # duplicated call site would make head -1 silently anchor on whichever
  # comes first, and the ordering compare below would pass or fail on the
  # wrong pair of lines without ever saying so.
  budget_n="$(printf '%s\n' "$got" | grep -c 'BUDGET LIMITED:')"
  undelivered_n="$(printf '%s\n' "$got" | grep -c 'wt_undelivered_work "\$run_dir"')"
  budget_at="$(printf '%s\n' "$got" | grep -n 'BUDGET LIMITED:' | head -1 | cut -d: -f1)"
  undelivered_at="$(printf '%s\n' "$got" | grep -n 'wt_undelivered_work "\$run_dir"' | head -1 | cut -d: -f1)"
  [ "${budget_n:-0}" -eq 1 ] && [ "${undelivered_n:-0}" -eq 1 ] && [ "$undelivered_at" -gt "$budget_at" ] \
    && ok "the rule sits after BUDGET LIMITED, not before it (line $undelivered_at vs $budget_at)" \
    || bad "undelivered-work rule x$undelivered_n at line ${undelivered_at:-?}, BUDGET LIMITED x$budget_n at ${budget_at:-?} — expected exactly one of each, with the rule after"
  # Trimmed and compared for EXACT equality, not globbed: a suffix pattern
  # like *'success|warning)' also matches `stopped|success|warning)` — `*`
  # absorbs the prepended "stopped|" just as happily as it absorbs nothing —
  # so a case that let `stopped` back in by being listed FIRST would still
  # read as `ok`. Only an exact compare catches every position it could be
  # inserted at, not just appended.
  #
  # Semantic anchor, not positional: find THIS rule's own case statement by
  # its exact, anchored text -- two leading spaces, nothing after `in`, no
  # trailing comment marker -- rather than a bare substring search. A bare
  # substring match on `case "$status" in` is not safe here: this very
  # function now carries several COMMENTS that quote that exact pattern in
  # prose (the paragraph right above this one, for a start), and a search
  # that cannot tell code from a comment describing that code finds whichever
  # sits closer, silently reading the wrong text as the guard. Anchoring on
  # the real statement's own shape sidesteps that regardless of how many
  # comments discuss it or where they sit.
  case_at="$(printf '%s\n' "$got" | grep -n '^  case "\$status" in$' | head -1 | cut -d: -f1)"
  guard_line="$(printf '%s\n' "$got" | sed -n "$((case_at + 1))p" \
                  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "${case_at:-}" ] && [ "$guard_line" = "success|warning)" ] \
    && ok "and its guard covers success/warning only, never a stopped run" \
    || bad "the line after the status case reads '$guard_line', not exactly 'success|warning)'"
  # The regression this task's own self-review caught: wt_undelivered_work
  # has to be CHECKED for every status, not only inside the success/warning
  # arm above, or the .ended gate reads an error/stopped run's undelivered
  # work as empty without ever having asked -- and force-removes a tree that
  # may hold exactly the uncommitted work this mechanism exists to protect.
  # Confirmed by ORDER: the check has to sit BEFORE the status guard, not
  # nested inside it, so it runs unconditionally.
  [ -n "${undelivered_at:-}" ] && [ -n "${case_at:-}" ] && [ "$undelivered_at" -lt "$case_at" ] \
    && ok "undelivered is checked before the status guard, not nested inside it" \
    || bad "the undelivered check (line ${undelivered_at:-?}) is not before the status guard (line ${case_at:-?}) -- it may be gated to success/warning again, leaving error/stopped unchecked"

  echo "run_classify() — .ended is decided by declared_ending + undelivered, not by status"
  # Structural, like the two checks just above: run_job cannot be exercised
  # end-to-end here without a mocked agent CLI, so the only thing that can
  # catch a revert of finding 9.3 is reading the text. The regression this
  # guards is reverting to `case "$status" in success) done ;; *) open ;;
  # esac` -- a SMALLER, more innocent-looking diff than what replaced it, and
  # every behavioural test in this file would stay green: nothing here drives
  # run_job far enough to write a real .ended file.
  ended_body="$(sed -n '/^run_classify()/,/^}/p' "$BIN_DIR/agentloop")"
  got="$(printf '%s\n' "$ended_body" \
          | grep -c '\[ "\$declared_ending" = "true" \] && \[ -z "\${undelivered:-}" \]')"
  [ "${got:-0}" -eq 1 ] \
    && ok "the .ended gate reads declared_ending and undelivered ($got)" \
    || bad "run_classify's .ended gate no longer tests declared_ending+undelivered (matched $got times)"
  # declared_ending itself has to be computed UNCONDITIONALLY, not only while
  # status is still success (the shape it had before 9.3, when it fed only the
  # UNDECLARED ENDING warning). Gating it on status would make it silently
  # false for every run this classifier calls `warning` -- stray stderr, an
  # empty result, NOTHING TO DO -- which is exactly the case 9.3 exists to
  # stop losing: a warning run that DID say how it ended. Checked by exact
  # indentation: two spaces means a bare statement in run_classify's own body: put
  # back inside `if [ "$status" = "success" ]`, it would indent four.
  [ "$(printf '%s\n' "$ended_body" | grep -c '^  declared_ending=false$')" -eq 1 ] \
    && ok "declared_ending=false is a bare statement, not nested inside a status guard" \
    || bad "declared_ending's assignment is no longer an unconditional top-level statement"

  echo "run_job's parts — every RJ_* is assigned on its owner's first line, and nothing else goes back"
  # Structural, like the three above, and it guards the ONE defect taking
  # run_job apart can introduce. Its three parts (run_refusals,
  # run_launch_and_watch, run_classify) hand their results back as RJ_*
  # globals. A global a function reads without having assigned it first
  # carries whatever an earlier call in the same shell left there -- nothing
  # loops run_job in one shell today (cmd_tick detaches each run), and the
  # rule is what keeps that from ever mattering: every RJ_* a function
  # mentions is assigned on its FIRST line, before any path can return.
  # And the parts read run_job's locals through dynamic scope, so the other
  # way to smuggle a result out is to assign one of those locals from
  # inside -- an interface nobody can see from the call site. Every name a
  # part assigns is therefore either its own `local` or an RJ_*.
  local _rj_fn _rj_body _rj_first _rj_v _rj_bad _rj_locals _rj_mine _rj_writes
  _rj_locals="$(sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop" \
    | grep -E '^[[:space:]]*local ' | sed -E 's/^[[:space:]]*local (-a )?//' \
    | tr ' ' '\n' | sed -E 's/=.*//' | grep -E '^[a-z_][a-z0-9_]*$' | sort -u)"
  for _rj_fn in run_refusals run_launch_and_watch run_classify; do
    _rj_body="$(sed -n "/^$_rj_fn()/,/^}/p" "$BIN_DIR/agentloop")"
    [ -n "$_rj_body" ] || { bad "$_rj_fn is not in the engine"; continue; }
    _rj_first="$(printf '%s\n' "$_rj_body" | sed -n 2p)"
    _rj_bad=""
    for _rj_v in $(printf '%s\n' "$_rj_body" | grep -oE 'RJ_[A-Z_]+' | sort -u); do
      case "$_rj_first" in *"$_rj_v="*) ;; *) _rj_bad="$_rj_bad $_rj_v" ;; esac
    done
    [ -z "$_rj_bad" ] \
      && ok "$_rj_fn assigns every RJ_* it mentions on its first line" \
      || bad "$_rj_fn mentions$_rj_bad without assigning it on its first line — a value could carry over from an earlier call in the same shell"
    # The names it declares itself, subshells included (`) & local x=$!`).
    _rj_mine="$(printf '%s\n' "$_rj_body" | grep -E '^[[:space:]]*(\) & )?local ' \
      | sed -E 's/^[[:space:]]*(\) & )?local (-a )?//' | tr ' ' '\n' | sed -E 's/=.*//' \
      | grep -E '^[a-z_][a-z0-9_]*$' | sort -u)"
    # The names it assigns: at a line's start, or after `; `, `&& `, `|| `,
    # `then `, `else ` on the same line.
    _rj_writes="$(printf '%s\n' "$_rj_body" \
      | grep -oE '(^[[:space:]]*|; |&& |\|\| |then |else )[a-z_][a-z0-9_]*\+?=' \
      | sed -E 's/^.*[[:space:]]//; s/\+?=$//' | sort -u)"
    _rj_bad=""
    for _rj_v in $_rj_writes; do
      printf '%s\n' "$_rj_locals" | grep -qx "$_rj_v" || continue   # not a run_job local
      printf '%s\n' "$_rj_mine"   | grep -qx "$_rj_v" && continue   # its own, shadowing
      _rj_bad="$_rj_bad $_rj_v"
    done
    [ -z "$_rj_bad" ] \
      && ok "$_rj_fn assigns none of run_job's locals behind its back" \
      || bad "$_rj_fn assigns$_rj_bad — run_job's own local(s), through dynamic scope: an interface no call site shows"
  done
  # The three are called, and in the order the run has always gone: refuse,
  # launch, classify.
  _rj_body="$(sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop")"
  [ "$(printf '%s\n' "$_rj_body" | grep -E '^  (run_refusals |run_launch_and_watch |run_classify$)' \
        | sed -E 's/^ *//; s/ .*//' | tr '\n' ' ')" = "run_refusals run_launch_and_watch run_classify " ] \
    && ok "run_job calls the three, once each, in that order" \
    || bad "run_job's calls read: $(printf '%s\n' "$_rj_body" | grep -E '^  (run_refusals |run_launch_and_watch |run_classify$)' | tr '\n' ' ')"

  echo "run_refusals() — the account's gates sit after Settings' own and before the CLI is asked"
  local _rfb _rfo
  _rfb="$(sed -n '/^run_refusals()/,/^}/p' "$BIN_DIR/agentloop")"
  # Which gate each line is, in the order the lines come: a gate moved ahead
  # of Settings' own, or behind the readiness probe, changes this sequence.
  _rfo="$(printf '%s\n' "$_rfb" | awk '
    /no model is enabled for/ { print "nomodel" }
    /OpenCode has no accounts/ { print "opencode" }
    /is not an account of/ { print "unknown" }
    /is missing its directory/ { print "missing" }
    /platform_ready "\$platform" "\$account" "\$account_dir"/ { print "ready" }' | tr '\n' ' ')"
  [ "$_rfo" = "nomodel opencode unknown missing ready " ] \
    && ok "no model -> OpenCode -> unknown account -> missing directory -> the account's own readiness, in that order" \
    || bad "gate order: $_rfo"
  : > "$tmp/acct-runs.ndjson"
  ( RUNS_FILE="$tmp/acct-runs.ndjson"; LOCK_DIR="$tmp"
    record_run j1 success 1 2 0 1 sess-a /x.json "" false "" P opus claude-opus-5 "" "" anthropic reported null client-a /x/.claude-a
    record_run j2 success 1 2 0 1 sess-b /y.json "" false "" P opus claude-opus-5 "" "" anthropic reported null )
  [ "$( RUNS_FILE="$tmp/acct-runs.ndjson"; journal_account_of_session sess-a | tr '\037' '|' )" = "client-a|/x/.claude-a" ] \
    && [ -z "$( RUNS_FILE="$tmp/acct-runs.ndjson"; journal_account_of_session sess-b )" ] \
    && ok "record_run keeps the account and its directory; a record without them says nothing" \
    || bad "journal: $(cat "$tmp/acct-runs.ndjson")"
  ( env -u CLAUDE_CONFIG_DIR AGENTLOOP_CONFIG="$tmp/acexp/config" AGENTLOOP_DATA="$tmp/acexp/data" \
      bash -c '. "$1" --help >/dev/null 2>&1; CLAUDE_CONFIG_DIR=/pin; export CLAUDE_CONFIG_DIR
      account_export anthropic ""; printf "%s|" "${CLAUDE_CONFIG_DIR-<unset>}"
      account_export anthropic /x/a; printf "%s" "$CLAUDE_CONFIG_DIR"' _ "$SELF" ) > "$tmp/acct-export.out" 2>/dev/null
  [ "$(cat "$tmp/acct-export.out")" = "<unset>|/x/a" ] \
    && ok "account_export: the CLI's own directory unsets the variable, even over a pin; any other sets it" \
    || bad "account_export: $(cat "$tmp/acct-export.out")"

  echo "cpu_tree_sum() — a busy tool tree is proof of life, not a stall"
  # A run whose agent is quiet because a test suite is grinding away in a child
  # (shell -> make -> pytest) must read as ALIVE. This is the case that got a
  # healthy run killed at the stall timeout for running the tests it was told to.
  printf '%s\n' '100 1 00:10' '200 100 05:00' '300 200 10:00' '999 1 99:00' > "$tmp/ps.txt"
  local cpu
  cpu="$(cpu_tree_sum 100 < "$tmp/ps.txt")"   # 10s + 300s + 600s
  [ "$cpu" = "910" ] && ok "whole descendant tree counted ($cpu s)" \
                     || bad "tree cpu wrong: got '$cpu', want 910"
  # An unrelated process's CPU must never keep a genuinely hung run alive.
  cpu="$(cpu_tree_sum 999 < "$tmp/ps.txt")"
  [ "$cpu" = "5940" ] && ok "an unrelated tree is not counted in" \
                      || bad "isolation broke: got '$cpu', want 5940"
  # Children are not guaranteed to be listed after their parents.
  printf '%s\n' '300 200 10:00' '200 100 05:00' '100 1 00:10' > "$tmp/ps2.txt"
  cpu="$(cpu_tree_sum 100 < "$tmp/ps2.txt")"
  [ "$cpu" = "910" ] && ok "descendants found regardless of ps order" \
                     || bad "ordering broke: got '$cpu', want 910"
  # [dd-]hh:mm:ss must not be read as mm:ss — a day of CPU is not 0 seconds.
  printf '%s\n' '100 1 1-02:03:04' > "$tmp/ps3.txt"
  cpu="$(cpu_tree_sum 100 < "$tmp/ps3.txt")"
  [ "$cpu" = "93784" ] && ok "dd-hh:mm:ss parsed ($cpu s)" \
                       || bad "day-form parse wrong: got '$cpu', want 93784"
  # A dead or absent pid burns nothing — it must never look busy.
  cpu="$(cpu_tree_sum 4242 < "$tmp/ps.txt")"
  [ "$cpu" = "0" ] && ok "an absent pid reports no CPU" || bad "absent pid: got '$cpu'"
  cpu="$(num "$(tree_cpu_seconds '')")"
  [ "$cpu" = "0" ] && ok "an empty pid reports no CPU" || bad "empty pid: got '$cpu'"

  echo "the run-ending contract ships with the CODE, not with a personal jobs.json"
  # The classifier demands a marker. If the contract that teaches it lives only in
  # one person's (gitignored) jobs.json, everyone else clones a scheduler that
  # files every run as a warning. So injection must reach a prompt that has never
  # heard of it, and must not double up on one that has.
  inject() { # inject <prompt> -> the prompt as the agent will receive it
    case "$1" in
      *"$RUN_ENDING_MARKER"*) printf '%s' "$1" ;;
      *) printf '%s\n\n%s' "$1" "$(run_ending_contract)" ;;
    esac
  }
  local plain injected twice
  plain="Do the thing."
  injected="$(inject "$plain")"
  case "$injected" in *"RUN COMPLETE:"*) ok "a bare prompt receives the contract" ;;
    *) bad "a bare prompt did NOT receive the contract" ;; esac
  case "$injected" in "$plain"*) ok "the job's own prompt is kept, not replaced" ;;
    *) bad "the job's prompt was lost" ;; esac
  twice="$(inject "$injected")"
  [ "$twice" = "$injected" ] && ok "injection is idempotent (no double contract)" \
                             || bad "injection duplicated the contract"
  # And the marker the classifier looks for must be the one the contract teaches:
  # if these two ever drift, every run is a warning and nothing says why.
  case "$(run_ending_contract)" in
    *"RUN COMPLETE:"*"NOTHING TO DO:"*"BLOCKED:"*) ok "contract names every marker the classifier accepts" ;;
    *) bad "contract and classifier disagree on the markers" ;;
  esac

  echo "workflow ids are resolved, never trusted"
  # The reviewer prompts carried ids that were correct FROM `Review - DEV` and
  # wrong from `In Review - DEV` -- and the precheck moves the card to the latter
  # before the session starts, so every closing transition used the wrong number.
  # The durable cure is in the contract every job receives: resolve by to.name.
  case "$(run_ending_contract)" in
    *"resolve it by name"*) ok "the contract tells every run to resolve ids by name" ;;
    *) bad "the contract never warns about hard-coded transition ids" ;;
  esac
  case "$(run_ending_contract)" in
    *"per SOURCE STATE"*) ok "and says WHY a correct id goes stale (source state)" ;;
    *) bad "the contract states the rule without the reason it exists" ;;
  esac

  echo "the changelog moves when main moves"
  # Other people run this scheduler on their own projects: a change they cannot
  # see the shape of is a change they cannot trust or adopt. Writing the entry
  # afterwards never happens, so the check is here -- if the code moved and
  # CHANGELOG.md did not, this fails while the reason is still known.
  if [ -e "$BASE_DIR/.git" ] && command -v git >/dev/null 2>&1; then
    local _code _log
    # --no-merges: a merge commit touches bin/ by definition, and is always newer
    # than the changelog entry that came in WITH the branch it merges. Counting it
    # made this fail after every single merge, with the entry correctly in place —
    # a check that cries wolf on a healthy repo is one people learn to ignore.
    _code="$(git -C "$BASE_DIR" log -1 --no-merges --format=%ct -- bin skills test 2>/dev/null)"
    _log="$(git -C "$BASE_DIR" log -1 --format=%ct -- CHANGELOG.md 2>/dev/null)"
    if [ -z "${_code:-}" ]; then
      ok "no committed code yet — nothing to describe"
    elif [ -z "${_log:-}" ]; then
      bad "CHANGELOG.md has never been committed, but bin/ has"
    elif [ "$_log" -ge "$_code" ]; then
      ok "CHANGELOG.md is at least as new as the last code commit"
    else
      bad "code moved after the last CHANGELOG.md entry — describe the change before pushing"
    fi
  else
    ok "not a git checkout — changelog freshness not checkable here"
  fi
  [ -f "$BASE_DIR/CHANGELOG.md" ] && ok "CHANGELOG.md exists" || bad "CHANGELOG.md is missing"

  echo "no tracked file carries anybody's home directory"
  # Sits with the changelog check because it is the same kind of gate: a
  # promise about what a CLONE receives, checkable only against git, and
  # useless if it is remembered rather than enforced. It is NOT a pytest:
  # tests/security/ is scoped to the security package and tests/test_page_
  # contract.py to the served HTML page, while the file that leaked here --
  # tests/security/fixtures/engines/syft-cyclonedx.json, a raw Syft capture
  # taken on a maintainer's laptop -- proves the exposure has no natural home
  # in the tree. Any file can carry it, so the check must read every tracked
  # file, and this function is already the place that does whole-repository
  # hygiene.
  #
  # THE RULE IS NOT "NO ABSOLUTE HOME PATHS". The Syft fixture has to keep the
  # SHAPE of one -- dropping that field is the entire point of
  # `adapters.syft_document`, and a fixture with the shape scrubbed out would
  # leave its test green over nothing. So a home path is fine as long as the
  # user in it is a placeholder, and the allowed placeholders are the ones
  # this repository already documents with: `me` (README.md's
  # `/Users/me/code/web`) and `Jane` (the worktree-prefix cases, which need a
  # home directory with a space in it), plus the generic `example`, `runner`
  # and `user`. Keep this list short — every name on it is a name the check
  # will not catch.
  if [ -e "$BASE_DIR/.git" ] && command -v git >/dev/null 2>&1; then
    local _homes _ok='|Jane|example|me|runner|user|'
    # -I so a committed binary is never scanned as text; no revision, so this
    # reads the tracked working tree -- exactly what a clone would get. The
    # allowlist is applied per OCCURRENCE, not per line: a line carrying both
    # a placeholder and a real home must still fail.
    _homes="$(git -C "$BASE_DIR" grep -nIE '/(Users|home)/[A-Za-z0-9._-]+' -- . 2>/dev/null \
              | awk -v ok="$_ok" '
                  { rest = $0
                    while (match(rest, /\/(Users|home)\/[A-Za-z0-9._-]+/)) {
                      hit = substr(rest, RSTART, RLENGTH)
                      sub(/^\/(Users|home)\//, "", hit)
                      if (index(ok, "|" hit "|") == 0) { print; next }
                      rest = substr(rest, RSTART + RLENGTH)
                    }
                  }' || true)"
    if [ -z "$_homes" ]; then
      ok "no tracked file names a real home directory"
    else
      bad "a tracked file carries someone's home directory — replace the user with one of:${_ok//|/ }"
      printf '%s\n' "$_homes" | sed 's/^/        /'
    fi
  else
    ok "not a git checkout — tracked paths not checkable here"
  fi

  echo "the security-analysis skill ships with the repo, not only in ~/.claude/skills"
  # security_prompt() makes this skill MANDATORY ("Invoke the
  # `security-analysis` skill and follow it exactly") -- a prompt that names a
  # skill the machine does not have is a prompt whose standards silently do
  # not apply. See the comment above SKILLS_DIR for why the skills this loop
  # depends on live here rather than only in the unversioned user directory.
  [ -f "$SKILLS_DIR/security-analysis/SKILL.md" ] \
    && ok "the security-analysis skill ships with the repo" \
    || bad "the security-analysis skill ships with the repo"
  grep -q 'security-analysis' "$SELF" \
    && ok "the prompt still names the security-analysis skill" \
    || bad "the prompt still names the security-analysis skill"

  echo "a human's board move is an answer, not an anomaly"
  # QG-15: the cap parked the ticket, the human moved it to the ready column, and
  # the next run read the spent rounds, decided the board was glitched, and put it
  # straight back in Blocked. The human's only lever moves it forward; the agent's
  # caution moved it back. Both halves of the cure must be present.
  case "$(run_ending_contract)" in
    *"a human's move is an answer"*|*"human decision"*) ok "the injected contract tells a run not to re-block a human's move" ;;
    *) bad "the contract never mentions the human-released case" ;;
  esac
  case "$(run_ending_contract)" in
    *"block only on something NEW"*) ok "and says what DOES still justify blocking" ;;
    *) bad "the contract removed blocking without saying when it is still right" ;;
  esac

  echo "a run that stops talking is not a run that finished"
  # The exact shape that filed an abandoned ticket as a clean success: a normal
  # result event whose text simply never claims the work is done.
  declared() { printf '%s' "$1" | grep -qE '(RUN COMPLETE|NOTHING TO DO|BLOCKED):'; }
  declared "I'll wait for the suite to finish and then commit."
  want "an agent promising to continue is NOT a finished run"        1 $?
  declared "RUN COMPLETE: QG-15 reworked, pushed, moved to Review - DEV."
  want "a declared completion is a finished run"                     0 $?
  declared "NOTHING TO DO: the board had no ready ticket."
  want "a declared no-op is accepted"                                0 $?
  declared "BLOCKED: QG-15 — needs a human decision on scope."
  want "a declared escalation is accepted"                           0 $?
  declared ""
  want "an empty final message is NOT a finished run"                1 $?

  echo "undelivered_note() — the note names what was left behind and how to continue"
  got="$(undelivered_note "unpushed commits in api")"
  case "$got" in
    "UNDELIVERED: unpushed commits in api."*)
      ok "it leads with the marker the dashboard matches on, then the finding" ;;
    *) bad "the note read '$got'" ;;
  esac
  case "$got" in
    *"resume this run"*) ok "and points at the one action that continues the work" ;;
    *) bad "the note never says how to continue: '$got'" ;;
  esac

  echo "killed runs report what they consumed"
  printf '%s\n' \
    '{"type":"system","subtype":"init","session_id":"s"}' \
    '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":2}}}' \
    > "$tmp/usage.ndjson"
  local got
  got="$("$JQ" -rn -R '[inputs | fromjson?] as $ev | [$ev[] | .message?.usage? // empty] as $u
    | "\([$u[].input_tokens // 0] | add // 0)/\([$u[].cache_read_input_tokens // 0] | add // 0)/\([$u[].output_tokens // 0] | add // 0)"' \
    "$tmp/usage.ndjson" 2>/dev/null)"
  [ "$got" = "10/100/2" ] && ok "token usage recovered from a stream ($got)" \
                          || bad "token usage wrong: got '$got', want 10/100/2"

  echo "a disabled job is never launched"
  [ "$(job_get __no_such_job__ '.enabled' 'true')" = "true" ] && ok "absent job defaults to enabled" || bad "default broke"
  printf '%s' '{"jobs":[{"id":"x","enabled":false}]}' > "$tmp/jobs.json"
  got="$("$JQ" -r '[.jobs[] | select(.id=="x") | .enabled] | .[0] as $v | (if $v == null then "true" else $v end) | tostring' "$tmp/jobs.json")"
  [ "$got" = "false" ] && ok "enabled:false reads as false (jq // would say true)" || bad "enabled:false read as '$got'"

  echo "wt_repos() — declared repos win, a bare cwd is the single-repo case"
  mkdir -p "$tmp/proj"
  printf '%s' '{"projects":[{"name":"multi","cwd":"/x/front","repos":[
      {"name":"front","path":"/x/front","base":"develop"},
      {"name":"back","path":"/x/back","base":"release"}]},
    {"name":"solo","cwd":"/x/solo"}]}' > "$tmp/proj/projects.json"
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; wt_repos multi /x/front | wc -l | tr -d ' ' )"
  [ "$got" = "2" ] && ok "a declared multi-repo project yields 2 rows" || bad "multi yielded '$got' rows"
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; wt_repos multi /x/front | sed -n '2p' )"
  [ "$got" = "$(printf 'back\t/x/back\trelease')" ] && ok "name/path/base survive the round trip" \
    || bad "second row was '$got'"
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; wt_repos solo /x/solo )"
  [ "$got" = "$(printf 'solo\t/x/solo\t')" ] && ok "no .repos[] synthesises one row from cwd" \
    || bad "solo row was '$got'"

  echo "wt_repos() — an analysis gets the one repo it names, never the others"
  # An analysis names ONE repository and a branch of it (AL_BASE_OVERRIDE), and
  # runs in that repository's checkout. Every declared row used to come back
  # here, so each repo was cut from the analysed branch -- a branch of one
  # repository need not exist in another, and one that lacked it aborted the
  # whole analysis -- and the report read whichever repo matched the PROJECT's
  # cwd rather than the one it named.
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; AL_BASE_OVERRIDE=feat/x wt_repos multi /x/back )"
  [ "$got" = "$(printf 'back\t/x/back\trelease')" ] \
    && ok "under an analysis's branch, only the repo the run is in" \
    || bad "an analysis of back was handed '$(printf '%s\n' "$got" | cut -f1 | tr '\n' ' ')'"
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; AL_BASE_OVERRIDE=feat/x wt_repos solo /x/solo )"
  [ "$got" = "$(printf 'solo\t/x/solo\t')" ] \
    && ok "and a single-repo project's synthesised row is that repo already" \
    || bad "a single-repo analysis was handed '$got'"

  echo "wt_base_ref() — declared base wins, then local, then HEAD"
  local gitc="git -c user.name=cc -c user.email=cc@local -c commit.gpgsign=false"
  mkdir -p "$tmp/g"
  git init -q --bare "$tmp/g/origin.git"
  git -c init.defaultBranch=develop init -q "$tmp/g/repo"
  ( cd "$tmp/g/repo" && echo hi > f && git add f && $gitc commit -qm init \
      && git remote add origin "$tmp/g/origin.git" && git push -q -u origin develop ) >/dev/null 2>&1
  got="$(wt_base_ref "$tmp/g/repo" develop)"
  [ "$got" = "origin/develop" ] && ok "a pushed base resolves to origin/<base>" || bad "got '$got'"
  ( cd "$tmp/g/repo" && git branch local-only ) >/dev/null 2>&1
  got="$(wt_base_ref "$tmp/g/repo" local-only)"
  [ "$got" = "local-only" ] && ok "a local-only base resolves to the local branch" || bad "got '$got'"
  got="$(wt_base_ref "$tmp/g/repo" no-such-branch)"
  [ "$got" = "HEAD" ] && ok "an unresolvable base falls back to HEAD" || bad "got '$got'"
  got="$(wt_base_ref "$tmp/g/repo" "")"
  [ "$got" = "origin/develop" ] && ok "an empty base is inferred from the current branch" || bad "got '$got'"

  echo "wt_base_ref() — a base pattern tracks the release train by itself"
  # A literal `release/0.9.0` is correct until 0.9.0 stops being current, and
  # then keeps cutting worktrees from an abandoned train with no symptom but
  # agents working on the wrong baseline. A pattern is written once.
  # Pushed to the ORIGIN, not faked as local remote-refs: wt_base_ref fetches
  # with --prune first, so a remote-tracking ref with no branch behind it is
  # deleted before it can be resolved — which is correct, and is also exactly
  # how a retired release train disappears on its own.
  ( cd "$tmp/g/repo"
    for v in 0.8.0 0.9.0 0.10.0; do git push -q origin "HEAD:refs/heads/release/$v"; done ) >/dev/null 2>&1
  got="$(wt_base_ref "$tmp/g/repo" 'release/*')"
  [ "$got" = "origin/release/0.10.0" ] \
    && ok "a base pattern resolves to the highest VERSION (0.10.0 > 0.9.0)" \
    || bad "pattern resolved to '$got', want origin/release/0.10.0"
  # The whole point: sorted as text, 0.9.0 beats 0.10.0 and the project silently
  # pins itself to the train it just left. This case is why --sort=-v:refname.
  got="$(git -C "$tmp/g/repo" for-each-ref --sort=-refname --count=1 \
          --format='%(refname:short)' 'refs/remotes/origin/release/*')"
  [ "$got" = "origin/release/0.9.0" ] \
    && ok "and text ordering would have picked 0.9.0 — the bug this avoids" \
    || bad "the text-order control did not reproduce: got '$got'"
  # A pattern that matches nothing must REFUSE, not fall through to HEAD:
  # falling through is exactly the silent-wrong-baseline failure being prevented.
  got="$(wt_base_ref "$tmp/g/repo" 'nosuch/*' 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$got" ] \
    && ok "a pattern matching nothing refuses instead of falling back to HEAD" \
    || bad "unmatched pattern returned '$got' (exit $rc) instead of refusing"
  # And a literal base must be unaffected by any of this.
  got="$(wt_base_ref "$tmp/g/repo" develop)"
  [ "$got" = "origin/develop" ] && ok "a literal base still resolves as before" || bad "got '$got'"

  echo "wt_base_ref() — a hung fetch cannot hold a run for ever"
  # The fetch runs inside wt_setup, i.e. AFTER the run has taken its slot and
  # BEFORE the watchdog exists — so a remote that accepts the connection and
  # then says nothing used to pin the slot indefinitely. With max_parallel=1
  # that is the job dead until a human notices.
  mkdir -p "$tmp/fakebin"
  printf '%s\n' '#!/bin/bash' \
    'for a in "$@"; do [ "$a" = fetch ] && { sleep 8; exit 0; }; done' \
    'exec /usr/bin/git "$@"' > "$tmp/fakebin/git"
  chmod +x "$tmp/fakebin/git"
  local t0 elapsed ref_got
  t0="$(now_epoch)"
  ref_got="$( PATH="$tmp/fakebin:$PATH"; wt_base_ref "$tmp/g/repo" develop 2 2>/dev/null )"
  elapsed=$(( $(now_epoch) - t0 ))
  [ "$elapsed" -lt 6 ] && ok "a stalled fetch is abandoned after the timeout (${elapsed}s)" \
    || bad "wt_base_ref waited ${elapsed}s for a hung fetch"
  [ "$ref_got" = "origin/develop" ] \
    && ok "the base still resolves from the refs already on disk" \
    || bad "after a timed-out fetch the base resolved to '$ref_got'"

  echo "wt_provision() — a missing hook is a no-op, a failing one is a failure"
  mkdir -p "$tmp/cfg/provision" "$tmp/run/repoA"
  ( CONFIG_DIR="$tmp/cfg"; PROJECTS_FILE="$tmp/proj/projects.json"
    wt_provision up nohooks j1 "$tmp/run" repoA /x/a "$tmp/run/repoA" develop ) >/dev/null 2>&1
  want "no script at all is a no-op" 0 $?
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "$AL_REPO_NAME" "$AL_BASE" > "$AL_WORKTREE/seen"' \
    > "$tmp/cfg/provision/hooked.up.sh"
  ( CONFIG_DIR="$tmp/cfg"; PROJECTS_FILE="$tmp/proj/projects.json"
    wt_provision up hooked j1 "$tmp/run" repoA /x/a "$tmp/run/repoA" develop ) >/dev/null 2>&1
  want "a passing hook returns 0" 0 $?
  got="$(cat "$tmp/run/repoA/seen" 2>/dev/null)"
  [ "$got" = "repoA develop" ] && ok "the hook sees AL_REPO_NAME and AL_BASE" || bad "hook saw '$got'"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$tmp/cfg/provision/broken.up.sh"
  ( CONFIG_DIR="$tmp/cfg"; PROJECTS_FILE="$tmp/proj/projects.json"
    wt_provision up broken j1 "$tmp/run" repoA /x/a "$tmp/run/repoA" develop ) >/dev/null 2>&1
  [ $? -ne 0 ] && ok "a failing hook reports failure" || bad "a failing hook reported success"

  echo "wt_setup() — one worktree per repo, a manifest, and an untouched canonical"
  git -c init.defaultBranch=develop init -q "$tmp/g/repo2"
  ( cd "$tmp/g/repo2" && echo hi > f && git add f && $gitc commit -qm init ) >/dev/null 2>&1
  printf '%s' '{"projects":[{"name":"two","cwd":"'"$tmp"'/g/repo","repos":[
      {"name":"one","path":"'"$tmp"'/g/repo","base":"develop"},
      {"name":"two","path":"'"$tmp"'/g/repo2","base":"develop"}]}]}' > "$tmp/proj/two.json"
  local rd="$tmp/wtroot/j2/stampA" prim
  prim="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
           wt_setup j2 two "$tmp/g/repo" stampA )"
  [ "$prim" = "$rd/one" ] && ok "the primary worktree is the repo matching .cwd" || bad "primary was '$prim'"
  [ -d "$rd/one" ] && [ -d "$rd/two" ] && ok "one worktree per declared repo" || bad "missing worktrees"
  got="$("$JQ" -r '.repos | length' "$rd/.run.json" 2>/dev/null)"
  [ "$got" = "2" ] && ok "the manifest lists both repos" || bad "manifest listed '$got'"
  got="$("$JQ" -r '.repos[0].fork_sha' "$rd/.run.json" 2>/dev/null)"
  [ "$got" = "$(git -C "$rd/one" rev-parse HEAD)" ] && ok "fork_sha matches the worktree's HEAD" \
    || bad "fork_sha was '$got'"
  got="$(git -C "$tmp/g/repo" symbolic-ref --short --quiet HEAD 2>/dev/null)"
  [ "$got" = "develop" ] && ok "the canonical checkout keeps its branch" || bad "canonical is on '$got'"

  echo "wt_setup() — a project that declares no repos still gets its one worktree"
  printf '%s' '{"projects":[{"name":"solo1","cwd":"'"$tmp"'/g/repo2"}]}' > "$tmp/proj/solo.json"
  prim="$( PROJECTS_FILE="$tmp/proj/solo.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
           wt_setup j9 solo1 "$tmp/g/repo2" stampS )"
  [ "$prim" = "$tmp/wtroot/j9/stampS/repo2" ] && ok "the single-repo path needs no .repos[]" \
    || bad "single-repo primary was '$prim'"
  got="$(wt_run_worktrees "$tmp/wtroot/j9/stampS" | wc -l | tr -d ' ')"
  [ "$got" = "1" ] && ok "exactly one worktree, named after the cwd" || bad "got $got worktrees"

  echo "wt_setup() — an analysis of the second repo is cut from its branch, and alone"
  # The run's cwd is the repo the analysis names (run_job, AL_SECURITY_REPO);
  # from here on that repo is the whole of the run. Before, every declared repo
  # was cut from the analysed branch, so a branch only the second repo has
  # aborted the analysis on the first -- "no base ref resolvable".
  ( cd "$tmp/g/repo2" && git checkout -q -b feat/only-two && echo two > g && git add g \
      && $gitc commit -qm two && git checkout -q develop ) >/dev/null 2>&1
  local rdN="$tmp/wtroot/jan/stampN"
  prim="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
           AL_BASE_OVERRIDE=feat/only-two wt_setup jan two "$tmp/g/repo2" stampN 2>/dev/null )"
  [ "$prim" = "$rdN/two" ] && ok "the run is in the repo the analysis named" \
    || bad "an analysis of repo two ran in '$prim'"
  [ -n "$prim" ] && [ "$(git -C "$rdN/two" rev-parse HEAD 2>/dev/null)" = "$(git -C "$tmp/g/repo2" rev-parse feat/only-two)" ] \
    && ok "cut from the branch it named, which the other repo does not have" \
    || bad "repo two's worktree is at '$(git -C "$rdN/two" rev-parse HEAD 2>/dev/null)'"
  [ -n "$prim" ] && [ ! -e "$rdN/one" ] \
    && [ "$("$JQ" -r '[.repos[].name] | join(",")' "$rdN/.run.json" 2>/dev/null)" = "two" ] \
    && ok "and nothing else is cut: the manifest lists that repo alone" \
    || bad "the manifest lists '$("$JQ" -r '[.repos[].name] | join(",")' "$rdN/.run.json" 2>/dev/null)'"
  if [ -d "$rdN" ]; then
    echo done > "$rdN/.ended"
    ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
      wt_teardown jan two "$rdN" ) >/dev/null 2>&1
  fi

  echo "wt_isolation_enabled() — an analysis is isolated even where runs are not"
  # An analysis reads the branch it names, and a worktree cut from that branch
  # is the only way to read it without touching the canonical checkout. With a
  # project's isolation off, the analysis ran in the checkout itself -- on
  # whatever branch was checked out there -- and the report was filed under the
  # commit of the branch it named. By job id, like every other rule about a
  # derived security job: a resume carries the id, and none of the run's env.
  printf '%s' '{"projects":[{"name":"flat","cwd":"'"$tmp"'/g/repo2","worktree":{"enabled":false}}]}' \
    > "$tmp/proj/flat.json"
  ( PROJECTS_FILE="$tmp/proj/flat.json"; wt_isolation_enabled flat "$tmp/g/repo2" j1 )
  want "an ordinary run of a project with isolation off stays in its checkout" 1 $?
  ( PROJECTS_FILE="$tmp/proj/flat.json"; wt_isolation_enabled flat "$tmp/g/repo2" security-flat )
  want "an analysis of that same project is isolated all the same" 0 $?
  # Structural: the rule is worth nothing if its one caller keeps asking the
  # question without the id. Captured, then matched: `sed | grep -q` under
  # pipefail fails on the SIGPIPE a match sends back up the pipe.
  local rjbody
  rjbody="$(sed -n '/^run_job() {/,/^}/p' "$SELF")"
  case "$rjbody" in
    *'wt_isolation_enabled "$project" "$cwd" "$id"'*) ok "and run_job asks it with the job's id" ;;
    *) bad "run_job asks wt_isolation_enabled without the job's id" ;;
  esac

  echo "wt_repos() — a single-repo project pins its base without declaring a repo"
  # The row it used to need was a copy of .cwd carrying one new field. Reading
  # .base directly is what lets the form stop asking for the path twice, which
  # is where a trailing slash used to creep in and orphan the primary.
  printf '%s' '{"projects":[{"name":"solo2","cwd":"'"$tmp"'/g/repo2","base":"develop"}]}' \
    > "$tmp/proj/solobase.json"
  got="$( PROJECTS_FILE="$tmp/proj/solobase.json"; wt_repos solo2 "$tmp/g/repo2" | cut -f3 )"
  [ "$got" = "develop" ] && ok "the project's .base reaches the synthesised row" \
    || bad "base came out '$got'"
  got="$( PROJECTS_FILE="$tmp/proj/solo.json"; wt_repos solo1 "$tmp/g/repo2" | cut -f3 )"
  [ -z "$got" ] && ok "a project declaring neither still infers, exactly as before" \
    || bad "an undeclared base came out '$got'"
  # .repos[] is the more specific statement, so it must not be quietly overruled
  # by a .base left behind from before the project grew a second repository.
  printf '%s' '{"projects":[{"name":"solo3","cwd":"'"$tmp"'/g/repo2","base":"develop","repos":[
      {"name":"repo2","path":"'"$tmp"'/g/repo2","base":"main"}]}]}' > "$tmp/proj/both.json"
  got="$( PROJECTS_FILE="$tmp/proj/both.json"; wt_repos solo3 "$tmp/g/repo2" | cut -f3 )"
  [ "$got" = "main" ] && ok "a declared repo's base still wins over the project's" \
    || bad "with both declared the base came out '$got'"

  echo "wt_setup() — a failing hook aborts, takes down what it built, leaves nothing"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$tmp/cfg/provision/two.up.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$AL_REPO_NAME" >> "$tmp_down_log"' \
    > "$tmp/cfg/provision/two.down.sh"
  export tmp_down_log="$tmp/abort-down.log"; : > "$tmp_down_log"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampB ) >/dev/null 2>&1
  want "a failing up aborts the setup" 1 $?
  [ ! -d "$tmp/wtroot/j2/stampB" ] && ok "the run dir is gone after a rollback" || bad "run dir survived"
  got="$(sort -u "$tmp_down_log" 2>/dev/null | tr '\n' ' ')"
  [ "$got" = "one two " ] && ok "down ran for what had been built before the abort" \
    || bad "abort ran down for '$got'"
  unset tmp_down_log
  rm -f "$tmp/cfg/provision/two.up.sh" "$tmp/cfg/provision/two.down.sh"

  echo "wt_teardown() — a finished session's dir goes, whatever is in it"
  printf '%s\n' '#!/usr/bin/env bash' 'echo down >> "$AL_RUN_DIR/../down.count"' \
    > "$tmp/cfg/provision/two.down.sh"
  chmod +x "$tmp/cfg/provision/two.down.sh"
  rm -f "$tmp/wtroot/j2/down.count"
  local rd2="$tmp/wtroot/j2/stampC"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampC ) >/dev/null 2>&1
  echo "work nobody else has" > "$rd2/one/agent.txt"
  echo done > "$rd2/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_teardown j2 two "$rd2" ) >/dev/null 2>&1
  [ ! -d "$rd2" ] \
    && ok "a done session is removed even holding work on no remote" \
    || bad "a done session's dir survived"
  got="$(wc -l < "$tmp/wtroot/j2/down.count" 2>/dev/null | tr -d ' ')"
  [ "${got:-0}" -eq 2 ] && ok "down ran once per repo" || bad "down ran $got times for 2 repos"

  echo "wt_teardown() — an open session is kept, and its down is NOT run"
  rm -f "$tmp/wtroot/j2/down.count"
  local rd5="$tmp/wtroot/j2/stampO"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampO ) >/dev/null 2>&1
  echo open > "$rd5/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_teardown j2 two "$rd5" ) >/dev/null 2>&1
  [ -d "$rd5" ] && ok "an open session keeps its tree" || bad "an open session was removed"
  [ ! -f "$tmp/wtroot/j2/down.count" ] \
    && ok "and its services are left up for the resume" \
    || bad "down tore down a session that is still open"

  echo "wt_teardown() — a dir with no marker is KEPT, because a crash writes none"
  # The discriminating half of this task, and the one that can destroy work if
  # it is wrong. A SIGKILL or a reboot runs no EXIT trap: no marker is written,
  # AND the classifier never fires, so the UNDELIVERED report that justifies
  # deleting a tree never happens either. The fixture therefore carries real
  # work — an empty dir would be reclaimed by any implementation and would
  # prove nothing.
  local rd6="$tmp/wtroot/j2/stampN"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampN ) >/dev/null 2>&1
  echo "work only this tree has" > "$rd6/one/agent.txt"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_teardown j2 two "$rd6" ) >/dev/null 2>&1
  [ -d "$rd6" ] && ok "a run killed before it could mark anything keeps its work" \
    || bad "an unmarked dir was deleted — a reboot would take every in-flight run with it"
  # And once it IS marked done, the same work is no obstacle: it was reported.
  echo done > "$rd6/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_teardown j2 two "$rd6" ) >/dev/null 2>&1
  [ ! -d "$rd6" ] && ok "and a done session goes even holding work on no remote" \
    || bad "a done session was kept"
  rm -f "$tmp/cfg/provision/two.down.sh" "$tmp/wtroot/j2/down.count"

  echo "wt_find_by_session() — a session's directory is found again by its id"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jR two "$tmp/g/repo" stampS1 ) >/dev/null 2>&1
  echo "sess-xyz" > "$tmp/wtroot/jR/stampS1/.session"
  echo open       > "$tmp/wtroot/jR/stampS1/.ended"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_find_by_session jR sess-xyz )"
  [ "$got" = "$tmp/wtroot/jR/stampS1" ] && ok "the open session's dir is found" \
    || bad "found '$got'"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_find_by_session jR sess-nope )"
  [ -z "$got" ] && ok "an unknown session finds nothing" || bad "found '$got'"
  # Two things have to be true for this to test anything.
  #
  # Asked BEFORE jR closes its session, while stampS1 is still open and would
  # be a real match for jR. Asked afterwards, a lookup that ignored the job id
  # and searched every job's directory would ALSO find nothing here -- by then
  # nothing open exists anywhere for it to wrongly return -- and this assertion
  # would pass whether or not job scoping was implemented at all.
  #
  # And jOther's directory has to EXIST. If it does not, `wt_find_by_session`'s
  # own `[ -d "$WORKTREES_DIR/$id" ]` early return is what answers empty, and a
  # DIFFERENT bug -- a scoping check that lets the id through but then globs
  # every job's directory instead of just this one's -- would never even be
  # reached, let alone caught.
  mkdir -p "$tmp/wtroot/jOther"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_find_by_session jOther sess-xyz )"
  [ -z "$got" ] && ok "another job's session is never returned" || bad "found '$got'"
  # A SIGKILL, an OOM kill or a reboot writes NO marker at all -- no EXIT trap
  # ever runs, so `.ended` is never created. `.session` is still there (the
  # watchdog binds it on its first pass, long before a run could reach an
  # ending), so this directory is exactly the one a resume most needs back.
  # wt_teardown, wt_prune_orphans, run_cleanup and the server's expires_in all
  # already read "absent" as open; this function alone demanded the literal
  # string "open" and refused it, so the resume fell through to a fresh
  # worktree instead -- silently: the tick log said "isolated in", never
  # "resumed ... in its own tree", so nothing anywhere recorded that a
  # session had been dropped.
  rm -f "$tmp/wtroot/jR/stampS1/.ended"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_find_by_session jR sess-xyz )"
  [ "$got" = "$tmp/wtroot/jR/stampS1" ] \
    && ok "a session with NO .ended marker (kill -9 / OOM / reboot) is still offered back" \
    || bad "an unmarked session was refused -- found '$got'"
  echo done > "$tmp/wtroot/jR/stampS1/.ended"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_find_by_session jR sess-xyz )"
  [ -z "$got" ] && ok "a session already closed is not offered back" || bad "found '$got'"
  rm -rf "$tmp/wtroot/jR" "$tmp/wtroot/jOther"

  echo "run_job() — a reattach claims its tree under a lock, check before write"
  # Structural, deliberately, like the bind_session call-site count above:
  # run_job cannot be exercised end-to-end without mocking the agent CLI, so
  # neither of these has a behavioural test in this file. What actually proves
  # two concurrent resumes cannot both proceed is the real two-process race
  # below, against the live lock_take/wt_is_claimed; this only guards against
  # run_job's own inline code silently reordering the three away from each
  # other, or the primary-name guard regressing to a bare directory check.
  body="$(sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop")"
  lt_line="$(printf '%s\n' "$body" | grep -n 'lock_take "\$rlock"'                  | head -1 | cut -d: -f1)"
  wc_line="$(printf '%s\n' "$body" | grep -n 'wt_is_claimed "\$id" "\$run_dir"'     | head -1 | cut -d: -f1)"
  wr_line="$(printf '%s\n' "$body" | grep -n 'echo "\$run_dir" > "\$slot/worktree"' | head -1 | cut -d: -f1)"
  # Both exits from the locked region have to drop it: the refusal path drops
  # BETWEEN the check and the write (it never reaches the write at all), and
  # the fall-through path drops AFTER it. Missing either leaks $LOCK_DIR/.resume
  # -- bounded (lock_take's own stale-owner recovery frees it once the holding
  # pid exits) but every OTHER resume serialises behind this one in the
  # meantime, which the line-order check above cannot see: deleting a
  # lock_drop leaves lt_line/wc_line/wr_line untouched and passes it clean.
  ld_lines="$(printf '%s\n' "$body" | grep -n 'lock_drop "\$rlock"' | cut -d: -f1)"
  ld1_line="$(printf '%s\n' "$ld_lines" | sed -n '1p')"
  ld2_line="$(printf '%s\n' "$ld_lines" | sed -n '2p')"
  if [ -n "${lt_line:-}" ] && [ -n "${wc_line:-}" ] && [ -n "${wr_line:-}" ] \
       && [ -n "${ld1_line:-}" ] && [ -n "${ld2_line:-}" ] \
       && [ "$lt_line" -lt "$wc_line" ] && [ "$wc_line" -lt "$wr_line" ] \
       && [ "$wc_line" -lt "$ld1_line" ] && [ "$ld1_line" -lt "$wr_line" ] \
       && [ "$wr_line" -lt "$ld2_line" ]; then
    ok "the lock is taken, the claim checked, and dropped on both exits -- the refusal and the claim -- in order"
  else
    bad "reattach claim ordering broken (lock=${lt_line:-?} check=${wc_line:-?} drop1=${ld1_line:-?} write=${wr_line:-?} drop2=${ld2_line:-?})"
  fi
  got="$(printf '%s\n' "$body" | grep -c '\[ -z "\$primary_name" \] ||')"
  [ "${got:-0}" -eq 1 ] \
    && ok "an empty manifest primary refuses the resume, not just a missing directory" \
    || bad "the primary-name emptiness guard is missing or duplicated (found $got)"
  # 9.9: deleting the line that COMPUTES reattached (leaving only
  # `local reattached=""`, which alone silences set -u) turns the whole
  # `if [ -n "$reattached" ]` branch into dead code -- every resume falls
  # through to the fresh-worktree path and Task 7 is gone, silently, with
  # every assertion above still reading text that is simply never reached at
  # runtime: the ordering check just above protects everything INSIDE that
  # branch, and says nothing about whether anything ever ENTERS it.
  got="$(printf '%s\n' "$body" | grep -c 'reattached="\$(wt_find_by_session "\$id" "\$resume_sid")"')"
  [ "${got:-0}" -eq 1 ] \
    && ok "reattached is still computed from wt_find_by_session ($got)" \
    || bad "run_job computes reattached from wt_find_by_session $got times, expected 1 -- a resume can no longer reach its own tree"

  echo "run_job() — a resume that cannot find its own tree refuses, instead of cutting a fresh one"
  # 10.3: a `NOTHING TO DO:` run ends `warning` with `.ended=done` (9.3) when
  # nothing was left undelivered, so run_cleanup has already removed its tree
  # by the time an operator clicks Resume — wt_find_by_session then finds
  # nothing (`reattached=""`) and, before this fix, fell straight through to
  # the fresh-worktree branch below, silently: a whole new agent session
  # spent on a task that had already said there was nothing to do. Structural
  # only, like the checks around it: run_job cannot be exercised end-to-end
  # here without a mocked agent CLI.
  got="$(printf '%s\n' "$body" | grep -c '\[ -n "\$resume_sid" \] && \[ -z "\$reattached" \]')"
  [ "${got:-0}" -eq 1 ] \
    && ok "the refusal's condition (resume requested, no directory found) appears exactly once ($got)" \
    || bad "the resume-not-found guard is missing or duplicated (found $got)"
  # Named by its reason, not just by "refusing to resume": run_job refuses a
  # resume for more than one reason now (a session that belongs to the other
  # platform is the other), and a bare count would rise with every new one
  # while saying nothing about THIS refusal.
  got="$(printf '%s\n' "$body" | grep -c 'refusing to resume \$resume_sid — no open session directory')"
  [ "${got:-0}" -eq 1 ] \
    && ok "the refusal logs its reason ($got)" \
    || bad "the refusal's log_tick is missing or duplicated (found $got)"
  # Ordering: it has to sit between the reattached branch's own success (so a
  # FOUND tree is never refused) and the fresh-worktree branch's first write
  # (so a normal, non-resume run is never even in reach of this condition,
  # and a refused resume leaves $slot/worktree unwritten — the same "nothing
  # half-started" shape the two refusals inside the reattached branch rely
  # on, confirmed separately above).
  resumed_line="$(printf '%s\n' "$body" | grep -n 'log_tick "\$id: resumed \$resume_sid in its own tree' | head -1 | cut -d: -f1)"
  refuse_line="$(printf '%s\n' "$body" | grep -n 'elif \[ -n "\$resume_sid" \] && \[ -z "\$reattached" \]; then' | head -1 | cut -d: -f1)"
  fresh_line="$(printf '%s\n' "$body" | grep -n 'run_dir="\$WORKTREES_DIR/\$id/\$stamp"' | head -1 | cut -d: -f1)"
  [ -n "${resumed_line:-}" ] && [ -n "${refuse_line:-}" ] && [ -n "${fresh_line:-}" ] \
       && [ "$resumed_line" -lt "$refuse_line" ] && [ "$refuse_line" -lt "$fresh_line" ] \
    && ok "the refusal sits after a successful reattach and before the fresh worktree is staked" \
    || bad "refusal ordering broken (resumed=${resumed_line:-?} refuse=${refuse_line:-?} fresh-claim=${fresh_line:-?})"
  # A normal run (no resume requested at all) can never reach this branch:
  # `reattached` is assigned only `[ -n "$resume_sid" ] &&`-guarded (checked
  # above), so it stays "" whenever resume_sid is empty too -- but the
  # refusal's OWN condition restates `[ -n "$resume_sid" ]` explicitly
  # rather than leaning on that context, so it stays correct even if this
  # if-chain is ever reordered or this branch is lifted into its own
  # function. Already proven exactly-once by the condition-text check above;
  # this just names the guarantee it buys.
  case "$(printf '%s\n' "$body" | sed -n "${refuse_line:-0}p")" in
    *'[ -n "$resume_sid" ]'*) ok "and the guard is self-contained: it names resume_sid itself, not just reattached's emptiness" ;;
    *) bad "the refusal no longer checks resume_sid directly -- a future reorder of this if-chain could fire it for a non-resume run" ;;
  esac

  echo "run_job() — a reattach restarts the ttl clock on its run dir"
  # wt_mtime reads the run dir's own mtime, and rewriting .ended on exit does
  # not touch a directory entry -- so without a fresh touch on the claim, the
  # second cycle's window is ttl minus however old the directory already was
  # when the resume started, and a long resume can outlive it before it even
  # finishes. Anchored to ld2_line (the SUCCESSFUL claim's lock_drop, found
  # above): the touch has to land after it, not before -- before it, a
  # refused claim (the branch just above, which returns rather than
  # continuing) would restart a clock for a run that never gets to keep the
  # directory at all.
  # Scoped to BEFORE the resume-not-found refusal (10.3's elif, which closes
  # the reattach branch): run_job also touches $run_dir a second time much
  # later, alongside the classifier's OWN .ended write (10.4) -- a real,
  # separate touch this count must not trip on, so a bare whole-function grep
  # is no longer precise enough here.
  got="$(printf '%s\n' "$body" | sed -n "1,${refuse_line:-0}p" | grep -c 'touch "\$run_dir" 2>/dev/null')"
  [ "${got:-0}" -eq 1 ] \
    && ok "the reattach branch touches its run dir exactly once ($got)" \
    || bad "run_job touches \$run_dir $got times in the reattach branch, expected 1"
  touch_line="$(printf '%s\n' "$body" | sed -n "1,${refuse_line:-0}p" | grep -n 'touch "\$run_dir" 2>/dev/null' | head -1 | cut -d: -f1)"
  [ -n "${ld2_line:-}" ] && [ -n "${touch_line:-}" ] && [ "$touch_line" -gt "$ld2_line" ] \
    && ok "and it happens after the claim succeeds, at line $touch_line vs drop at $ld2_line" \
    || bad "touch (line ${touch_line:-?}) is not after the successful claim's lock_drop (line ${ld2_line:-?})"
  # 9.10: the reattach's second `up` pass has to refresh dirt_sha, or its own
  # residue reads as the resumed agent's work. Structural only, guarding the
  # line that recomputes it -- the behavioural proof (that the refresh
  # actually clears a false UNDELIVERED report) is below, driving the real
  # wt_provision/wt_dirt_sha/wt_undelivered_work.
  got="$(printf '%s\n' "$body" | grep -c 'wt_dirt_sha "\$rwt"')"
  [ "${got:-0}" -eq 1 ] \
    && ok "the reattach's second provisioning pass recomputes dirt_sha ($got)" \
    || bad "run_job no longer recomputes dirt_sha after a reattach's second up pass ($got)"

  echo "run_job() — a reattach's second provisioning pass refreshes dirt_sha too"
  # Not structural alone: this drives the REAL wt_setup / wt_provision /
  # wt_dirt_sha / wt_undelivered_work, replicating exactly what the reattach
  # branch does inline (run_job itself cannot be called here). wt_dirt_sha
  # hashes `git status --porcelain`'s TEXT, which for an untracked file is
  # its PATH, not its content -- overwriting the same filename each run would
  # leave that text, and the sha, identical. The hook instead names the file
  # after its own pid -- a fresh bash subprocess every invocation -- so a
  # second pass leaves a DIFFERENT untracked path behind, standing in for
  # what a real hook can do (a compose lockfile or a temp dir named after its
  # own pid).
  printf '%s\n' '#!/usr/bin/env bash' 'echo hi > "$AL_WORKTREE/build-$$.txt"' \
    > "$tmp/cfg/provision/two.up.sh"
  chmod +x "$tmp/cfg/provision/two.up.sh"
  local rdDirt="$tmp/wtroot/jDirt/stampDirt" wtDirt
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jDirt two "$tmp/g/repo" stampDirt ) >/dev/null 2>&1
  wtDirt="$rdDirt/one"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_undelivered_work "$rdDirt" ) >/dev/null 2>&1
  want "right after setup, nothing is undelivered" 1 $?
  # Re-run `up`, exactly as the reattach branch does -- WITHOUT refreshing
  # dirt_sha yet. This reproduces the bug on its own: the hook's second
  # stamp differs from its first, so the snapshot taken after the FIRST up
  # no longer matches, and it now reads as the resumed agent's own work.
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    wt_provision up two jDirt "$rdDirt" one "$tmp/g/repo" "$wtDirt" develop ) >/dev/null 2>&1
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_undelivered_work "$rdDirt" ) >/dev/null 2>&1
  want "WITHOUT a refresh, the second pass's own residue reads as undelivered work" 0 $?
  # Refresh dirt_sha the way the fix does. The false report clears even
  # though nothing about the actual residue changed since the check just
  # above -- only the snapshot it is compared against did.
  new_sha="$(wt_dirt_sha "$wtDirt")"
  "$JQ" --arg n "one" --arg s "$new_sha" \
    '.repos = [.repos[] | if .name==$n then .dirt_sha=$s else . end]' \
    "$rdDirt/.run.json" > "$rdDirt/.run.json.new" 2>/dev/null \
    && mv -f "$rdDirt/.run.json.new" "$rdDirt/.run.json"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_undelivered_work "$rdDirt" ) >/dev/null 2>&1
  want "and WITH the refresh, that same residue is no longer undelivered" 1 $?
  rm -rf "$tmp/wtroot/jDirt" "$tmp/cfg/provision/two.up.sh"

  echo "run_job() — the reattach's dirt_sha merge keeps the stale value, not empty, when wt_dirt_sha itself fails"
  # Found by an independent review of 10.1, not by the brief: 10.1 made
  # wt_dirt_sha print NOTHING (not a hash) when git cannot read a worktree.
  # This merge's own comment says a missing fresh reading should fall back to
  # the EXISTING dirt_sha -- but a failed wt_dirt_sha still writes a TSV line
  # for that repo, just with an EMPTY value, which is present, not absent.
  # jq's `//` treats an empty string as truthy, so `$d[.name] // .dirt_sha`
  # kept the "" and silently discarded the stale-but-valid value -- exactly
  # the fallback the comment says exists. Reproduced against the REAL merge
  # code (sed-extracted, the same technique errsnippet uses above), not a
  # reimplementation of the jq filter.
  local rdMerge="$tmp/wtroot/jMerge/stampMerge" mergesnippet
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jMerge two "$tmp/g/repo" stampMerge ) >/dev/null 2>&1
  "$JQ" --arg n "one" --arg s "STALE-BUT-VALID" \
    '.repos = [.repos[] | if .name==$n then .dirt_sha=$s else . end]' \
    "$rdMerge/.run.json" > "$rdMerge/.run.json.new" 2>/dev/null \
    && mv -f "$rdMerge/.run.json.new" "$rdMerge/.run.json"
  mergesnippet="$(sed -n '/^      if \[ -n "\$rdirt" \] && "\$JQ" -R -n --slurpfile mf "\$run_dir\/.run.json" .$/,/^      rm -f "\$rdirt"$/p' \
                    "$BIN_DIR/agentloop")"
  [ -n "$mergesnippet" ] || bad "could not extract the reattach dirt_sha merge block -- its anchors moved"
  # "one" has an empty fresh reading (exactly what a failed wt_dirt_sha now
  # writes); "two" has a real one, to prove a genuine refresh still wins and
  # this fix does not just make the merge ignore fresh readings altogether.
  (
    run_dir="$rdMerge"
    rdirt="$rdMerge/.dirt.tsv"
    printf 'one\t\ntwo\tFRESH-VALID\n' > "$rdirt"
    eval "$mergesnippet"
  )
  got="$("$JQ" -r '.repos[] | select(.name=="one") | .dirt_sha' "$rdMerge/.run.json" 2>/dev/null)"
  [ "$got" = "STALE-BUT-VALID" ] \
    && ok "an empty fresh reading falls back to the stale-but-valid dirt_sha" \
    || bad "dirt_sha for 'one' reads '$got', expected the stale value STALE-BUT-VALID to survive"
  got="$("$JQ" -r '.repos[] | select(.name=="two") | .dirt_sha' "$rdMerge/.run.json" 2>/dev/null)"
  [ "$got" = "FRESH-VALID" ] \
    && ok "a real fresh reading still wins over whatever was there before" \
    || bad "dirt_sha for 'two' reads '$got', expected the fresh value FRESH-VALID"
  rm -rf "$tmp/wtroot/jMerge"

  echo "run_job() — an error run with a declared ending but undelivered work stays open"
  # The regression this task's own self-review caught (three independent
  # review passes converged on it), reproduced against the REAL code rather
  # than a reimplementation: sed-extract the exact block from
  # declared_ending=false through the .ended write -- the same text the
  # structural checks near the top of this suite examine -- and eval it for
  # real, with a real run_dir holding real undelivered work. If this block is
  # ever edited back to gating the undelivered CHECK on status (not just the
  # note), this test runs the actual new text and catches it directly, not a
  # stale copy of the old logic.
  #
  # The bug: `undelivered` used to be computed only inside
  # `case "$status" in success|warning)`, so for status=error or
  # status=stopped it stayed at its initial "" -- read by the .ended gate as
  # "nothing undelivered" without ever having been asked. An agent run that
  # trips one denied tool call (status=error, unrelated to whether it pushed
  # anything) but still finishes and says `RUN COMPLETE:` would satisfy
  # declared_ending=true with an unchecked, default-empty undelivered, mark
  # `.ended=done`, and have its uncommitted work force-removed on the very
  # next tick.
  local rdErr="$tmp/wtroot/jErr/stampErr" errsnippet
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jErr two "$tmp/g/repo" stampErr ) >/dev/null 2>&1
  echo "never pushed" > "$rdErr/one/undelivered-err.txt"
  printf '{"result":"RUN COMPLETE: done, but a tool call was denied along the way"}' \
    > "$tmp/err.logfile.json"
  # The block lives in run_classify now, and ends where its results go back
  # to run_job -- the comment right after the .ended write is the anchor.
  errsnippet="$(sed -n '/^  declared_ending=false$/,/^  # What goes back to run_job, and nothing else does/p' \
                  "$BIN_DIR/agentloop")"
  [ -n "$errsnippet" ] || bad "could not extract the .ended classifier block -- its anchors moved"
  (
    id="jErr"; status="error"; wdreason=""; cost=""
    logfile="$tmp/err.logfile.json"; run_dir="$rdErr"
    declared_ending=""; undelivered=""
    eval "$errsnippet"
  )
  [ "$(cat "$rdErr/.ended" 2>/dev/null)" = "open" ] \
    && ok "declared an ending, status=error, undelivered work -- .ended stays open" \
    || bad ".ended reads '$(cat "$rdErr/.ended" 2>/dev/null)', expected open -- an error run's undelivered work would be force-removed"
  rm -rf "$tmp/wtroot/jErr" "$tmp/err.logfile.json"

  echo "run_job() — a second .ended write restarts the run dir's ttl clock too"
  # 10.4: cycle 1 gets a fresh mtime for free -- CREATING .ended the first
  # time bumps its parent directory's own entry. A resumed run's SECOND
  # ending only overwrites that file's content, which does not touch the
  # directory entry at all: without an explicit touch here, a long resume's
  # clock would still read whatever the reattach's own claim-time touch (9.4)
  # left it at -- ttl minus however long this cycle ran, not a fresh window.
  # Same errsnippet extraction as the test just above -- eval'd again,
  # against a run dir whose mtime is deliberately stale first, the way a
  # claim made hours ago and a long-running resume would leave it.
  local rdTtl="$tmp/wtroot/jTtl/stampTtl" ttlage
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jTtl two "$tmp/g/repo" stampTtl ) >/dev/null 2>&1
  echo open > "$rdTtl/.ended"            # already ended once, like a resumed run's tree
  touch -t 202001010000 "$rdTtl"         # ... with a stale clock, like an old reattach claim
  printf '{"result":"RUN COMPLETE: nothing left to do"}' > "$tmp/ttl.logfile.json"
  (
    id="jTtl"; status="warning"; wdreason=""; cost=""
    logfile="$tmp/ttl.logfile.json"; run_dir="$rdTtl"
    declared_ending=""; undelivered=""
    eval "$errsnippet"
  )
  ttlage="$(( $(now_epoch) - $(num "$(wt_mtime "$rdTtl")") ))"
  [ "$ttlage" -lt 60 ] \
    && ok "ending a second time restarts the run dir's ttl clock (${ttlage}s old)" \
    || bad "run dir mtime is ${ttlage}s old right after a second .ended write -- the ttl clock did not reset"
  rm -rf "$tmp/wtroot/jTtl" "$tmp/ttl.logfile.json"

  echo "run_job() — two concurrent reattaches to the same tree: exactly one wins"
  # Not structural: this drives the real lock_take/lock_drop/wt_is_claimed/
  # slot_alive under genuine concurrency, to prove the mechanism the ordering
  # check above just confirmed run_job's code follows actually holds. Two
  # background attempts race for the SAME run_dir; each performs precisely the
  # sequence the reattach branch does -- lock, check wt_is_claimed, write the
  # breadcrumb, unlock -- with a deliberate pause INSIDE the locked section so
  # the second attempt is guaranteed to still be waiting on lock_take when the
  # first finishes, rather than hoping OS scheduling happens to interleave
  # them. bash 3.2 has no $BASHPID and does not reseed $$ inside a subshell,
  # so each attempt's "process" is a real, separately-spawned placeholder --
  # slot_alive needs a genuinely live pid to check.
  #
  # Initialised here, not left to the read below: both branches inside the
  # subshell write race_summary, but if the subshell dies before either does
  # (an interrupted wait, a killed sleep), the file never exists, the read's
  # redirection fails, and under `set -u` an unbound $raceN on the next line
  # would abort THIS WHOLE SCRIPT, not just this one assertion -- a flaky
  # harness has no business taking the other ~90 down with it.
  local raceN="" raceRA="" raceRB=""
  (
    LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    mkdir -p "$LOCK_DIR/jRace"
    rd="$tmp/wtroot/jRace/stampRace"; mkdir -p "$rd"
    rlock="$LOCK_DIR/.resume"; rm -rf "$rlock"

    sleep 5 & pidA=$!
    sleep 5 & pidB=$!
    slotA="$LOCK_DIR/jRace/$pidA"; slotB="$LOCK_DIR/jRace/$pidB"
    mkdir -p "$slotA" "$slotB"
    echo "$pidA" > "$slotA/pid"; boot_id > "$slotA/boot"
    echo "$pidB" > "$slotB/pid"; boot_id > "$slotB/boot"

    race_attempt() {
      local slot="$1" resultfile="$2" hold="$3"
      lock_take "$rlock"
      if wt_is_claimed jRace "$rd"; then
        echo REFUSED > "$resultfile"
      else
        [ "$hold" = "1" ] && sleep 0.1
        echo "$rd" > "$slot/worktree"
        echo CLAIMED > "$resultfile"
      fi
      lock_drop "$rlock"
    }

    race_attempt "$slotA" "$tmp/raceA" 1 & raceA=$!
    i=0
    while [ ! -d "$rlock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    if [ ! -d "$rlock" ]; then
      echo "TIMEOUT" > "$tmp/race_summary"
    else
      race_attempt "$slotB" "$tmp/raceB" 0 & raceB=$!
      wait "$raceA" "$raceB"
      raceRA="$(cat "$tmp/raceA" 2>/dev/null)"; raceRB="$(cat "$tmp/raceB" 2>/dev/null)"
      raceClaimed=0
      [ "$raceRA" = "CLAIMED" ] && raceClaimed=$(( raceClaimed + 1 ))
      [ "$raceRB" = "CLAIMED" ] && raceClaimed=$(( raceClaimed + 1 ))
      printf '%s %s %s\n' "$raceClaimed" "$raceRA" "$raceRB" > "$tmp/race_summary"
    fi
    kill "$pidA" "$pidB" 2>/dev/null; wait "$pidA" "$pidB" 2>/dev/null
  )
  # Same redirection trap as alloc_port_base's portbase write: a missing file
  # is raised by the shell setting up the `<` before read ever runs, so a
  # 2>/dev/null on read itself does not silence it -- the group is what has
  # to swallow it.
  { read -r raceN raceRA raceRB < "$tmp/race_summary"; } 2>/dev/null || true
  if [ "$raceN" = "1" ]; then
    ok "exactly one of two concurrent reattach attempts claims the tree ($raceRA/$raceRB)"
  else
    bad "expected exactly one claim, got '$raceN' ($raceRA/$raceRB) -- the lock did not serialise them"
  fi
  rm -rf "$tmp/locks/jRace" "$tmp/wtroot/jRace" "$tmp/raceA" "$tmp/raceB" "$tmp/race_summary"

  echo "cmd_worktree_drop() — a reattach that claims first cannot be deleted out from under it"
  # Not structural: drives the REAL cmd_worktree_drop against a simulated
  # reattach claim (run_job itself cannot be called here, same constraint as
  # above), racing for the SAME $LOCK_DIR/.resume lock 9.5 adds to the drop.
  # wt_down_all is a provisioning hook that can take real seconds to minutes;
  # before this fix, cmd_worktree_drop never looked at this lock at all, so
  # nothing stopped a resume from claiming the tree, starting its agent with
  # a valid cwd, and then having wt_remove_all delete that cwd out from under
  # the now-running agent. The claim goes FIRST and holds the lock a moment
  # (like a resume doing its own checks) so the drop, which has to wait, is
  # not just winning a lucky scheduling race.
  local rdRace="$tmp/wtroot/jDropRace/stampRaceA"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jDropRace two "$tmp/g/repo" stampRaceA ) >/dev/null 2>&1
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 0.3' > "$tmp/cfg/provision/two.down.sh"
  chmod +x "$tmp/cfg/provision/two.down.sh"
  (
    LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    rlock="$LOCK_DIR/.resume"; rm -rf "$rlock"
    mkdir -p "$LOCK_DIR/jDropRace"
    sleep 5 & pidR=$!
    slotR="$LOCK_DIR/jDropRace/$pidR"; mkdir -p "$slotR"
    echo "$pidR" > "$slotR/pid"; boot_id > "$slotR/boot"

    ( lock_take "$rlock"; sleep 0.15; echo "$rdRace" > "$slotR/worktree"; lock_drop "$rlock" ) \
      & reattach=$!
    i=0; while [ ! -d "$rlock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
      cmd_worktree_drop jDropRace stampRaceA ) > "$tmp/dropRace.out" 2>&1
    echo "$?" > "$tmp/dropRace.rc"
    wait "$reattach"
    kill "$pidR" 2>/dev/null; wait "$pidR" 2>/dev/null
  )
  [ -d "$rdRace" ] \
    && ok "the tree the reattach claimed first survives a concurrent drop" \
    || bad "the tree was removed out from under a reattach that had already claimed it"
  [ "$(cat "$tmp/dropRace.rc" 2>/dev/null)" != "0" ] && grep -q "still going" "$tmp/dropRace.out" 2>/dev/null \
    && ok "the drop, arriving second, refuses citing the live claim ($(cat "$tmp/dropRace.out" 2>/dev/null))" \
    || bad "the drop did not refuse (rc=$(cat "$tmp/dropRace.rc" 2>/dev/null), $(cat "$tmp/dropRace.out" 2>/dev/null))"
  rm -rf "$tmp/locks/jDropRace" "$tmp/wtroot/jDropRace" "$tmp/dropRace.out" "$tmp/dropRace.rc"
  rm -f "$tmp/cfg/provision/two.down.sh"

  echo "wt_prune_orphans() — a reattach that claims first cannot be swept out from under it"
  # The adjacent route this task's own self-review found: 9.5 protected the
  # HUMAN drop (cmd_worktree_drop, tested just above) with the resume lock,
  # but wt_prune_orphans -- the automatic sweep every tick runs -- read
  # wt_is_claimed unsynchronized, and could race a reattach the identical
  # way: in the narrow window after a reattach has taken $LOCK_DIR/.resume
  # but before it has written its own claim, the sweep's OWN unsynchronized
  # read would see "not claimed", find the directory past its ttl, and
  # remove it out from under the reattach that is mid-way through claiming
  # it. Same technique as the drop-race test above: the reattach claims
  # first and holds the lock a moment, so the sweep, arriving second, is not
  # just winning a lucky scheduling race.
  local rdSweep="$tmp/wtroot/jSweepRace/stampA"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jSweepRace two "$tmp/g/repo" stampA ) >/dev/null 2>&1
  # `.session` present, so this reads as an ordinary open session past its
  # ttl -- not the pre-upgrade adoption case, which is a different route
  # already covered above and would never reach the age check at all.
  echo "sess-sweep" > "$rdSweep/.session"
  touch -t 202001010000 "$rdSweep"    # weeks past any ttl
  (
    LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    rlock="$LOCK_DIR/.resume"; rm -rf "$rlock"
    mkdir -p "$LOCK_DIR/jSweepRace"
    sleep 5 & pidR=$!
    slotR="$LOCK_DIR/jSweepRace/$pidR"; mkdir -p "$slotR"
    echo "$pidR" > "$slotR/pid"; boot_id > "$slotR/boot"

    ( lock_take "$rlock"; sleep 0.15; echo "$rdSweep" > "$slotR/worktree"; lock_drop "$rlock" ) \
      & reattach=$!
    i=0; while [ ! -d "$rlock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
      wt_prune_orphans ) >/dev/null 2>&1
    wait "$reattach"
    kill "$pidR" 2>/dev/null; wait "$pidR" 2>/dev/null
  )
  [ -d "$rdSweep" ] \
    && ok "the tree the reattach claimed first survives a concurrent sweep" \
    || bad "the sweep removed a tree that had already been claimed by a reattach"
  rm -rf "$tmp/locks/jSweepRace" "$tmp/wtroot/jSweepRace"

  echo "wt_undelivered_work() — what provisioning left behind is not the agent's work"
  printf '%s\n' '#!/usr/bin/env bash' 'echo residue > provisioned.txt' \
    > "$tmp/cfg/provision/two.up.sh"
  local rd3="$tmp/wtroot/j4/stampE"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j4 two "$tmp/g/repo" stampE ) >/dev/null 2>&1
  [ -f "$rd3/one/provisioned.txt" ] && ok "the hook's untracked file is there" || bad "hook wrote nothing"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_undelivered_work "$rd3" ) >/dev/null 2>&1
  want "provisioning residue alone is NOT undelivered work" 1 $?
  echo "the agent was here" > "$rd3/two/agent.txt"
  got="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
          wt_undelivered_work "$rd3" )"
  want "a file the agent added after provisioning IS undelivered work" 0 $?
  case "$got" in *"uncommitted changes in two"*)
      ok "and it names the repo it is in" ;;
    *) bad "the description was '$got'" ;;
  esac
  rm -f "$tmp/cfg/provision/two.up.sh"

  echo "wt_merge_probe_only() — a trial merge of what is already on a remote is not work"
  # Reviewing a change means measuring the MERGED tree, so a reviewer runs
  # `git merge --no-commit` inside its own run directory. That leaves every
  # incoming file staged with MERGE_HEAD set, and the dirty-tree check read it
  # as work that exists nowhere else: RP-216 was reviewed, approved and merged,
  # and still came back UNDELIVERED with its directory retained. The contents
  # came FROM a remote, so nothing there could be lost -- the same question the
  # unpushed-commits check below already asks of HEAD, asked of MERGE_HEAD.
  local mp="$tmp/g/mp"
  mkdir -p "$mp"
  git init --bare -q "$mp/origin.git"
  git clone -q "$mp/origin.git" "$mp/work" 2>/dev/null
  git -C "$mp/work" config user.email t@example.com
  git -C "$mp/work" config user.name tester
  echo base > "$mp/work/base.txt"
  git -C "$mp/work" add -A && git -C "$mp/work" commit -qm base
  git -C "$mp/work" push -q origin HEAD:refs/heads/main
  git -C "$mp/work" branch -q --set-upstream-to=origin/main 2>/dev/null
  git -C "$mp/work" checkout -q -b feat
  echo incoming > "$mp/work/incoming.txt"
  git -C "$mp/work" add -A && git -C "$mp/work" commit -qm feat
  git -C "$mp/work" push -q origin feat
  git -C "$mp/work" checkout -q -
  git -C "$mp/work" fetch -q origin
  git -C "$mp/work" merge --no-commit --no-ff -q origin/feat >/dev/null 2>&1
  [ -n "$(git -C "$mp/work" status --porcelain 2>/dev/null)" ] \
    && ok "the fixture really is dirty: the trial merge staged something" \
    || bad "the trial merge staged nothing -- fixture invalid"
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "a staged trial merge of a commit already on a remote is recognised" 0 $?
  # Anything the agent put on top of the merge is still its own work.
  echo "the agent was here" > "$mp/work/agent.txt"
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "an untracked file on top of the merge fails the test" 1 $?
  rm -f "$mp/work/agent.txt"
  echo "edited" >> "$mp/work/base.txt"
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "an unstaged edit on top of the merge fails the test" 1 $?
  git -C "$mp/work" checkout -q -- base.txt
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "and the untouched trial merge is recognised again" 0 $?
  # A merge of something that exists on NO remote is exactly the case the
  # undelivered report exists for -- it must still be caught.
  git -C "$mp/work" merge --abort 2>/dev/null
  git -C "$mp/work" checkout -q -b local-only
  echo private > "$mp/work/private.txt"
  git -C "$mp/work" add -A && git -C "$mp/work" commit -qm private
  git -C "$mp/work" checkout -q -
  git -C "$mp/work" merge --no-commit --no-ff -q local-only >/dev/null 2>&1
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "a trial merge of a branch on no remote is NOT excused" 1 $?
  git -C "$mp/work" merge --abort 2>/dev/null
  # No merge at all: an ordinary dirty tree must never take this exit.
  echo "plain work" > "$mp/work/plain.txt"
  ( wt_merge_probe_only "$mp/work" ) >/dev/null 2>&1
  want "a dirty tree with no merge in progress is NOT excused" 1 $?
  rm -f "$mp/work/plain.txt"

  echo "wt_undelivered_work() — and the classifier itself consults it"
  local rdM="$tmp/wtroot/jMerge/stampM"
  mkdir -p "$rdM"
  git clone -q "$mp/origin.git" "$rdM/repo" 2>/dev/null
  # `git init --bare` points HEAD at a branch this fixture never creates, so a
  # plain clone lands with an unborn HEAD and wt_undelivered_work reports
  # "cannot read commits" -- true, and nothing to do with the merge. Put the
  # clone on a real branch so the test measures what it says it measures.
  git -C "$rdM/repo" checkout -q -B main origin/main
  git -C "$rdM/repo" config user.email t@example.com
  git -C "$rdM/repo" config user.name tester
  git -C "$rdM/repo" merge --no-commit --no-ff -q origin/feat >/dev/null 2>&1
  ( WORKTREES_DIR="$tmp/wtroot"; wt_undelivered_work "$rdM" ) >/dev/null 2>&1
  want "a run dir holding only a trial merge is not reported as undelivered" 1 $?
  echo "the agent was here" > "$rdM/repo/agent.txt"
  got="$( WORKTREES_DIR="$tmp/wtroot"; wt_undelivered_work "$rdM" )"
  want "the agent's own file on top of the merge still IS undelivered" 0 $?
  case "$got" in *"uncommitted changes in repo"*)
      ok "and it names the repo it is in" ;;
    *) bad "the description was '$got'" ;;
  esac
  rm -rf "$tmp/wtroot/jMerge"

  echo "wt_dirt_sha() / wt_undelivered_work() — git that cannot answer is reported, not read as clean"
  # `git status --porcelain` prints nothing for a clean tree AND for one it
  # cannot read at all — hashing empty stdout used to give the SAME
  # fingerprint either way, measured for real: da39a3ee5e6b4b0d3255bfef9560
  # 1890afd80709 for a clean repo, a missing path, and a non-repo alike. So a
  # broken .git pointer — the operator moves or renames the canonical
  # checkout, which breaks every one of its linked worktrees' pointers at
  # once — used to compare equal to "nothing changed". Reproduced against the
  # REAL classifier, not a reimplementation: a real wt_setup, a real
  # uncommitted file, a real broken .git file, then wt_undelivered_work
  # itself.
  local rdG="$tmp/wtroot/jGitBroken/stampGB"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jGitBroken two "$tmp/g/repo" stampGB ) >/dev/null 2>&1
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_undelivered_work "$rdG" ) >/dev/null 2>&1
  want "right after setup, nothing is undelivered" 1 $?
  echo "agent work, never committed" > "$rdG/one/agent-work.txt"
  got="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
          wt_undelivered_work "$rdG" )"
  want "the fixture is valid: a real uncommitted file IS caught while git still works" 0 $?
  case "$got" in *"uncommitted changes in one"*) ok "and names the repo" ;;
    *) bad "was '$got'" ;;
  esac
  # Break it exactly the way an operator moving the canonical does: a linked
  # worktree's own .git is a FILE naming its gitdir inside the canonical's
  # .git/worktrees/ — point it nowhere. (Editing this one worktree's pointer
  # reproduces the identical symptom as moving $tmp/g/repo itself, without
  # disturbing every other fixture in this suite that shares that checkout.)
  echo "gitdir: $tmp/g/nonexistent/.git/worktrees/one" > "$rdG/one/.git"
  git -C "$rdG/one" status --porcelain >/dev/null 2>&1
  [ $? -ne 0 ] && ok "the fixture really is unreadable: git status fails on it" \
    || bad "breaking .git did not actually break git -- fixture invalid"
  ( wt_dirt_sha "$rdG/one" ) >/dev/null 2>&1
  want "wt_dirt_sha itself reports failure rather than a colliding fingerprint" 1 $?
  # The return code alone is not the whole story: `set -o pipefail` (active
  # throughout this codebase) already made the OLD one-liner's OWN exit
  # status non-zero on a git failure, by accident, since nothing ever CHECKED
  # it -- wt_setup's snapshot pass still does not. What actually protects
  # that call site is stdout: printing NOTHING on failure, instead of the
  # collision hash, is what keeps a setup-time failure from being recorded as
  # a real (but wrong) snapshot.
  got="$(wt_dirt_sha "$rdG/one" 2>/dev/null)"
  [ -z "$got" ] && ok "and prints nothing on failure, not the colliding hash" \
    || bad "wt_dirt_sha printed '$got' on a git failure -- a caller that only checks stdout, like wt_setup's snapshot pass, would still be fooled"
  got="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
          wt_undelivered_work "$rdG" )"
  want "the SAME real uncommitted file is still reported once git cannot look" 0 $?
  case "$got" in
    *"cannot read git in one"*) ok "the note says git could not look, not that the tree is clean" ;;
    *) bad "was '$got' -- the broken worktree went unreported" ;;
  esac
  case "$got" in
    *"cannot read commits in one"*) ok "the commit-history blind spot ([ -n \"\$head\" ] || continue) is closed too" ;;
    *) bad "rev-parse's failure was not reported: '$got'" ;;
  esac
  # The sibling worktree was never touched -- a broken repo must not make the
  # whole run dir read as undelivered, only the repo that is actually broken.
  case "$got" in
    *"in two"*) bad "the healthy sibling worktree was blamed too: '$got'" ;;
    *) ok "the healthy sibling worktree is not blamed" ;;
  esac
  rm -rf "$rdG"; git -C "$tmp/g/repo" worktree prune >/dev/null 2>&1 || true

  echo "wt_setup() — a snapshot failure degrades to 'missing', not a crash or a false clean"
  # The OTHER caller: a hook can succeed and still leave git unable to read
  # the tree right afterward (corrupts its own index, say) -- provisioning
  # itself is not at fault, so wt_setup does not abort the run over this
  # alone. The manifest records an empty snapshot, the same shape as "no
  # snapshot was ever taken", which wt_undelivered_work already has a defined
  # meaning for. The safety net is downstream, not here: the live check at
  # teardown time goes through this SAME wt_dirt_sha, so a failure still
  # there when it matters is still reported, not silently read as clean.
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo residue > "$AL_WORKTREE/leftover.txt"' \
    'echo "gitdir: $AL_WORKTREE/nonexistent-gitdir" > "$AL_WORKTREE/.git"' \
    > "$tmp/cfg/provision/two.up.sh"
  chmod +x "$tmp/cfg/provision/two.up.sh"
  local rdSF="$tmp/wtroot/jSnapFail/stampSF"
  prim="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
           wt_setup jSnapFail two "$tmp/g/repo" stampSF )"
  [ -n "$prim" ] && [ -d "$rdSF" ] \
    && ok "setup still completes: a post-provisioning snapshot failure alone does not abort the run" \
    || bad "wt_setup aborted (or left nothing behind) over a dirt_sha failure alone -- prim='$prim'"
  got="$("$JQ" -r '.repos[] | select(.name=="one") | .dirt_sha // "FIELD-ABSENT"' "$rdSF/.run.json" 2>/dev/null)"
  [ "$got" = "" ] && ok "the manifest records an empty snapshot, not a crash or a stale value" \
    || bad "dirt_sha recorded as '$got', expected empty"
  got="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
          wt_undelivered_work "$rdSF" )"
  want "the live check still catches it -- git is STILL broken at teardown time" 0 $?
  case "$got" in
    *"cannot read git in one"*) ok "reported as unreadable, not silently clean, even with no snapshot to compare against" ;;
    *) bad "was '$got'" ;;
  esac
  rm -rf "$rdSF"; git -C "$tmp/g/repo" worktree prune >/dev/null 2>&1 || true
  rm -f "$tmp/cfg/provision/two.up.sh"

  echo "boot_id() — an opaque per-boot identity, stable within one boot"
  got="$(boot_id)"
  case "$got" in
    *-*-*-*-*) ok "it is a boot session uuid, not a timestamp that a clock step moves" ;;
    *) bad "boot_id printed '$got', which is not a uuid" ;;
  esac
  [ "$got" = "$(AL_BOOT_ID=""; boot_id)" ] \
    && ok "and two reads inside one boot agree" || bad "boot_id is not stable"

  echo "slot_alive() — a lease is pinned to the boot it was taken in"
  mkdir -p "$tmp/locks/j8/$$"
  echo $$ > "$tmp/locks/j8/$$/pid"
  boot_id > "$tmp/locks/j8/$$/boot"
  ( LOCK_DIR="$tmp/locks"; slot_alive "$tmp/locks/j8/$$" )
  want "this process's own slot, stamped with this boot, is alive" 0 $?
  echo "0" > "$tmp/locks/j8/$$/boot"
  ( LOCK_DIR="$tmp/locks"; slot_alive "$tmp/locks/j8/$$" )
  want "the same live pid from an earlier boot is dead" 1 $?
  rm -f "$tmp/locks/j8/$$/boot"
  ( LOCK_DIR="$tmp/locks"; slot_alive "$tmp/locks/j8/$$" )
  want "a slot with no boot file predates this and falls back to the pid" 0 $?
  rm -rf "$tmp/locks/j8"

  echo "wt_is_claimed() — a claim from an earlier boot holds nothing"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j8 two "$tmp/g/repo" stampBoot ) >/dev/null 2>&1
  mkdir -p "$tmp/locks/j8/$$"
  echo $$ > "$tmp/locks/j8/$$/pid"
  echo "0" > "$tmp/locks/j8/$$/boot"
  echo "$tmp/wtroot/j8/stampBoot" > "$tmp/locks/j8/$$/worktree"
  # `done`, not left unmarked: an unmarked dir is now kept regardless of
  # whether its claim is live or stale (see wt_teardown), so leaving this one
  # unmarked could not tell THIS function's job -- disregarding a pre-reboot
  # claim -- apart from the boot-pinning being broken and the sweep never
  # reaching wt_teardown at all. Both would leave the dir standing and read as
  # `ok`. A done dir is reaped ONLY if the stale claim is correctly
  # disregarded, which is the exact recycled-pid risk Task 1 exists for.
  echo done > "$tmp/wtroot/j8/stampBoot/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ ! -d "$tmp/wtroot/j8/stampBoot" ] \
    && ok "a run dir claimed only by a pre-reboot slot is reaped" \
    || bad "a stale pre-reboot claim kept an orphan alive"
  rm -rf "$tmp/locks/j8" "$tmp/wtroot/j8"

  # No backticks in this string: inside double quotes the shell would run it.
  echo "wt_provision() — a down hook from the orphan sweep still knows its ports"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "down saw ${AL_PORT_BASE:-none}" >> "$AL_RUN_DIR/../down.log"' \
    > "$tmp/cfg/provision/two.down.sh"
  chmod +x "$tmp/cfg/provision/two.down.sh"
  rm -f "$tmp/wtroot/j6/down.log"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j6 two "$tmp/g/repo" stampP 27100 ) >/dev/null 2>&1
  got="$("$JQ" -r '.port_base' "$tmp/wtroot/j6/stampP/.run.json" 2>/dev/null)"
  [ "$got" = "27100" ] && ok "the manifest records the run's port block" \
    || bad "port_base was '$got'"
  # `done`, not left unmarked: the orphan sweep now KEEPS an unmarked dir (see
  # above), so proving `down` still finds its ports needs a dir the sweep will
  # actually tear down -- a crash that landed AFTER the run's own classifier
  # wrote `done`, not one caught before any classifier ran.
  echo done > "$tmp/wtroot/j6/stampP/.ended"
  # No slot, no ambient AL_PORT_BASE: exactly the orphan sweep's situation.
  # wt_prune_orphans resolves the project via job_get (JOBS_FILE), not by
  # reading the manifest's own .project — so the sweep needs a job "j6" ->
  # project "two" of its own, same as the real jobs.json a live job would
  # have, or the down hook this test is proving out is never found.
  printf '%s' '{"jobs":[{"id":"j6","project":"two"}]}' > "$tmp/proj/j6.jobs.json"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"; JOBS_FILE="$tmp/proj/j6.jobs.json"
    unset AL_PORT_BASE
    wt_prune_orphans ) >/dev/null 2>&1
  grep -q "down saw 27100" "$tmp/wtroot/j6/down.log" 2>/dev/null \
    && ok "a crashed run's down hook reads its ports from the manifest" \
    || bad "down ran without the run's port block"
  rm -f "$tmp/cfg/provision/two.down.sh" "$tmp/wtroot/j6/down.log"

  echo "wt_prune_orphans() — an unclaimed run dir is kept until it is marked done"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j3 two "$tmp/g/repo" stampD ) >/dev/null 2>&1
  # `.session` present, so this fixture reads as a dir THIS engine already
  # bound (an ordinary in-flight or crashed-before-classifying run) rather
  # than a pre-upgrade one — that adoption case gets its own dedicated test
  # below, and conflating the two here would leave this test passing for
  # either reason without saying which.
  echo "sess-d1" > "$tmp/wtroot/j3/stampD/.session"
  mkdir -p "$tmp/locks/j3/999"
  echo $$ > "$tmp/locks/j3/999/pid"
  echo "$tmp/wtroot/j3/stampD" > "$tmp/locks/j3/999/worktree"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ -d "$tmp/wtroot/j3/stampD" ] && ok "a run dir a live slot claims is left alone" \
    || bad "the sweep deleted a claimed run dir"
  rm -rf "$tmp/locks/j3"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ -d "$tmp/wtroot/j3/stampD" ] \
    && ok "unclaimed but still unmarked, it is kept rather than reaped" \
    || bad "the orphan was reaped though nothing ever said its run was done"
  # The control: this is not "the sweep never reaps anything now" -- only that
  # it needs telling. Once the run IS marked done, the very next sweep lets it
  # go, same as any other done run the sweep finds.
  echo done > "$tmp/wtroot/j3/stampD/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ ! -d "$tmp/wtroot/j3/stampD" ] && ok "and a done, unclaimed run IS reaped by the sweep" \
    || bad "a done run survived a sweep — the sweep no longer reaps anything"

  echo "wt_prune_orphans() — a pre-upgrade retained dir is ADOPTED, not aged out"
  # The exact shape the OLD code left on disk: a run dir holding a real commit
  # that lives on no remote, no `.ended` (that file did not exist before this
  # branch), no `.session` (bind_session did not exist either), and an mtime
  # from whenever that old run last touched the directory -- which by the
  # time anyone upgrades is routinely weeks old. Before the fix, this is the
  # `*)` branch: age computed from that stale mtime, found past the ttl,
  # written `done`, and wt_teardown runs `git worktree remove --force` --
  # discarding the very commit the OLD teardown kept this directory alive to
  # protect. Reproduced for real below: a real git worktree, a real commit,
  # no mocks, no markers.
  # "two" declares TWO repos (see wt_setup's own test above) and names the one
  # at $tmp/g/repo "one", not "repo" -- so the primary has to be READ from
  # wt_setup's own stdout, the same way its own test does, rather than guessed
  # from a basename.
  preprimary="$( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jPre two "$tmp/g/repo" stampPre )"
  echo "work nobody pushed" > "$preprimary/undelivered.txt"
  ( cd "$preprimary" && git add undelivered.txt && $gitc commit -qm "pre-upgrade work, on no remote" ) >/dev/null 2>&1
  presha="$(git -C "$preprimary" rev-parse HEAD 2>/dev/null)"
  [ -n "$presha" ] && [ ! -f "$tmp/wtroot/jPre/stampPre/.ended" ] \
    && [ ! -f "$tmp/wtroot/jPre/stampPre/.session" ] \
    && ok "fixture: a real commit, no .ended, no .session -- exactly what pre-upgrade left behind" \
    || bad "fixture setup is wrong ($presha) -- the rest of this test proves nothing"
  # Weeks old: nobody has touched this directory since the run that made it
  # ended, long before an operator ever runs an upgraded tick.
  touch -t 202001010000 "$tmp/wtroot/jPre/stampPre"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ -d "$tmp/wtroot/jPre/stampPre" ] \
    && ok "the pre-upgrade directory survives the very first post-upgrade sweep" \
    || bad "the sweep deleted a pre-upgrade run dir on its first tick"
  [ "$(git -C "$preprimary" rev-parse HEAD 2>/dev/null)" = "$presha" ] \
    && ok "and its commit is still there -- nothing was force-removed" \
    || bad "the commit is gone: the worktree was force-removed"
  [ "$(cat "$tmp/wtroot/jPre/stampPre/.ended" 2>/dev/null)" = "open" ] \
    && ok "adopted as open, so a resume or the operator can still find it" \
    || bad ".ended reads '$(cat "$tmp/wtroot/jPre/stampPre/.ended" 2>/dev/null)', expected open"
  age_after="$(( $(now_epoch) - $(num "$(wt_mtime "$tmp/wtroot/jPre/stampPre")" 0) ))"
  [ "$age_after" -lt 60 ] \
    && ok "and its clock restarted -- it gets a full ttl window, not the remainder of the old one" \
    || bad "mtime was not refreshed on adoption (age ${age_after}s)"
  # wt_remove_all, not rm -rf: a raw rm -rf leaves $tmp/g/repo's own
  # .git/worktrees/one registration behind, and the very next test in this
  # file asserts on `git worktree list` for that same canonical -- a leaked
  # registration here would fail a fixture three tests away for a reason that
  # has nothing to do with what that test is checking.
  wt_remove_all "$tmp/wtroot/jPre/stampPre" >/dev/null 2>&1
  rmdir "$tmp/wtroot/jPre" 2>/dev/null || true

  echo "cmd_tick() — every tick still prunes stale canonical registrations"
  # Structural. wt_prune_canonicals has its full behavioural coverage just
  # below, called directly the way every test here calls it -- which is
  # exactly why deleting cmd_tick's OWN call to it (the only production call
  # site; every other match below is this suite calling it itself) would
  # leave every one of those tests green while Task 3 quietly stops running
  # in production. Same shape as the reattached check above: a behavioural
  # test of the function proves the function works, not that anything still
  # calls it.
  got="$(sed -n '/^cmd_tick()/,/^}/p' "$BIN_DIR/agentloop" | grep -c 'wt_prune_canonicals')"
  [ "${got:-0}" -eq 1 ] \
    && ok "cmd_tick calls wt_prune_canonicals ($got)" \
    || bad "cmd_tick calls wt_prune_canonicals $got times, expected 1 -- stale worktree registrations would accumulate for ever"

  echo "cmd_tick() — .tick wraps the WHOLE body: the sweep AND the due-job loop, not just part of it"
  # This is what pins the regression -- not a timing-based real race. A real
  # two-process test was tried and dropped: even with the sweep and the
  # due-job loop reduced to instant no-ops, "cmd_tick has not finished N
  # seconds after a second one started" is a claim about wall-clock time on
  # a shared CI machine, and a genuinely lock-less cmd_tick that happens to
  # be slow for any other reason reads as correctly blocked -- the one
  # assertion in that shape that could survive its own subject being
  # reverted. The lock_take/lock_drop primitive is ALREADY proven safe under
  # real concurrency elsewhere in this suite (the reattach race, the
  # port_base_reclaim race); what remains to prove for cmd_tick is only that
  # it calls that already-proven primitive, on the right lock, wrapping the
  # right span -- which is exactly a source-shape question, not a timing
  # one. Same bar this codebase already holds simple single lock_take/
  # lock_drop wraps to elsewhere (alloc_port_base has no dedicated race of
  # its own either); the deeper, check-then-act critical sections earned
  # theirs by being more than a single wrap.
  #
  # Guards against lock_take/lock_drop silently narrowing to cover only PART
  # of cmd_tick (e.g. just the sweep), which would leave the due-job loop
  # still reachable by a second, concurrent tick -- exactly the narrower
  # shape this task's own brief considered and rejected (see the comment on
  # the lock in cmd_tick itself).
  tbody="$(sed -n '/^cmd_tick()/,/^}/p' "$BIN_DIR/agentloop")"
  tlt_line="$(printf '%s\n' "$tbody" | grep -n 'lock_take "\$LOCK_DIR/.tick"'  | head -1 | cut -d: -f1)"
  # Anchored to a bare call line, not a substring match: the comment on the
  # lock itself (right above it) names wt_prune_orphans in prose, and a loose
  # match would find that mention instead of the real call several lines later.
  tsw_line="$(printf '%s\n' "$tbody" | grep -n '^  wt_prune_orphans$'        | head -1 | cut -d: -f1)"
  tpl_line="$(printf '%s\n' "$tbody" | grep -n 'done < <(tick_plan)'         | head -1 | cut -d: -f1)"
  tld_line="$(printf '%s\n' "$tbody" | grep -n 'lock_drop "\$LOCK_DIR/.tick"' | head -1 | cut -d: -f1)"
  if [ -n "${tlt_line:-}" ] && [ -n "${tsw_line:-}" ] && [ -n "${tpl_line:-}" ] && [ -n "${tld_line:-}" ] \
       && [ "$tlt_line" -lt "$tsw_line" ] && [ "$tsw_line" -lt "$tpl_line" ] && [ "$tpl_line" -lt "$tld_line" ]; then
    ok "the lock is taken before the sweep and dropped after the due-job loop"
  else
    bad "cmd_tick's .tick lock does not wrap the whole body (take=${tlt_line:-?} sweep=${tsw_line:-?} joblopp=${tpl_line:-?} drop=${tld_line:-?})"
  fi
  got="$(printf '%s\n' "$tbody" | grep -c 'lock_take "\$LOCK_DIR/.tick"')"
  [ "${got:-0}" -eq 1 ] && ok "lock_take \$LOCK_DIR/.tick appears exactly once ($got)" \
    || bad "lock_take \$LOCK_DIR/.tick appears $got times, expected 1"
  got="$(printf '%s\n' "$tbody" | grep -c 'lock_drop "\$LOCK_DIR/.tick"')"
  [ "${got:-0}" -eq 1 ] && ok "lock_drop \$LOCK_DIR/.tick appears exactly once ($got)" \
    || bad "lock_drop \$LOCK_DIR/.tick appears $got times, expected 1"

  echo "wt_prune_canonicals() — a run dir removed by hand leaves no registration behind"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j5 two "$tmp/g/repo" stampR ) >/dev/null 2>&1
  rm -rf "$tmp/wtroot/j5/stampR"          # behind git's back, the way a human does it
  git -C "$tmp/g/repo" worktree list --porcelain 2>/dev/null | grep -q 'stampR' \
    && ok "git still lists the registration before the prune" \
    || bad "the fixture did not leave a stale registration to clear"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_prune_canonicals ) >/dev/null 2>&1
  git -C "$tmp/g/repo" worktree list --porcelain 2>/dev/null | grep -q 'stampR' \
    && bad "the stale registration survived the prune" \
    || ok "the canonical checkout is clean again"

  echo "wt_prune_orphans() — an open session outlives one sweep and dies of old age"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jT two "$tmp/g/repo" stampT ) >/dev/null 2>&1
  echo open > "$tmp/wtroot/jT/stampT/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    wt_prune_orphans ) >/dev/null 2>&1
  [ -d "$tmp/wtroot/jT/stampT" ] && ok "an open session survives the sweep" \
    || bad "the sweep reaped a session that is still open"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    AGENTLOOP_SESSION_TTL=0
    wt_prune_orphans ) >/dev/null 2>&1
  [ ! -d "$tmp/wtroot/jT/stampT" ] && ok "and is reclaimed once its ttl is up" \
    || bad "an expired session was kept"

  echo "wt_prune_orphans() — a deleted job's run dir still takes its services down"
  printf '%s\n' '#!/usr/bin/env bash' 'echo down >> "$AL_RUN_DIR/../orphan-down.log"' \
    > "$tmp/cfg/provision/two.down.sh"
  chmod +x "$tmp/cfg/provision/two.down.sh"
  rm -f "$tmp/wtroot/jGone/orphan-down.log"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jGone two "$tmp/g/repo" stampG ) >/dev/null 2>&1
  # `.session` present: this fixture is proving out the project-fallback rule
  # for an ORDINARY unmarked dir, not the pre-upgrade adoption case above --
  # without it, the very first sweep below would adopt (mark open, restart
  # the clock, continue) before ever reaching the age/ttl check this test
  # means to exercise, and the down hook this asserts on would never run.
  echo "sess-gone" > "$tmp/wtroot/jGone/stampG/.session"
  # jGone is in NO jobs.json — the job was deleted while its run dir sat there.
  # The project has to come from the manifest, or `down` never runs at all.
  # Left unmarked and young, this dir is exactly the "outlives the sweep" case
  # above and would be kept, not reaped — nothing will ever resume a deleted
  # job to mark it done, so TTL=0 is the only way this dir ever reaches
  # teardown at all, same as it would in the wild once the real TTL is up.
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    AGENTLOOP_SESSION_TTL=0
    wt_prune_orphans ) >/dev/null 2>&1
  [ -f "$tmp/wtroot/jGone/orphan-down.log" ] \
    && ok "the manifest's project is what teardown uses, so down still fires" \
    || bad "a deleted job's services were left running for ever"

  # And the OTHER half of that line. `wt_setup` always writes `.project`, so the
  # assertion above can never reach the `job_get` fallback — it short-circuits
  # every time. The fallback exists for a manifest that cannot answer (truncated,
  # corrupt, or written before the field existed), so build one and prove it
  # still finds a project.
  rm -f "$tmp/wtroot/jGone/orphan-down.log"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jFallback two "$tmp/g/repo" stampF2 ) >/dev/null 2>&1
  # Same reason as jGone above: `.session` keeps this out of the adoption
  # branch, so the single sweep below reaches the age/ttl check and the
  # job_get fallback this test is actually about.
  echo "sess-fb" > "$tmp/wtroot/jFallback/stampF2/.session"
  "$JQ" 'del(.project)' "$tmp/wtroot/jFallback/stampF2/.run.json" \
    > "$tmp/wtroot/jFallback/stampF2/.run.json.tmp" 2>/dev/null \
    && mv "$tmp/wtroot/jFallback/stampF2/.run.json.tmp" \
          "$tmp/wtroot/jFallback/stampF2/.run.json"
  printf '%s' '{"jobs":[{"id":"jFallback","project":"two"}]}' > "$tmp/cfg/jobs.json"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; JOBS_FILE="$tmp/cfg/jobs.json"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"; AGENTLOOP_SESSION_TTL=0
    wt_prune_orphans ) >/dev/null 2>&1
  [ -f "$tmp/wtroot/jFallback/orphan-down.log" ] \
    && ok "a manifest with no project falls back to the jobs file" \
    || bad "the job_get fallback never supplied a project"
  rm -f "$tmp/cfg/provision/two.down.sh" "$tmp/wtroot/jGone/orphan-down.log" \
        "$tmp/wtroot/jFallback/orphan-down.log"

  echo "wt_prune_canonicals() — the path list survives spaces and a malformed entry"
  # The enumeration is the fragile half, so test it directly rather than through
  # a git side effect: a path silently dropped here is a repo that is never
  # pruned again, and nothing anywhere would say so.
  mkdir -p "$tmp/proj"
  cat > "$tmp/proj/nasty.json" <<'NASTY'
{"projects":[
 {"cwd":"/Users/Jane Doe/repo-a"},
 {"cwd":"/Users/Jane"},
 {"cwd":"/Users/Jane Doe/repo-a"},
 {"repos":["not-an-object"],"cwd":"/tmp/malformed"},
 {"repos":[{"path":"/tmp/api"},{"name":"no-path"}],"cwd":"/tmp/web"},
 {"name":"no-cwd-at-all"},
 {"cwd":null}
]}
NASTY
  # LC_ALL=C on the sort below, because the expectation is a byte order and
  # `sort` honours the caller's collation. Under en_US.UTF-8 -- what a GitHub
  # runner sets and a bare shell does not -- "/tmp" sorts BEFORE "/Users",
  # since that collation folds case; under C it does not. Same list, same
  # code, two orders, and the assertion is an exact string. This was green on
  # laptops for months and red on the first CI run that ever set a locale.
  got="$("$JQ" -r '
    .projects[]? | ((.repos // [])[]? | objects | .path), .cwd
    | strings | select(. != "")' "$tmp/proj/nasty.json" 2>/dev/null | LC_ALL=C sort -u | tr '\n' '|')"
  [ "$got" = "/Users/Jane|/Users/Jane Doe/repo-a|/tmp/api|/tmp/malformed|/tmp/web|" ] \
    && ok "a home dir with a space is its own path, and one bad entry drops only itself" \
    || bad "the path list came out as '$got'"
  rm -f "$tmp/proj/nasty.json"

  echo "wt_prune_canonicals() — end to end, a canonical whose path is a space-truncated prefix of another is pruned too"
  # The two blocks above prove the dedup logic in isolation (the jq expression)
  # and the git side effect for a single canonical (the stampR case). Neither
  # can regress on the one thing the finding was actually about: a SECOND real
  # canonical checkout whose path is what "/Users/Jane" is to
  # "/Users/Jane Doe/repo-a" — a literal prefix ending right where the longer
  # path has a space. This drives the real wt_prune_canonicals against two real
  # git repos shaped exactly that way, so a regression back to the
  # space-delimited seen/glob would fail this assertion even though it cannot
  # touch the fixture above (whose paths do not exist on disk).
  mkdir -p "$tmp/g/spacer/Jane Doe/repo-a" "$tmp/g/spacer/Jane"
  for r in "$tmp/g/spacer/Jane Doe/repo-a" "$tmp/g/spacer/Jane"; do
    git -c init.defaultBranch=develop init -q "$r"
    ( cd "$r" && echo hi > f && git add f && $gitc commit -qm init ) >/dev/null 2>&1
  done
  printf '%s' '{"projects":[
      {"name":"spacer-a","cwd":"'"$tmp"'/g/spacer/Jane Doe/repo-a"},
      {"name":"spacer-b","cwd":"'"$tmp"'/g/spacer/Jane"}]}' > "$tmp/proj/spacer.json"
  ( PROJECTS_FILE="$tmp/proj/spacer.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jsp1 spacer-a "$tmp/g/spacer/Jane Doe/repo-a" stampSA
    wt_setup jsp2 spacer-b "$tmp/g/spacer/Jane" stampSB ) >/dev/null 2>&1
  rm -rf "$tmp/wtroot/jsp1/stampSA" "$tmp/wtroot/jsp2/stampSB"
  ( git -C "$tmp/g/spacer/Jane Doe/repo-a" worktree list --porcelain 2>/dev/null | grep -q 'stampSA' \
    && git -C "$tmp/g/spacer/Jane" worktree list --porcelain 2>/dev/null | grep -q 'stampSB' ) \
    && ok "both stale registrations exist before the prune" \
    || bad "the fixture did not leave both stale registrations to clear"
  ( PROJECTS_FILE="$tmp/proj/spacer.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_prune_canonicals ) >/dev/null 2>&1
  git -C "$tmp/g/spacer/Jane" worktree list --porcelain 2>/dev/null | grep -q 'stampSB' \
    && bad "the shorter canonical (.../Jane) was never pruned -- the old seen-glob bug is back" \
    || ok "the shorter canonical (.../Jane) was pruned despite matching a longer path up to a space"
  git -C "$tmp/g/spacer/Jane Doe/repo-a" worktree list --porcelain 2>/dev/null | grep -q 'stampSA' \
    && bad "the longer canonical (.../Jane Doe/repo-a) survived the prune" \
    || ok "the longer canonical (.../Jane Doe/repo-a) was pruned"

  echo "wt_live_worktrees() — a dead slot's worktree is not in use"
  # The sweep hooks are handed this list and refuse to touch anything in it, so
  # a path WRONGLY present here is a stack that never gets cleaned up, and a
  # path wrongly ABSENT is a running agent's database being torn down under it.
  # Both directions are asserted.
  mkdir -p "$tmp/data"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup jLive two "$tmp/g/repo" stampLive ) >/dev/null 2>&1
  mkdir -p "$tmp/locks/jLive/1"
  echo $$ > "$tmp/locks/jLive/1/pid"
  echo "$tmp/wtroot/jLive/stampLive" > "$tmp/locks/jLive/1/worktree"
  got="$( LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"; wt_live_worktrees )"
  printf '%s\n' "$got" | grep -qx "$tmp/wtroot/jLive/stampLive" \
    && ok "a live slot's run dir is reported in use" \
    || bad "a live run's directory was not listed: $got"
  printf '%s\n' "$got" | grep -q "stampLive/" \
    && ok "and so is each repo worktree inside it" \
    || bad "the repo worktrees inside a live run dir were not listed: $got"
  # A slot from a process that is gone. No `boot` file, so slot_alive falls
  # through to the pid, and this pid answers for nobody.
  mkdir -p "$tmp/locks/jDead/1"
  echo 2147483646 > "$tmp/locks/jDead/1/pid"
  echo "$tmp/wtroot/jLive/stampLive-dead" > "$tmp/locks/jDead/1/worktree"
  got="$( LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"; wt_live_worktrees )"
  printf '%s\n' "$got" | grep -q "stampLive-dead" \
    && bad "a dead slot's worktree was reported as still in use — it would never be cleaned up" \
    || ok "a dead slot's worktree is not reported in use"

  echo "wt_project_has_live_run() — an unresolvable job blocks every project"
  ( LOCK_DIR="$tmp/locks"; JOBS_FILE="$tmp/cfg/jobs.json"
    printf '%s' '{"jobs":[{"id":"jLive","project":"two"}]}' > "$tmp/cfg/jobs.json"
    wt_project_has_live_run two ) \
    && ok "a live run of the project is found" \
    || bad "a live run of the project was missed — its stacks would be swept mid-run"
  ( LOCK_DIR="$tmp/locks"; JOBS_FILE="$tmp/cfg/jobs.json"
    wt_project_has_live_run other ) \
    && bad "a live run of 'two' was counted as a live run of 'other'" \
    || ok "a live run of another project does not block this one"
  # jLive is in NO jobs file now: a derived security job, or a job deleted while
  # its run was still going. It must count as live for EVERY project — an empty
  # project comparing unequal to every name is what would silently license a
  # sweep of all of them while that run is still working.
  printf '%s' '{"jobs":[]}' > "$tmp/cfg/jobs.json"
  ( LOCK_DIR="$tmp/locks"; JOBS_FILE="$tmp/cfg/jobs.json"
    wt_project_has_live_run two ) \
    && ok "a live job whose project cannot be resolved blocks the sweep" \
    || bad "an unresolvable live job licensed a sweep — the conservative branch is gone"

  echo "wt_sweep_projects() — periodic, throttled, and never while a run is live"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "swept" >> "$AL_SWEEP_LOG"' \
    'cp "$AL_LIVE_WORKTREES" "$AL_SWEEP_LOG.live"' \
    'cp "$AL_CANONICALS" "$AL_SWEEP_LOG.canon"' \
    > "$tmp/cfg/provision/two.sweep.sh"
  chmod +x "$tmp/cfg/provision/two.sweep.sh"
  # The live slot from the block above is still standing, and `two` is its
  # project again — so this first call must do nothing at all.
  printf '%s' '{"jobs":[{"id":"jLive","project":"two"}]}' > "$tmp/cfg/jobs.json"
  rm -f "$tmp/data/.sweep.stamp" "$tmp/data/sweep.log"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; JOBS_FILE="$tmp/cfg/jobs.json"
    DATA_DIR="$tmp/data"; LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    AL_SWEEP_LOG="$tmp/data/sweep.log"; export AL_SWEEP_LOG
    wt_sweep_projects ) >/dev/null 2>&1
  [ ! -f "$tmp/data/sweep.log" ] \
    && ok "a project with a live run is not swept" \
    || bad "the sweep ran while a run of that project was still live"
  # Kill the claim and it runs.
  rm -rf "$tmp/locks/jLive"
  rm -f "$tmp/data/.sweep.stamp"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; JOBS_FILE="$tmp/cfg/jobs.json"
    DATA_DIR="$tmp/data"; LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    AL_SWEEP_LOG="$tmp/data/sweep.log"; export AL_SWEEP_LOG
    wt_sweep_projects ) >/dev/null 2>&1
  [ "$(grep -c . "$tmp/data/sweep.log" 2>/dev/null || echo 0)" = "1" ] \
    && ok "with nothing live, the project's sweep hook runs" \
    || bad "the sweep hook did not run for an idle project"
  # Immediately again: the tick fires every 60s and a sweep shells out to a
  # container daemon, so without the throttle this would run sixty times an hour
  # more than intended.
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; JOBS_FILE="$tmp/cfg/jobs.json"
    DATA_DIR="$tmp/data"; LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    AL_SWEEP_LOG="$tmp/data/sweep.log"; export AL_SWEEP_LOG
    wt_sweep_projects ) >/dev/null 2>&1
  [ "$(grep -c . "$tmp/data/sweep.log" 2>/dev/null || echo 0)" = "1" ] \
    && ok "a second call inside the interval is throttled away" \
    || bad "the sweep ran twice inside one interval"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; JOBS_FILE="$tmp/cfg/jobs.json"
    DATA_DIR="$tmp/data"; LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtroot"
    AGENTLOOP_SWEEP_INTERVAL=0
    AL_SWEEP_LOG="$tmp/data/sweep.log"; export AL_SWEEP_LOG
    wt_sweep_projects ) >/dev/null 2>&1
  [ "$(grep -c . "$tmp/data/sweep.log" 2>/dev/null || echo 0)" = "1" ] \
    && ok "an interval of 0 disables the sweep rather than running it every tick" \
    || bad "AGENTLOOP_SWEEP_INTERVAL=0 ran the hook instead of switching it off"
  # And the hook is handed the two facts it cannot work out for itself. The
  # canonical list is what stops it reclaiming a developer's own environment, so
  # an empty one is not a cosmetic defect.
  grep -q "$tmp/g/repo" "$tmp/data/sweep.log.canon" 2>/dev/null \
    && ok "the hook is handed the canonical checkouts to protect" \
    || bad "AL_CANONICALS reached the hook empty — nothing would be protected"

  echo "toggle-many flips only the jobs it was handed"
  printf '%s' '{"jobs":[{"id":"a"},{"id":"b","enabled":false},{"id":"c"}]}' > "$tmp/tm.json"
  got="$("$JQ" -c --argjson want '["a","b"]' --argjson v false "$TOGGLE_MANY_FILTER" "$tmp/tm.json")"
  [ "$got" = '{"jobs":[{"id":"a","enabled":false},{"id":"b","enabled":false},{"id":"c"}]}' ] \
    && ok "disabling a set leaves every job outside it byte-identical" \
    || bad "toggle-many disable produced: $got"
  got="$("$JQ" -c --argjson want '["b"]' --argjson v true "$TOGGLE_MANY_FILTER" "$tmp/tm.json")"
  [ "$got" = '{"jobs":[{"id":"a"},{"id":"b","enabled":true},{"id":"c"}]}' ] \
    && ok "enabling one job adds no key to the others" \
    || bad "toggle-many enable produced: $got"

  echo "the suite itself touches nothing outside its scratch dir"
  [ "$(size_of "$_real_tick")" = "$_tick0" ] \
    && ok "the real tick.log is byte-identical after the suite" \
    || bad "the suite appended to the real tick.log ($_tick0 -> $(size_of "$_real_tick") bytes)"
  [ "$(size_of "$_real_exec")" = "$_exec0" ] \
    && ok "the real exec.log is byte-identical after the suite" \
    || bad "the suite appended to the real exec.log ($_exec0 -> $(size_of "$_real_exec") bytes)"
  [ "$(stat -f %m "$_real_pf" 2>/dev/null || echo none)" = "$_pf0" ] \
    && ok "the suite never touched the real config/platforms.json" \
    || bad "the suite created or rewrote $_real_pf"

  echo "log_rotate() — a log that grows without bound is capped, never lost"
  printf 'old line\n' > "$tmp/r.log"
  log_rotate "$tmp/r.log" 1000000
  [ ! -e "$tmp/r.log.1" ] && ok "a small log is left alone" || bad "a small log was rotated"
  local i=0; : > "$tmp/r.log"
  while [ "$i" -lt 200 ]; do printf 'a line that takes up some space %s\n' "$i" >> "$tmp/r.log"; i=$((i+1)); done
  log_rotate "$tmp/r.log" 1000
  [ "$(size_of "$tmp/r.log")" = "0" ] && ok "an oversized log is truncated" \
    || bad "log still $(size_of "$tmp/r.log") bytes"
  grep -q 'a line that takes up some space 199' "$tmp/r.log.1" 2>/dev/null \
    && ok "the previous generation is kept in .1" || bad "rotated content was lost"
  # A second rotation must not stack generations for ever.
  : > "$tmp/r.log"; i=0
  while [ "$i" -lt 200 ]; do printf 'second generation %s\n' "$i" >> "$tmp/r.log"; i=$((i+1)); done
  log_rotate "$tmp/r.log" 1000
  grep -q 'second generation 199' "$tmp/r.log.1" 2>/dev/null \
    && ok "rotating again replaces .1 rather than growing a chain" || bad ".1 was not replaced"
  [ ! -e "$tmp/r.log.2" ] && ok "no .2 is ever created" || bad "a .2 generation appeared"

  echo "precheck_verdict() — a broken probe is not an idle one"
  [ "$(precheck_verdict 0)" = "work" ]  && ok "exit 0 means work was found"    || bad "exit 0 -> $(precheck_verdict 0)"
  [ "$(precheck_verdict 1)" = "idle" ]  && ok "exit 1 means nothing to do"     || bad "exit 1 -> $(precheck_verdict 1)"
  # The whole point: a probe that could not run at all used to be indistinguishable
  # from one that ran and found nothing, so a job whose credentials had gone
  # missing sat "idle" for ever with nothing showing red anywhere.
  [ "$(precheck_verdict 2)" = "error" ] && ok "exit 2 is a broken probe"       || bad "exit 2 -> $(precheck_verdict 2)"
  [ "$(precheck_verdict 127)" = "error" ] && ok "exit 127 (missing command) is broken" || bad "exit 127 -> $(precheck_verdict 127)"
  [ "$(precheck_verdict '')" = "error" ]  && ok "a missing exit code is broken" || bad "empty -> $(precheck_verdict '')"

  echo "lock_take() — a lock is stolen from the dead, never from the living"
  local t0 elapsed dead=99999
  if kill -0 "$dead" 2>/dev/null; then dead=99998; fi
  lock_take "$tmp/free" && ok "a free lock is taken" || bad "could not take a free lock"
  [ "$(cat "$tmp/free/pid" 2>/dev/null)" = "$$" ] && ok "the holder records its pid" || bad "no pid recorded"
  lock_drop "$tmp/free"
  [ ! -d "$tmp/free" ] && ok "dropping removes the lock" || bad "lock survived the drop"

  mkdir -p "$tmp/stale"; echo "$dead" > "$tmp/stale/pid"
  t0="$(now_epoch)"; lock_take "$tmp/stale"; elapsed=$(( $(now_epoch) - t0 ))
  [ "$elapsed" -lt 2 ] && ok "a lock whose owner is gone is taken at once (${elapsed}s)" \
    || bad "waited ${elapsed}s for a dead owner"
  lock_drop "$tmp/stale"

  # The regression that matters. Every one of these locks used to be broken
  # purely on elapsed time (~4s), so a journal rewrite over a large history —
  # exactly the slow case — would have its lock stolen mid-rewrite by a run
  # ending, and lose the record the lock exists to protect.
  mkdir -p "$tmp/live"; echo $$ > "$tmp/live/pid"
  ( lock_take "$tmp/live" && : > "$tmp/live-was-stolen" ) >/dev/null 2>&1 & local waiter=$!
  sleep 5
  [ ! -f "$tmp/live-was-stolen" ] \
    && ok "a lock held by a LIVE process is still held after 5s" \
    || bad "the lock was stolen from a live holder"
  kill "$waiter" 2>/dev/null; wait "$waiter" 2>/dev/null
  rm -rf "$tmp/live"

  # The regression 9.6 closes: a bare `kill -0` cannot tell a recycled pid
  # from the SAME process. .state.lock, .journal.lock, .ports and .resume all
  # live under data/ and survive a reboot exactly like a run slot -- and the
  # kernel reissues pids from 1 on the way up, so a live-looking pid here can
  # belong to an entirely different process than the one that took the lock.
  # Simulate it directly: our own pid is alive by definition (kill -0 $$
  # always succeeds), but a `boot` file that disagrees with boot_id says this
  # lock is from a boot that is gone -- the same signal slot_alive already
  # trusts for run slots.
  mkdir -p "$tmp/oldboot"; echo $$ > "$tmp/oldboot/pid"; echo "0" > "$tmp/oldboot/boot"
  t0="$(now_epoch)"; lock_take "$tmp/oldboot"; elapsed=$(( $(now_epoch) - t0 ))
  [ "$elapsed" -lt 2 ] \
    && ok "a live-looking pid from an earlier boot is taken at once (${elapsed}s), not waited on forever" \
    || bad "waited ${elapsed}s for a pid that only looks like the same process"
  [ "$(cat "$tmp/oldboot/boot" 2>/dev/null)" = "$(boot_id)" ] \
    && ok "and the new holder records THIS boot" \
    || bad "boot file was not refreshed on take"
  lock_drop "$tmp/oldboot"

  # The control: swapping kill -0 for slot_alive must not turn every lock into
  # an instant steal -- a live holder from THIS boot is still waited for, and
  # by an unbounded wait however old its lock is: only a bounded wait (the
  # models.json lock) takes a lock for its age.
  mkdir -p "$tmp/thisboot"; echo $$ > "$tmp/thisboot/pid"; boot_id > "$tmp/thisboot/boot"; touch -t 202001010000 "$tmp/thisboot"
  ( lock_take "$tmp/thisboot" && : > "$tmp/thisboot-was-stolen" ) >/dev/null 2>&1 & local waiter2=$!
  sleep 3
  [ ! -f "$tmp/thisboot-was-stolen" ] \
    && ok "a live holder from THIS boot is still held after 3s, however old its lock" \
    || bad "a live same-boot holder was stolen from"
  kill "$waiter2" 2>/dev/null; wait "$waiter2" 2>/dev/null
  rm -rf "$tmp/thisboot" "$tmp/thisboot-was-stolen"

  # An owner with no pid to read is a taker between its mkdir and its pid, or
  # one killed there -- and only the lock's own age tells them apart: a lock
  # directory changes when an entry is added or removed, so one with no pid is
  # as old as its mkdir. Older than the grace, nobody is on the way to it, and
  # an unbounded wait takes it at once; the wait used to give such an owner
  # the grace counted in its own polls, however old the lock already was. In
  # the background, so that a wait that never ends fails here instead of
  # hanging the suite; the grace pinned, as the operator may have set it.
  mkdir -p "$tmp/ownerless"; touch -t 202001010000 "$tmp/ownerless"
  ( LOCK_GRACE_SECONDS=30; t0="$(now_epoch)"; lock_take "$tmp/ownerless"; r=$?; echo "$r $(( $(now_epoch) - t0 ))" > "$tmp/ownerless.rc" ) >/dev/null 2>&1 & local owaiter=$!
  i=0; while [ ! -s "$tmp/ownerless.rc" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$(( i + 1 )); done
  kill "$owaiter" 2>/dev/null; wait "$owaiter" 2>/dev/null
  got="$(cat "$tmp/ownerless.rc" 2>/dev/null)"
  [ "${got%% *}" = 0 ] && [ "$(num "${got#* }" 99)" -lt 2 ] && [ "$(cat "$tmp/ownerless/pid" 2>/dev/null)" = "$$" ] \
    && ok "an old lock left with no pid is taken at once by an unbounded wait (${got#* }s)" \
    || bad "an unbounded wait on an old lock with no pid: [$got] (exit, seconds) within 5 s, the lock names pid [$(cat "$tmp/ownerless/pid" 2>/dev/null)]"
  rm -rf "$tmp/ownerless" "$tmp/ownerless.rc"

  # The regression that rule is for. A waiter that had already waited past
  # the grace -- behind live owners, a long journal rewrite -- broke the NEXT
  # owner's lock if it looked in the instant between that owner's mkdir and
  # its pid, and both then held it. How long the waiter has waited says
  # nothing about that lock; its age does. Here the owner stays live until
  # the waiter has polled half as many times again as a grace of 1 s allowed
  # (150 polls against 100: the sleep between polls counts them), then leaves
  # the lock the way the next owner holds it before its pid: empty, and as
  # young as that moment, since removing its entries is a change like any.
  mkdir -p "$tmp/handover"; echo $$ > "$tmp/handover/pid"; boot_id > "$tmp/handover/boot"
  ( LOCK_GRACE_SECONDS=1; n=0
    sleep() { n=$(( n + 1 )); [ "$n" != 150 ] || : > "$tmp/handover.polled"; command sleep "$@"; }
    lock_take "$tmp/handover" && : > "$tmp/handover.taken" ) >/dev/null 2>&1 & local hwaiter=$!
  i=0; while [ ! -e "$tmp/handover.polled" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$(( i + 1 )); done
  rm -f "$tmp/handover/pid" "$tmp/handover/boot"; sleep 0.3
  [ -e "$tmp/handover.polled" ] && [ ! -e "$tmp/handover.taken" ] && [ ! -e "$tmp/handover/pid" ] && kill -0 "$hwaiter" 2>/dev/null \
    && ok "a young lock with no pid is never broken by an unbounded wait, however long that wait has already been" \
    || bad "the next owner's lock, before its pid, was broken: polled 150 times [$([ -e "$tmp/handover.polled" ] && echo yes || echo no)], taken [$([ -e "$tmp/handover.taken" ] && echo yes || echo no)], pid [$(cat "$tmp/handover/pid" 2>/dev/null)]"
  i=0; while [ ! -e "$tmp/handover.taken" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$(( i + 1 )); done
  [ -e "$tmp/handover.taken" ] && [ "$(cat "$tmp/handover/pid" 2>/dev/null)" = "$$" ] \
    && ok "and the same wait takes it once it is older than the grace" \
    || bad "a lock with no pid, past a grace of 1 s, was still not taken 5 s later"
  kill "$hwaiter" 2>/dev/null; wait "$hwaiter" 2>/dev/null
  rm -rf "$tmp/handover" "$tmp/handover.polled" "$tmp/handover.taken"

  # Where that age ends: both clocks count whole seconds, so a lock whose age
  # reads exactly the grace may be up to a second younger than it, and is not
  # abandoned yet; a second more and it is. Asked right after a second turns,
  # both inside it -- tried again should a stall carry them into the next.
  local edge_s edge_now at_grace="" past_grace="" tries=0
  mkdir -p "$tmp/edge"
  while [ "$tries" -lt 3 ]; do
    tries=$(( tries + 1 ))
    edge_s="$(now_epoch)"; while [ "$(now_epoch)" = "$edge_s" ]; do sleep 0.01; done
    edge_now="$(now_epoch)"
    touch -t "$(date -r $(( edge_now - 30 )) +%Y%m%d%H%M.%S)" "$tmp/edge"; ( LOCK_GRACE_SECONDS=30; lock_abandoned "$tmp/edge" ); at_grace=$?
    touch -t "$(date -r $(( edge_now - 31 )) +%Y%m%d%H%M.%S)" "$tmp/edge"; ( LOCK_GRACE_SECONDS=30; lock_abandoned "$tmp/edge" ); past_grace=$?
    [ "$(now_epoch)" = "$edge_now" ] && break
    at_grace="" past_grace=""
  done
  [ "$at_grace" = 1 ] && [ "$past_grace" = 0 ] \
    && ok "a lock whose age reads exactly the grace is not abandoned yet; one second more and it is" \
    || bad "lock_abandoned at the grace [$at_grace], a second past it [$past_grace]: 1 and 0 wanted, empty if never inside one second"
  rm -rf "$tmp/edge"

  # The grace comes from the environment (AGENTLOOP_LOCK_GRACE), and every
  # lock does arithmetic with it. Anything but a plain number killed the
  # engine at the first lock found with no pid -- set -u reads abc as an
  # unset variable, and 08 is no octal -- and judged by age such a lock would
  # now wait for good instead. It is read as a decimal number, or the default.
  sed '/^case "${1:-}" in$/,$d' "$SELF" > "$tmp/engine-lib.sh"
  got="$(for g in abc 1x 08 ' 7 ' ''; do
           AGENTLOOP_LOCK_GRACE="$g" AGENTLOOP_CONFIG="$tmp/lg/config" AGENTLOOP_DATA="$tmp/lg/data" \
             /bin/bash -c '. "$1"; printf "%s," "$LOCK_GRACE_SECONDS"' "$SELF" "$tmp/engine-lib.sh" 2>/dev/null
         done)"
  [ "$got" = "30,30,8,7,30," ] \
    && ok "a grace that is not a plain number reads as the default, one with a leading zero as decimal" \
    || bad "AGENTLOOP_LOCK_GRACE abc, 1x, 08, ' 7 ' and unset read as [$got], wanted 30,30,8,7,30,"
  rm -rf "$tmp/engine-lib.sh" "$tmp/lg"

  # Bounded, as the models.json lock takes it: a live holder is given up on
  # once the time is up, and never a moment before it -- exit 1, and the lock
  # stays with its owner -- while a dead one is still taken at once. Timed in
  # milliseconds, since the bound counts whole seconds, and started in the
  # middle of one on the shell's clock: a bound that counted only the whole
  # seconds would give up half a second early there. Beside it, the grace an
  # operator can set (AGENTLOOP_LOCK_GRACE) set as low as 1 must not turn the
  # bounded lock into none: a lock is taken for its age only once it is older
  # than twice the wait as well, which no live write ever is. Both in the
  # background, so that a bound that never fires fails here instead of
  # hanging the suite; the grace is pinned, as the operator may have set it.
  local LOCK_GRACE_SECONDS=30
  now_ms() { "$PYTHON" -c 'import time; print(int(time.time() * 1000))'; }
  mkdir -p "$tmp/bounded" "$tmp/floor"
  echo $$ > "$tmp/bounded/pid"; boot_id > "$tmp/bounded/boot"; echo $$ > "$tmp/floor/pid"; boot_id > "$tmp/floor/boot"
  ( LOCK_GRACE_SECONDS=1; lock_take "$tmp/floor" 2; echo "$?" > "$tmp/floor.rc" ) >/dev/null 2>&1 & local fwaiter=$!
  ( s=$SECONDS; while [ "$SECONDS" = "$s" ]; do sleep 0.01; done; sleep 0.4
    t0="$(now_ms)"; lock_take "$tmp/bounded" 2; r=$?; echo "$r $(( $(now_ms) - t0 ))" > "$tmp/bounded.rc" ) >/dev/null 2>&1 & local bwaiter=$!
  i=0; while { [ ! -s "$tmp/bounded.rc" ] || [ ! -s "$tmp/floor.rc" ]; } && [ "$i" -lt 80 ]; do sleep 0.1; i=$(( i + 1 )); done
  kill "$bwaiter" "$fwaiter" 2>/dev/null; wait "$bwaiter" "$fwaiter" 2>/dev/null
  got="$(cat "$tmp/bounded.rc" 2>/dev/null)"; elapsed="$(num "${got#* }" 99999)"
  [ "${got%% *}" = 1 ] && [ "$elapsed" -ge 2000 ] && [ "$elapsed" -lt 4000 ] && [ "$(cat "$tmp/bounded/pid")" = "$$" ] \
    && ok "a bounded wait gives up on a live holder once its time is up, never before (${elapsed} ms of 2 s), and leaves the lock to it" \
    || bad "a bounded wait on a live holder: [$got] (exit, milliseconds), the lock now names pid $(cat "$tmp/bounded/pid" 2>/dev/null)"
  [ "$(cat "$tmp/floor.rc" 2>/dev/null)" = 1 ] && [ "$(cat "$tmp/floor/pid")" = "$$" ] \
    && ok "with a grace of 1 s, a bounded wait still gives up on a live holder rather than take its lock" \
    || bad "a bounded wait with a grace of 1 s: exit [$(cat "$tmp/floor.rc" 2>/dev/null)], the lock now names pid $(cat "$tmp/floor/pid" 2>/dev/null)"
  rm -rf "$tmp/floor" "$tmp/floor.rc"
  echo "$dead" > "$tmp/bounded/pid"
  t0="$(now_epoch)"; lock_take "$tmp/bounded" 2; got=$?; elapsed=$(( $(now_epoch) - t0 ))
  [ "$got" = 0 ] && [ "$elapsed" -lt 2 ] && [ "$(cat "$tmp/bounded/pid")" = "$$" ] \
    && ok "and a dead holder's lock is still taken at once by a bounded wait (${elapsed}s)" \
    || bad "a bounded wait on a dead holder: exit $got after ${elapsed}s"
  lock_drop "$tmp/bounded"; rm -f "$tmp/bounded.rc"
  # A stale lock that cannot be removed (its directory read-only) still ends
  # a bounded wait on time -- a dead owner's, and an old one with no pid: the
  # break used to go straight back to mkdir, and spun on rm for ever without
  # once reaching the bound. Root removes them whatever the mode, so there is
  # nothing to check as root.
  if [ "$(id -u)" = 0 ]; then
    ok "a stale lock that cannot be removed: not checkable as root, who removes it anyway"
  else
    mkdir -p "$tmp/unremovable" "$tmp/unremovable2"; echo "$dead" > "$tmp/unremovable/pid"; : > "$tmp/unremovable2/boot"
    touch -t 202001010000 "$tmp/unremovable2"; chmod 555 "$tmp/unremovable" "$tmp/unremovable2"
    ( t0="$(now_epoch)"; lock_take "$tmp/unremovable" 1; r=$?; echo "$r $(( $(now_epoch) - t0 ))" > "$tmp/unremovable.rc" ) >/dev/null 2>&1 & local uwaiter=$!
    ( t0="$(now_epoch)"; lock_take "$tmp/unremovable2" 1; r=$?; echo "$r $(( $(now_epoch) - t0 ))" > "$tmp/unremovable2.rc" ) >/dev/null 2>&1 & local uwaiter2=$!
    i=0; while { [ ! -s "$tmp/unremovable.rc" ] || [ ! -s "$tmp/unremovable2.rc" ]; } && [ "$i" -lt 60 ]; do sleep 0.1; i=$(( i + 1 )); done
    kill "$uwaiter" "$uwaiter2" 2>/dev/null; wait "$uwaiter" "$uwaiter2" 2>/dev/null
    chmod 755 "$tmp/unremovable" "$tmp/unremovable2"
    local ua ub
    ua="$(cat "$tmp/unremovable.rc" 2>/dev/null)"; ub="$(cat "$tmp/unremovable2.rc" 2>/dev/null)"
    [ "${ua%% *}" = 1 ] && [ "$(num "${ua#* }" 99)" -le 4 ] && [ "${ub%% *}" = 1 ] && [ "$(num "${ub#* }" 99)" -le 4 ] \
      && ok "a stale lock that cannot be removed ends a bounded wait on time all the same, a dead owner's or an old one with no pid" \
      || bad "a bounded wait on a stale lock it cannot remove: dead owner [$ua], old with no pid [$ub] (exit, seconds), within 6 s"
    rm -rf "$tmp/unremovable" "$tmp/unremovable2" "$tmp/unremovable.rc" "$tmp/unremovable2.rc"
  fi

  # acquire_lock, the _models mutex, takes the same lock without waiting --
  # and broke one with no pid on sight: the owner inside that gap robbed
  # outright, and two refreshes then ran at once. The same rule holds there:
  # a young lock with no pid is a taker on its way, refused like a live one;
  # an old one is nobody's, and taken.
  mkdir -p "$tmp/acq/_young" "$tmp/acq/_old"; touch -t 202001010000 "$tmp/acq/_old"
  ( LOCK_DIR="$tmp/acq"; LOCK_GRACE_SECONDS=30; acquire_lock _young ); local ryoung=$?
  ( LOCK_DIR="$tmp/acq"; LOCK_GRACE_SECONDS=30; acquire_lock _old ); local rold=$?
  [ "$ryoung" = 1 ] && [ -d "$tmp/acq/_young" ] && [ ! -e "$tmp/acq/_young/pid" ] \
    && ok "acquire_lock refuses a young lock with no pid, a taker between its mkdir and its pid, instead of breaking it" \
    || bad "acquire_lock on a young lock with no pid: exit $ryoung, the lock names pid [$(cat "$tmp/acq/_young/pid" 2>/dev/null)]"
  [ "$rold" = 0 ] && [ "$(cat "$tmp/acq/_old/pid" 2>/dev/null)" = "$$" ] \
    && ok "and takes an old one, abandoned" \
    || bad "acquire_lock on an old lock with no pid: exit $rold, the lock names pid [$(cat "$tmp/acq/_old/pid" 2>/dev/null)]"
  rm -rf "$tmp/acq"

  echo "lock_take()/acquire_lock() — two waiters that judged the same stale lock break it once"
  # Breaking a lock is check-then-act. Two waiters that both found the owner
  # gone each removed "it" -- and the slower one removed the lock the faster
  # one had just taken in its place, so both held it: two journal rewrites,
  # two state writes, two refreshes at once. Here the slower waiter (B) is held
  # right after its judgement of the stale lock until the faster one (A) has
  # broken it, taken it and left a mark in it; a second later A checks its
  # mark is still there. Both are subshells, where $$ is this suite's own pid
  # for either, so the mark says whose lock it is, not the pid.
  local rdead=99999; if kill -0 "$rdead" 2>/dev/null; then rdead=99998; fi
  eval "orig_slot_alive() $(declare -f slot_alive | tail -n +2)"
  eval "orig_lock_abandoned() $(declare -f lock_abandoned | tail -n +2)"
  race_a() { # race_a <case> <take-command...> -- waits for B's judgement, then takes, marks, holds 1 s, checks
    local c="$tmp/$1" i=0; shift
    while [ ! -e "$c.B-judged" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$(( i + 1 )); done
    "$@" || return 1
    : > "$c.lock/A-mark"; : > "$c.A-holds"; sleep 1
    [ -e "$c.lock/A-mark" ] && : > "$c.A-kept"
    : > "$c.A-done"
  }
  race_wait() { # race_wait <case> <pids...> -- until A is done and B has an answer, 6 s at most
    local c="$tmp/$1" i=0; shift
    while { [ ! -e "$c.A-done" ] || [ ! -e "$c.B-rc" ]; } && [ "$i" -lt 60 ]; do sleep 0.1; i=$(( i + 1 )); done
    kill "$@" 2>/dev/null; wait "$@" 2>/dev/null
  }
  # 1. lock_take, the owner dead.
  mkdir -p "$tmp/race1.lock"; echo "$rdead" > "$tmp/race1.lock/pid"; boot_id > "$tmp/race1.lock/boot"
  ( slot_alive() { orig_slot_alive "$@" && return 0; : > "$tmp/race1.B-judged"
                   while [ ! -e "$tmp/race1.A-holds" ]; do command sleep 0.01; done; return 1; }
    lock_take "$tmp/race1.lock"; r=$?; [ -e "$tmp/race1.A-done" ] && w=after || w=during
    echo "$r $w" > "$tmp/race1.B-rc" ) >/dev/null 2>&1 & local rb1=$!
  ( race_a race1 lock_take "$tmp/race1.lock" && lock_drop "$tmp/race1.lock" ) >/dev/null 2>&1 & local ra1=$!
  race_wait race1 "$rb1" "$ra1"
  [ -e "$tmp/race1.A-kept" ] && [ "$(cat "$tmp/race1.B-rc" 2>/dev/null)" = "0 after" ] \
    && ok "lock_take: a dead owner's lock is broken once -- the waiter that judged it too is left waiting, and takes it after" \
    || bad "lock_take on a dead owner's lock, two waiters: the first one's mark kept [$([ -e "$tmp/race1.A-kept" ] && echo yes || echo no)], the second one [$(cat "$tmp/race1.B-rc" 2>/dev/null)] (exit, while or after the first held it)"
  # 2. lock_take, an old lock with no pid (abandoned). A holds the new lock
  # as a taker does between its mkdir and its pid -- with no pid either --
  # so only which directory was judged tells the two locks apart.
  mkdir -p "$tmp/race2.lock"; touch -t 202001010000 "$tmp/race2.lock"
  take_before_its_pid() { lock_take "$1" && rm -f "$1/pid" "$1/boot"; }
  ( lock_abandoned() { orig_lock_abandoned "$@" || return 1; : > "$tmp/race2.B-judged"
                       while [ ! -e "$tmp/race2.A-holds" ]; do command sleep 0.01; done; return 0; }
    LOCK_GRACE_SECONDS=30; lock_take "$tmp/race2.lock"; r=$?; [ -e "$tmp/race2.A-done" ] && w=after || w=during
    echo "$r $w" > "$tmp/race2.B-rc" ) >/dev/null 2>&1 & local rb2=$!
  ( LOCK_GRACE_SECONDS=30; race_a race2 take_before_its_pid "$tmp/race2.lock" && lock_drop "$tmp/race2.lock" ) >/dev/null 2>&1 & local ra2=$!
  race_wait race2 "$rb2" "$ra2"
  [ -e "$tmp/race2.A-kept" ] && [ "$(cat "$tmp/race2.B-rc" 2>/dev/null)" = "0 after" ] \
    && ok "lock_take: an abandoned lock is broken once, never the fresh one the first waiter took in its place" \
    || bad "lock_take on an abandoned lock, two waiters: the first one's mark kept [$([ -e "$tmp/race2.A-kept" ] && echo yes || echo no)], the second one [$(cat "$tmp/race2.B-rc" 2>/dev/null)] (exit, while or after the first held it)"
  # 3. acquire_lock, which does not wait: the second taker is refused.
  mkdir -p "$tmp/race3/_job"; echo "$rdead" > "$tmp/race3/_job/pid"; boot_id > "$tmp/race3/_job/boot"
  ln -s "$tmp/race3/_job" "$tmp/race3.lock"
  ( slot_alive() { orig_slot_alive "$@" && return 0; : > "$tmp/race3.B-judged"
                   while [ ! -e "$tmp/race3.A-holds" ]; do command sleep 0.01; done; return 1; }
    LOCK_DIR="$tmp/race3"; acquire_lock _job; r=$?; [ -e "$tmp/race3.A-done" ] && w=after || w=during
    echo "$r $w" > "$tmp/race3.B-rc" ) >/dev/null 2>&1 & local rb3=$!
  ( LOCK_DIR="$tmp/race3"; race_a race3 acquire_lock _job && release_lock _job ) >/dev/null 2>&1 & local ra3=$!
  race_wait race3 "$rb3" "$ra3"
  [ -e "$tmp/race3.A-kept" ] && [ "$(cat "$tmp/race3.B-rc" 2>/dev/null)" = "1 during" ] \
    && ok "acquire_lock: a dead owner's lock is taken once -- the other taker that judged it too is refused, not handed the same lock" \
    || bad "acquire_lock on a dead owner's lock, two takers: the first one's mark kept [$([ -e "$tmp/race3.A-kept" ] && echo yes || echo no)], the second one [$(cat "$tmp/race3.B-rc" 2>/dev/null)] (exit, while or after the first held it)"
  # 4. The bounded wait (models_lock), which takes a lock for its age alone,
  # whoever it names.
  eval "orig_lock_older_than() $(declare -f lock_older_than | tail -n +2)"
  mkdir -p "$tmp/race4.lock"; echo $$ > "$tmp/race4.lock/pid"; boot_id > "$tmp/race4.lock/boot"; touch -t 202001010000 "$tmp/race4.lock"
  ( lock_older_than() { orig_lock_older_than "$@" || return 1; : > "$tmp/race4.B-judged"
                        while [ ! -e "$tmp/race4.A-holds" ]; do command sleep 0.01; done; return 0; }
    LOCK_GRACE_SECONDS=30; lock_take "$tmp/race4.lock" 5; r=$?; [ -e "$tmp/race4.A-done" ] && w=after || w=during
    echo "$r $w" > "$tmp/race4.B-rc" ) >/dev/null 2>&1 & local rb4=$!
  ( LOCK_GRACE_SECONDS=30; race_a race4 lock_take "$tmp/race4.lock" 5 && lock_drop "$tmp/race4.lock" ) >/dev/null 2>&1 & local ra4=$!
  race_wait race4 "$rb4" "$ra4"
  [ -e "$tmp/race4.A-kept" ] && [ "$(cat "$tmp/race4.B-rc" 2>/dev/null)" = "0 after" ] \
    && ok "lock_take, bounded: a lock taken for its age is taken once, never the fresh one the first writer took in its place" \
    || bad "a bounded lock_take on an old lock, two writers: the first one's mark kept [$([ -e "$tmp/race4.A-kept" ] && echo yes || echo no)], the second one [$(cat "$tmp/race4.B-rc" 2>/dev/null)] (exit, while or after the first held it)"
  rm -rf "$tmp"/race1.* "$tmp"/race2.* "$tmp"/race3 "$tmp"/race3.* "$tmp"/race4.*
  # The breaker itself. While another breaker holds it nothing is removed --
  # that one checks and removes, the rest take their turn -- and one left by
  # a breaker killed mid-break is cleared once older than LOCK_BREAKER_STALE,
  # so the stale lock is still broken after it. The server's journal_lock
  # takes the breaker by the same name, a hidden sibling of the lock.
  mkdir -p "$tmp/brk/.x.break" "$tmp/brk/x"; echo "$rdead" > "$tmp/brk/x/pid"
  lock_break "$tmp/brk/x" "$(lock_id "$tmp/brk/x")" "$rdead"; local rbusy=$?
  [ "$rbusy" = 1 ] && [ -d "$tmp/brk/x" ] && [ -d "$tmp/brk/.x.break" ] \
    && ok "lock_break removes nothing while another breaker holds the breaker" \
    || bad "lock_break with the breaker held elsewhere: exit $rbusy, the lock [$([ -d "$tmp/brk/x" ] && echo kept || echo removed)]"
  touch -t 202001010000 "$tmp/brk/.x.break"
  lock_break "$tmp/brk/x" "$(lock_id "$tmp/brk/x")" "$rdead"
  lock_break "$tmp/brk/x" "$(lock_id "$tmp/brk/x")" "$rdead"; local rnext=$?
  [ "$rnext" = 0 ] && [ ! -e "$tmp/brk/x" ] && [ ! -e "$tmp/brk/.x.break" ] \
    && ok "and one left behind by a killed breaker is cleared, so the stale lock is broken after all" \
    || bad "lock_break past a stale breaker: exit $rnext, the lock [$([ -e "$tmp/brk/x" ] && echo kept || echo removed)], the breaker [$([ -e "$tmp/brk/.x.break" ] && echo kept || echo cleared)]"
  rm -rf "$tmp/brk"

  echo "backoff_multiplier() — a job that only ever fails must stop costing full price"
  # Nothing slowed a failing job down: it relaunched every interval, at full
  # budget, for as long as it kept failing. 14 dev/review jobs on a 5-minute
  # interval is a lot of money to spend discovering the same breakage.
  [ "$(backoff_multiplier 0)" = "1" ] && ok "a healthy job is never slowed"        || bad "streak 0 -> $(backoff_multiplier 0)"
  [ "$(backoff_multiplier 2)" = "1" ] && ok "two failures are still just noise"    || bad "streak 2 -> $(backoff_multiplier 2)"
  [ "$(backoff_multiplier 3)" = "2" ] && ok "the third failure doubles the wait"   || bad "streak 3 -> $(backoff_multiplier 3)"
  [ "$(backoff_multiplier 4)" = "4" ] && ok "it keeps doubling"                    || bad "streak 4 -> $(backoff_multiplier 4)"
  [ "$(backoff_multiplier 7)" = "16" ] && ok "the multiplier is capped at 16x"     || bad "streak 7 -> $(backoff_multiplier 7)"
  [ "$(backoff_multiplier 99)" = "16" ] && ok "and stays capped"                   || bad "streak 99 -> $(backoff_multiplier 99)"
  [ "$(backoff_multiplier '')" = "1" ] && ok "an absent streak is not a failure"   || bad "empty -> $(backoff_multiplier '')"
  [ "$(effective_interval 300 0)" = "300" ] && ok "a healthy job keeps its interval" || bad "300/0 -> $(effective_interval 300 0)"
  [ "$(effective_interval 300 4)" = "1200" ] && ok "a failing job waits 4x longer" || bad "300/4 -> $(effective_interval 300 4)"

  echo "state_set_many() — the end of a run is one write, not seven"
  ( STATE_FILE="$tmp/state.json"; echo '{"x":{"keep":"me"}}' > "$STATE_FILE"
    state_set_many x '{"last_status":"success","last_cost":1.25,"fail_streak":0}'
    printf '%s|%s|%s|%s\n' "$(state_get x last_status)" "$(state_get x last_cost)" \
           "$(state_get x fail_streak)" "$(state_get x keep)" ) > "$tmp/sm.out" 2>/dev/null
  got="$(cat "$tmp/sm.out")"
  [ "$got" = "success|1.25|0|me" ] \
    && ok "every field lands and the fields already there survive" || bad "got '$got'"
  ( STATE_FILE="$tmp/state2.json"; echo '{}' > "$STATE_FILE"
    state_set_many newjob '{"a":1}'; state_get newjob a ) > "$tmp/sm2.out" 2>/dev/null
  [ "$(cat "$tmp/sm2.out")" = "1" ] && ok "a job with no state yet is created" || bad "new job: $(cat "$tmp/sm2.out")"

  echo "in_window_vals() — the schedule window, including the one that wraps midnight"
  in_window_vals "" "" 3 600            ; want "no restriction is always open"        0 $?
  in_window_vals "1,2,3,4,5" "" 3 600   ; want "a listed weekday is open"             0 $?
  in_window_vals "1,2,3,4,5" "" 6 600   ; want "an unlisted weekday is closed"        1 $?
  in_window_vals "" "08:00-20:00" 3 600 ; want "inside the hours is open (10:00)"     0 $?
  in_window_vals "" "08:00-20:00" 3 479 ; want "a minute before opening is closed"    1 $?
  in_window_vals "" "08:00-20:00" 3 480 ; want "the opening minute is open"           0 $?
  in_window_vals "" "08:00-20:00" 3 1200; want "the closing minute is closed"         1 $?
  # A window that wraps midnight is the one people get wrong: 22:00-06:00 must
  # be open at 23:00 AND at 02:00, and shut at midday.
  in_window_vals "" "22:00-06:00" 3 1380; want "a wrapping window is open at 23:00"   0 $?
  in_window_vals "" "22:00-06:00" 3 120 ; want "a wrapping window is open at 02:00"   0 $?
  in_window_vals "" "22:00-06:00" 3 720 ; want "a wrapping window is shut at midday"  1 $?
  in_window_vals "6,7" "22:00-06:00" 7 120; want "day and hour must BOTH match"       0 $?
  in_window_vals "6,7" "22:00-06:00" 1 120; want "the wrong day closes it"            1 $?
  # 08:00 written as 08 must not be read as octal — the classic bash trap.
  in_window_vals "" "08:00-09:00" 3 510 ; want "a leading zero is decimal, not octal" 0 $?

  echo "tick_plan() — a job with no schedule window keeps its seven columns"
  # The plan was joined with tabs and read back with IFS=tab. A tab is IFS
  # whitespace, and bash folds a run of it into ONE delimiter -- so a job with
  # no active_days and no active_hours came through as days=interval,
  # hours=last_start, interval=0, and in_window_vals refused it on every tick,
  # silently. The shape with active_hours "" alone is config/jobs.example.json's
  # own. Read here exactly the way cmd_tick reads, column by column.
  mkdir -p "$tmp/tp"
  printf '%s' '{"jobs":[{"id":"nowin","interval_seconds":600},
                        {"id":"hoursblank","active_days":[1,2,3,4,5,6,7],"active_hours":"","interval_seconds":900},
                        {"id":"windowed","active_days":[1,2],"active_hours":"08:00-20:00","interval_seconds":1200,"max_parallel":2},
                        {"id":"off","enabled":false}]}' > "$tmp/tp/jobs.json"
  printf '%s' '{"windowed":{"last_start":1700000000,"fail_streak":2}}' > "$tmp/tp/state.json"
  ( JOBS_FILE="$tmp/tp/jobs.json"; STATE_FILE="$tmp/tp/state.json"; tick_plan ) > "$tmp/tp/plan" 2>/dev/null
  tp_cols() { # tp_cols <job-id> -> the columns after the id, |-joined, read the way cmd_tick reads
    local id days hours interval last streak max_par
    while IFS="$TICK_SEP" read -r id days hours interval last streak max_par; do
      [ "$id" = "$1" ] || continue
      printf '%s|%s|%s|%s|%s|%s\n' "$days" "$hours" "$interval" "$last" "$streak" "$max_par"
    done < "$tmp/tp/plan"
  }
  got="$(tp_cols nowin)"
  [ "$got" = "||600|0|0|3" ] && ok "no days, no hours: both columns empty, the interval where the interval goes" || bad "nowin -> '$got'"
  got="$(tp_cols hoursblank)"
  [ "$got" = "1,2,3,4,5,6,7||900|0|0|3" ] && ok "days set and hours blank (the example file's shape): the hours column stays empty" || bad "hoursblank -> '$got'"
  got="$(tp_cols windowed)"
  [ "$got" = "1,2|08:00-20:00|1200|1700000000|2|2" ] && ok "a fully windowed job reads as before, state included" || bad "windowed -> '$got'"
  [ -z "$(tp_cols off)" ] && ok "a disabled job is not in the plan" || bad "off is planned: '$(tp_cols off)'"
  [ "$(grep -c "$(printf '\t')" "$tmp/tp/plan")" -eq 0 ] && ok "and no tab is left in the plan for IFS to fold" || bad "a tab survives in the plan"

  echo "is_due_vals() — due-ness accounts for the failure backoff"
  is_due_vals 300 "$(( $(now_epoch) - 400 ))" 0 ; want "past its interval is due"     0 $?
  is_due_vals 300 "$(( $(now_epoch) - 100 ))" 0 ; want "inside its interval is not"   1 $?
  is_due_vals 300 "$(( $(now_epoch) - 400 ))" 4 ; want "a backed-off job waits longer" 1 $?
  is_due_vals 300 "$(( $(now_epoch) - 1300 ))" 4; want "and runs once the longer wait passes" 0 $?
  is_due_vals 300 0 0                           ; want "a job that never ran is due"  0 $?

  echo "daily caps — a ceiling can be set per job, per project, and for everything"
  mkdir -p "$tmp/caps"
  printf '%s' '{"jobs":[{"id":"own","project":"P","daily_budget_usd":5},
                        {"id":"inherits","project":"P"},
                        {"id":"loner"}]}' > "$tmp/caps/jobs.json"
  printf '%s' '{"global_daily_budget_usd":100,
                "projects":[{"name":"P","daily_budget_usd":20}]}' > "$tmp/caps/projects.json"
  got="$( JOBS_FILE="$tmp/caps/jobs.json"; PROJECTS_FILE="$tmp/caps/projects.json"; daily_cap_for own )"
  [ "$got" = "5" ] && ok "a job's own cap wins" || bad "own -> '$got'"
  got="$( JOBS_FILE="$tmp/caps/jobs.json"; PROJECTS_FILE="$tmp/caps/projects.json"; daily_cap_for inherits )"
  # This is the gap: daily_budget_usd was read from the job ALONE, so setting it
  # on a project quietly did nothing at all.
  [ "$got" = "20" ] && ok "a job with no cap inherits its project's" || bad "inherits -> '$got'"
  got="$( JOBS_FILE="$tmp/caps/jobs.json"; PROJECTS_FILE="$tmp/caps/projects.json"; daily_cap_for loner )"
  [ -z "$got" ] && ok "no cap anywhere means no cap" || bad "loner -> '$got'"
  got="$( PROJECTS_FILE="$tmp/caps/projects.json"; global_daily_cap )"
  [ "$got" = "100" ] && ok "a global ceiling can be declared" || bad "global -> '$got'"
  got="$( PROJECTS_FILE="$tmp/proj/projects.json"; global_daily_cap )"
  [ -z "$got" ] && ok "and is absent unless declared" || bad "undeclared global -> '$got'"

  echo "rate limits — the usage window the API reports, read and acted on"
  # The dollar caps above are not what stops a subscription; these windows are,
  # and the engine was throwing the readings away. Both fixtures below are real
  # events lifted off runs on disk, not invented shapes.
  mkdir -p "$tmp/rl/locks"
  # Fields, not a JSON literal: `\"` inside "$( ... )" is a quoting corner that
  # differs between shells, and this suite has to read the same everywhere.
  rl_probe() { # rl_probe <window> <status> <utilization|null> <resets_at> <overage>
    ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"
      RATE_LIMIT_FILE="$tmp/rl/rate-limits.json"
      "$JQ" -n --arg w "$1" --arg s "$2" --argjson u "$3" --argjson r "$4" --arg o "$5" \
        '{($w): {status:$s, utilization:$u, resets_at:$r, overage:$o, seen_at:0}}' \
        > "$RATE_LIMIT_FILE"
      rl_gate ) 2>/dev/null
  }
  soon="$(( $(now_epoch) + 3600 ))"
  gone="$(( $(now_epoch) - 3600 ))"

  # The file from before platforms carried the two windows at the top level.
  # It is read as anthropic and rewritten on first contact -- rl_probe above
  # still writes the OLD shape, which is exactly what makes it a migration test.
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig.json"
    "$JQ" -n '{five_hour:{status:"allowed",utilization:0.5,resets_at:1,overage:null,seen_at:0}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.5 and (has("five_hour") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a pre-platforms file is nested under anthropic on first contact" || bad "the old shape was not migrated"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig2.json"
    "$JQ" -n '{anthropic:{five_hour:{utilization:0.1}},openai:{}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.1' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a file already in the new shape is left alone" || bad "migration damaged a migrated file"
  # A file carrying BOTH shapes at once, which is what the live install ended up
  # with: an unmerged binary nested the windows once while the installed engine
  # and the statusline kept writing the top-level ones. `{anthropic: top} + rest`
  # let the NESTED block win whatever its age, throwing away the reading the gate
  # actually needs. Per window now, and the greater seen_at wins.
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig3.json"
    "$JQ" -n '{five_hour:{utilization:0.4,seen_at:200},
               anthropic:{five_hour:{utilization:0.9,seen_at:100}}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.4 and (has("five_hour") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "both shapes at once: the fresher top-level window wins" || bad "the fresher top-level reading was discarded"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig4.json"
    "$JQ" -n '{five_hour:{utilization:0.4,seen_at:100},
               anthropic:{five_hour:{utilization:0.9,seen_at:200}}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.9 and (has("five_hour") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "and the nested one is kept when it is the fresher" || bad "a fresher nested reading was overwritten"

  # Capture: the real seven-day warning that sat at 98% while the loop kept
  # waking runs into it, plus a truncated tail — a killed run is always cut off
  # mid-write, and one bad line must not cost us the reading.
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1785427200,"rateLimitType":"seven_day","utilization":0.98,"surpassedThreshold":0.75}}' > "$tmp/rl/s.ndjson"
  printf '%s' '{"type":"rate_limit_ev' >> "$tmp/rl/s.ndjson"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/cap.json"
    rl_capture "$tmp/rl/s.ndjson"
    "$JQ" -e '.anthropic.seven_day.utilization == 0.98 and .anthropic.seven_day.status == "allowed_warning"' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a window reading is lifted off the stream into the anthropic block, truncated tail and all" \
    || bad "rl_capture did not record the reading"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/none.json"
    printf 'not json at all\n' > "$tmp/rl/junk.ndjson"; rl_capture "$tmp/rl/junk.ndjson" ) \
    && ok "a stream with no events is not an error" || bad "rl_capture failed on a clean stream"

  # The gate itself.
  printf '%s' '{}' > "$tmp/rl/rate-limits.json"
  got="$( DATA_DIR="$tmp/rl"; RATE_LIMIT_FILE="$tmp/rl/rate-limits.json"; rl_gate 2>/dev/null )"
  [ -z "$got" ] && ok "no reading, no gate" || bad "gated with no data: $got"

  got="$(rl_probe five_hour allowed null "$soon" rejected)"
  [ -z "$got" ] && ok "a healthy window does not hold anything back" || bad "gated on a healthy window: $got"

  got="$(rl_probe seven_day allowed_warning 0.98 "$soon" rejected)"
  [ -n "$got" ] && ok "98% of a live window holds the next run back" || bad "did not gate at 98%"

  got="$(rl_probe seven_day allowed_warning 0.80 "$soon" rejected)"
  [ -z "$got" ] && ok "80% is under the floor and runs carry on" || bad "gated below the floor: $got"

  # The one that keeps a bad afternoon from wedging the fleet for ever: a reading
  # is only about the window it was taken in, and that window is over.
  got="$(rl_probe seven_day allowed_warning 0.98 "$gone" rejected)"
  [ -z "$got" ] && ok "a reading whose window has already reset says nothing" || bad "a stale reading still gated: $got"

  # A refusal outranks any number, including no number at all.
  got="$(rl_probe five_hour rejected null "$soon" rejected)"
  [ -n "$got" ] && ok "an API refusal gates even with no utilisation reported" || bad "a refusal did not gate"

  # The OpenAI reading comes off the rollout, not a stream: primary (300 min)
  # is the five-hour window, secondary (10080 min) the seven-day one.
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl"
    "$JQ" -e '.openai.five_hour.utilization == 0.05 and .openai.five_hour.resets_at == 1788617232
              and .openai.seven_day.utilization == 0.02 and .openai.seven_day.resets_at == 1788786623
              and .openai.five_hour.source == "rollout" and .openai.five_hour.plan_type == "plus"
              and .openai.five_hour.status == "allowed"' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "the LAST token_count of the rollout feeds both openai windows" || bad "rl_capture_openai: $(cat "$tmp/rl/oa.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa2.json"
    "$JQ" -n '{anthropic:{five_hour:{utilization:0.9,resets_at:1,seen_at:0}}}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl"
    "$JQ" -e '.anthropic.five_hour.utilization == 0.9 and .openai.five_hour.utilization == 0.05' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "and never touches the anthropic block" || bad "the anthropic reading was lost"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa3.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" refused
    "$JQ" -e '.openai.five_hour.status == "usage_limit_reached" and .openai.seven_day.status == "allowed"' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a quota refusal marks the fuller window spent until its reset" || bad "refused: $(cat "$tmp/rl/oa3.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa4.json"
    printf 'not a rollout\n' > "$tmp/rl/junk.jsonl"; printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$tmp/rl/junk.jsonl"
    [ "$(cat "$RATE_LIMIT_FILE")" = "{}" ] ) \
    && ok "a rollout with no token_count writes nothing" || bad "junk rollout changed the file"

  # The gate is per platform: one spent window must not hold the other CLI back.
  rl_at() { # rl_at <platform> <window> <utilization> <resets_at> -> rl_gate <platform-asked> output
    ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/pp.json"
      "$JQ" -n --arg p "$1" --arg w "$2" --argjson u "$3" --argjson r "$4" \
        '{($p): {($w): {status:"allowed", utilization:$u, resets_at:$r, overage:null, seen_at:0}}}' > "$RATE_LIMIT_FILE"
      rl_gate "$5" 2>/dev/null )
  }
  got="$(rl_at openai five_hour 0.97 "$soon" openai)"
  case "$got" in *"the openai five_hour window is 97% used"*) ok "a spent openai window gates an openai run, and names itself" ;; *) bad "openai gate: '$got'" ;; esac
  got="$(rl_at openai five_hour 0.97 "$soon" anthropic)"
  [ -z "$got" ] && ok "and does not gate an anthropic run" || bad "cross-platform gate: $got"
  got="$(rl_at anthropic seven_day 0.98 "$soon" openai)"
  [ -z "$got" ] && ok "a spent anthropic window does not gate an openai run" || bad "cross-platform gate: $got"
  got="$(rl_at openai five_hour 0.97 "$gone" openai)"
  [ -z "$got" ] && ok "an openai window past its reset says nothing" || bad "expired openai window gated: $got"

  # opencode has no window at all -- nothing captures one for it -- so the
  # gate must never hold a run back on it, even when the SAME file holds a
  # real, spent window for another platform (rl_at, not an empty/missing
  # file -- a missing file would let anything through trivially and prove
  # nothing about opencode specifically).
  got="$(rl_at openai five_hour 0.97 "$soon" opencode)"
  [ -z "$got" ] && ok "rl_gate opencode never holds a run back: there are no windows for it" || bad "rl_gate opencode: $got"
  got="$(rl_at openai five_hour 0.97 "$soon" openai)"
  case "$got" in *"the openai five_hour window is 97% used"*) ok "...while rl_gate openai on that same file still holds" ;; *) bad "openai gate on the same file: $got" ;; esac

  # The windows are an ACCOUNT's: the platform's own key is the CLI's default
  # directory, any other account directory reads and writes <platform>@<dir>.
  [ "$(rl_key anthropic "")" = "anthropic" ] && [ "$(rl_key openai /x/.codex-a)" = "openai@/x/.codex-a" ] \
    && ok "rl_key: the platform for the CLI's own directory, platform@dir for any other" || bad "rl_key"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/acct.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture "$tmp/rl/s.ndjson" "anthropic@/x/.claude-a"
    "$JQ" -e '.["anthropic@/x/.claude-a"].seven_day.utilization == 0.98 and (has("anthropic") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "rl_capture writes a run's reading into its account's block" || bad "rl_capture per account: $(cat "$tmp/rl/acct.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/acct-oa.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" "" "openai@/x/.codex-a"
    "$JQ" -e '.["openai@/x/.codex-a"].five_hour.utilization == 0.05 and (has("openai") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "and so does rl_capture_openai" || bad "rl_capture_openai per account: $(cat "$tmp/rl/acct-oa.json")"
  got="$(rl_at "anthropic@/x/.claude-a" five_hour 0.97 "$soon" "anthropic@/x/.claude-a")"
  case "$got" in *"the anthropic five_hour window is 97% used"*) ok "an account's spent window holds that account's runs back" ;; *) bad "account gate: '$got'" ;; esac
  got="$(rl_at "anthropic@/x/.claude-a" five_hour 0.97 "$soon" anthropic)"
  [ -z "$got" ] && ok "and not the Default's" || bad "cross-account gate: $got"
  got="$(rl_at anthropic five_hour 0.97 "$soon" "anthropic@/x/.claude-a")"
  [ -z "$got" ] && ok "nor does the Default's hold another account back" || bad "cross-account gate: $got"
  got="$( DATA_DIR="$tmp/rl"; RATE_LIMIT_FILE="$tmp/rl/named.json"
          "$JQ" -n --arg k "anthropic@/x/.claude-a" --argjson r "$soon" \
            '{($k): {five_hour: {status:"allowed", utilization:0.97, resets_at:$r, overage:null, seen_at:0}}}' > "$RATE_LIMIT_FILE"
          rl_gate "anthropic@/x/.claude-a" "Client A" 2>/dev/null )"
  case "$got" in *"the anthropic five_hour window of Client A is 97% used"*) ok "and the hold names the account" ;; *) bad "named gate: '$got'" ;; esac
  # The OTHER branch of the same sentence -- a refusal, not a percentage --
  # names the account too; only the utilisation one was ever probed with a name.
  got="$( DATA_DIR="$tmp/rl"; RATE_LIMIT_FILE="$tmp/rl/named2.json"
          "$JQ" -n --arg k "anthropic@/x/.claude-a" --argjson r "$soon" \
            '{($k): {five_hour: {status:"rejected", utilization:null, resets_at:$r, overage:null, seen_at:0}}}' > "$RATE_LIMIT_FILE"
          rl_gate "anthropic@/x/.claude-a" "Client A" 2>/dev/null )"
  case "$got" in *"the anthropic five_hour window of Client A is spent (API says rejected)"*) ok "and so does the refusal sentence" ;; *) bad "named refusal gate: '$got'" ;; esac

  echo "statusline-rate-limits.sh — the figure the run stream never carries"
  # The stream only reports utilisation once the CLI has decided to warn (0.75),
  # so below that the gate is armed and blind. The statusLine payload has the
  # number on every turn — but ONLY in an interactive session: measured, it is
  # not invoked under `-p` in either output format. So this is fed by the
  # operator's own sessions, on the same account, and has to merge with what the
  # runs recorded rather than overwrite it.
  sl="$BIN_DIR/statusline-rate-limits.sh"
  mkdir -p "$tmp/sl"
  sl_run() { # sl_run <payload-json> -> writes $tmp/sl/rate-limits.json
    printf '%s' "$1" | env -u CLAUDE_CONFIG_DIR AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
  }
  sl_get() { "$JQ" -r "$1" "$tmp/sl/rate-limits.json" 2>/dev/null; }

  sl_run '{"rate_limits":{"five_hour":{"used_percentage":62.5,"resets_at":111},"seven_day":{"used_percentage":18,"resets_at":222}}}'
  [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.625" ] \
    && ok "used_percentage (0-100) is stored as the utilisation the gate reads (0-1)" \
    || bad "five_hour utilisation -> $(sl_get '.anthropic.five_hour.utilization')"
  [ "$(sl_get '.anthropic.seven_day.resets_at')" = "222" ] \
    && ok "both windows are recorded, not just the first" || bad "seven_day missing"

  # An API-key account reports no windows at all. That is not a failure, and it
  # must not leave a file behind that the gate would then read as fact.
  rm -f "$tmp/sl/rate-limits.json"
  sl_run '{"model":{"id":"x"},"workspace":{}}'
  [ ! -f "$tmp/sl/rate-limits.json" ] \
    && ok "a payload with no windows writes nothing" || bad "wrote a file with no windows in the payload"

  # The merge. `status` and `overage` only ever come from a run's stream, and
  # they describe the window that was measured.
  "$JQ" -n '{five_hour:{status:"allowed_warning",utilization:0.9,resets_at:111,overage:"rejected",seen_at:0}}' > "$tmp/sl/rate-limits.json"
  sl_run '{"rate_limits":{"five_hour":{"used_percentage":93,"resets_at":111}}}'
  [ "$(sl_get '.anthropic.five_hour.overage')" = "rejected" ] && [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.93" ] \
    && ok "a fresher figure for the SAME window keeps what the stream knew" \
    || bad "same-window merge lost the stream's fields: $(sl_get '.anthropic.five_hour|tostring')"
  # ...and the moment the window rolls over, that knowledge is about a window
  # that no longer exists. Carrying it would hold the fleet back on a spent fact.
  sl_run '{"rate_limits":{"five_hour":{"used_percentage":4,"resets_at":999}}}'
  [ "$(sl_get '.anthropic.five_hour.overage')" = "null" ] && [ "$(sl_get '.anthropic.five_hour.status')" = "null" ] \
    && ok "a NEW window drops the previous one's status and overage" \
    || bad "stale status survived a window roll: $(sl_get '.anthropic.five_hour|tostring')"

  # The gate must not read that null status as a refusal — the statusline never
  # reports one, so treating its silence as "not allowed" would hold back every
  # healthy run the moment this script was installed.
  got="$( DATA_DIR="$tmp/sl"; RATE_LIMIT_FILE="$tmp/sl/rate-limits.json"; rl_gate 2>/dev/null )"
  [ -z "$got" ] && ok "a reading with no status is not a refusal" || bad "gated on a status-less reading: $got"

  # Its `$was` migration carries rl_migrate's precedence rule, for the same
  # reason: a file holding BOTH shapes must not lose the fresher top-level
  # window to a stale nested one merely because nested is the shape being
  # written. The payload touches seven_day only, so five_hour is decided
  # entirely by the migration.
  "$JQ" -n '{five_hour:{utilization:0.4,resets_at:111,seen_at:200},
             anthropic:{five_hour:{utilization:0.9,resets_at:111,seen_at:100}}}' > "$tmp/sl/rate-limits.json"
  sl_run '{"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":222}}}'
  [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.4" ] && [ "$(sl_get 'has("five_hour")')" = "false" ] \
    && ok "the statusline migration keeps the fresher of the two shapes too" \
    || bad "statusline migration lost the fresher window: $(sl_get '.|tostring')"

  # A session's account is its CLAUDE_CONFIG_DIR: the reading lands in that
  # account's block, the one its runs read -- the CLI's own directory, with
  # the variable set or not, is the platform's block.
  rm -f "$tmp/sl/rate-limits.json"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":333}}}' \
    | CLAUDE_CONFIG_DIR="/x/.claude-a/" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.["anthropic@/x/.claude-a"].five_hour.utilization')" = "0.4" ] && [ "$(sl_get 'has("anthropic")')" = "false" ] \
    && ok "a session with CLAUDE_CONFIG_DIR feeds that account's block, trailing slash or not" || bad "statusline per account: $(sl_get '.|tostring')"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":41,"resets_at":333}}}' \
    | CLAUDE_CONFIG_DIR="$HOME/.claude" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.41" ] \
    && ok "and one pointed at ~/.claude feeds the platform's own" || bad "statusline ~/.claude: $(sl_get '.|tostring')"

  # The write floor is per KEY, not per file: every case above pinned
  # AGENTLOOP_STATUSLINE_MIN_SECONDS=0, so the floor itself -- the one thing
  # this script exists to have at all -- was never actually exercised.
  rm -f "$tmp/sl/rate-limits.json"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":444}}}' \
    | CLAUDE_CONFIG_DIR="/x/.claude-b" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=999 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.["anthropic@/x/.claude-b"].five_hour.utilization')" = "0.1" ] \
    && ok "a fresh account key writes through the floor the first time" || bad "first account write under the floor: $(sl_get '.|tostring')"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":333}}}' \
    | env -u CLAUDE_CONFIG_DIR AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=999 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.5" ] \
    && ok "...and a Default write right after is NOT held back by another account's floor" \
    || bad "Default write held by account B's floor: $(sl_get '.|tostring')"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":444}}}' \
    | CLAUDE_CONFIG_DIR="/x/.claude-b" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=999 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.["anthropic@/x/.claude-b"].five_hour.utilization')" = "0.1" ] \
    && ok "but a second write to the SAME account key inside the floor IS held back" \
    || bad "same-key floor did not hold: $(sl_get '.["anthropic@/x/.claude-b"].five_hour.utilization')"

  echo "failure causes — an outage is not the job's fault, and must not slow it down"
  # `error` covered a 529 the API returned and an agent that got its tools taken
  # away, and the backoff counted them the same: a provider outage would crawl a
  # perfectly healthy job for the rest of the day. These pin the two halves —
  # which cause is derived, and which of them the backoff is allowed to count.
  mkdir -p "$tmp/cause"
  cause_of() { # cause_of <result-json> <denials> <wdreason> -> the derived cause
    printf '%s' "$1" > "$tmp/cause/log.json"
    ( logfile="$tmp/cause/log.json"; status="error"
      denials="${2:-0}"; wdreason="${3:-}"
      subtype="$("$JQ" -r '.subtype // "success"' "$logfile")"
      cause=""
      # The derivation itself, lifted verbatim from run_job by anchor so this
      # cannot drift into testing a copy that no longer matches the engine.
      eval "$(sed -n '/^  cause=""$/,/^  fi$/p' "$BIN_DIR/agentloop" | head -20)"
      printf '%s' "$cause" )
  }
  [ "$(cause_of '{"api_error_status":529,"subtype":"success"}')" = "api_error" ] \
    && ok "a 529 is an api_error, whatever the CLI called the subtype" \
    || bad "529 -> '$(cause_of '{"api_error_status":529,"subtype":"success"}')'"
  [ "$(cause_of '{"api_error_status":429,"subtype":"success"}')" = "rate_limited" ] \
    && ok "a 429 is told apart from an overload — different wait, different fix" \
    || bad "429 -> '$(cause_of '{"api_error_status":429,"subtype":"success"}')'"
  [ "$(cause_of '{"subtype":"success"}' 2)" = "tools_denied" ] \
    && ok "denied tools name the agent being blocked, not a vague error" \
    || bad "denials -> '$(cause_of '{"subtype":"success"}' 2)'"
  [ "$(cause_of '{"subtype":"no_result_event"}')" = "killed" ] \
    && ok "a run that never reported a result is killed, not an agent error" \
    || bad "no_result -> '$(cause_of '{"subtype":"no_result_event"}')'"
  [ "$(cause_of '{"subtype":"error_during_execution"}')" = "agent_error" ] \
    && ok "everything else falls back to the agent's own error" \
    || bad "fallback -> '$(cause_of '{"subtype":"error_during_execution"}')'"
  # An API failure outranks a denial count: the run died before the denial could
  # matter, and telling the operator to go fix permissions would send them at
  # the wrong problem entirely.
  [ "$(cause_of '{"api_error_status":529,"subtype":"success"}' 3)" = "api_error" ] \
    && ok "an API failure outranks a denial count on the same run" \
    || bad "denials masked the API failure"

  # The half that changes behaviour. Read the real rule out of the script: a
  # copy of it here would pass happily while the engine did something else.
  rule="$(sed -n '/Nor is an outage/,/^  fi$/p' "$BIN_DIR/agentloop")"
  case "$rule" in
    *"api_error|rate_limited)"*) ok "the backoff rule names both provider-side causes" ;;
    *) bad "the backoff no longer spares provider-side causes" ;;
  esac
  case "$rule" in
    *'streak_next="$(num "$(state_get "$id" fail_streak 0)")"'*)
      ok "an outage leaves the streak where it was — neither raised nor reset" ;;
    *) bad "an outage does not preserve the streak" ;;
  esac
  # A job that is genuinely broken must still back off, or this whole change
  # would just be a way to never slow anything down.
  case "$rule" in
    *'*) streak_next="$(( $(num "$(state_get "$id" fail_streak 0)") + 1 ))" ;;'*)
      ok "every other cause still counts, so a broken job still backs off" ;;
    *) bad "the ordinary failure path stopped counting" ;;
  esac

  # And the record has to carry it, or the dashboard has nothing to show.
  case "$(sed -n '/^record_run()/,/^}/p' "$BIN_DIR/agentloop")" in
    *'cause:$cause'*) ok "the cause is written onto the run record" ;;
    *) bad "record_run does not persist the cause" ;;
  esac

  echo "fleet_stall_reason() — the fleet can stop having runs without any run failing"
  # on-run-end fires when a run ENDS. None of the ways the fleet stops HAVING
  # runs produce one, so the loop can tick for hours, the dashboard can keep
  # saying it is awake, and nothing happens and nobody is told. Each case below
  # is one of those ways.
  mkdir -p "$tmp/stall"
  stall_at() { # stall_at <minutes-ago> <line...> -> appends to the fixture log
    local m="$1"; shift
    printf '%s %s\n' "$(date -u -v-"${m}"M +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$tmp/stall/tick.log"
  }
  stall_ask() { # -> the reason, or empty
    ( TICK_LOG="$tmp/stall/tick.log"; JOBS_FILE="$tmp/stall/jobs.json"
      LOCK_DIR="$tmp/stall/locks"; STALL_HOURS=4
      fleet_stall_reason ) 2>/dev/null
  }
  printf '%s' '{"jobs":[{"id":"a"}]}' > "$tmp/stall/jobs.json"
  mkdir -p "$tmp/stall/locks"

  : > "$tmp/stall/tick.log"
  [ -z "$(stall_ask)" ] && ok "an empty log is not a stall" || bad "gated on an empty log"

  # The healthy quiet. A loop with nothing to do is the loop WORKING, and paging
  # somebody for it teaches them to ignore the message that matters.
  : > "$tmp/stall/tick.log"
  stall_at 200 "a: precheck found nothing to do (exit 1)"
  stall_at 100 "a: precheck found nothing to do (exit 1)"
  [ -z "$(stall_ask)" ] && ok "hours of 'nothing to do' is not a stall" || bad "an idle fleet was called stalled"

  # Blind, not idle: this is the failure board-probe.sh exists to name, and it
  # looks exactly like the healthy case from the outside.
  stall_at 90 "a: PRECHECK FAILED (exit 7) — the probe could not run"
  case "$(stall_ask)" in
    *"cannot SEE its work"*) ok "prechecks failing for hours is a stall, and says why" ;;
    *) bad "failing prechecks were not reported: $(stall_ask)" ;;
  esac

  # A run inside the window clears everything above it, however bad the log looks.
  stall_at 30 "a: starting run (x)"
  [ -z "$(stall_ask)" ] && ok "a run inside the window ends the question" || bad "called stalled with a recent run"

  # The gate holding the whole fleet back — the case that made this exist.
  : > "$tmp/stall/tick.log"
  stall_at 180 "a: usage limit reached — the anthropic seven_day window is 98% used — skipping"
  stall_at 60 "a: usage limit reached — the anthropic seven_day window is 98% used — skipping"
  case "$(stall_ask)" in
    *"spent usage window"*) ok "a spent usage window holding every run back is a stall" ;;
    *) bad "the usage gate holding the fleet was not reported" ;;
  esac

  : > "$tmp/stall/tick.log"
  stall_at 90 "a: daily cap reached (\$9 / \$5) — skipping"
  case "$(stall_ask)" in
    *"daily spend cap"*) ok "a daily cap holding every run back is a stall" ;;
    *) bad "the daily cap holding the fleet was not reported" ;;
  esac

  # max_parallel with nothing actually running means the slots being counted
  # belong to processes that are gone — a job blocked for ever by a ghost.
  : > "$tmp/stall/tick.log"
  stall_at 90 "a: at max_parallel=1 run(s), not launching another"
  case "$(stall_ask)" in
    *"stale slot"*) ok "blocked at max_parallel with nothing alive names the stale slot" ;;
    *) bad "a stale slot was not reported: $(stall_ask)" ;;
  esac
  # ...but with a live slot it is not a stall at all: that run IS the reason
  # there have been no new ones, and this is the false alarm most likely to
  # happen — any job whose runs outlast the window.
  mkdir -p "$tmp/stall/locks/a/$$" && echo $$ > "$tmp/stall/locks/a/$$/pid"
  echo "$(boot_id)" > "$tmp/stall/locks/a/$$/boot" 2>/dev/null || true
  [ -z "$(stall_ask)" ] && ok "a long run still going is not a stall" || bad "a live run was called a stall"
  rm -rf "$tmp/stall/locks/a"

  # Announced once, then re-armed by recovery — not once a minute for ever.
  ( TICK_LOG="$tmp/stall/tick.log"; JOBS_FILE="$tmp/stall/jobs.json"
    LOCK_DIR="$tmp/stall/locks"; DATA_DIR="$tmp/stall"; CONFIG_DIR="$tmp/stall/cfg"
    STALL_MARK_FILE="$tmp/stall/.stalled"; STALL_HOURS=4
    mkdir -p "$tmp/stall/cfg/hooks"
    printf '#!/usr/bin/env bash\necho "$AL_REASON" >> "%s/fired.txt"\n' "$tmp/stall" > "$tmp/stall/cfg/hooks/on-fleet-stalled.sh"
    fleet_stall_check; fleet_stall_check; fleet_stall_check
    wait 2>/dev/null
    [ -f "$STALL_MARK_FILE" ] || exit 3
    stall_at 1 "a: starting run (y)"        # recovery
    fleet_stall_check
    [ -f "$STALL_MARK_FILE" ] && exit 4
    exit 0 ) >/dev/null 2>&1
  case $? in
    0) ok "announced once per stall, and re-armed the moment a run starts again" ;;
    3) bad "the stall was never marked" ;;
    4) bad "recovery did not clear the mark, so the next stall would be silent" ;;
    *) bad "fleet_stall_check errored" ;;
  esac
  fired="$(wc -l < "$tmp/stall/fired.txt" 2>/dev/null | tr -d ' ')"
  [ "${fired:-0}" = "1" ] \
    && ok "the hook ran exactly once across three stalled ticks" \
    || bad "the hook fired ${fired:-0} times, not once"

  # The phrases above are the server's, and a rename there would silently blind
  # this without breaking anything visible.
  srv="$BIN_DIR/agentloop-server"
  miss=""
  for phrase in "PRECHECK FAILED" "usage limit reached" "daily cap reached" "max_parallel"; do
    grep -qF "$phrase" "$srv" || miss="$miss '$phrase'"
  done
  [ -z "$miss" ] \
    && ok "every phrase this reads still exists in the server's classify_tick" \
    || bad "phrases have drifted from the server:$miss"

  echo "agentloop usage — the feature can say whether it is switched on"
  # A gate nobody can verify is a gate nobody trusts, and the honest answer used
  # to be a hand-written one-liner over the JSON. Each case below is a wiring
  # mistake an operator can actually make.
  mkdir -p "$tmp/usg"
  usg() { # usg <settings-json> [rate-limits-json] -> what the command prints
    printf '%s' "$1" > "$tmp/usg/settings.json"
    if [ -n "${2:-}" ]; then printf '%s' "$2" > "$tmp/usg/rate-limits.json"
    else rm -f "$tmp/usg/rate-limits.json"; fi
    ( HOME="$tmp/usg_home"; mkdir -p "$HOME/.claude"; cp "$tmp/usg/settings.json" "$HOME/.claude/settings.json"
      # CODEX_HOME_DIR is set once, at script load, off the REAL $HOME -- it
      # does not track this HOME override the way account_cli_default's own
      # fresh read of $HOME does. Left alone, the openai Default would look
      # pinned to every test below, never the CLI's own directory. Kept in
      # step with HOME above, the same way a real process's never drifts.
      PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR="${USG_PIN:-}"; PLATFORMS_FILE="${USG_PLATFORMS:-$PLATFORMS_FILE}"
      CODEX_HOME_DIR="$HOME/.codex"
      DATA_DIR="$tmp/usg"; RATE_LIMIT_FILE="$tmp/usg/rate-limits.json"; cmd_usage ) 2>/dev/null
  }
  soon2="$(( $(now_epoch) + 3600 ))"

  case "$(usg '{}')" in
    *"No usage window has been recorded yet"*) ok "with no reading it says so, rather than printing nothing" ;;
    *) bad "empty state did not say it was empty" ;;
  esac
  case "$(usg '{}')" in
    *"statusline: not configured"*) ok "an unconfigured statusline is named as the reason the gate is blind" ;;
    *) bad "did not report the missing statusline" ;;
  esac
  # The mistake that looks like success: something IS configured, just not this.
  case "$(usg '{"statusLine":{"type":"command","command":"/usr/bin/true"}}')" in
    *"not to this script"*) ok "a statusline pointing elsewhere is not mistaken for a working one" ;;
    *) bad "a foreign statusline was accepted" ;;
  esac
  # The one that bit during development: the path is right, the file is not there
  # (wrong branch checked out), and every session's status line fails in silence.
  case "$(usg '{"statusLine":{"type":"command","command":"/nope/statusline-rate-limits.sh"}}')" in
    *"NOT RUNNABLE"*) ok "a configured path that does not exist is called out, not assumed fine" ;;
    *) bad "a missing script passed as wired" ;;
  esac
  # Wired, but every reading still came off a run stream: the session that was
  # already open when it was wired will never call it.
  wired="{\"statusLine\":{\"type\":\"command\",\"command\":\"$BIN_DIR/statusline-rate-limits.sh\"}}"
  stream_only="$("$JQ" -nc --argjson r "$soon2" '{five_hour:{status:"allowed",utilization:null,resets_at:$r,overage:"rejected",seen_at:0}}')"
  case "$(usg "$wired" "$stream_only")" in
    *"never fed the gate yet"*) ok "wired but never fired is reported as such, not as working" ;;
    *) bad "claimed the statusline had fed the gate when it had not" ;;
  esac
  fed="$("$JQ" -nc --argjson r "$soon2" '{five_hour:{status:null,utilization:0.42,resets_at:$r,overage:null,seen_at:0,source:"statusline"}}')"
  case "$(usg "$wired" "$fed")" in
    *"it has fed the gate"*) ok "a live statusline reading is confirmed as live" ;;
    *) bad "did not confirm a working statusline" ;;
  esac
  # And when the gate IS holding runs back, saying so here is the whole point.
  spent="$("$JQ" -nc --argjson r "$soon2" '{seven_day:{status:null,utilization:0.99,resets_at:$r,overage:"rejected",seen_at:0,source:"statusline"}}')"
  case "$(usg "$wired" "$spent")" in
    *"HELD BACK"*) ok "a gate that is holding runs back says so where you look for it" ;;
    *) bad "the command did not report an active hold" ;;
  esac
  case "$(usg '{}' '{"anthropic":{"five_hour":{"status":"allowed","utilization":0.3,"resets_at":'"$soon2"',"seen_at":0,"source":"statusline"}},"openai":{"five_hour":{"status":"allowed","utilization":0.05,"resets_at":'"$soon2"',"seen_at":0,"source":"rollout","plan_type":"plus"}}}')" in
    *"anthropic five_hour: 30% used"*"openai five_hour: 5% used"*"rollout"*"opencode: no usage windows"*) ok "usage lists both platforms, each window named by its platform" ;;
    *) bad "usage output did not list both platforms" ;;
  esac
  mkdir -p "$tmp/usg/acct-a"
  printf '%s' "$wired" > "$tmp/usg/acct-a/settings.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"a","name":"Client A","dir":"%s"}]}}}\n' "$tmp/usg/acct-a" > "$tmp/usg/platforms.json"
  got="$(USG_PLATFORMS="$tmp/usg/platforms.json" usg '{}' '{"anthropic@'"$tmp/usg/acct-a"'":{"five_hour":{"status":"allowed","utilization":0.3,"resets_at":'"$soon2"',"seen_at":0,"source":"statusline"}},"anthropic@/gone/.claude-x":{"five_hour":{"status":"allowed","utilization":0.2,"resets_at":'"$soon2"',"seen_at":0}}}')"
  case "$got" in *"anthropic (Client A) five_hour: 30% used"*"anthropic (/gone/.claude-x — not an account) five_hour: 20% used"*)
      ok "usage names each account's block: a registered one by name, one Settings no longer has by its directory" ;;
    *) bad "usage per account: $got" ;; esac
  case "$got" in *"statusline (Client A): wired to"*"it has fed the gate"*) ok "and says whether each account's own settings feed its gate" ;; *) bad "statusline per account: $got" ;; esac

  # usage_account_label's own "Default" branch, directly: a pinned Claude
  # Default, and a Codex Default whose CODEX_HOME is not ~/.codex.
  got="$( AGENTLOOP_CLAUDE_CONFIG_DIR="$tmp/usg/pin"; usage_account_label anthropic "$tmp/usg/pin" )"
  [ "$got" = "Default" ] && ok "usage_account_label: a pinned Claude Default is named Default" || bad "pinned Default label: '$got'"
  got="$( CODEX_HOME_DIR="$tmp/usg/codex-x"; usage_account_label openai "$tmp/usg/codex-x" )"
  [ "$got" = "Default" ] && ok "and so is a Codex Default on a non-default CODEX_HOME" || bad "codex Default label: '$got'"

  # The bug this round fixes: a pinned install upgraded from an unpinned one
  # carries a STALE, spent bare block that no scheduled run reads any more
  # (the Default's own gate moved to the pinned key) -- `usage` used to cry
  # HOLD over it anyway, while the run it was actually worried about went
  # right through. Reproduced here rather than only in the bug report: a bare
  # block and the pinned key's block, both spent, on a platforms.json with no
  # registered accounts at all -- nothing but the pin decides either label.
  mkdir -p "$tmp/usg/pin"
  printf '{"platforms":{}}\n' > "$tmp/usg/platforms-pin.json"
  pinrl="$("$JQ" -nc --argjson r "$soon2" --arg k "anthropic@$tmp/usg/pin" \
    '{anthropic: {five_hour:{status:"allowed",utilization:0.97,resets_at:$r,seen_at:0}},
      ($k): {five_hour:{status:"allowed",utilization:0.97,resets_at:$r,seen_at:0}}}')"
  got="$(USG_PLATFORMS="$tmp/usg/platforms-pin.json" USG_PIN="$tmp/usg/pin" usg '{}' "$pinrl")"
  case "$got" in
    *"anthropic ($tmp/usg_home/.claude — not an account) five_hour: 97% used"*)
      ok "usage: under a pin, the stale bare block is labelled not an account" ;;
    *) bad "bare block under a pin: $got" ;;
  esac
  case "$got" in
    *"SCHEDULED anthropic ($tmp/usg_home/.claude — not an account) RUNS ARE BEING HELD BACK"*)
      bad "the bare block still claims to hold runs back under a pin: $got" ;;
    *) ok "...and carries no HOLD line: no scheduled run reads it any more" ;;
  esac
  case "$got" in
    *"anthropic (Default) five_hour: 97% used"*"SCHEDULED anthropic (Default) RUNS ARE BEING HELD BACK"*)
      ok "while the pinned key's own block -- the Default's real gate -- does carry the HOLD line" ;;
    *) bad "pinned Default block: $got" ;;
  esac

  echo "the Claude account comes from the setting, never from the environment"
  # cmd_install refuses an ambient CLAUDE_CONFIG_DIR, and for a while the runtime
  # did not: `agentloop run <job>` typed inside a Claude Code session inherited
  # THAT session's account, so the run billed elsewhere and loaded another
  # account's plugins with nothing in the record saying so. Probe the real script
  # rather than a copy of the rule — the rule was never wrong, the wiring was.
  # Sourcing it with `--help` runs every top-level assignment and then returns.
  # An empty value and an unset one are the same to `${VAR:-}`, so both can be
  # passed unconditionally — and stay quoted, which a conditional would not.
  # What is read back is what a CHILD of the engine gets (printenv is one),
  # not the engine's own shell variable: the model probes and the hooks are
  # children, and only an exported value reaches them.
  al_account_probe() { # <ambient CLAUDE_CONFIG_DIR> <AGENTLOOP_CLAUDE_CONFIG_DIR> [HOME]
    env CLAUDE_CONFIG_DIR="$1" AGENTLOOP_CLAUDE_CONFIG_DIR="$2" HOME="${3:-$HOME}" \
        AGENTLOOP_CONFIG="$tmp/acct/config" AGENTLOOP_DATA="$tmp/acct/data" \
        bash -c '. "$1" --help >/dev/null 2>&1; printenv CLAUDE_CONFIG_DIR || printf "<unset>"' _ "$SELF"
  }
  got="$(al_account_probe /tmp/al-someones-session "")"
  [ "$got" = "<unset>" ] \
    && ok "an ambient CLAUDE_CONFIG_DIR is not inherited" \
    || bad "an ambient CLAUDE_CONFIG_DIR leaked in as '$got'"
  got="$(al_account_probe /tmp/al-someones-session /tmp/al-declared)"
  [ "$got" = "/tmp/al-declared" ] \
    && ok "the declared account wins over the environment" \
    || bad "declared account -> '$got'"
  got="$(al_account_probe "" /tmp/al-declared)"
  [ "$got" = "/tmp/al-declared" ] \
    && ok "and is honoured when nothing is ambient" \
    || bad "declared account alone -> '$got'"
  got="$(al_account_probe "" "")"
  [ "$got" = "<unset>" ] \
    && ok "no setting anywhere leaves the CLI's own default" \
    || bad "no setting -> '$got'"
  # The pin reaches a child through account_env_value's rule, the one a run's
  # own environment follows: exported raw, a pin naming the CLI's own
  # ~/.claude -- a trailing slash, or the tilde -- made a model probe or a
  # hook look for another Keychain entry (no session), while check, enable
  # and every run called the same account signed in.
  mkdir -p "$tmp/acct/fakehome"
  got="$(al_account_probe "" "$tmp/acct/fakehome/.claude/" "$tmp/acct/fakehome")"
  [ "$got" = "<unset>" ] \
    && ok "a pin naming the CLI's own directory, trailing slash and all, reaches a child as no variable at all" \
    || bad "pin \$HOME/.claude/ -> a child sees '$got'"
  got="$(al_account_probe "" "~/.claude" "$tmp/acct/fakehome")"
  [ "$got" = "<unset>" ] \
    && ok "and so does the same directory written ~/.claude" \
    || bad "pin ~/.claude -> a child sees '$got'"
  got="$(al_account_probe "" "$tmp/acct/fakehome/.claude-x/" "$tmp/acct/fakehome")"
  [ "$got" = "$tmp/acct/fakehome/.claude-x" ] \
    && ok "any other pin reaches a child normalized: no trailing slash" \
    || bad "pin \$HOME/.claude-x/ -> a child sees '$got'"
  got="$(al_account_probe "" "~/.claude-x" "$tmp/acct/fakehome")"
  [ "$got" = "$tmp/acct/fakehome/.claude-x" ] \
    && ok "and with its ~ expanded" \
    || bad "pin ~/.claude-x -> a child sees '$got'"
  got="$(al_account_probe "" "relative/pin" "$tmp/acct/fakehome")"
  [ "$got" = "<unset>" ] \
    && ok "a pin that is not an absolute directory is no pin, as a run already reads it" \
    || bad "pin relative/pin -> a child sees '$got'"

  # ...and the half nobody tested: does the account the INSTALLER pinned ever
  # reach a scheduled run? launchd hands the tick exactly what the plist's
  # EnvironmentVariables say, and the rule above discards an ambient
  # CLAUDE_CONFIG_DIR by design -- so a plist that names only that key pins an
  # account the engine then throws away, while `install` prints it as though it
  # were in force. The plist has to speak the variable the engine actually
  # reads. cmd_install is driven for real here, in a shadowed home with a
  # launchctl stub, and the plist it wrote is read back with plistlib.
  echo "cmd_install() — the account it pins is the one the engine reads back"
  local _instout
  _instout="$(
    mkdir -p "$tmp/inst/fakehome/Library/LaunchAgents" "$tmp/inst/fakebin" \
             "$tmp/inst/data" "$tmp/inst/config" "$tmp/inst/codexhome" "$tmp/inst/al-pinned" "$tmp/inst/old-acct"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$tmp/inst/fakebin/launchctl"
    chmod +x "$tmp/inst/fakebin/launchctl"
    printf '%s\n' '#!/bin/sh' 'echo 0.0.0' > "$tmp/inst/fakebin/claude"
    chmod +x "$tmp/inst/fakebin/claude"
    HOME="$tmp/inst/fakehome"; PATH="$tmp/inst/fakebin:$PATH"
    PLIST_PATH="$tmp/inst/fakehome/Library/LaunchAgents/tick.plist"
    SERVER_PLIST="$tmp/inst/fakehome/Library/LaunchAgents/server.plist"
    # install_migrate_legacy reads the pre-rename plists through this, not
    # through $HOME directly -- shadowed to the same fake directory PLIST_PATH
    # and SERVER_PLIST already use, or the write_legacy_plist fixtures below
    # would land somewhere install_migrate_legacy never looks.
    LAUNCH_AGENTS_DIR="$tmp/inst/fakehome/Library/LaunchAgents"
    DATA_DIR="$tmp/inst/data"; CONFIG_DIR="$tmp/inst/config"
    MODELS_FILE="$tmp/inst/config/models.json"; PRICING_FILE="$tmp/inst/config/pricing.json"
    TICK_LOG="$tmp/inst/data/tick.log"
    # install now converts the claude_config_dir left in projects.json: never the real file.
    # PLATFORMS_FILE is shadowed too: accounts_migrate_legacy (below) now
    # registers an account as a side effect, and that must never land on
    # whatever platforms.json the rest of this suite happens to share.
    PROJECTS_FILE="$tmp/inst/config/projects.json"; JOBS_FILE="$tmp/inst/config/jobs.json"
    PLATFORMS_FILE="$tmp/inst/config/platforms.json"
    printf '{"projects":[{"name":"InstP","cwd":"%s","claude_config_dir":"%s"}]}\n' "$tmp/inst" "$tmp/inst/old-acct" > "$PROJECTS_FILE"
    printf '{"jobs":[]}\n' > "$JOBS_FILE"
    USER_SKILLS="$tmp/inst/fakehome/.claude/skills"
    CODEX_HOME_DIR="$tmp/inst/codexhome"; CODEX_SKILLS="$CODEX_HOME_DIR/skills"
    CLAUDE_BIN="$tmp/inst/fakebin/claude"; CODEX_BIN="$BASE_DIR/test/fake-codex"; OPENCODE_BIN="$BASE_DIR/test/fake-opencode"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    # plist_key <file> <key> -- what launchd would hand the tick for that name
    plist_key() {
      "$PYTHON" - "$1" "$2" <<'PY'
import plistlib, sys
try:
    v = plistlib.load(open(sys.argv[1], "rb")).get("EnvironmentVariables", {}).get(sys.argv[2])
except Exception:
    v = None
print(v if v else "")
PY
    }
    AGENTLOOP_CLAUDE_CONFIG_DIR=$tmp/inst/al-pinned cmd_install >/dev/null 2>&1
    [ "$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)" = "$tmp/inst/al-pinned" ] \
      && ok "the tick's plist names the variable the engine reads" \
      || bad "tick plist AGENTLOOP_CLAUDE_CONFIG_DIR '$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)'"
    [ "$(plist_key "$SERVER_PLIST" AGENTLOOP_CLAUDE_CONFIG_DIR)" = "$tmp/inst/al-pinned" ] \
      && ok "and so does the server's" \
      || bad "server plist AGENTLOOP_CLAUDE_CONFIG_DIR '$(plist_key "$SERVER_PLIST" AGENTLOOP_CLAUDE_CONFIG_DIR)'"
    [ "$(readlink "$tmp/inst/al-pinned/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "and the pinned account's own skills directory gets the links: runs there read it, not ~/.claude/skills" \
      || bad "pin skills: '$(readlink "$tmp/inst/al-pinned/skills/security-analysis" 2>/dev/null)'"
    [ "$(plist_key "$PLIST_PATH" CLAUDE_CONFIG_DIR)" = "$tmp/inst/al-pinned" ] \
      && ok "CLAUDE_CONFIG_DIR stays beside it, for anything that reads the CLI's own name" \
      || bad "tick plist CLAUDE_CONFIG_DIR '$(plist_key "$PLIST_PATH" CLAUDE_CONFIG_DIR)'"
    # The pin survives a re-run that names nothing -- read back from the plist.
    got="$( AGENTLOOP_CLAUDE_CONFIG_DIR="" installed_config_dir )"
    [ "$got" = "$tmp/inst/al-pinned" ] && ok "installed_config_dir reads it back off the plist" \
      || bad "installed_config_dir -> '$got'"
    # An install written before this fix names only CLAUDE_CONFIG_DIR; the
    # reader must still find it, or re-running the installer drops the pin.
    "$PYTHON" - "$PLIST_PATH" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p.get("EnvironmentVariables", {}).pop("AGENTLOOP_CLAUDE_CONFIG_DIR", None)
plistlib.dump(p, open(sys.argv[1], "wb"))
PY
    got="$( AGENTLOOP_CLAUDE_CONFIG_DIR="" installed_config_dir )"
    [ "$got" = "$tmp/inst/al-pinned" ] && ok "and off an older plist that carries only CLAUDE_CONFIG_DIR" \
      || bad "older plist -> '$got'"
    # install calls accounts_migrate_legacy itself now, in cmd_install --
    # the leftover claude_config_dir seeded onto InstP above proves that
    # wiring actually runs, not just that the function exists.
    [ "$("$JQ" -c '.projects[0] | {a: .account, c: has("claude_config_dir")}' "$PROJECTS_FILE")" = '{"a":"old-acct","c":false}' ] \
      && ok "install itself converts a leftover claude_config_dir into an account" \
      || bad "InstP after install: $("$JQ" -c '.projects[0]' "$PROJECTS_FILE")"
    # A relative pin is refused before it reaches either plist --
    # account_norm_dir already treats it as no pin at runtime (see above), so
    # honouring it here would install a home nothing later run signs in as,
    # while this very command printed it as though it were in force.
    _tick_before="$(cat "$PLIST_PATH")"; _server_before="$(cat "$SERVER_PLIST")"
    _relrc=0
    _relout="$(AGENTLOOP_CLAUDE_CONFIG_DIR="relative/pin" cmd_install 2>&1)" || _relrc=$?
    [ "$_relrc" -ne 0 ] && ok "a relative AGENTLOOP_CLAUDE_CONFIG_DIR is refused" \
      || bad "relative pin rc=$_relrc out=$_relout"
    if printf '%s' "$_relout" | grep -q "AGENTLOOP_CLAUDE_CONFIG_DIR" \
       && printf '%s' "$_relout" | grep -q "relative/pin" \
       && printf '%s' "$_relout" | grep -q "absolute"; then
      ok "and the refusal names the value and says to give an absolute path"
    else
      bad "refusal text: [$_relout]"
    fi
    [ "$(cat "$PLIST_PATH")" = "$_tick_before" ] && [ "$(cat "$SERVER_PLIST")" = "$_server_before" ] \
      && ok "and nothing is written -- both plists are exactly as the last successful install left them" \
      || bad "a plist changed after the refused install"
    # A pin with characters a plist XML must escape round-trips through
    # both plists to installed_config_dir unchanged -- an unescaped & or <
    # used to make the plistlib read fail on the file this wrote, silently
    # answering no pin at all.
    _ampdir="$tmp/inst/al-pinned & <special>"
    mkdir -p "$_ampdir"
    AGENTLOOP_CLAUDE_CONFIG_DIR="$_ampdir" cmd_install >/dev/null 2>&1
    got="$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ "$got" = "$_ampdir" ] \
      && ok "a pin with & and < round-trips through the tick plist unchanged" \
      || bad "tick plist with & and < -> got=[$got] want=[$_ampdir]"
    got="$( AGENTLOOP_CLAUDE_CONFIG_DIR="" installed_config_dir )"
    [ "$got" = "$_ampdir" ] && ok "and installed_config_dir reads it back exactly" \
      || bad "installed_config_dir with & and < -> got=[$got] want=[$_ampdir]"
    plist_raw_line="$(grep -o '<key>AGENTLOOP_CLAUDE_CONFIG_DIR</key><string>[^<]*' "$PLIST_PATH")"
    grep -q '&amp;' "$PLIST_PATH" \
      && ok "the plist file itself carries the escaped ampersand, never a raw one" \
      || bad "no &amp; found in $PLIST_PATH: $plist_raw_line"
    # The Claude account line install prints shows the directory as the
    # engine resolves it -- ~ expanded, no trailing slash -- never the raw pin.
    mkdir -p "$tmp/inst/fakehome/.claude-x"
    _normout="$(AGENTLOOP_CLAUDE_CONFIG_DIR='~/.claude-x/' cmd_install 2>&1)"
    normline="$(printf '%s\n' "$_normout" | grep 'Claude account')"
    printf '%s\n' "$_normout" | grep -qxF "Claude account : $tmp/inst/fakehome/.claude-x" \
      && ok "a ~/.claude-x/ pin prints its normalized directory: tilde expanded, no trailing slash" \
      || bad "Claude account line: $normline"
    # Round 2, finding 4: a pin already sitting in the plist can be relative
    # -- an install from before the refusal above, or a hand edit -- and a
    # re-run with the variable unset must not just read it back and write it
    # forward again, unchanged and still useless.
    "$PYTHON" - "$PLIST_PATH" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["EnvironmentVariables"]["AGENTLOOP_CLAUDE_CONFIG_DIR"] = "relative/leftover"
p["EnvironmentVariables"]["CLAUDE_CONFIG_DIR"] = "relative/leftover"
plistlib.dump(p, open(sys.argv[1], "wb"))
PY
    _leftout="$(cmd_install 2>&1)"
    printf '%s\n' "$_leftout" | grep -qF "the account pinned in the existing install ('relative/leftover') is not an absolute directory" \
      && ok "a relative pin already in the plist is named and dropped, not silently carried forward" \
      || bad "leftover-pin drop line: $(printf '%s\n' "$_leftout" | grep 'pinned in the existing install')"
    got="$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ -z "$got" ] && ok "and the new tick plist does not carry it forward" \
      || bad "tick plist still names AGENTLOOP_CLAUDE_CONFIG_DIR='$got' after the drop"
    got="$(plist_key "$SERVER_PLIST" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ -z "$got" ] && ok "nor does the server's" \
      || bad "server plist still names AGENTLOOP_CLAUDE_CONFIG_DIR='$got' after the drop"
    normline="$(printf '%s\n' "$_leftout" | grep 'Claude account')"
    printf '%s\n' "$_leftout" | grep -qxF "Claude account : the CLI default (~/.claude) — set AGENTLOOP_CLAUDE_CONFIG_DIR and re-run to change it" \
      && ok "and the Claude account line reads the CLI default, not the dropped value" \
      || bad "Claude account line after the drop: $normline"
    # Round 3: install_migrate_legacy no longer announces the carry itself --
    # it only ever knew a legacy pin EXISTED, never whether cmd_install would
    # go on to actually use it (the variable or the new plist can both beat
    # it, and it still has to be absolute). The announcement now comes from
    # cmd_install, once that is decided. The tick plist carries no pin at
    # this point (the drop just above cleared it), so a fresh legacy plist is
    # the only candidate for case A.
    write_legacy_plist() { # write_legacy_plist <dir> -- (re)creates the pre-rename tick plist, pinned to <dir>; install_migrate_legacy consumes (and deletes) it on every cmd_install call
      mkdir -p "$tmp/inst/fakehome/Library/LaunchAgents"
      "$PYTHON" - "$tmp/inst/fakehome/Library/LaunchAgents/$LEGACY_PLIST_LABEL.plist" "$1" <<'PY'
import plistlib, sys
plistlib.dump({"EnvironmentVariables": {"CLAUDE_CONFIG_DIR": sys.argv[2]}}, open(sys.argv[1], "wb"))
PY
    }
    # A: an absolute legacy pin, nothing else naming one -- it is the account
    # this install carries forward, so the notice is true, and the pin
    # reaches both new plists.
    mkdir -p "$tmp/inst/legacy-acct"
    write_legacy_plist "$tmp/inst/legacy-acct"
    _legouta="$(cmd_install 2>&1)"
    printf '%s\n' "$_legouta" | grep -qxF "carrying the account pinned in $LEGACY_PLIST_LABEL: $tmp/inst/legacy-acct" \
      && ok "a legacy pin that is actually used is announced, naming the directory" \
      || bad "legacy-carry line (used): $(printf '%s\n' "$_legouta" | grep 'carrying the account pinned')"
    got="$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ "$got" = "$tmp/inst/legacy-acct" ] && ok "and the legacy pin reaches the new tick plist" \
      || bad "tick plist AGENTLOOP_CLAUDE_CONFIG_DIR after a used legacy carry: '$got'"
    got="$(plist_key "$SERVER_PLIST" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ "$got" = "$tmp/inst/legacy-acct" ] && ok "and the server plist too" \
      || bad "server plist AGENTLOOP_CLAUDE_CONFIG_DIR after a used legacy carry: '$got'"
    # B: a legacy pin AND the variable naming another absolute directory --
    # the variable wins (it is checked first), so the legacy pin is never
    # used and must never be announced as carried.
    mkdir -p "$tmp/inst/legacy-acct2" "$tmp/inst/var-wins"
    write_legacy_plist "$tmp/inst/legacy-acct2"
    _legoutb="$(AGENTLOOP_CLAUDE_CONFIG_DIR="$tmp/inst/var-wins" cmd_install 2>&1)"
    if printf '%s\n' "$_legoutb" | grep -q "carrying the account pinned"; then
      bad "a legacy pin the variable already beat must not be announced: $(printf '%s\n' "$_legoutb" | grep 'carrying the account pinned')"
    else
      ok "no carry line when the variable already names a pin"
    fi
    got="$(plist_key "$PLIST_PATH" AGENTLOOP_CLAUDE_CONFIG_DIR)"
    [ "$got" = "$tmp/inst/var-wins" ] && ok "and the variable's directory is what actually reaches the plist, not the legacy one" \
      || bad "tick plist AGENTLOOP_CLAUDE_CONFIG_DIR when the variable wins over a legacy pin: '$got'"
    # Reset: case B left the tick plist pinned to var-wins, which would beat
    # a legacy pin in case C too -- installed_config_dir reads the plist
    # before ever asking install_migrate_legacy -- so case C needs to start
    # from no pin at all, exactly like case A did.
    "$PYTHON" - "$PLIST_PATH" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["EnvironmentVariables"].pop("AGENTLOOP_CLAUDE_CONFIG_DIR", None)
p["EnvironmentVariables"].pop("CLAUDE_CONFIG_DIR", None)
plistlib.dump(p, open(sys.argv[1], "wb"))
PY
    # C: a relative legacy pin -- it is the only candidate (like A), but is
    # not usable, so it must be dropped (as any other unusable pin is) and
    # never announced as carried.
    write_legacy_plist "relative/legacy"
    _legoutc="$(cmd_install 2>&1)"
    if printf '%s\n' "$_legoutc" | grep -q "carrying the account pinned"; then
      bad "a relative legacy pin must never be announced as carried: $(printf '%s\n' "$_legoutc" | grep 'carrying the account pinned')"
    else
      ok "no carry line for a relative legacy pin"
    fi
    printf '%s\n' "$_legoutc" | grep -qF "the account pinned in the existing install ('relative/legacy') is not an absolute directory" \
      && ok "and it is named and dropped instead, exactly like any other unusable pin" \
      || bad "relative-legacy drop line: $(printf '%s\n' "$_legoutc" | grep 'not an absolute directory')"
    echo "RESULT ok=$_upass bad=$_ufail"
  )"
  printf '%s\n' "$_instout" | grep -v '^RESULT '
  printf '%s\n' "$_instout" | grep -qx 'RESULT ok=25 bad=0' \
    && ok "cmd_install over a shadowed home: all 25 assertions reach the gate" \
    || bad "cmd_install over a shadowed home did not: $(printf '%s\n' "$_instout" | tail -1)"

  echo "spent_today() — today's spend is summed without reading all of history"
  local midnight; midnight="$(date -v0H -v0M -v0S +%s)"
  : > "$tmp/runs.ndjson"
  printf '{"id":"a","start":%s,"cost":1.5}\n' "$(( midnight + 10 ))" >> "$tmp/runs.ndjson"
  printf '{"id":"a","start":%s,"cost":2.25}\n' "$(( midnight + 20 ))" >> "$tmp/runs.ndjson"
  printf '{"id":"b","start":%s,"cost":4}\n'    "$(( midnight + 30 ))" >> "$tmp/runs.ndjson"
  printf '{"id":"a","start":%s,"cost":99}\n'   "$(( midnight - 8000 ))" >> "$tmp/runs.ndjson"
  got="$( RUNS_FILE="$tmp/runs.ndjson"; spent_today a )"
  [ "$got" = "3.750000" ] && ok "one job's spend today is summed" || bad "spent_today a -> '$got'"
  got="$( RUNS_FILE="$tmp/runs.ndjson"; spent_today_all )"
  [ "$got" = "7.750000" ] && ok "every job's spend today is summed" || bad "spent_today_all -> '$got'"
  # A truncated leading line (the scan starts at a byte offset, not a line
  # boundary) must be skipped, never parsed into a bogus cost.
  printf '%s\n' '{"id":"a","start":1,"co' > "$tmp/cut.ndjson"
  cat "$tmp/runs.ndjson" >> "$tmp/cut.ndjson"
  got="$( RUNS_FILE="$tmp/cut.ndjson"; spent_today a )"
  [ "$got" = "3.750000" ] && ok "a truncated first line is ignored" || bad "with a cut line -> '$got'"

  echo "cmd_worktree_drop() — a retained run dir can be discarded on purpose"
  # wt_teardown deliberately KEEPS an open session (a run cut short, waiting on
  # a resume), and the sweep then re-examines it every tick for ever until one
  # comes. Nothing could ever let go of it on its own, so the only exit is
  # rm -rf by hand.
  local rd4="$tmp/wtroot/j7/stampF"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j7 two "$tmp/g/repo" stampF ) >/dev/null 2>&1
  echo open > "$rd4/.ended"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_teardown j7 two "$rd4" ) >/dev/null 2>&1
  [ -d "$rd4" ] && ok "an open session is still preserved by the normal path" || bad "teardown removed it"

  mkdir -p "$tmp/locks/j7/888"; echo $$ > "$tmp/locks/j7/888/pid"
  echo "$rd4" > "$tmp/locks/j7/888/worktree"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    cmd_worktree_drop j7 stampF ) >/dev/null 2>&1
  [ -d "$rd4" ] && ok "a dir a LIVE run is using is never dropped" || bad "dropped a live run's dir"
  rm -rf "$tmp/locks/j7"

  # The one remedy for round-1's Important #3 (a leaked compose stack and
  # ports) had no assertion of its own: nothing here ever proved `down`
  # actually fires on a drop, only that the directory goes. An open session
  # never reaches wt_teardown's own down block, so this explicit drop is the
  # ONLY place left that can still release it -- prove it does.
  printf '%s\n' '#!/usr/bin/env bash' 'echo down >> "$AL_RUN_DIR/../down.count"' \
    > "$tmp/cfg/provision/two.down.sh"
  chmod +x "$tmp/cfg/provision/two.down.sh"
  rm -f "$tmp/wtroot/j7/down.count"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
    WORKTREES_DIR="$tmp/wtroot"; LOCK_DIR="$tmp/locks"
    cmd_worktree_drop j7 stampF ) >/dev/null 2>&1
  want "dropping an unclaimed dir succeeds" 0 $?
  [ ! -d "$rd4" ] && ok "the retained dir is gone once dropped explicitly" || bad "dir survived the drop"
  got="$(wc -l < "$tmp/wtroot/j7/down.count" 2>/dev/null | tr -d ' ')"
  [ "${got:-0}" -eq 2 ] && ok "the drop released what teardown left up, once per repo" \
    || bad "down ran $got times for 2 repos on an explicit drop"
  # And git must not be left believing the worktrees are still checked out.
  got="$(git -C "$tmp/g/repo" worktree list --porcelain 2>/dev/null | grep -c "stampF" || true)"
  [ "$(num "$got")" = "0" ] && ok "git no longer lists the removed worktree" || bad "git still lists $got"
  rm -f "$tmp/cfg/provision/two.down.sh" "$tmp/wtroot/j7/down.count"

  echo "a run the operator stops is recorded as stopped, never lost"
  # Stopping in the seconds between claiming a slot and spawning the agent used
  # to just delete the slot: the row vanished from the table with no run, no log
  # and no record that it had ever been asked for. And a TERM'd agent exits
  # non-zero, so a deliberate stop was filed as `error` — counted in the error
  # tile and feeding the failure backoff, slowing the job down as punishment for
  # a decision its owner made on purpose.
  local sl="$tmp/locks/j9/777"
  mkdir -p "$sl" "$tmp/stoplogs"
  echo 777 > "$sl/pid"; echo 1700000000 > "$sl/start"
  echo "$tmp/stoplogs/r.json" > "$sl/logfile"
  # The marker as _stop_slot writes it: where the stop came from.
  printf 'from the dashboard\n' > "$sl/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    run_record_stopped_early j9 "$sl" ) >/dev/null 2>&1
  got="$("$JQ" -r '.status' "$tmp/stop.ndjson" 2>/dev/null | head -1)"
  [ "$got" = "stopped" ] && ok "a stop before the agent starts still journals a run" \
    || bad "journalled status '$got'"
  # And says where the stop came from, off the marker -- never "by you" for
  # every stop, which put a stop nobody made in the dashboard down to its
  # operator (2026-09-24). test/e2e.test.sh scenario 53 drives both origins.
  got="$("$JQ" -r '.note // ""' "$tmp/stop.ndjson" 2>/dev/null | head -1)"
  case "$got" in "STOPPED: ended from the dashboard before its agent started"*)
                   ok "and the record says why it ended, and where the stop came from" ;;
                 *) bad "note was '$got'" ;; esac
  got="$("$JQ" -r '.subtype // ""' "$tmp/stoplogs/r.json" 2>/dev/null)"
  [ "$got" = "stopped_by_user" ] && ok "and it leaves a log body explaining itself" \
    || bad "log subtype '$got'"
  got="$("$JQ" -r '.result // ""' "$tmp/stoplogs/r.json" 2>/dev/null)"
  case "$got" in "**Stopped.**"*) ok "headed Stopped, not Stopped by you" ;;
                 *) bad "log body began '${got%%$'\n'*}'" ;; esac
  # The record used to carry no model at all, which in the run modal reads as
  # missing data rather than as a run that never got far enough to have one.
  got="$("$JQ" -r '.model // ""' "$tmp/stop.ndjson" 2>/dev/null | head -1)"
  [ -n "$got" ] && ok "and says which model it would have run" || bad "model was empty"
  # And a stop landing before the slot has a logfile breadcrumb still gets a log.
  local sl2="$tmp/locks/j9/778"
  mkdir -p "$sl2"; echo 778 > "$sl2/pid"; echo 1700000000 > "$sl2/start"; : > "$sl2/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop2.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    run_record_stopped_early j9 "$sl2" ) >/dev/null 2>&1
  got="$("$JQ" -r '.log // ""' "$tmp/stop2.ndjson" 2>/dev/null | head -1)"
  [ -n "$got" ] && [ -f "$got" ] && ok "a stop with no logfile breadcrumb still writes one" \
    || bad "log path '$got'"
  rm -rf "$tmp/locks/j9/778"
  # A derived security job stopped before its agent started left its analysis
  # `running` for ever (seen on a real install: the page refused a second
  # Analyse and the row had to be closed by hand). The record closes the
  # analysis with the run's own verdict, through the same door the
  # classifier uses, and a plain job never reaches that door.
  local sl5="$tmp/locks/security-app/779"
  mkdir -p "$sl5"; echo 779 > "$sl5/pid"; echo 1700000000 > "$sl5/start"; : > "$sl5/stopped"
  : > "$tmp/secpy.calls"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop5.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    AL_SECURITY_ANALYSIS_ID=41
    security_py() { printf '%s\n' "$*" >> "$tmp/secpy.calls"; }
    run_record_stopped_early security-app "$sl5" ) >/dev/null 2>&1
  grep -q '^finish --analysis 41 --state failed' "$tmp/secpy.calls" \
    && ok "a derived job stopped before its agent closes its analysis as failed" \
    || bad "security_py calls: $(cat "$tmp/secpy.calls")"
  : > "$tmp/secpy.calls"
  local sl6="$tmp/locks/j9/781"
  mkdir -p "$sl6"; echo 781 > "$sl6/pid"; echo 1700000000 > "$sl6/start"; : > "$sl6/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop6.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    AL_SECURITY_ANALYSIS_ID=41
    security_py() { printf '%s\n' "$*" >> "$tmp/secpy.calls"; }
    run_record_stopped_early j9 "$sl6" ) >/dev/null 2>&1
  [ "$("$JQ" -r '.status' "$tmp/stop6.ndjson" 2>/dev/null | head -1)" = "stopped" ] && [ ! -s "$tmp/secpy.calls" ] \
    && ok "and a plain job stopped early is journaled without touching the security ledger" \
    || bad "plain job: status $("$JQ" -r '.status' "$tmp/stop6.ndjson" 2>/dev/null | head -1), security_py calls: $(cat "$tmp/secpy.calls")"
  rm -rf "$tmp/locks/security-app" "$tmp/locks/j9/781"
  # Twice must not produce two rows: the normal path drops `journaled` the moment
  # it files its own record, and this must respect that.
  : > "$sl/journaled"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    run_record_stopped_early j9 "$sl" ) >/dev/null 2>&1
  got="$(wc -l < "$tmp/stop.ndjson" | tr -d ' ')"
  [ "$got" = "1" ] && ok "a run that already journalled is not recorded twice" \
    || bad "$got rows in the journal"
  # And a slot with no stop marker is none of this function's business.
  rm -f "$sl/stopped" "$sl/journaled"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop.tick"
    run_record_stopped_early j9 "$sl" ) >/dev/null 2>&1
  got="$(wc -l < "$tmp/stop.ndjson" | tr -d ' ')"
  [ "$got" = "1" ] && ok "a run nobody stopped is left alone" || bad "$got rows after a no-op"
  rm -rf "$tmp/locks/j9"

  echo "run_record_stopped_early() — a stop after the agent ran does not claim nothing happened"
  # Review: the tree now survives a mid-classifier stop (see run_cleanup
  # below), but this function still filed "no work was done and nothing was
  # spent" regardless of $slot/child -- a record that actively denies the very
  # thing the kept directory proves, and the only exit before the TTL is
  # Discard. $slot/child (written the instant an agent is spawned, never
  # removed) was already in hand to tell the two cases apart; no cost or turns
  # accounting needed, just a different note.
  local sl3="$tmp/locks/j9/779"
  mkdir -p "$sl3"
  echo 779 > "$sl3/pid"; echo 1700000000 > "$sl3/start"
  echo "$tmp/stoplogs/r3.json" > "$sl3/logfile"
  echo 55555 > "$sl3/child"          # an agent WAS spawned before the stop landed
  : > "$sl3/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop3.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop3.tick"
    run_record_stopped_early j9 "$sl3" ) >/dev/null 2>&1
  got="$("$JQ" -r '.note // ""' "$tmp/stop3.ndjson" 2>/dev/null | head -1)"
  case "$got" in
    *"no work was done"*) bad "with an agent spawned, the note still claims '$got'" ;;
    STOPPED:*)            ok "and it no longer denies the agent ever ran" ;;
    *)                    bad "note was '$got'" ;;
  esac
  grep -q "already run" "$tmp/stop3.tick" 2>/dev/null \
    && ok "the tick log tells the two cases apart too" || bad "tick log did not distinguish the case"
  rm -rf "$tmp/locks/j9"

  echo "run_record_stopped_early() — a session bound before the stop is not thrown away"
  # $slot/child says an agent was spawned; it says nothing about whether that
  # agent got far enough to REPORT a session before the stop landed -- that is
  # a separate race against the watchdog's own bind_session poll (see
  # run_job), and the two must not be conflated. When the run dir's OWN
  # .session is already bound (the ordinary case: bind_session's first poll
  # runs immediately, not gated on its 30s cadence), the journal must carry
  # the REAL id, not the unconditional "" this function used to write --
  # otherwise the dashboard's Resume button can never work for a stopped run
  # even when there is genuinely a session sitting right there to continue.
  local rd9="$tmp/wtroot/j9/stampSess"
  mkdir -p "$rd9"
  printf 'sess-real-9000\n' > "$rd9/.session"
  local sl4="$tmp/locks/j9/780"
  mkdir -p "$sl4"
  echo 780 > "$sl4/pid"; echo 1700000000 > "$sl4/start"
  echo "$rd9" > "$sl4/worktree"
  echo "$tmp/stoplogs/r4.json" > "$sl4/logfile"
  echo 66666 > "$sl4/child"
  : > "$sl4/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop4.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop4.tick"
    run_record_stopped_early j9 "$sl4" ) >/dev/null 2>&1
  got="$("$JQ" -r '.session // "MISSING"' "$tmp/stop4.ndjson" 2>/dev/null | head -1)"
  [ "$got" = "sess-real-9000" ] && ok "the journal carries the session that was actually bound" \
    || bad "journal session was '$got', wanted sess-real-9000"
  got="$("$JQ" -r '.session_id // "MISSING"' "$tmp/stoplogs/r4.json" 2>/dev/null)"
  [ "$got" = "sess-real-9000" ] && ok "and the run's own log body agrees" \
    || bad "log session_id was '$got'"
  rm -rf "$tmp/locks/j9" "$tmp/wtroot/j9"

  echo "run_record_stopped_early() — no session bound yet still reports none, not a guess"
  # The other half of the SAME race: the agent was spawned ($slot/child
  # exists) but the stop landed before bind_session's own poll ever ran, so
  # the run dir has no .session at all yet. This must still report "",
  # exactly like before an agent was ever spawned -- there is nothing here to
  # hand a Resume button that would actually work, and fabricating one would
  # be precisely the button this task exists to rule out.
  local rd10="$tmp/wtroot/j9/stampNoSess"
  mkdir -p "$rd10"
  local sl5="$tmp/locks/j9/781"
  mkdir -p "$sl5"
  echo 781 > "$sl5/pid"; echo 1700000000 > "$sl5/start"
  echo "$rd10" > "$sl5/worktree"
  echo "$tmp/stoplogs/r5.json" > "$sl5/logfile"
  echo 77777 > "$sl5/child"
  : > "$sl5/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop5.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop5.tick"
    run_record_stopped_early j9 "$sl5" ) >/dev/null 2>&1
  got="$("$JQ" -r '.session // "MISSING"' "$tmp/stop5.ndjson" 2>/dev/null | head -1)"
  [ "$got" = "" ] && ok "an agent spawned but not yet bound still reports no session" \
    || bad "journal session was '$got', wanted empty"
  rm -rf "$tmp/locks/j9" "$tmp/wtroot/j9"

  echo "run_record_stopped_early() — a stale .session from an earlier resume is not claimed by a run whose OWN agent never started"
  # A resumed run reuses its run dir, whose .session already names the
  # earlier session (bind_session never rebinds). A stop landing before
  # THIS launch's own agent is spawned must not read that leftover file as
  # though it were this run's own -- $slot/child is what actually
  # distinguishes the two, not merely whether .session happens to exist.
  local rd11="$tmp/wtroot/j9/stampStale"
  mkdir -p "$rd11"
  printf 'sess-from-a-previous-run\n' > "$rd11/.session"
  local sl6="$tmp/locks/j9/782"
  mkdir -p "$sl6"
  echo 782 > "$sl6/pid"; echo 1700000000 > "$sl6/start"
  echo "$rd11" > "$sl6/worktree"
  echo "$tmp/stoplogs/r6.json" > "$sl6/logfile"
  # $sl6/child deliberately never written -- this run's own agent never started.
  : > "$sl6/stopped"
  ( CONFIG_DIR="$tmp/cfg"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/stop6.ndjson"
    STATE_FILE="$tmp/stopstate.json"; LOG_DIR="$tmp/stoplogs"; TICK_LOG="$tmp/stop6.tick"
    run_record_stopped_early j9 "$sl6" ) >/dev/null 2>&1
  got="$("$JQ" -r '.session // "MISSING"' "$tmp/stop6.ndjson" 2>/dev/null | head -1)"
  [ "$got" = "" ] && ok "a leftover session from an earlier resume is not claimed for a run that never started" \
    || bad "journal session was '$got', wanted empty -- claimed a stale id"
  rm -rf "$tmp/locks/j9" "$tmp/wtroot/j9"

  echo "run_cleanup() — a stop landing after the agent finished must not delete its work"
  # The Critical this closes. _stop_slot TERMs the run WRAPPER whenever the
  # agent's own pid is not ALIVE -- true both when no agent has been spawned
  # yet and when one already finished and exited. A Stop clicked while the
  # wrapper is still inside its post-agent classifier (git status / git branch
  # -r --contains per repo -- real wall-clock time on a real checkout, with the
  # dashboard still showing the run as active) lands here with $slot/stopped
  # set, no `.ended` written yet (the classifier never reached that line), and
  # the agent's actual commits sitting in the tree. $slot/child is the one fact
  # that tells the two cases apart: it is written the moment an agent is
  # spawned and is never removed, so its VALUE does not matter here, only its
  # presence.
  local rd7="$tmp/wtroot/j2/stampS"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampS ) >/dev/null 2>&1
  echo "the agent's own commit, never pushed" > "$rd7/one/agent.txt"
  local scl="$tmp/locks/j2/999"
  mkdir -p "$scl" "$tmp/rclogs"
  echo 999 > "$scl/pid"; echo 1700000000 > "$scl/start"
  echo "$rd7" > "$scl/worktree"
  echo "$tmp/rclogs/rc.json" > "$scl/logfile"
  echo 12345 > "$scl/child"          # an agent WAS spawned -- dead or alive, it existed
  : > "$scl/stopped"                 # the operator clicked Stop
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    DATA_DIR="$tmp"; RUNS_FILE="$tmp/rc.ndjson"; STATE_FILE="$tmp/rcstate.json"
    LOG_DIR="$tmp/rclogs"; TICK_LOG="$tmp/rc.tick"
    run_cleanup j2 "$scl" ) >/dev/null 2>&1
  [ -d "$rd7" ] \
    && ok "an agent that was spawned keeps its run open, never marked done" \
    || bad "CRITICAL: a stop after the agent ran deleted its work"
  got="$(cat "$rd7/.ended" 2>/dev/null)"
  [ "$got" = "open" ] && ok "and .ended says so, not done" || bad ".ended was '$got'"

  echo "run_cleanup() — a stop with no agent ever spawned is still closed as done"
  # The control, not just the refusal: the ORIGINAL case this branch exists
  # for -- stopped in the seconds between claiming the slot and spawning --
  # must still resolve to done, or the fix above just traded one wrong default
  # for another. Same fixture, minus the one fact ($slot/child) that changes
  # the verdict.
  local rd8="$tmp/wtroot/j2/stampS2"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup j2 two "$tmp/g/repo" stampS2 ) >/dev/null 2>&1
  local scl2="$tmp/locks/j2/998"
  mkdir -p "$scl2"
  echo 998 > "$scl2/pid"; echo 1700000000 > "$scl2/start"
  echo "$rd8" > "$scl2/worktree"
  echo "$tmp/rclogs/rc2.json" > "$scl2/logfile"
  : > "$scl2/stopped"                # stopped, and $scl2/child never existed
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    DATA_DIR="$tmp"; RUNS_FILE="$tmp/rc2.ndjson"; STATE_FILE="$tmp/rc2state.json"
    LOG_DIR="$tmp/rclogs"; TICK_LOG="$tmp/rc.tick"
    run_cleanup j2 "$scl2" ) >/dev/null 2>&1
  [ ! -d "$rd8" ] && ok "no agent ever spawned still closes the run as done" \
    || bad "a genuinely pre-agent stop was left open, unable to ever close"
  rm -rf "$tmp/locks/j2" "$tmp/wtroot/j2/stampS" "$tmp/wtroot/j2/stampS2"

  echo "_stop_slot() — a live pid from an earlier boot is cleared, never signalled"
  # Same reboot-recycled-pid risk slot_alive exists for, but with teeth: the old
  # bare kill -0 here did not just miscount a slot, it aimed a real TERM at
  # whatever unrelated process the kernel had since handed that pid to.
  sleep 60 & local bgpid=$!
  mkdir -p "$tmp/locks/j9/$bgpid"
  echo "$bgpid" > "$tmp/locks/j9/$bgpid/pid"
  echo "0" > "$tmp/locks/j9/$bgpid/boot"
  _stop_slot j9 "$tmp/locks/j9/$bgpid" >/dev/null 2>&1
  # A TERM just sent is not necessarily a TERM already delivered: give the
  # kernel a moment before asking whether the process is still there, so a
  # signal in flight cannot read as "never sent".
  sleep 0.3
  kill -0 "$bgpid" 2>/dev/null
  want "a live pid from an earlier boot is left running, not TERM'd" 0 $?
  [ ! -d "$tmp/locks/j9/$bgpid" ] && ok "its stale slot is cleared instead" \
    || bad "the stale slot survived the stop"
  kill "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
  rm -rf "$tmp/locks/j9"

  echo "_stop_slot() — signals the pid the FILE names, not the directory"
  # locks/j3/999 above (wt_prune_orphans, dir named 999 holding pid=$$) is not a
  # one-off fixture shape: a stale slot's directory name and its own pid file
  # can genuinely disagree. Signalling the name instead of the file is worse
  # than the leak that fixture guards against -- it is a live TERM aimed at
  # whichever unrelated process the kernel now happens to call by that number.
  # _stop_slot's TERM reaches realpid from inside this same shell -- no
  # subshell sits between here and there -- so when the process dies, bash
  # defers the news to the next command boundary instead of dropping it. Left
  # tracked, that surfaces as `Terminated: 15   sleep 60` printed straight into
  # a PASSING run's output, and that exact line is what this suite's own RED
  # transcripts use as proof the bug is alive -- so a green run left tracked
  # would read as a crashed one. Disowning drops only the job-table entry;
  # kill -0 and the explicit wait below still see the real process.
  sleep 60 & local realpid=$!; disown "$realpid"
  sleep 60 & local decoypid=$!; disown "$decoypid"
  mkdir -p "$tmp/locks/j9/$decoypid"
  echo "$realpid" > "$tmp/locks/j9/$decoypid/pid"
  boot_id > "$tmp/locks/j9/$decoypid/boot"
  _stop_slot j9 "$tmp/locks/j9/$decoypid" >/dev/null 2>&1
  sleep 0.3
  kill -0 "$realpid" 2>/dev/null
  want "the process the pid FILE names is the one TERM'd" 1 $?
  kill -0 "$decoypid" 2>/dev/null
  want "the process the directory merely happens to be named after is untouched" 0 $?
  kill "$realpid" "$decoypid" 2>/dev/null; wait "$realpid" "$decoypid" 2>/dev/null
  rm -rf "$tmp/locks/j9"

  echo "_stop_slot() — a slot claimed but not yet given a pid file is still signalled"
  # The window inside acquire_slot between mkdir and its own pid write: nothing
  # was read wrong here, there is simply nothing written yet to read. slot_alive
  # cannot call this alive without a pid file, and treating "cannot tell" as
  # "dead" would silently clear a run mid-claim -- the exact bug the comment
  # inside _stop_slot exists to keep fixed.
  # Same job-control noise as the section above, same fix: disown right away.
  sleep 60 & local midpid=$!; disown "$midpid"
  mkdir -p "$tmp/locks/j9/$midpid"        # mkdir happened; pid/boot files did not
  _stop_slot j9 "$tmp/locks/j9/$midpid" >/dev/null 2>&1
  sleep 0.3
  kill -0 "$midpid" 2>/dev/null
  want "a claim with no pid file yet is signalled, not silently ignored" 1 $?
  [ -d "$tmp/locks/j9/$midpid" ] && ok "its slot is left for the run's own EXIT path to clear" \
    || bad "the slot was cleared instead of signalled"
  kill "$midpid" 2>/dev/null; wait "$midpid" 2>/dev/null
  rm -rf "$tmp/locks/j9"

  echo "_stop_slot() — a pid file of literal 0 clears the slot, never signals the process group"
  # kill -TERM 0 does not name a process, it names the CALLER's own process
  # group -- so an unguarded rpid=0 would TERM this very selftest run, and
  # whatever invoked it, instead of the one dead slot it was meant to clear.
  # Proving that live would mean actually sending that signal from inside the
  # process running this suite: the one outcome this guard exists to rule
  # out, not something to reproduce for real just to watch it fail. Shadow
  # `kill` instead -- real calls (slot_alive's own kill -0 check, reached only
  # if the guard fails to refuse first) still pass through via `command
  # kill`, only the exact dangerous shape is trapped -- so the guard runs for
  # real, end to end, without ever risking the shell running it.
  local pid0_term=0
  kill() {
    if [ "$1" = "-TERM" ] && [ "$2" = "0" ]; then pid0_term=1; return 0; fi
    command kill "$@"
  }
  mkdir -p "$tmp/locks/j9/997"
  echo "0" > "$tmp/locks/j9/997/pid"
  # A plain `_stop_slot ... > file` runs in THIS shell, so the shadow above can
  # mutate pid0_term. `got="$(_stop_slot ...)"` would not: command
  # substitution forks a subshell, and a subshell's writes to an existing
  # variable die with it -- pid0_term would read 0 whether the guard held or
  # not, turning the very assertion this section exists for into one that
  # always passes. Capture to a file instead and read it back after.
  _stop_slot j9 "$tmp/locks/j9/997" > "$tmp/pid0.out" 2>&1
  unset -f kill
  got="$(cat "$tmp/pid0.out")"
  [ "$pid0_term" -eq 0 ] && ok "kill -TERM 0 is never attempted" \
    || bad "the guard let a pid of 0 reach a real kill"
  case "$got" in
    *"no usable pid"*) ok "and it is the refuse-early branch, not the kill branch, that ran" ;;
    *) bad "unexpected output: '$got'" ;;
  esac
  [ ! -d "$tmp/locks/j9/997" ] && ok "and its slot is cleared" || bad "the slot survived"
  rm -rf "$tmp/locks/j9"

  echo "_stop_slot() — a child file of literal 0 is refused, not signalled as the agent"
  # The rpid guard above closes one route to kill -TERM 0; this is the other
  # one, in the branch that runs BEFORE rpid is ever read. child comes from
  # its own file and had no digit check at all before this section existed --
  # kill -0 "0" succeeds the same way it does for rpid, so a child file that
  # ever read "0" would reach a real kill -TERM 0 first, never mind what rpid
  # would have said. Same shadow technique as above, for the same reason: not
  # something to prove by actually sending it.
  local child0_term=0
  kill() {
    if [ "$1" = "-TERM" ] && [ "$2" = "0" ]; then child0_term=1; return 0; fi
    command kill "$@"
  }
  sleep 60 & local claimpid=$!; disown "$claimpid"
  mkdir -p "$tmp/locks/j9/$claimpid"
  echo "0" > "$tmp/locks/j9/$claimpid/child"
  _stop_slot j9 "$tmp/locks/j9/$claimpid" > "$tmp/child0.out" 2>&1
  unset -f kill
  sleep 0.3
  [ "$child0_term" -eq 0 ] && ok "kill -TERM 0 is never attempted" \
    || bad "the guard let a child of 0 reach a real kill"
  kill -0 "$claimpid" 2>/dev/null
  want "and the run's own claim pid is TERM'd instead of the phantom agent" 1 $?
  kill "$claimpid" 2>/dev/null; wait "$claimpid" 2>/dev/null
  rm -rf "$tmp/locks/j9"

  echo "slots_active() — a stale-boot slot is not counted, and is pruned"
  # The other two leaks this task closes (a phantom counted against
  # max_parallel, a retained port block) were, before this task, exercised only
  # through the shared slot_alive() unit assertions above, never end to end
  # through the functions that actually leak. This is that end-to-end path for
  # max_parallel: a slot with a genuinely live pid but the wrong boot must
  # neither be counted nor be left behind for the next call to recount.
  mkdir -p "$tmp/locks/sa/$$" "$tmp/locks/sa/201"
  echo $$ > "$tmp/locks/sa/$$/pid"; boot_id > "$tmp/locks/sa/$$/boot"
  echo $$ > "$tmp/locks/sa/201/pid"; echo "0" > "$tmp/locks/sa/201/boot"
  got="$( LOCK_DIR="$tmp/locks"; slots_active sa )"
  [ "$got" = "1" ] && ok "a slot from an earlier boot is not counted against max_parallel" \
    || bad "slots_active counted $got, wanted 1"
  [ ! -d "$tmp/locks/sa/201" ] && ok "and its directory is pruned, not left behind" \
    || bad "the stale-boot slot's directory survived the count"
  [ -d "$tmp/locks/sa/$$" ] && ok "the genuinely live slot is left alone" \
    || bad "slots_active pruned a live slot"
  rm -rf "$tmp/locks/sa"

  # A slot with no pid is a run between acquire_slot's mkdir and its pid, and
  # slots_active is asked from outside acquire_slot's mutex too: the tick's
  # max_parallel gate, running, the stall check, a security analysis, a
  # rename. Pruned on sight, that run went on with no slot on disk -- not
  # counted against max_parallel, unseen by the dashboard and by stop, its
  # ports never recorded. A young one is counted and kept, like a live slot;
  # one left with no pid past the grace is abandoned, and pruned.
  mkdir -p "$tmp/locks/sm/111" "$tmp/locks/sm/222"; touch -t 202001010000 "$tmp/locks/sm/222"
  got="$( LOCK_DIR="$tmp/locks"; LOCK_GRACE_SECONDS=30; slots_active sm )"
  [ "$got" = "1" ] && [ -d "$tmp/locks/sm/111" ] \
    && ok "a slot not given its pid yet is counted and kept, not pruned from under its run" \
    || bad "slots_active on a slot mid-claim: counted $got, wanted 1; kept [$([ -d "$tmp/locks/sm/111" ] && echo yes || echo no)]"
  [ ! -d "$tmp/locks/sm/222" ] && ok "and one left with no pid past the grace is pruned" \
    || bad "an abandoned slot with no pid survived the count"
  rm -rf "$tmp/locks/sm"
  # agentloop runs walks the same slots and pruned them the same way. A slot
  # mid-claim is left alone, and not listed -- it has nothing to list yet --
  # while an abandoned one goes and a live one is listed.
  mkdir -p "$tmp/locks/rn/111" "$tmp/locks/rn/222" "$tmp/locks/rn/$$"; touch -t 202001010000 "$tmp/locks/rn/222"
  echo $$ > "$tmp/locks/rn/$$/pid"; boot_id > "$tmp/locks/rn/$$/boot"
  got="$( LOCK_DIR="$tmp/locks"; LOCK_GRACE_SECONDS=30; cmd_runs rn | cut -f1 )"
  [ "$got" = "$$" ] && [ -d "$tmp/locks/rn/111" ] && [ ! -d "$tmp/locks/rn/222" ] \
    && ok "agentloop runs lists the live run, leaves one mid-claim alone and prunes one abandoned" \
    || bad "agentloop runs listed [$got], kept mid-claim [$([ -d "$tmp/locks/rn/111" ] && echo yes || echo no)], kept abandoned [$([ -d "$tmp/locks/rn/222" ] && echo yes || echo no)]"
  rm -rf "$tmp/locks/rn"

  echo "alloc_port_base() — two live runs never get the same ports"
  # Isolation settles the filesystem and says nothing about ports: two runs of
  # one repo each publish 5432 and the second dies on "address already in use",
  # which reads as a broken test suite and is nothing of the kind.
  mkdir -p "$tmp/locks/pj/101" "$tmp/locks/pj/102" "$tmp/locks/pk/103"
  echo $$ > "$tmp/locks/pj/101/pid"; echo $$ > "$tmp/locks/pj/102/pid"
  local b1 b2 b3 b4
  b1="$( LOCK_DIR="$tmp/locks"; alloc_port_base "$tmp/locks/pj/101" )"
  b2="$( LOCK_DIR="$tmp/locks"; alloc_port_base "$tmp/locks/pj/102" )"
  [ -n "$b1" ] && [ "$b1" != "$b2" ] && ok "two live runs get different blocks ($b1 vs $b2)" \
    || bad "both got '$b1'"
  [ "$(( b2 - b1 ))" = "$AL_PORT_SPAN" ] && ok "the blocks do not overlap" \
    || bad "blocks are $(( b2 - b1 )) apart, span is $AL_PORT_SPAN"
  # A slot whose process is gone holds nothing — otherwise the pool shrinks by
  # one for every run that ever ended and never came back.
  echo 999999 > "$tmp/locks/pk/103/pid"
  echo "$b1" > "$tmp/locks/pk/103/portbase"
  rm -rf "$tmp/locks/pj/101" "$tmp/locks/pj/102"
  mkdir -p "$tmp/locks/pj/104"
  b3="$( LOCK_DIR="$tmp/locks"; alloc_port_base "$tmp/locks/pj/104" )"
  [ "$b3" = "$b1" ] && ok "a dead slot's block is handed back out" || bad "got '$b3', wanted '$b1'"
  # Same again with a stale BOOT instead of a dead pid: pk/105 keeps b1
  # genuinely taken (a live, current-boot pid) so the only way alloc_port_base
  # can hand back b2 is by refusing pk/106's claim on it, and pk/106's pid is
  # $$ -- very much alive -- so the only thing making it refusable is the boot
  # it carries.
  mkdir -p "$tmp/locks/pk/105" "$tmp/locks/pk/106"
  echo $$ > "$tmp/locks/pk/105/pid"; echo "$b1" > "$tmp/locks/pk/105/portbase"
  echo $$ > "$tmp/locks/pk/106/pid"; echo "0" > "$tmp/locks/pk/106/boot"
  echo "$b2" > "$tmp/locks/pk/106/portbase"
  mkdir -p "$tmp/locks/pj/107"
  b4="$( LOCK_DIR="$tmp/locks"; alloc_port_base "$tmp/locks/pj/107" )"
  [ "$b4" = "$b2" ] && ok "a live pid from an earlier boot holds no block either" \
    || bad "got '$b4', wanted '$b2' ($b1 should still read taken, held by pk/105)"
  rm -rf "$tmp/locks/pj" "$tmp/locks/pk"

  echo "port_base_free() — a resume takes its block back only if nothing live holds it"
  # The gate that decides between reusing a resume's own block and refusing the
  # resume outright, so it earns the same scrutiny alloc_port_base's own tests
  # give allocation: get this backwards and a resume either steals ports out
  # from under a live run, or refuses one it should have been free to take.
  mkdir -p "$tmp/locks/pf1/201" "$tmp/locks/pf2/301"
  echo $$ > "$tmp/locks/pf1/201/pid"; echo "21000" > "$tmp/locks/pf1/201/portbase"
  ( LOCK_DIR="$tmp/locks"; port_base_free "$tmp/locks/pf2/301" 21000 )
  want "a block a live run holds is refused" 1 $?
  ( LOCK_DIR="$tmp/locks"; port_base_free "$tmp/locks/pf2/301" 21100 )
  want "an unheld block is free" 0 $?
  # The asking slot is excluded from its own search -- otherwise a slot that
  # already recorded this exact block (a resume re-checking the block it is
  # about to keep) would read it as held by somebody else and refuse itself.
  ( LOCK_DIR="$tmp/locks"; port_base_free "$tmp/locks/pf1/201" 21000 )
  want "a slot never finds its own block taken" 0 $?
  # Same as alloc_port_base: a slot whose process is gone holds nothing.
  mkdir -p "$tmp/locks/pf1/202"
  echo 999999 > "$tmp/locks/pf1/202/pid"; echo "21200" > "$tmp/locks/pf1/202/portbase"
  ( LOCK_DIR="$tmp/locks"; port_base_free "$tmp/locks/pf2/301" 21200 )
  want "a dead slot holds no block either" 0 $?
  rm -rf "$tmp/locks/pf1" "$tmp/locks/pf2"

  echo "port_base_reclaim() — claims under the same mutex alloc_port_base uses, or refuses cleanly"
  mkdir -p "$tmp/locks/pr1/401"
  echo $$ > "$tmp/locks/pr1/401/pid"
  ( LOCK_DIR="$tmp/locks"; port_base_reclaim "$tmp/locks/pr1/401" 21100 )
  want "an unheld block is claimed" 0 $?
  got="$(cat "$tmp/locks/pr1/401/portbase" 2>/dev/null)"
  [ "$got" = "21100" ] && ok "and recorded in the slot" || bad "portbase was '$got'"
  # Cross-visibility, not just self-consistency: a plain read of $slot/portbase
  # could pass even if the claim were never made visible to anyone ELSE's scan.
  # alloc_port_base is exactly that someone else -- the fresh-run path this
  # whole function exists to stop colliding with.
  mkdir -p "$tmp/locks/pr2/402"
  echo $$ > "$tmp/locks/pr2/402/pid"
  got="$( LOCK_DIR="$tmp/locks"; alloc_port_base "$tmp/locks/pr2/402" )"
  [ "$got" != "21100" ] && ok "alloc_port_base's own scan sees the reclaimed block as taken ($got)" \
    || bad "alloc_port_base handed out 21100, the block port_base_reclaim just claimed"
  # A block a live run holds: refused, and NOTHING is written -- a half claim
  # left on disk would be indistinguishable from a real one to the next reader.
  mkdir -p "$tmp/locks/pr3/403"
  echo $$ > "$tmp/locks/pr3/403/pid"
  ( LOCK_DIR="$tmp/locks"; port_base_reclaim "$tmp/locks/pr3/403" 21100 )
  want "a block a live run holds is refused" 1 $?
  [ ! -f "$tmp/locks/pr3/403/portbase" ] && ok "and nothing is written on refusal" \
    || bad "portbase was written despite the refusal: $(cat "$tmp/locks/pr3/403/portbase" 2>/dev/null)"
  rm -rf "$tmp/locks/pr1" "$tmp/locks/pr2" "$tmp/locks/pr3"

  echo "port_base_reclaim() — a write that cannot land is a failure, not a silent success"
  # A block found free but never actually WRITTEN is invisible to
  # alloc_port_base's own scan -- which reads $slot/portbase from disk, not
  # from what this function believes it did -- so a caller told it succeeded
  # would proceed as if the block were reserved while nothing on disk says
  # so. The exact cannot-express-failure shape this function exists to
  # remove, reintroduced by the one line inside it that swallowed its own
  # outcome. $slot deliberately never created, so the write has nowhere to
  # land; port_base_free's own scan does not require $slot to exist (it only
  # excludes it by name), so this exercises the write failing on its own,
  # not a failure earlier in the function.
  local pr4="$tmp/locks/pr4/404"
  ( LOCK_DIR="$tmp/locks"; port_base_reclaim "$pr4" 21100 )
  want "a write that cannot land is reported as a failure, not a claim" 1 $?
  [ ! -f "$pr4/portbase" ] && ok "and nothing exists to be read back (there was nowhere to write it)" \
    || bad "a portbase file exists despite the slot dir never being created"
  # And the lock is not left held: a different slot can still claim a block
  # right afterwards.
  mkdir -p "$tmp/locks/pr5/405"
  echo $$ > "$tmp/locks/pr5/405/pid"
  ( LOCK_DIR="$tmp/locks"; port_base_reclaim "$tmp/locks/pr5/405" 21300 )
  want "the lock was not left held by the failed write" 0 $?
  rm -rf "$tmp/locks/pr4" "$tmp/locks/pr5"

  echo "port_base_reclaim() — the scan and the write happen inside ONE lock hold, not around it"
  # Structural: what actually proves the lock closes the race against a
  # concurrent alloc_port_base is the real two-process test below; this
  # guards against port_base_reclaim's own body silently reverting to a
  # scan-then-unlock-then-write shape (or to the wrong lock entirely), which
  # would defeat the whole point while every OTHER test here -- none of
  # which drives real contention against this exact function -- kept passing.
  # Three exits share the lock now, not two: the block-held refusal, a write
  # that could not land, and the success path -- all three must drop it.
  rbody="$(sed -n '/^port_base_reclaim()/,/^}/p' "$BIN_DIR/agentloop")"
  rlt_line="$(printf '%s\n' "$rbody" | grep -n 'lock_take "\$L"'                   | head -1 | cut -d: -f1)"
  rpf_line="$(printf '%s\n' "$rbody" | grep -n 'port_base_free "\$slot" "\$want"'  | head -1 | cut -d: -f1)"
  rwr_line="$(printf '%s\n' "$rbody" | grep -n 'echo "\$want" > "\$slot/portbase"' | head -1 | cut -d: -f1)"
  rld_lines="$(printf '%s\n' "$rbody" | grep -n 'lock_drop "\$L"' | cut -d: -f1)"
  rld1_line="$(printf '%s\n' "$rld_lines" | sed -n '1p')"
  rld2_line="$(printf '%s\n' "$rld_lines" | sed -n '2p')"
  rld3_line="$(printf '%s\n' "$rld_lines" | sed -n '3p')"
  if [ -n "${rlt_line:-}" ] && [ -n "${rpf_line:-}" ] && [ -n "${rwr_line:-}" ] \
       && [ -n "${rld1_line:-}" ] && [ -n "${rld2_line:-}" ] && [ -n "${rld3_line:-}" ] \
       && [ "$rlt_line" -lt "$rpf_line" ] && [ "$rpf_line" -lt "$rld1_line" ] \
       && [ "$rld1_line" -lt "$rwr_line" ] && [ "$rwr_line" -lt "$rld2_line" ] \
       && [ "$rld2_line" -lt "$rld3_line" ]; then
    ok "the lock is taken, the block checked, and dropped on all three exits -- refusal, failed write, and claim -- in order"
  else
    bad "port_base_reclaim's own lock ordering broke (lock=${rlt_line:-?} check=${rpf_line:-?} drop1=${rld1_line:-?} write=${rwr_line:-?} drop2=${rld2_line:-?} drop3=${rld3_line:-?})"
  fi
  got="$(printf '%s\n' "$rbody" | grep -c 'lock_drop "\$L"')"
  [ "${got:-0}" -eq 3 ] && ok "lock_drop appears exactly three times -- once per exit ($got)" \
    || bad "port_base_reclaim drops \$L $got times, expected 3 (refusal, failed write, success)"
  got="$(printf '%s\n' "$rbody" | grep -c 'L="\$LOCK_DIR/.ports"')"
  [ "${got:-0}" -eq 1 ] && ok "and the mutex is \$LOCK_DIR/.ports -- the same one alloc_port_base uses" \
    || bad "port_base_reclaim's lock variable is not pinned to \$LOCK_DIR/.ports (found $got)"

  echo "run_job() — the resume's port claim goes through port_base_reclaim, not an unlocked scan+write"
  # Structural, same reasoning as the reattach-claim-ordering test above: what
  # actually proves the mutex closes the race is the real two-process test
  # below; this only guards against run_job's own call silently reverting to
  # the unlocked port_base_free-then-echo shape the race exists to remove.
  body="$(sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop")"
  got="$(printf '%s\n' "$body" | grep -c 'port_base_reclaim "\$slot" "\$port_base"')"
  [ "${got:-0}" -eq 1 ] && ok "the resume claims its existing block through port_base_reclaim ($got)" \
    || bad "run_job calls port_base_reclaim $got times, expected 1"
  got="$(printf '%s\n' "$body" | grep -c 'echo "\$port_base" > "\$slot/portbase"')"
  [ "${got:-0}" -eq 0 ] && ok "and no longer writes \$slot/portbase itself, unlocked, beside it" \
    || bad "run_job still writes \$slot/portbase directly $got times outside port_base_reclaim"

  echo "port_base_reclaim() vs alloc_port_base() — a resume and a fresh run racing for \$LOCK_DIR/.ports never get the same block"
  # The bug this closes: a resume used to scan port_base_free and write
  # $slot/portbase with NO lock at all, so a fresh run's alloc_port_base --
  # which DOES hold $LOCK_DIR/.ports across its own scan+write -- could land
  # in the gap and hand the SAME block to both: two live runs binding the
  # same published ports, which reads as a broken service, not a scheduling
  # race.
  #
  # Not structural, for the same reason the reattach race above is not: it
  # drives the real lock_take/port_base_free/lock_drop under genuine
  # concurrency, with a deliberate pause INSIDE the held lock so the
  # concurrent alloc_port_base is guaranteed to still be waiting on lock_take
  # when the reclaim has decided the block is free but not yet written it --
  # rather than hoping OS scheduling happens to interleave two calls that
  # would otherwise each finish in well under a millisecond. Reimplements
  # port_base_reclaim's own five-line body (same reason run_job's reattach
  # sequence is reimplemented above, not called directly: there is no way to
  # inject a deterministic pause into the real function without adding a
  # test-only hook to production code) -- the structural test just above is
  # what pins that the REAL function actually has this shape.
  mkdir -p "$tmp/locks/jPort"
  (
    LOCK_DIR="$tmp/locks"
    plock="$LOCK_DIR/.ports"; rm -rf "$plock"

    sleep 5 & pidR=$!
    sleep 5 & pidF=$!
    slotR="$LOCK_DIR/jPort/$pidR"; slotF="$LOCK_DIR/jPort/$pidF"
    mkdir -p "$slotR" "$slotF"
    echo "$pidR" > "$slotR/pid"; boot_id > "$slotR/boot"
    echo "$pidF" > "$slotF/pid"; boot_id > "$slotF/boot"

    reclaim_slow() {
      lock_take "$plock"
      if port_base_free "$slotR" 21000; then
        sleep 0.15
        echo 21000 > "$slotR/portbase"
        echo CLAIMED > "$tmp/portR.out"
      else
        echo REFUSED > "$tmp/portR.out"
      fi
      lock_drop "$plock"
    }
    reclaim_slow & rR=$!
    i=0
    while [ ! -d "$plock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    if [ ! -d "$plock" ]; then
      echo "TIMEOUT" > "$tmp/portF.out"
    else
      alloc_port_base "$slotF" > "$tmp/portF.out" 2>/dev/null
    fi
    wait "$rR"
    kill "$pidR" "$pidF" 2>/dev/null; wait "$pidR" "$pidF" 2>/dev/null
  )
  portR="$(cat "$tmp/portR.out" 2>/dev/null)"
  portF="$(cat "$tmp/portF.out" 2>/dev/null)"
  [ "$portR" = "CLAIMED" ] && ok "the resume's reclaim succeeds ($portR)" || bad "reclaim result was '$portR'"
  [ "$portF" = "21100" ] && ok "the concurrent alloc_port_base gets the NEXT block, not the reclaimed one ($portF)" \
    || bad "alloc_port_base returned '$portF', wanted 21100 -- either it collided with 21000 or timed out on the lock"
  rm -rf "$tmp/locks/jPort" "$tmp/portR.out" "$tmp/portF.out"

  echo "provision-lib.sh — a run's ports come from its own block"
  local plib="$BIN_DIR/provision-lib.sh"
  got="$( AL_PORT_BASE=21000 AL_PORT_SPAN=100 TMPDIR="$tmp" bash -c \
    'source "$1"; echo "$(al_port POSTGRES_PORT) $(al_port REDIS_PORT) $(al_port POSTGRES_PORT)"' _ "$plib" )"
  [ "$got" = "21000 21001 21000" ] && ok "each name gets its own port, and keeps it" \
    || bad "got '$got'"
  # The whole point: rewrite the ports a checked-in .env carries, and touch
  # nothing else in it.
  printf '%s\n' 'POSTGRES_PORT=5432' 'REDIS_PORT=6379' 'SECRET=keepme' > "$tmp/dotenv"
  ( AL_PORT_BASE=21200 AL_PORT_SPAN=100 TMPDIR="$tmp" bash -c \
    'source "$1"; al_env_ports "$2"' _ "$plib" "$tmp/dotenv" ) >/dev/null 2>&1
  got="$(grep -c -E '^(POSTGRES|REDIS)_PORT=212[0-9][0-9]$' "$tmp/dotenv")"
  [ "$got" = "2" ] && ok "every *_PORT in the file moves into the block" || bad "$got of 2 rewritten"
  grep -q '^SECRET=keepme$' "$tmp/dotenv" && ok "and nothing else in the file is touched" \
    || bad "the rest of the file did not survive"
  # A key the file does not have must not be invented: publishing a service the
  # project never asked for is worse than leaving it alone.
  grep -q "QDRANT" "$tmp/dotenv" && bad "invented a key that was not there" \
    || ok "keys the file never had are not added"

  echo "run_end_hook() — an unattended pipeline can tell someone it broke"
  mkdir -p "$tmp/hookcfg/hooks"
  ( CONFIG_DIR="$tmp/hookcfg"; run_end_hook j1 error 1.5 "boom" P sess /tmp/l.json 1 2 ) >/dev/null 2>&1
  want "no hook installed is a no-op" 0 $?
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s|%s|%s|%s|%s\n" "$AL_JOB_ID" "$AL_STATUS" "$AL_COST" "$AL_NOTE" "$AL_PROJECT" > "$AL_HOOK_OUT"' \
    > "$tmp/hookcfg/hooks/on-run-end.sh"
  export AL_HOOK_OUT="$tmp/hook.seen"; rm -f "$AL_HOOK_OUT"
  ( CONFIG_DIR="$tmp/hookcfg"; run_end_hook j1 error 1.5 "boom" P sess /tmp/l.json 1 2 ) >/dev/null 2>&1
  local waited=0
  while [ ! -f "$AL_HOOK_OUT" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
  got="$(cat "$AL_HOOK_OUT" 2>/dev/null)"
  [ "$got" = "j1|error|1.5|boom|P" ] && ok "the hook is told which run ended and how" \
    || bad "the hook saw '$got'"
  # It must never delay the run's cleanup, however slow or wedged it is.
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$tmp/hookcfg/hooks/on-run-end.sh"
  t0="$(now_epoch)"
  ( CONFIG_DIR="$tmp/hookcfg"; run_end_hook j1 error 0 "" P s /tmp/l.json 1 2 ) >/dev/null 2>&1
  elapsed=$(( $(now_epoch) - t0 ))
  [ "$elapsed" -lt 3 ] && ok "a slow hook does not hold the run open (${elapsed}s)" \
    || bad "run_end_hook blocked for ${elapsed}s"
  unset AL_HOOK_OUT
  rm -f "$tmp/hookcfg/hooks/on-run-end.sh"

  echo "the round cap itself — counting, parking, failing open"
  # The cap is the only hard stop on the dev/review loop, so its own behaviour is
  # tested against a fake Jira rather than asserted by reading the source.
  if [ -x "$BASE_DIR/test/round-cap.test.sh" ]; then
    local rcout
    if rcout="$("$BASE_DIR/test/round-cap.test.sh" 2>&1)"; then
      ok "round-cap suite ($(printf '%s' "$rcout" | grep -c '  PASS') cases)"
    else
      bad "round-cap suite failed:"
      printf '%s\n' "$rcout" | grep '  FAIL' | sed 's/^/      /'
    fi
  else
    ok "round-cap suite not installed — skipped"
  fi

  echo "a whole run, end to end — worktree, agent, marker, teardown, resume, expiry"
  # Everything above this line is unit-level: it calls wt_setup, the classifier
  # and the sweep directly. The defects that cost most getting here were the ones
  # that only appear where those MEET -- a marker written before the status was
  # final, a resume that could not find the directory its own session was bound
  # to, an upgrade that reaped what the previous version had been preserving.
  # None of them is visible to a test that never drives a whole run.
  #
  # It stays offline and free: test/fake-claude stands in for the CLI, and the
  # run redirects CONFIG and DATA into its own sandbox, so an operator's jobs and
  # run history are neither read nor written.
  if [ -x "$BASE_DIR/test/e2e.test.sh" ]; then
    local e2eout
    if e2eout="$("$BASE_DIR/test/e2e.test.sh" 2>&1)"; then
      ok "end-to-end suite ($(printf '%s' "$e2eout" | grep -c '  ok ') checks)"
    else
      bad "end-to-end suite failed:"
      printf '%s\n' "$e2eout" | grep '  FAIL' | sed 's/^/      /'
    fi
  else
    ok "end-to-end suite not installed — skipped"
  fi

  echo "the dev/review loop has an exit condition"
  # The loop between the dev and review agents once ran without a terminating
  # condition: both prompts said "repeat until nothing blocks", and the reviewer's
  # bar ("any behavioural finding of any severity") is not a state a real pull
  # request reaches. Rounds only ended when the budget did. Three properties keep
  # that closed, and each has been silently undone before by an edit elsewhere —
  # so they are asserted here rather than trusted to prose.
  local jf="${AL_JOBS_FILE:-$CONFIG_DIR/jobs.json}"
  if [ ! -f "$jf" ]; then
    ok "no jobs.json — loop invariants not applicable"
  else
    # All three invariants below find their subjects by an id convention
    # (`<project>-dev-agent`, `<project>-reviewer-agent`). An install that names
    # its jobs otherwise matches nothing — and "nothing matched" was reported as
    # total non-compliance ("missing from 0 of 0"), so the suite was red on every
    # install not using the suffix, for a rule none of its jobs were breaking.
    # An invariant over an empty set holds. Say so, and say the convention out
    # loud in the same breath: a check that silently examined nothing is the
    # failure mode this whole block exists to prevent.
    #
    # 1. The cap is enforced in shell, before a session exists, on BOTH boards.
    local capped=0 devjobs=0
    for pc in "$CONFIG_DIR"/prechecks/*-dev-agent.sh; do
      [ -f "$pc" ] || continue
      devjobs=$(( devjobs + 1 ))
      grep -q 'rc_gate_rework' "$pc" && capped=$(( capped + 1 ))
    done
    if [ "$devjobs" -eq 0 ]; then
      ok "round cap: no prechecks/*-dev-agent.sh here — nothing to check"
    elif [ "$capped" -eq "$devjobs" ]; then
      ok "every dev precheck enforces the round cap ($capped/$devjobs)"
    else
      bad "round cap missing from $(( devjobs - capped )) of $devjobs dev prechecks"
    fi

    # 2. No prompt still promises an unbounded loop, or a bar that cannot be met.
    local residual
    residual="$("$JQ" -r '.jobs[] | .id as $i | .prompt // "" | split("\n")[]
                          | select(test("any finding of any severity|repeating until nothing blocks|repeating until the review is genuinely clean|found nothing at all"))
                          | $i' "$jf" 2>/dev/null | sort -u | tr '\n' ' ')"
    [ -z "$residual" ] \
      && ok "no prompt promises an unbounded loop" \
      || bad "unbounded-loop wording is back in: $residual"

    # 3. The reviewer can actually approve over a non-blocking finding, and the
    #    dev is told to prove a widening did not go too far. Losing either one
    #    restarts the pendulum that produced the expensive rounds.
    local rev_ok=0 rev_n=0 dev_ok=0 dev_n=0
    while IFS=$'\t' read -r id prompt; do
      case "$id" in
        *-reviewer-agent)
          rev_n=$(( rev_n + 1 ))
          printf '%s' "$prompt" | grep -q 'Follow-up findings (not blocking)' \
            && rev_ok=$(( rev_ok + 1 )) ;;
        *-dev-agent)
          dev_n=$(( dev_n + 1 ))
          printf '%s' "$prompt" | grep -q 'containment test' \
            && dev_ok=$(( dev_ok + 1 )) ;;
      esac
    done < <("$JQ" -r '.jobs[] | [.id, (.prompt // "")] | @tsv' "$jf" 2>/dev/null)
    if [ "$rev_n" -eq 0 ]; then
      ok "non-blocking route: no *-reviewer-agent job here — nothing to check"
    elif [ "$rev_ok" -eq "$rev_n" ]; then
      ok "every reviewer may record a finding without spending a round ($rev_ok/$rev_n)"
    else
      bad "the non-blocking route is missing from $(( rev_n - rev_ok )) of $rev_n reviewers"
    fi
    if [ "$dev_n" -eq 0 ]; then
      ok "containment rule: no *-dev-agent job here — nothing to check"
    elif [ "$dev_ok" -eq "$dev_n" ]; then
      ok "every dev prompt requires a containment test when a rule widens ($dev_ok/$dev_n)"
    else
      bad "the containment rule is missing from $(( dev_n - dev_ok )) of $dev_n dev prompts"
    fi
  fi

  # ---- security configuration ------------------------------------------
  mkdir -p "$tmp/sec"
  cat > "$tmp/sec/projects.json" <<'JSON'
{"projects":[
 {"name":"Quality Gate","cwd":"/tmp/qg","base":"develop",
  "security":{"enabled":true,"model":"claude-opus-5","max_budget_usd":5}},
 {"name":"Off","cwd":"/tmp/off","security":{"enabled":false}},
 {"name":"Bare","cwd":"/tmp/bare"}]}
JSON
  ( PROJECTS_FILE="$tmp/sec/projects.json"
    [ "$(security_get "Quality Gate" '.model' '')" = "claude-opus-5" ] ) \
    && ok "security_get reads a project's security block" \
    || bad "security_get reads a project's security block"
  ( PROJECTS_FILE="$tmp/sec/projects.json"
    [ "$(security_get "Bare" '.model' 'opus')" = "opus" ] ) \
    && ok "security_get falls back when there is no security block" \
    || bad "security_get falls back when there is no security block"
  ( PROJECTS_FILE="$tmp/sec/projects.json"; security_enabled "Quality Gate" ) \
    && ok "security_enabled is true for an enabled project" \
    || bad "security_enabled is true for an enabled project"
  ( PROJECTS_FILE="$tmp/sec/projects.json"; ! security_enabled "Off" ) \
    && ok "security_enabled is false when the block says so" \
    || bad "security_enabled is false when the block says so"
  ( PROJECTS_FILE="$tmp/sec/projects.json"; ! security_enabled "Bare" ) \
    && ok "security_enabled is false when there is no block at all" \
    || bad "security_enabled is false when there is no block at all"
  [ "$(security_slug "Quality Gate")" = "quality-gate" ] \
    && ok "security_slug lowercases and dashes a project name" \
    || bad "security_slug lowercases and dashes a project name"

  # ---- project-set merges by name ----------------------------------------
  # cmd_project_set receives whatever pane the dashboard's project editor was
  # on, not the whole project object -- a REPLACE would let an edit made on
  # one pane erase every field only some other pane owns. The merge (`. * $p`)
  # is what keeps them apart, and it merges recursively: a partial `security`
  # object does not erase the fields of `security` it does not mention either.
  mkdir -p "$tmp/pset"
  cat > "$tmp/pset/projects.json" <<'JSON'
{"projects":[{"name":"Web","cwd":"/tmp/web",
  "security":{"enabled":true,"model":"claude-opus-5"}}]}
JSON
  ( PROJECTS_FILE="$tmp/pset/projects.json"
    printf '{"name":"Web","cwd":"/tmp/web2"}' | cmd_project_set >/dev/null
    [ "$("$JQ" -r '.projects[0].security.model' "$tmp/pset/projects.json")" = "claude-opus-5" ] ) \
    && ok "editing a project's cwd does not wipe its security block" \
    || bad "editing a project's cwd does not wipe its security block"
  [ "$("$JQ" -r '.projects[0].cwd' "$tmp/pset/projects.json")" = "/tmp/web2" ] \
    && ok "and the cwd it was sent to change actually changed" \
    || bad "and the cwd it was sent to change actually changed"

  cat > "$tmp/pset/projects2.json" <<'JSON'
{"projects":[{"name":"Api","cwd":"/tmp/api",
  "repos":[{"name":"api","path":"/tmp/api","base":"main"}]}]}
JSON
  ( PROJECTS_FILE="$tmp/pset/projects2.json"
    printf '{"name":"Api","security":{"enabled":true,"model":"claude-opus-5"}}' \
      | cmd_project_set >/dev/null
    [ "$("$JQ" -c '.projects[0].repos' "$tmp/pset/projects2.json")" \
        = '[{"name":"api","path":"/tmp/api","base":"main"}]' ] ) \
    && ok "and enabling security on save does not wipe an existing repos list" \
    || bad "and enabling security on save does not wipe an existing repos list"

  # ---- derived security jobs -------------------------------------------
  mkdir -p "$tmp/derived"
  cat > "$tmp/derived/projects.json" <<'JSON'
{"projects":[{"name":"Web","cwd":"/tmp/web","base":"main",
  "security":{"enabled":true,"model":"claude-opus-5","max_budget_usd":5}}]}
JSON
  printf '{"jobs":[{"id":"real-job","enabled":true,"prompt":"x"}]}\n' > "$tmp/derived/jobs.json"
  mkdir -p "$tmp/derived/data/security/requests"
  cat > "$tmp/derived/data/security/requests/security-web.json" <<'JSON'
{"analysis_id":3,"project":"Web","repo":"web","branch":"develop","profile":"deep"}
JSON

  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job","security-web"]' >/dev/null ) \
    && ok "jobs_json emits a derived job for a security-enabled project" \
    || bad "jobs_json emits a derived job for a security-enabled project"

  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ "$(job_get security-web '.model' '')" = "claude-opus-5" ] ) \
    && ok "the derived job carries the project's security model" \
    || bad "the derived job carries the project's security model"

  # The `Agent` tool is closed at LAUNCH, not asked for in the prompt -- asking
  # is what already failed twice ($51.44, six subagents, zero of 40
  # deterministic findings triaged; see SECURITY_DISALLOWED_TOOLS). That is the
  # Claude Code half: on Codex nothing closes `spawn_agent` by flag, so there
  # the prompt is the only door (security_prompt, checked above). Three
  # separate things have to hold, and each has its own way of silently
  # regressing: the field on the derived job, the field NOT leaking onto
  # ordinary jobs, and run_job actually turning the field into a CLI flag.
  #
  # The literal "Agent", NOT $SECURITY_DISALLOWED_TOOLS. Comparing the emitted
  # value against the very constant that produced it asserts nothing: a test
  # may not take its expected value from the thing it tests.
  #
  # SINCE BLOCK 4.2 THE ASSERTION IS THE OTHER WAY UP. The verification phase
  # IS subagents, so the tool is open and the derived job closes nothing --
  # and what keeps that honest is not this field but the CLOSE, which counts
  # the `Task` calls in the run's stream against the verdicts in the ledger
  # (see security_task_count and `finish --tasks-launched`). An empty field
  # here would also be what a BROKEN derivation produces, so the job is read
  # for a field it must carry as well: an empty `disallowed_tools` on a job
  # that has a prompt is the open tool; an empty one on a job that has
  # nothing is a derivation that fell over.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ -z "$(job_get security-web '.disallowed_tools' '')" ] \
    && [ -n "$(job_get security-web '.prompt' '')" ] ) \
    && ok "the derived job closes no tool: verification needs subagents, and the close counts them" \
    || bad "the derived job's disallowed_tools is '$(job_get security-web '.disallowed_tools' '')' with prompt length $(job_get security-web '.prompt' '' | wc -c)"

  # A real job of the operator's carries no such field either, and never did:
  # what a user's job may launch is the user's business.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ -z "$(job_get real-job '.disallowed_tools' '')" ] ) \
    && ok "and a job the user wrote carries no such field, so nothing is denied to it" \
    || bad "disallowed_tools leaked onto a user's own job"

  # THE ARGV, not the source text. What stood here were two assertions that
  # `sed`-ed run_job's own body and grepped it for the literal lines
  # `disallowed="$(job_get ... .disallowed_tools` and
  # `args="$args --disallowedTools $disallowed"`. They proved those lines
  # EXISTED. They never once looked at what the CLI was actually handed -- and
  # the line they vouched for shipped BROKEN: `--disallowedTools` is variadic,
  # it sat last in $args immediately before the prompt positional, Commander ate
  # the prompt as a second tool name, and `--print` died with "Input must be
  # provided either through stdin or as a prompt argument". Every security
  # analysis ended error / killed / 0 turns, before its first turn, with both
  # assertions green. Source text is not behaviour. Observe the launch.
  #
  # AGENTLOOP_CLAUDE_BIN is honoured by run_job, so the whole apparatus is a
  # stand-in that records its own argv and exits. Offline and free -- no model
  # is reached, and CONFIG/DATA are redirected into this test's own $tmp.
  local argvdir="$tmp/argv"
  mkdir -p "$argvdir/config" "$argvdir/data" "$argvdir/work"
  cat > "$argvdir/claude" <<'SH'
#!/usr/bin/env bash
# Not a stand-in for the CLI so much as a microscope on the launch line. One
# line per ARGUMENT, "<n><TAB><that argument's first line>". Only the first
# line, because the prompt is a paragraph -- but one line here is still exactly
# one argument there, which is the entire point of recording it.
exec > "$AL_ARGV_OUT"
printf 'ARGC\t%s\n' "$#"
n=0
for a in "$@"; do n=$((n + 1)); printf '%s\t%s\n' "$n" "${a%%$'\n'*}"; done
SH
  chmod +x "$argvdir/claude"
  printf '{"projects":[]}\n' > "$argvdir/config/projects.json"
  # Three jobs, one per shape that has to hold. `allowed_tools` deliberately
  # carries a value with a SPACE and a glob character -- the `Bash(git *)` form
  # the README invites -- because an unquoted assembly would split it into
  # `Bash(git` and `*)` and then pathname-expand the second half.
  cat > "$argvdir/config/jobs.json" <<JSON
{"jobs":[
 {"id":"argv-deny","enabled":false,"cwd":"$argvdir/work","prompt":"PROMPT-SENTINEL",
  "permission_mode":"bypassPermissions","disallowed_tools":"Agent"},
 {"id":"argv-both","enabled":false,"cwd":"$argvdir/work","prompt":"PROMPT-SENTINEL",
  "permission_mode":"bypassPermissions","allowed_tools":"Bash(git *),Read",
  "disallowed_tools":"Agent"},
 {"id":"argv-plain","enabled":false,"cwd":"$argvdir/work","prompt":"PROMPT-SENTINEL",
  "permission_mode":"bypassPermissions"}]}
JSON
  # What Settings switched on for these launches. Explicit: the seed would
  # find three disabled jobs, enable nothing, and every run below would be
  # refused at the platform gate before a launch line ever existed.
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["opus"]}}}\n' > "$argvdir/config/platforms.json"
  st_argv_run() { # st_argv_run <job-id> -- the recorded argv of one real launch
    rm -f "$argvdir/out"
    AGENTLOOP_CONFIG="$argvdir/config" AGENTLOOP_DATA="$argvdir/data" \
      AGENTLOOP_CLAUDE_BIN="$argvdir/claude" AL_ARGV_OUT="$argvdir/out" \
      "$BIN_DIR/agentloop" run "$1" >/dev/null 2>&1
    cat "$argvdir/out" 2>/dev/null
  }
  st_argv_idx() { printf '%s\n' "$1" | awk -F'\t' -v w="$2" '$2==w {print $1; exit}'; }
  st_argv_at()  { printf '%s\n' "$1" | awk -F'\t' -v i="$2" '$1==i {print $2; exit}'; }
  st_argv_argc() { printf '%s\n' "$1" | awk -F'\t' '$1=="ARGC" {print $2; exit}'; }
  local av_deny av_both av_plain av_filebin di ai mi
  av_deny="$(st_argv_run argv-deny)"
  di="$(st_argv_idx "$av_deny" '--disallowedTools')"
  ( [ -n "$di" ] && [ "$(st_argv_at "$av_deny" "$((di + 1))")" = "Agent" ] ) \
    && ok "the launch really is handed --disallowedTools Agent, read back off its own argv" \
    || bad "no --disallowedTools Agent in the launch argv — the Agent tool is open again"

  # THE regression. Without `--` the variadic flag swallows this; with it, the
  # prompt is the last argument and stands alone. Both halves are asserted: `--`
  # is present, AND exactly one argument follows it.
  mi="$(st_argv_idx "$av_deny" '--')"
  ( [ -n "$mi" ] && [ "$((mi + 1))" = "$(st_argv_argc "$av_deny")" ] \
    && case "$(st_argv_at "$av_deny" "$((mi + 1))")" in PROMPT-SENTINEL*) true ;; *) false ;; esac ) \
    && ok "and the prompt survives as the one argument after --, not eaten by the variadic flag" \
    || bad "the prompt is not a lone positional after -- — --print gets no input and the run dies at 0 turns"

  # Both fields at once. The CLI decides which wins (deny does, measured on
  # 2.1.258 -- see the note by the `disallowed` read in run_job); what run_job
  # owes is that BOTH flags reach it, each with its value intact as ONE argument.
  av_both="$(st_argv_run argv-both)"
  ai="$(st_argv_idx "$av_both" '--allowedTools')"
  di="$(st_argv_idx "$av_both" '--disallowedTools')"
  mi="$(st_argv_idx "$av_both" '--')"
  ( [ -n "$ai" ] && [ -n "$di" ] \
    && [ "$(st_argv_at "$av_both" "$((di + 1))")" = "Agent" ] \
    && [ -n "$mi" ] && [ "$((mi + 1))" = "$(st_argv_argc "$av_both")" ] ) \
    && ok "a job carrying BOTH tool fields is launched with both flags, and still keeps its prompt" \
    || bad "a job with allowed_tools AND disallowed_tools loses a flag or its prompt at launch"
  [ "$(st_argv_at "$av_both" "$((ai + 1))")" = 'Bash(git *),Read' ] \
    && ok "and a tool value with a space and a glob arrives as ONE argument, unexpanded" \
    || bad "allowed_tools was word-split or glob-expanded: got '$(st_argv_at "$av_both" "$((ai + 1))")'"

  # The control. Nothing may be denied to a job that asked for nothing -- but
  # `--` is NOT conditional on a tool flag: it costs nothing when there is no
  # option to terminate, and making it conditional is how the prompt would lose
  # its guard again the next time a variadic flag is added anywhere in $args.
  av_plain="$(st_argv_run argv-plain)"
  ( [ -z "$(st_argv_idx "$av_plain" '--allowedTools')" ] \
    && [ -z "$(st_argv_idx "$av_plain" '--disallowedTools')" ] ) \
    && ok "a job with neither field is launched with neither flag, so nothing is denied to it" \
    || bad "a tool flag reached a job that set neither field"
  mi="$(st_argv_idx "$av_plain" '--')"
  ( [ -n "$mi" ] && [ "$((mi + 1))" = "$(st_argv_argc "$av_plain")" ] ) \
    && ok "and -- is there regardless, so the prompt is guarded with or without a tool flag" \
    || bad "-- is emitted only alongside a tool flag — the guard is conditional, and one day it will be missing"

  # The gate and the launch must agree on the binary. Same recording
  # stand-in, but no AGENTLOOP_CLAUDE_BIN this time: config/platforms.json's
  # own `bin` is the only route to it, so a recorded PROMPT-SENTINEL argument
  # can only have come from the real launch -- platform_check's own
  # --version/auth-status probes write the same file, but never the prompt.
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"%s","models":["opus"]}}}\n' \
    "$argvdir/claude" > "$argvdir/config/platforms.json"
  rm -f "$argvdir/out"
  AGENTLOOP_CONFIG="$argvdir/config" AGENTLOOP_DATA="$argvdir/data" \
    AGENTLOOP_CLAUDE_BIN="" AL_ARGV_OUT="$argvdir/out" \
    "$BIN_DIR/agentloop" run argv-plain >/dev/null 2>&1
  av_filebin="$(cat "$argvdir/out" 2>/dev/null)"
  mi="$(st_argv_idx "$av_filebin" '--')"
  ( [ -n "$mi" ] && [ "$((mi + 1))" = "$(st_argv_argc "$av_filebin")" ] \
    && case "$(st_argv_at "$av_filebin" "$((mi + 1))")" in PROMPT-SENTINEL*) true ;; *) false ;; esac ) \
    && ok "run_job launches config/platforms.json's own bin, the same one platform_ready checked" \
    || bad "the launch never reached the file's bin — no launch argv reached the recorder: $av_filebin"

  # The prompt explains the absence. It does not enforce it (the flag does),
  # but an agent that finds a tool missing with no reason given wastes turns
  # rediscovering the wall the first analysis already paid to find.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    job_get security-web '.prompt' '' | grep -q 'You HAVE subagents in this run' ) \
    && ok "the derived job's prompt says subagents exist and what they are for" \
    || bad "the prompt no longer explains what subagents are for"

  # The mode the analysis runs under. dontAsk looked safer and was the
  # opposite: headless dontAsk denies every tool outside an allowlist a fresh
  # worktree does not have, so the first live analysis could not run one
  # command. The default is the fleet's own headless default; an explicit
  # security.permission_mode wins; a typo falls back rather than launching a
  # run that dies at its first tool call.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ "$(job_get security-web '.permission_mode' '')" = "bypassPermissions" ] ) \
    && ok "a derived job defaults to bypassPermissions, not headless-dead dontAsk" \
    || bad "a derived job defaults to bypassPermissions, not headless-dead dontAsk"

  mkdir -p "$tmp/dperm"
  cat > "$tmp/dperm/projects.json" <<'JSON'
{"projects":[
 {"name":"Strict","cwd":"/tmp/s","security":{"enabled":true,"permission_mode":"dontAsk"}},
 {"name":"Typo","cwd":"/tmp/t","security":{"enabled":true,"permission_mode":"yolo"}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/dperm/jobs.json"
  ( JOBS_FILE="$tmp/dperm/jobs.json"; PROJECTS_FILE="$tmp/dperm/projects.json"
    DATA_DIR="$tmp/dperm/data"
    [ "$(job_get security-strict '.permission_mode' '')" = "dontAsk" ] ) \
    && ok "an explicit security.permission_mode wins over the default" \
    || bad "an explicit security.permission_mode wins over the default"
  ( JOBS_FILE="$tmp/dperm/jobs.json"; PROJECTS_FILE="$tmp/dperm/projects.json"
    DATA_DIR="$tmp/dperm/data"
    [ "$(job_get security-typo '.permission_mode' '')" = "bypassPermissions" ] ) \
    && ok "a permission_mode the CLI does not know falls back instead of dying later" \
    || bad "a permission_mode the CLI does not know falls back instead of dying later"

  # A slot must name the process that HOLDS it. $$ inside a ( subshell ) is
  # the parent's pid -- frozen by bash design -- and the detached analysis
  # runs run_job in exactly such a subshell: the recorded holder exited
  # seconds later, the engine judged the slot dead, max_parallel stopped
  # gating and the page called a healthy run dead. current_pid asks the
  # kernel instead.
  # The detached analysis must re-exec a NEW PROCESS. A ( subshell ) inherits
  # a frozen $$ on bash 3.2 (no BASHPID), so its slot would name a parent that
  # exits seconds later: the engine reads the slot as dead, max_parallel stops
  # gating, and the page calls a healthy analysis dead. Structural, because the
  # regression is a one-word edit back to calling the function inline.
  grep -q 'exec "$SELF" __run-analysis' "$SELF" \
    && ok "a detached analysis re-execs a new process, never a subshell" \
    || bad "a detached analysis re-execs a new process, never a subshell"
  grep -q '^  __run-analysis)' "$SELF" \
    && ok "the detached entry point is reachable from the dispatch" \
    || bad "the detached entry point is reachable from the dispatch"

  # The property the whole design rests on: the tick must never schedule it.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    [ "$(job_get security-web '.enabled' '')" = "false" ] ) \
    && ok "the derived job is disabled, so a scheduled tick never launches it" \
    || bad "the derived job is disabled, so a scheduled tick never launches it"

  # The prompt has to carry the request, or the agent has no branch to analyse.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"
    job_get security-web '.prompt' '' | grep -q 'develop' ) \
    && ok "the derived job's prompt names the requested branch" \
    || bad "the derived job's prompt names the requested branch"

  # write_jobs must not learn about it: config/jobs.json stays the user's.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"; CONFIG_DIR="$tmp/derived"
    write_jobs '.jobs = [.jobs[] | if .id=="real-job" then .enabled=false else . end]'
    "$JQ" -e '[.jobs[].id] == ["real-job"]' "$tmp/derived/jobs.json" >/dev/null ) \
    && ok "a write never persists a derived job into jobs.json" \
    || bad "a write never persists a derived job into jobs.json"

  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"; CONFIG_DIR="$tmp/derived"
    ! printf '{"id":"security-anything"}' | cmd_create 2>/dev/null ) \
    && ok "the security- prefix is refused for a hand-made job" \
    || bad "the security- prefix is refused for a hand-made job"

  # The engine's own security calls run without the agent's flag. `finish`,
  # `unit-close` and the lifecycle verbs are refused to an agent session,
  # and the engine makes them from inside the run_job that exported
  # AL_SECURITY_AGENT for the agent: without the unset every close of every
  # analysis would be refused, and every analysis would stay `running`.
  ( AL_SECURITY_AGENT=1; CC_SECURITY_AGENT=1; export AL_SECURITY_AGENT CC_SECURITY_AGENT
    PYTHON="$tmp/env-python"
    printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${AL_SECURITY_AGENT:-}" "${CC_SECURITY_AGENT:-}"\n' > "$PYTHON"
    chmod +x "$PYTHON"
    [ "$(security_engine_py finish --analysis 1 --state done)" = "|" ] \
      && [ "$(security_py finish --analysis 1 --state done)" = "1|1" ] ) \
    && ok "security_engine_py calls the CLI with the agent flag removed, and only that call" \
    || bad "security_engine_py passed the agent flag through, or security_py lost it"

  # security_close_analysis must ignore every job that is not a derived one,
  # or a normal run ending would try to close an analysis that never existed.
  ( DATA_DIR="$tmp/derived/data"; security_close_analysis "real-job" "error" "0" ) \
    && ok "closing an analysis is a no-op for a job that is not derived" \
    || bad "closing an analysis is a no-op for a job that is not derived"

  # What a run read, off its own stream: `Read` on Claude Code (file_path),
  # `read` on OpenCode (filePath, already canonicalised to Read by the
  # normaliser) and a `cat` through Bash on Codex all land in `input`, so the
  # input is matched as ONE string, with no per-platform key map.
  mkdir -p "$tmp/guides"
  cat > "$tmp/guides/stream.ndjson" <<'JSON'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Read","input":{"file_path":"/Users/me/.claude/skills/security-analysis/references/ATTACK-CLASSES.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"2","name":"Read","input":{"filePath":"/Users/me/.claude/skills/security-analysis/references/AI-AND-LLM.md"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"3","name":"Bash","input":{"command":"cat /Users/me/.claude/skills/security-analysis/references/AI-AND-LLM.md | head"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reading references/CLIENT-SIDE.md is not a tool call"}]}}
{"type":"result","subtype":"success"}
JSON
  [ "$(security_guides_read "$tmp/guides/stream.ndjson")" = "AI-AND-LLM,ATTACK-CLASSES" ] \
    && ok "security_guides_read: the guides a run opened, once each, off Read/read/Bash alike" \
    || bad "security_guides_read: got '$(security_guides_read "$tmp/guides/stream.ndjson")'"
  printf '{"type":"result"}\n' > "$tmp/guides/none.ndjson"
  [ -z "$(security_guides_read "$tmp/guides/none.ndjson")" ] \
    && ok "security_guides_read: a run that opened no guide answers an empty list, not unknown" \
    || bad "security_guides_read on a guide-less stream: '$(security_guides_read "$tmp/guides/none.ndjson")'"
  [ "$(security_guides_read "$tmp/guides/missing.ndjson")" = "unknown" ] \
    && [ "$(security_guides_read "")" = "unknown" ] \
    && ok "security_guides_read: a missing or unnamed stream answers unknown, never none" \
    || bad "security_guides_read on a missing stream: '$(security_guides_read "$tmp/guides/missing.ndjson")'"
  # The close hands the answer to `finish` as --guides-read, and `unknown`
  # when it has no stream to read.
  ( DATA_DIR="$tmp/derived/data"; AL_SECURITY_ANALYSIS_ID=7
    security_py() { printf '%s\n' "$*" >> "$tmp/guides/calls"; }
    security_close_analysis "security-x" success 1 "" "$tmp/guides/stream.ndjson"
    security_close_analysis "security-x" success 1 "" )
  grep -q -- '--guides-read AI-AND-LLM,ATTACK-CLASSES' "$tmp/guides/calls" \
    && grep -q -- '--guides-read unknown' "$tmp/guides/calls" \
    && ok "security_close_analysis passes what was read to finish, and unknown without a stream" \
    || bad "security_close_analysis calls: $(cat "$tmp/guides/calls")"

  # The subagents a run launched, off its own stream. BOTH NAMES: a `tool_use`
  # block carries `Agent` on Claude Code (measured on the block 4.2 acceptance
  # run) while the init roster and OpenCode's normaliser say `Task`. The
  # fixture below holds one of each, and the count is 2.
  cat > "$tmp/guides/tasks.ndjson" <<'JSON'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Task","input":{"description":"verify b1b1","prompt":"You are verifying one security finding"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"2","name":"Read","input":{"file_path":"/Users/me/x.py"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"3","name":"Agent","input":{"description":"verify c2c2","prompt":"You are verifying one security finding","subagent_type":"general-purpose"}}]}}
{"type":"result","subtype":"success"}
JSON
  [ "$(security_task_count "$tmp/guides/tasks.ndjson")" = "2" ] \
    && ok "security_task_count: counts the subagents a run launched" \
    || bad "security_task_count: got '$(security_task_count "$tmp/guides/tasks.ndjson")'"
  [ "$(security_task_count "$tmp/guides/none.ndjson")" = "0" ] \
    && ok "security_task_count: a run that launched none answers 0" \
    || bad "security_task_count on a Task-less stream: '$(security_task_count "$tmp/guides/none.ndjson")'"
  [ -z "$(security_task_count "$tmp/guides/missing.ndjson")" ] \
    && [ -z "$(security_task_count "")" ] \
    && ok "security_task_count: a missing stream answers nothing, never 0 -- the close then makes no comparison" \
    || bad "security_task_count on a missing stream: '$(security_task_count "$tmp/guides/missing.ndjson")'"
  ( DATA_DIR="$tmp/derived/data"; AL_SECURITY_ANALYSIS_ID=7
    security_py() { printf '%s\n' "$*" >> "$tmp/guides/tcalls"; }
    security_close_analysis "security-x" success 1 "" "$tmp/guides/tasks.ndjson"
    security_close_analysis "security-x" success 1 "" )
  grep -q -- '--tasks-launched 2' "$tmp/guides/tcalls" \
    && [ "$(grep -c -- '--tasks-launched' "$tmp/guides/tcalls")" = "1" ] \
    && ok "security_close_analysis passes the Task count, and omits the flag without a stream" \
    || bad "security_close_analysis calls: $(cat "$tmp/guides/tcalls")"

  # The Agent tool is OPEN now, and the prompt says what for.
  [ -z "$SECURITY_DISALLOWED_TOOLS" ] \
    && ok "the Agent tool is no longer closed at launch: verification needs subagents" \
    || bad "SECURITY_DISALLOWED_TOOLS is '$SECURITY_DISALLOWED_TOOLS'"

  # A project name that slugs to nothing (e.g. "!!!") would derive the bare
  # prefix -- not a usable id, and not any project's job. It must be skipped,
  # not silently emitted as a job nobody can tell apart from another.
  mkdir -p "$tmp/derived/data2"
  cat > "$tmp/derived/empty-slug-projects.json" <<'JSON'
{"projects":[{"name":"!!!","cwd":"/tmp/bang","security":{"enabled":true}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/empty-slug-projects.json"
    DATA_DIR="$tmp/derived/data2"; TICK_LOG="$tmp/derived/data2/tick.log"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job"]' >/dev/null \
    && grep -q "cannot derive a job id" "$TICK_LOG" ) \
    && ok "a project name that slugs to nothing is skipped, not emitted as a job" \
    || bad "a project name that slugs to nothing is skipped, not emitted as a job"

  # Two project names can slug to the same id ("My App" and "my-app"). The
  # first one wins; the second is skipped rather than silently colliding.
  mkdir -p "$tmp/derived/data3/security/requests"
  cat > "$tmp/derived/dup-slug-projects.json" <<'JSON'
{"projects":[
 {"name":"My App","cwd":"/tmp/a","security":{"enabled":true,"model":"claude-opus-5"}},
 {"name":"my-app","cwd":"/tmp/b","security":{"enabled":true,"model":"claude-sonnet-5"}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/dup-slug-projects.json"
    DATA_DIR="$tmp/derived/data3"; TICK_LOG="$tmp/derived/data3/tick.log"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job","security-my-app"]' >/dev/null \
    && [ "$(job_get security-my-app '.model' '')" = "claude-opus-5" ] \
    && grep -q "already used by another project" "$TICK_LOG" ) \
    && ok "two projects deriving the same job id: the first wins, the second is skipped" \
    || bad "two projects deriving the same job id: the first wins, the second is skipped"

  # A real job in jobs.json can already hold the id a project would derive
  # (it predates the reservation of the "security-" prefix). The real job
  # must win outright -- never duplicated, never shadowed.
  printf '{"jobs":[{"id":"security-web","enabled":true,"prompt":"real one"}]}\n' \
    > "$tmp/derived/preexisting-jobs.json"
  ( JOBS_FILE="$tmp/derived/preexisting-jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data"; TICK_LOG="$tmp/derived/data/tick.log"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["security-web"]' >/dev/null \
    && [ "$(job_get security-web '.prompt' '')" = "real one" ] \
    && grep -q "already exists" "$TICK_LOG" ) \
    && ok "a real job that already owns the derived id wins over the derived one" \
    || bad "a real job that already owns the derived id wins over the derived one"

  # One project's typo used to take every job on the machine down. `tonumber` on
  # a budget the user wrote as "abc" aborts the element's jq with NO stdout, and
  # the separator had already been printed -- so the array came out `[,{...}]`,
  # jobs_json died on every call, and job_get/resolve/job_exists failed for every
  # job. The array must still hold every project -- Bad included, now with the
  # conservative fallback in place of the unusable field (Task 10: it used to
  # be dropped outright, which ran the analysis with no cap at all).
  mkdir -p "$tmp/derived/data4"
  cat > "$tmp/derived/bad-number-projects.json" <<'JSON'
{"projects":[
 {"name":"Bad","cwd":"/tmp/bad","security":{"enabled":true,"max_budget_usd":"abc"}},
 {"name":"Healthy","cwd":"/tmp/h","security":{"enabled":true,"max_budget_usd":5}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/bad-number-projects.json"
    DATA_DIR="$tmp/derived/data4"; TICK_LOG="$tmp/derived/data4/tick.log"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job","security-bad","security-healthy"]' >/dev/null \
    && [ "$(job_get security-bad '.max_budget_usd' '')" = "$SECURITY_FALLBACK_BUDGET_USD" ] \
    && [ "$(job_get security-healthy '.max_budget_usd' '')" = "5" ] ) \
    && ok "a non-numeric budget falls back to the conservative default, not the array every job is read from" \
    || bad "a non-numeric budget falls back to the conservative default, not the array every job is read from"

  # The other half of the same bug: the separator must be committed only once an
  # element exists. Force a failure that has nothing to do with numbers -- a jq
  # that refuses exactly the `-nc` call the element is built with -- and the
  # array must still be one jobs_json can read.
  cat > "$tmp/derived/jq-no-nc" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = "-nc" ] && exit 1; done
exec "$JQ" "\$@"
EOF
  chmod +x "$tmp/derived/jq-no-nc"
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/bad-number-projects.json"
    DATA_DIR="$tmp/derived/data4b"; TICK_LOG="$tmp/derived/data4b/tick.log"
    JQ="$tmp/derived/jq-no-nc"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job"]' >/dev/null ) \
    && ok "an element that fails to build drops its project, never the array" \
    || bad "an element that fails to build drops its project, never the array"

  # Task 10 finding: a DECLARED max_budget_usd that fails to parse must not
  # fail OPEN. A derived run always carries --force, which skips the
  # rate-limit gate, the daily cap and the global cap (see run_job) --
  # max_budget_usd is the only spend gate left standing for it, so "declared
  # but unusable" has to land on the conservative fallback, not on no cap at
  # all, with one tick.log line naming both the bad value and the fallback.
  cat > "$tmp/derived/undeclared-vs-bad-projects.json" <<'JSON'
{"projects":[
 {"name":"Typo","cwd":"/tmp/typo","security":{"enabled":true,"max_budget_usd":"5 USD"}},
 {"name":"Unset","cwd":"/tmp/unset","security":{"enabled":true}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/undeclared-vs-bad-projects.json"
    DATA_DIR="$tmp/derived/data10"; TICK_LOG="$tmp/derived/data10/tick.log"
    [ "$(job_get security-typo '.max_budget_usd' '')" = "$SECURITY_FALLBACK_BUDGET_USD" ] \
    && grep -q "5 USD" "$TICK_LOG" \
    && grep -q "conservative default of \$$SECURITY_FALLBACK_BUDGET_USD" "$TICK_LOG" ) \
    && ok "a declared-but-unparseable budget falls back to \$$SECURITY_FALLBACK_BUDGET_USD, and the warning names both" \
    || bad "a declared-but-unparseable budget falls back to \$$SECURITY_FALLBACK_BUDGET_USD, and the warning names both"

  # The control this rests on: a budget that was never declared at all stays
  # undeclared -- that is a choice (no per-run ceiling beyond whatever the job
  # would otherwise use), not a typo, and must not be silently handed the
  # fallback too. Without this control, a fix broad enough to always inject
  # the fallback would pass the test above while capping every project that
  # never asked for a cap at all.
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/undeclared-vs-bad-projects.json"
    DATA_DIR="$tmp/derived/data10"; TICK_LOG="$tmp/derived/data10/tick.log"
    jobs_json | "$JQ" -e '[.jobs[] | select(.id=="security-unset") | has("max_budget_usd")] == [false]' >/dev/null ) \
    && ok "an undeclared budget stays undeclared -- no max_budget_usd key, no fallback" \
    || bad "an undeclared budget stays undeclared -- no max_budget_usd key, no fallback"

  # A `security` block that is not an object is unusable, and the project is
  # skipped either way -- but the raw `.security.enabled` path printed jq's
  # "Cannot index string" to stderr on every single job_get.
  cat > "$tmp/derived/nonobject-projects.json" <<'JSON'
{"projects":[{"name":"Sloppy","cwd":"/tmp/s","security":"yes"},
             {"name":"Web","cwd":"/tmp/web","security":{"enabled":true}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/nonobject-projects.json"
    DATA_DIR="$tmp/derived/data6"; TICK_LOG="$tmp/derived/data6/tick.log"
    err="$(jobs_json 2>&1 >/dev/null)"
    [ -z "$err" ] && jobs_json 2>/dev/null | "$JQ" -e '[.jobs[].id] == ["real-job","security-web"]' >/dev/null ) \
    && ok "a security block that is not an object is skipped in silence" \
    || bad "a security block that is not an object is skipped in silence"

  # Every guard here describes a PERMANENT state of the config. Logged per call
  # it was logged dozens of times per run -- ~1440 lines a day for one typo, in
  # the file the dashboard re-reads whole every 5s. One line per CHANGE.
  mkdir -p "$tmp/derived/data7"
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/dup-slug-projects.json"
    DATA_DIR="$tmp/derived/data7"; TICK_LOG="$tmp/derived/data7/tick.log"
    jobs_json >/dev/null; jobs_json >/dev/null; jobs_json >/dev/null
    [ "$(num "$(grep -c 'already used by another project' "$TICK_LOG" 2>/dev/null)")" = "1" ] ) \
    && ok "a permanent derivation warning is logged once, not once per jobs_json call" \
    || bad "a permanent derivation warning is logged once, not once per jobs_json call"

  # Nobody who has never enabled security should pay for the derivation. With no
  # security block anywhere the whole loop is skipped after one jq, and the file
  # a missing projects.json would have been created by is never even opened.
  cat > "$tmp/derived/nosec-projects.json" <<'JSON'
{"projects":[{"name":"Plain","cwd":"/tmp/plain"}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/nosec-projects.json"
    DATA_DIR="$tmp/derived/data8"; TICK_LOG="$tmp/derived/data8/tick.log"
    [ "$(security_derived_jobs)" = "[]" ] \
    && [ "$(jobs_json | "$JQ" -Sc .)" = "$("$JQ" -Sc . "$JOBS_FILE")" ] ) \
    && ok "with no security block anywhere, jobs_json is exactly the jobs file" \
    || bad "with no security block anywhere, jobs_json is exactly the jobs file"

  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/no-such-projects.json"
    DATA_DIR="$tmp/derived/data8"; TICK_LOG="$tmp/derived/data8/tick.log"
    [ "$(security_derived_jobs)" = "[]" ] && [ ! -e "$tmp/derived/no-such-projects.json" ] ) \
    && ok "a missing projects file short-circuits the derivation instead of building one" \
    || bad "a missing projects file short-circuits the derivation instead of building one"

  # The fast-path probe above short-circuits the WHOLE loop the moment it looks
  # like nobody has security on -- but "looks like" used to mean `== true` in
  # jq, boolean only, while security_enabled() (and the per-project loop this
  # probe guards) already treats the string "true" the same as the boolean,
  # because jq -r prints both of them identically. A hand-edited project with
  # `"enabled": "true"` passed security_enabled and cmd_security_analyze's own
  # gate, then derived NO job at all: this probe sent it home before the
  # per-project check that would have accepted it ever ran. Both spellings are
  # asserted here, alone, so the fast path cannot be the one that disagrees.
  cat > "$tmp/derived/stringtrue-projects.json" <<'JSON'
{"projects":[{"name":"Stringy","cwd":"/tmp/stringy","security":{"enabled":"true"}}]}
JSON
  ( JOBS_FILE="$tmp/derived/jobs.json"; PROJECTS_FILE="$tmp/derived/stringtrue-projects.json"
    DATA_DIR="$tmp/derived/data-stringtrue"; TICK_LOG="$tmp/derived/data-stringtrue/tick.log"
    jobs_json | "$JQ" -e '[.jobs[].id] == ["real-job","security-stringy"]' >/dev/null ) \
    && ok "a project with enabled as the STRING \"true\" still derives a job" \
    || bad "a project with enabled as the STRING \"true\" still derives a job"
  "$JQ" -e 'any(.projects[]?;
       ((.security? | objects | .enabled) as $e | ($e == true or $e == "true")))' \
      "$tmp/derived/stringtrue-projects.json" >/dev/null \
    && ok "the fast-path probe accepts the string spelling as well as the boolean" \
    || bad "the fast-path probe accepts the string spelling as well as the boolean"

  # ---- a derived id is not a job you can write to -----------------------
  # `job_exists` goes through jobs_json, so it says yes to a derived id -- and
  # every by-id write went ahead on that answer. `delete security-web` found
  # nothing to remove from jobs.json, said "deleted", and still rm -rf'd the lock
  # dir holding the max_parallel=1 gate of an analysis in flight.
  mkdir -p "$tmp/derived/data9/locks/security-web/slot-1" "$tmp/derived/data9/logs/security-web"
  printf '{}\n' > "$tmp/derived/data9/state.json"
  # Its own jobs file: the write tests above deliberately edited the shared one.
  printf '{"jobs":[{"id":"real-job","enabled":true,"prompt":"x"}]}\n' > "$tmp/derived/guard-jobs.json"
  # `die` writes to stderr and exits 1, and this script runs with `set -o
  # pipefail` -- so a `| grep -q` on the far side would inherit that 1 and read
  # as "did not refuse". Capture the output and match it.
  refuses_derived() { case "$1" in *"derived security job"*) return 0 ;; *) return 1 ;; esac; }
  ( JOBS_FILE="$tmp/derived/guard-jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data9"; CONFIG_DIR="$tmp/derived"
    LOCK_DIR="$tmp/derived/data9/locks"; LOG_DIR="$tmp/derived/data9/logs"
    STATE_FILE="$tmp/derived/data9/state.json"; TICK_LOG="$tmp/derived/data9/tick.log"
    refuses_derived "$(cmd_delete security-web 2>&1)" ) \
    && [ -d "$tmp/derived/data9/locks/security-web/slot-1" ] \
    && ok "delete refuses a derived id, so a running analysis keeps its lock" \
    || bad "delete refuses a derived id, so a running analysis keeps its lock"

  ( JOBS_FILE="$tmp/derived/guard-jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data9"; CONFIG_DIR="$tmp/derived"
    LOCK_DIR="$tmp/derived/data9/locks"; LOG_DIR="$tmp/derived/data9/logs"
    STATE_FILE="$tmp/derived/data9/state.json"; TICK_LOG="$tmp/derived/data9/tick.log"
    refuses_derived "$(cmd_rename security-web stolen 2>&1)" ) \
    && [ -d "$tmp/derived/data9/logs/security-web" ] && [ ! -e "$tmp/derived/data9/logs/stolen" ] \
    && ok "rename refuses a derived id, so its history is not moved onto a dead one" \
    || bad "rename refuses a derived id, so its history is not moved onto a dead one"

  ( JOBS_FILE="$tmp/derived/guard-jobs.json"; PROJECTS_FILE="$tmp/derived/projects.json"
    DATA_DIR="$tmp/derived/data9"; CONFIG_DIR="$tmp/derived"
    STATE_FILE="$tmp/derived/data9/state.json"; TICK_LOG="$tmp/derived/data9/tick.log"
    refuses_derived "$(cmd_toggle security-web true 2>&1)" \
    && refuses_derived "$(printf '%s\n' real-job security-web | cmd_toggle_many false 2>&1)" \
    && refuses_derived "$(printf 'x' | cmd_set_prompt security-web 2>&1)" \
    && refuses_derived "$(printf '9' | cmd_set_field security-web max_budget_usd 2>&1)" \
    && refuses_derived "$(printf 'exit 0' | cmd_set_precheck security-web 2>&1)" \
    && refuses_derived "$(printf '%s\n' security-web real-job | cmd_reorder 2>&1)" \
    && "$JQ" -e '[.jobs[] | {id, enabled}] == [{id:"real-job", enabled:true}]' "$tmp/derived/guard-jobs.json" >/dev/null ) \
    && ok "every other by-id write refuses a derived id, and jobs.json is untouched" \
    || bad "every other by-id write refuses a derived id, and jobs.json is untouched"

  echo "cmd_* guard rail — every by-id job mutation refuses a derived id before writing"
  # A structural assertion, deliberately, and found by SHAPE rather than kept
  # as a hand-maintained list of command names: a `write_jobs` filter that
  # selects on `.id` (`.id ==`, `.id !=`, `.id |`) is a mutation of an
  # EXISTING job named by id -- precisely what `job_exists` lies about for a
  # derived job (it answers through jobs_json, which DOES carry one; write_jobs
  # only ever touches $JOBS_FILE, which never does). Finding these by shape
  # means a future by-id mutation command that forgets the guard fails HERE,
  # the moment it is written, instead of the day someone runs it against a
  # derived id in anger.
  # `cmd_create` also calls job_exists and write_jobs, but its filter is
  # `.jobs += [$j]` -- a NEW job, not a selection by id -- and it already
  # refuses the "$SECURITY_JOB_PREFIX" prefix by name, so it correctly does
  # not match. `cmd_project_rename` selects on `.project==`, not `.id`, and
  # correctly does not match either: neither can reach a derived job's
  # on-disk state, because a derived job never lives in $JOBS_FILE at all.
  # `cmd_selftest` -- this very function -- is excluded outright: it is the
  # harness making the assertion, and its few thousand lines of test fixtures
  # happen to contain every shape below in JSON literals and old assertions.
  # A filter can also be named rather than inline (`cmd_toggle_many` writes
  # with $TOGGLE_MANY_FILTER, defined once above it as a shared constant) --
  # pull any such constant's own definition into the body under test, or its
  # shape is invisible to the check below.
  # `cmd_project_set` and `cmd_project_delete` (round 2, #77's account
  # cleanup) each carry ONE `write_jobs` call that DOES match the `.id ==`
  # shape: after a project save/delete, it clears a now-invalid `.account`
  # off every job of that project, its id read straight off $JOBS_FILE
  # itself (`.jobs[]? | select(.project == $n)`) -- never job_exists/
  # jobs_json, the only door a derived job's fake existence comes through.
  # A derived job therefore never lives in $JOBS_FILE at all, so this exact
  # filter can never reach one. `security_refuse_derived` would be the WRONG
  # fix here besides: it refuses any "security-" prefix outright, and a REAL
  # job that predates the prefix's reservation, legitimately sitting in
  # $JOBS_FILE, must still be cleared too -- and cmd_project_delete's own
  # pass runs inside a pipeline, where a `die` would not even stop the
  # write. So the exclusion below is narrow and by TEXT, not by function
  # name: only this one exact, already-reviewed filter is stripped out of
  # the two bodies before the shape match runs, so any OTHER by-id write
  # later added to either command is still caught, exactly like every other
  # site here.
  local guard_fn guard_body guard_var guard_sites=0 guard_missing=0 guard_bad_names=""
  while IFS= read -r guard_fn; do
    [ "$guard_fn" = "cmd_selftest" ] && continue
    guard_body="$(sed -n "/^${guard_fn}(/,/^}/p" "$BIN_DIR/agentloop")"
    case "$guard_body" in *write_jobs*) ;; *) continue ;; esac
    for guard_var in $(printf '%s' "$guard_body" | grep -oE '\$[A-Z_]+_FILTER'); do
      guard_body="$guard_body
$(grep "^${guard_var#\$}=" "$BIN_DIR/agentloop")"
    done
    case "$guard_fn" in
      cmd_project_set|cmd_project_delete)
        guard_body="$(printf '%s\n' "$guard_body" \
          | grep -vF '.jobs = [.jobs[] | if .id == $id then del(.account) else . end]')" ;;
    esac
    case "$guard_body" in *'.id =='*|*'.id !='*|*'.id |'*) ;; *) continue ;; esac
    guard_sites=$(( guard_sites + 1 ))
    case "$guard_body" in
      *security_refuse_derived*) ;;
      *) guard_missing=$(( guard_missing + 1 )); guard_bad_names="$guard_bad_names $guard_fn" ;;
    esac
  done <<EOF
$(grep -oE '^cmd_[a-zA-Z0-9_]*\(' "$BIN_DIR/agentloop" | tr -d '(' | sort -u)
EOF
  [ "$guard_sites" -eq 8 ] && [ "$guard_missing" -eq 0 ] \
    && ok "every by-id job mutation ($guard_sites found) refuses a derived id before writing" \
    || bad "cmd_* guard rail: $guard_sites by-id mutation site(s), $guard_missing missing security_refuse_derived ($guard_bad_names) -- expected 8 sites, 0 missing"

  echo "reattach never re-provisions a security job — the wt_provision up call site sits behind a SECURITY_JOB_PREFIX guard"
  # A structural assertion, deliberately: exercising the real reattach path
  # end-to-end needs a live slot, a killed agent and an actual resume, which
  # this suite has no harness for. What CAN be checked is the SHAPE of the
  # fix. AL_SKIP_PROVISION is an env var on the ORIGINAL invocation, so by the
  # time a SIGKILL/OOM/reboot casualty is resumed it is unset again -- the
  # only thing that still tells a derived security job apart at reattach time
  # is its ID. Find the reattach path's own wt_provision call, identified by
  # ITS variable names ($rname/$rrepo/$rwt/$rbase are unique to this call
  # site -- wt_setup's fresh-provision call uses $name/$repo/$wt/$base, and no
  # test fixture calls wt_provision with these names), and require a
  # SECURITY_JOB_PREFIX case guard in the lines immediately above it. Same
  # "found by shape" reasoning as the cmd_* guard rail above, so a future
  # refactor that moves this call but drops the guard fails HERE, not against
  # a live analysis in the field.
  #
  # cmd_selftest -- this very function -- is excluded the same way the guard
  # rail above excludes it: this assertion's OWN source line necessarily
  # contains the pattern it greps for, and without the exclusion `head`/`tail`
  # would be picking between this line and the real one by luck of ordering.
  local selftest_end reattach_line reattach_ctx
  selftest_end="$(awk '/^cmd_selftest\(\)/{f=1} f && /^}/{print NR; exit}' "$BIN_DIR/agentloop")"
  reattach_line="$(grep -n 'wt_provision up .*\$rname.*\$rrepo.*\$rwt.*\$rbase' "$BIN_DIR/agentloop" \
                     | awk -F: -v after="${selftest_end:-0}" '$1>after{print $1; exit}')"
  reattach_ctx=""
  [ -n "$reattach_line" ] && [ "$reattach_line" -gt 12 ] \
    && reattach_ctx="$(sed -n "$((reattach_line-12)),${reattach_line}p" "$BIN_DIR/agentloop")"
  case "$reattach_ctx" in
    *'"$SECURITY_JOB_PREFIX"'*)
      ok "the reattach wt_provision up call site sits behind a SECURITY_JOB_PREFIX guard" ;;
    *)
      bad "the reattach wt_provision up call (line ${reattach_line:-not found}) has no SECURITY_JOB_PREFIX guard within 12 lines above it" ;;
  esac

  # ---- analysing a chosen branch ---------------------------------------
  mkdir -p "$tmp/brov/origin.git" "$tmp/brov/repo"
  git init -q --bare "$tmp/brov/origin.git"
  ( cd "$tmp/brov/repo"
    # A branch name OTHER than "main" on purpose: the fixture's "main" base
    # below must stay unresolvable regardless of the host's own
    # init.defaultBranch, or the "falls back to HEAD" assertion further down
    # would silently stop meaning anything on a machine defaulting to "main".
    git -c init.defaultBranch=trunk init -q .
    git config user.email t@example.com && git config user.name t
    echo one > a.txt && git add -A && git commit -qm one
    git checkout -qb feature/x && echo two > a.txt && git commit -qam two
    git remote add origin "$tmp/brov/origin.git"
    git push -q -u origin feature/x
    # One MORE commit, local only, after the push. feature/x now names two
    # different commits depending on where you look -- exactly the case none
    # of the other wt_base_ref fixtures exercises, because none of them
    # registers an origin at all. The remote is what a security analysis
    # cares about (whatever was just pushed for review), so it must win over
    # a same-named local branch that has since diverged (an operator's own
    # stale checkout, say).
    echo three > a.txt && git commit -qam three
    git checkout -q - ) >/dev/null 2>&1

  got="$( AL_BASE_OVERRIDE="feature/x" wt_base_ref "$tmp/brov/repo" "main" 5 )"
  case "$got" in *feature/x*) ok "AL_BASE_OVERRIDE wins over the declared base" ;;
                 *) bad "AL_BASE_OVERRIDE wins over the declared base" ;; esac

  # The candidate order matters: refs/remotes/origin/<name> is tried BEFORE
  # refs/heads/<name>. Assert the EXACT ref and its resolved sha, not a
  # substring -- reordering the three candidates in wt_base_ref would still
  # print something containing "feature/x" and pass a looser check, while
  # silently handing the analysis the local branch's extra commit instead of
  # what was actually pushed.
  local origin_sha diverged_local_sha got_sha
  origin_sha="$(git -C "$tmp/brov/repo" rev-parse refs/remotes/origin/feature/x)"
  diverged_local_sha="$(git -C "$tmp/brov/repo" rev-parse refs/heads/feature/x)"
  if [ "$origin_sha" = "$diverged_local_sha" ]; then
    bad "fixture setup: local feature/x never diverged from origin/feature/x"
  fi
  got="$( AL_BASE_OVERRIDE="feature/x" wt_base_ref "$tmp/brov/repo" "main" 5 )"
  got_sha="$(git -C "$tmp/brov/repo" rev-parse --verify --quiet "$got" 2>/dev/null)"
  [ "$got" = "refs/remotes/origin/feature/x" ] && [ "$got_sha" = "$origin_sha" ] \
    && ok "AL_BASE_OVERRIDE prefers the remote branch over a diverged local one" \
    || bad "AL_BASE_OVERRIDE resolved '$got' ($got_sha), want refs/remotes/origin/feature/x ($origin_sha)"

  # Independently confirm neither candidate resolves for "main" in this repo,
  # so HEAD is the only correct fallback -- not just the ABSENCE of
  # "feature/x", which a wrongly resolved ref could satisfy just as well.
  if git -C "$tmp/brov/repo" rev-parse --verify --quiet "origin/main^{commit}" >/dev/null 2>&1 \
     || git -C "$tmp/brov/repo" rev-parse --verify --quiet "main^{commit}" >/dev/null 2>&1; then
    bad "fixture setup: 'main' unexpectedly resolves in this repo"
  fi
  got="$( wt_base_ref "$tmp/brov/repo" "main" 5 )"
  [ "$got" = "HEAD" ] \
    && ok "an unset override falls back to the declared base's own resolution (HEAD, since 'main' does not exist here)" \
    || bad "an unset override resolved to '$got', want 'HEAD' (the declared base's actual resolution)"

  ( AL_BASE_OVERRIDE="no/such/branch" wt_base_ref "$tmp/brov/repo" "main" 5 >/dev/null 2>&1 ) \
    && bad "a branch that does not exist is refused, not silently replaced" \
    || ok "a branch that does not exist is refused, not silently replaced"

  ( AL_BASE_OVERRIDE="-x" wt_base_ref "$tmp/brov/repo" "main" 5 >/dev/null 2>&1 ) \
    && bad "AL_BASE_OVERRIDE starting with '-' was accepted" \
    || ok "AL_BASE_OVERRIDE starting with '-' is refused before it reaches rev-parse"

  # The probe above passes today whether or not the guard exists, because
  # real git already refuses to create a branch named "-x" in the first
  # place (check-ref-format), so `rev-parse --verify --quiet` fails on it
  # regardless -- the guard and "no candidate resolved" reach the same
  # answer by different roads, and a probe that only checks the final rc
  # cannot tell them apart. Fake `git` into ACCEPTING a flag-shaped ref (as
  # some future or different git might) and prove the guard refuses before
  # git is ever asked -- the same PATH-override technique the hung-fetch
  # test above already uses.
  mkdir -p "$tmp/brov/fakebin"
  printf '%s\n' '#!/bin/bash' \
    'fv=0; last=""' \
    'for a in "$@"; do [ "$a" = --verify ] && fv=1; last="$a"; done' \
    'if [ "$fv" = 1 ]; then case "$last" in -*) exit 0 ;; esac; fi' \
    'exec /usr/bin/git "$@"' > "$tmp/brov/fakebin/git"
  chmod +x "$tmp/brov/fakebin/git"
  local rc
  got="$( PATH="$tmp/brov/fakebin:$PATH"; AL_BASE_OVERRIDE="-x"
          wt_base_ref "$tmp/brov/repo" "main" 5 2>/dev/null )"
  rc=$?
  [ -z "$got" ] && [ "$rc" -ne 0 ] \
    && ok "even a git that WOULD accept '-x' is never asked -- the guard refuses first" \
    || bad "AL_BASE_OVERRIDE starting with '-' resolved to '$got' (rc=$rc) once git said yes to it"

  # ---- AL_SKIP_PROVISION really skips wt_provision up (not just by shape) --
  # A security analysis reads code; it must neither pay for nor be blocked by
  # a project's provisioning (.env, containers, migrations). The fixture's up
  # hook writes a marker file precisely so its ABSENCE is what proves the
  # skip -- a hook that merely "did nothing observable" would pass whether or
  # not it actually ran at all.
  mkdir -p "$tmp/brov/skip-repo" "$tmp/brov/cfg/provision" "$tmp/brov/proj"
  ( cd "$tmp/brov/skip-repo" && git init -q . && git config user.email t@example.com \
      && git config user.name t && echo hi > f && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' '{"projects":[{"name":"secskip","cwd":"'"$tmp"'/brov/skip-repo"}]}' \
    > "$tmp/brov/proj/secskip.json"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$AL_WORKTREE/PROVISIONED"' \
    > "$tmp/brov/cfg/provision/secskip.up.sh"
  chmod +x "$tmp/brov/cfg/provision/secskip.up.sh"

  ( PROJECTS_FILE="$tmp/brov/proj/secskip.json"; CONFIG_DIR="$tmp/brov/cfg"; WORKTREES_DIR="$tmp/brov/wtroot"
    AL_SKIP_PROVISION=1 wt_setup jsec secskip "$tmp/brov/skip-repo" stampSkip ) >/dev/null 2>&1
  [ ! -f "$tmp/brov/wtroot/jsec/stampSkip/skip-repo/PROVISIONED" ] \
    && ok "AL_SKIP_PROVISION=1 leaves the project's up hook unrun" \
    || bad "AL_SKIP_PROVISION=1 still ran the up hook"

  ( PROJECTS_FILE="$tmp/brov/proj/secskip.json"; CONFIG_DIR="$tmp/brov/cfg"; WORKTREES_DIR="$tmp/brov/wtroot"
    wt_setup jsec secskip "$tmp/brov/skip-repo" stampNoSkip ) >/dev/null 2>&1
  [ -f "$tmp/brov/wtroot/jsec/stampNoSkip/skip-repo/PROVISIONED" ] \
    && ok "and an ordinary run still provisions, so the skip above was AL_SKIP_PROVISION's doing" \
    || bad "an ordinary run did not provision at all — the fixture proves nothing"

  # ---- ...and teardown must not run `down` over a stack it never brought up -
  # THE BUG THIS PINS. `up` was skipped for an analysis and `down` was not, so
  # the one half of provisioning the analysis promised not to touch ran anyway
  # at teardown: containers stopped, ports released and services unlinked for
  # whatever IS up on that project -- the developer's own environment, torn
  # down by a read-only code review. The guard is by IDENTITY, not by
  # environment: AL_SKIP_PROVISION was a variable on the original invocation
  # and teardown can happen from a later process entirely (the orphan sweep, an
  # explicit drop) where it is long gone.
  mkdir -p "$tmp/brov/data"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$AL_RUN_DIR/WENT-DOWN"' \
    > "$tmp/brov/cfg/provision/secskip.down.sh"
  chmod +x "$tmp/brov/cfg/provision/secskip.down.sh"
  ( PROJECTS_FILE="$tmp/brov/proj/secskip.json"; CONFIG_DIR="$tmp/brov/cfg"
    DATA_DIR="$tmp/brov/data"
    wt_down_all "${SECURITY_JOB_PREFIX}skipproj" secskip "$tmp/brov/wtroot/jsec/stampSkip" ) >/dev/null 2>&1
  [ ! -f "$tmp/brov/wtroot/jsec/stampSkip/WENT-DOWN" ] \
    && ok "a derived security job's teardown leaves the project's down hook unrun" \
    || bad "wt_down_all ran the down hook for a security job that never ran up"
  ( PROJECTS_FILE="$tmp/brov/proj/secskip.json"; CONFIG_DIR="$tmp/brov/cfg"
    DATA_DIR="$tmp/brov/data"
    wt_down_all jsec secskip "$tmp/brov/wtroot/jsec/stampNoSkip" ) >/dev/null 2>&1
  [ -f "$tmp/brov/wtroot/jsec/stampNoSkip/WENT-DOWN" ] \
    && ok "and an ordinary job's teardown still runs it, so the skip above was the guard's doing" \
    || bad "an ordinary teardown did not run the down hook at all — the fixture proves nothing"
  # Structural too, the same way the reattach `up` call site is checked: the
  # behavioural pair above would stay green if a refactor moved the call
  # somewhere the guard no longer covers.
  local downbody
  downbody="$(sed -n '/^wt_down_all() {/,/^}/p' "$BIN_DIR/worktree-lib.sh")"
  case "$downbody" in
    *'SECURITY_JOB_PREFIX'*'wt_provision down'*)
      ok "the wt_provision down call site sits behind a SECURITY_JOB_PREFIX guard" ;;
    *)
      bad "wt_down_all's wt_provision down call has no SECURITY_JOB_PREFIX guard before it" ;;
  esac

  # ---- the security subcommand, end to end in bash --------------------------
  echo "cmd_security_analyze() — the row and the request exist before the run does"
  local sec="$tmp/sec" secjid secdb
  mkdir -p "$sec/cfg" "$sec/data/locks" "$sec/repo"
  ( cd "$sec/repo" && git init -q . && git config user.email t@example.com \
      && git config user.name t && echo hi > f && git add -A && git commit -qm init \
      && git branch -M main ) >/dev/null 2>&1
  cat > "$sec/cfg/projects.json" <<JSON
{"projects":[{"name":"Sec App","cwd":"$sec/repo","security":{"enabled":true},
              "worktree":{"enabled":true}}]}
JSON
  printf '{"jobs":[]}\n' > "$sec/cfg/jobs.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":false,"bin":"","models":[]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$sec/cfg/platforms.json"
  secjid="$(security_job_id "Sec App")"
  secdb="$sec/security.db"
  # Everything below runs against this scratch ledger, never the operator's.
  # A frozen $SECURITY_DB computed at load time is exactly what this override
  # exists to make impossible (see security_db).
  sec_env() {
    PROJECTS_FILE="$sec/cfg/projects.json"; JOBS_FILE="$sec/cfg/jobs.json"
    PLATFORMS_FILE="$sec/cfg/platforms.json"
    CONFIG_DIR="$sec/cfg"; DATA_DIR="$sec/data"; LOCK_DIR="$sec/data/locks"
    TICK_LOG="$sec/data/tick.log"; RUNS_FILE="$sec/data/runs.ndjson"
    AGENTLOOP_SECURITY_DB="$secdb"
  }
  # An analysis row that is allowed to close `done`. `finish` downgrades a
  # `done` close to `capped` for a row whose deterministic phases never ran
  # (bin/security/cli.py, cmd_finish) -- so every fixture below that is about
  # what a CLOSE does has to prepare its row first, or it silently stops
  # testing the close and starts testing that guard. The tree is deliberately
  # empty: what is asserted here is the verdict, not what prepare found.
  mkdir -p "$sec/tree"
  sec_open() { # sec_open [commit-sha] -> the id of a prepared, running analysis
    local a
    a="$(security_py open-analysis --project "Sec App" --repo repo --branch main \
           --commit "${1:-abc}" --profile quick --run-id "$secjid" | "$JQ" -r '.analysis_id')"
    security_py prepare --analysis "$a" --root "$sec/tree" --offline >/dev/null 2>&1
    printf '%s' "$a"
  }
  local secreq="$sec/data/security/requests/$secjid.json"

  # run_job is stubbed, so nothing spends a session -- but the stub reads the
  # ledger from INSIDE the call, which is the only way to prove the row is
  # open, and open as `running`, at the moment the run starts. That ordering is
  # the whole point of opening it in cmd_security_analyze rather than in
  # `prepare`: an agent that dies on launch must still leave an analysis.
  ( sec_env
    run_job() {
      printf '%s\n' "$*" > "$sec/runjob.args"
      printf '%s|%s\n' "${AL_BASE_OVERRIDE:-}" "${AL_SKIP_PROVISION:-}" > "$sec/runjob.env"
      printf '%s\n' "${AL_SECURITY_REPO:-}" > "$sec/runjob.repo"
      # A CHILD PROCESS, not this shell: what matters is that the two markers
      # are EXPORTED all the way down to the agent's own tool shell, not that
      # run_job can see them as shell variables.
      sh -c 'printf "%s|%s\n" "${AL_SECURITY_AGENT:-}" "${AL_SECURITY_ANALYSIS_ID:-}"' \
        > "$sec/runjob.childenv"
      security_py list --project "Sec App" | "$JQ" -r '.[0].state' > "$sec/state-during"
      return 0
    }
    cmd_security_analyze "Sec App" repo main quick
    printf '%s|%s|%s\n' "${AL_SECURITY_AGENT:-unset}" "${AL_SECURITY_ANALYSIS_ID:-unset}" \
      "${AL_SECURITY_REPO:-unset}" > "$sec/after-analyze.env" ) > "$sec/analyze.out" 2>&1
  [ "$("$JQ" -r '.analysis_id' "$secreq" 2>/dev/null)" = "1" ] \
    && ok "the request file carries the analysis id the run has to report against" \
    || bad "request file: $(cat "$secreq" 2>/dev/null)"
  # "Sec App", not the "repo" that was typed: the project has no `repos` rows,
  # so the argument names nothing and the analysis is filed under the project's
  # own name -- the same spelling the dashboard uses (secRepos()), so a
  # hand-typed analysis and a page-triggered one land in ONE history.
  [ "$("$JQ" -r '[.branch,.profile,.repo] | join(",")' "$secreq" 2>/dev/null)" = "main,quick,Sec App" ] \
    && ok "and the branch, profile and repo the derived job's prompt is built from" \
    || bad "request file: $("$JQ" -r '[.branch,.profile,.repo] | join(",")' "$secreq" 2>/dev/null)"
  [ "$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r '.[0].repo' ) )" = "Sec App" ] \
    && ok "a single-checkout project files the analysis under its own name, whatever repo argument was typed" \
    || bad "the ledger filed it under '$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r '.[0].repo' ) )'"
  [ "$(cat "$sec/state-during" 2>/dev/null)" = "running" ] \
    && ok "the analysis row is open and running before run_job is called" \
    || bad "state during the run was '$(cat "$sec/state-during" 2>/dev/null)'"
  [ "$(cat "$sec/runjob.args" 2>/dev/null)" = "$secjid --force" ] \
    && ok "the derived job is run forced, never waiting for a tick it can never have" \
    || bad "run_job got '$(cat "$sec/runjob.args" 2>/dev/null)'"
  [ "$(cat "$sec/runjob.env" 2>/dev/null)" = "main|1" ] \
    && ok "with the branch as AL_BASE_OVERRIDE and provisioning skipped" \
    || bad "run_job saw '$(cat "$sec/runjob.env" 2>/dev/null)'"
  # The repo travels beside the branch: run_job runs the analysis in the
  # checkout of the repo it names, which on a multi-repo project is not the
  # project's cwd. The spelling the ledger files it under, so the two agree.
  [ "$(cat "$sec/runjob.repo" 2>/dev/null)" = "Sec App" ] \
    && ok "and the repo it names as AL_SECURITY_REPO, spelt as the ledger files it" \
    || bad "run_job saw AL_SECURITY_REPO='$(cat "$sec/runjob.repo" 2>/dev/null)'"
  # The agent reaches `security decide` and `security rename-project` through
  # the very same command the operator does; the marker is what tells the door
  # who is knocking, and it is worth nothing unless it reaches the agent's own
  # process rather than only run_job's shell.
  [ "$(cat "$sec/runjob.childenv" 2>/dev/null)" = "1|1" ] \
    && ok "and AL_SECURITY_AGENT=1 plus the analysis id exported into every process the run starts" \
    || bad "a child of run_job saw '$(cat "$sec/runjob.childenv" 2>/dev/null)'"
  [ "$(cat "$sec/after-analyze.env" 2>/dev/null)" = "unset|unset|unset" ] \
    && ok "and gone again the moment run_job returns, so the sweep after it is not marked as the agent" \
    || bad "the markers outlived the run: '$(cat "$sec/after-analyze.env" 2>/dev/null)'"
  # The stub never reached security_close_analysis, which is precisely the
  # shape of every early return in run_job (the slot gate, a missing cwd, an
  # empty prompt). The sweep at the end of cmd_security_analyze is what keeps
  # that from leaving a row `running` for ever.
  [ "$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r '.[0].state' ) )" = "failed" ] \
    && ok "a run that never started leaves the analysis closed, not running for ever" \
    || bad "the row was left open after run_job returned without running"

  echo "cmd_security_analyze --detach — the caller is not held for the run"
  # THE BUG THIS PINS. The control server gives a CLI call 30 seconds and then
  # SIGKILLs it. Run inline, the Analyse button spun for 30s, showed a timeout,
  # and the killed shell never reached the close -- the row stayed `running` for
  # ever and the button stayed disabled for that project.
  #
  # Two halves, tested apart because they fail apart. Here: the DETACH itself,
  # driven through a stand-in $SELF. It has to be a stand-in -- the detached
  # half is a NEW PROCESS now (a ( subshell ) inherits a frozen $$ on bash 3.2,
  # so its slot named a parent that exits seconds later and the engine read
  # every detached run as dead), and a new process cannot see a shell function
  # this suite defined. Testing it with an in-process stub would have meant
  # testing a subshell the shipped code no longer uses.
  local dt0 dt1 detout
  cat > "$sec/fake-self" <<'FAKESELF'
#!/bin/bash
# Stands in for the script the detached half re-execs. Records how it was
# called, then outlives its parent to prove the parent did not wait.
echo "$@" > "$(dirname "$0")/detached.argv"
sleep 6
: > "$(dirname "$0")/detached.ran"
FAKESELF
  chmod +x "$sec/fake-self"
  dt0="$(now_epoch)"
  ( sec_env; SELF="$sec/fake-self"
    cmd_security_analyze --detach "Sec App" repo main quick ) > "$sec/detach.out" 2>&1
  dt1="$(now_epoch)"
  [ "$((dt1 - dt0))" -lt 4 ] \
    && ok "it returns in $((dt1 - dt0))s, while the run it started is still going" \
    || bad "--detach blocked for $((dt1 - dt0))s — the run was not detached"
  detout="$(grep -o '{"analysis_id":[0-9]*}' "$sec/detach.out" 2>/dev/null | tail -1)"
  [ -n "$detout" ] \
    && ok "and prints the id the page follows the analysis by: $detout" \
    || bad "no analysis id on stdout: $(cat "$sec/detach.out" 2>/dev/null)"
  [ "$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r '.[0].state' ) )" = "running" ] \
    && ok "the row is open and running the moment the command returns" \
    || bad "the row was already '$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r '.[0].state' ) )'"
  local detwait=0
  while [ "$detwait" -lt 25 ] && [ ! -f "$sec/detached.ran" ]; do
    sleep 1; detwait=$((detwait + 1))
  done
  [ -f "$sec/detached.ran" ] \
    && ok "the detached process really ran, after its parent had already exited" \
    || bad "the detached process never ran (waited ${detwait}s)"
  # The repo last, after the branch: the new process is a fresh `agentloop`,
  # and the repo the analysis names reaches run_job through nothing else.
  case "$(cat "$sec/detached.argv" 2>/dev/null)" in
    "__run-analysis "*" main Sec App")
      ok "and it was re-execed as __run-analysis <job> <analysis> <branch> <repo>" ;;
    *) bad "the detached process got '$(cat "$sec/detached.argv" 2>/dev/null)'" ;;
  esac

  # The other half: what the detached process DOES once it is running. This is
  # security_run_analysis, called directly -- the same function the new process
  # re-execs into -- so run_job can be stubbed the way the rest of this suite
  # stubs it.
  ( sec_env
    run_job() { return 0; }   # ends without ever closing the row, like an early return
    aid="$(security_py open-analysis --project "Sec App" --repo repo --branch nc \
             --commit c --profile quick --run-id jid | "$JQ" -r '.analysis_id')"
    security_run_analysis "security-sec-app" "$aid" nc >/dev/null 2>&1
    security_py list --project "Sec App" | "$JQ" -r --arg a "$aid" \
      '.[] | select(.id == ($a|tonumber)) | .state' ) > "$sec/nc.state" 2>/dev/null
  [ "$(cat "$sec/nc.state" 2>/dev/null)" = "failed" ] \
    && ok "and the close travels with it: a run that ends without closing still closes the row" \
    || bad "row left '$(cat "$sec/nc.state" 2>/dev/null)' after a run that never closed"

  # A run that DOES close its own row keeps its verdict: the sweep is a no-op.
  ( sec_env
    # It prepares before it closes, exactly as a real run does: the agent runs
    # the deterministic phases first and `finish` refuses `done` without them.
    run_job() {
      security_py prepare --analysis "$AL_SECURITY_ANALYSIS_ID" --root "$sec/tree" \
        --offline >/dev/null 2>&1
      security_close_analysis "$1" success "1.25" "" >/dev/null 2>&1; return 0; }
    aid="$(security_py open-analysis --project "Sec App" --repo repo --branch sc \
             --commit c --profile quick --run-id jid | "$JQ" -r '.analysis_id')"
    security_run_analysis "security-sec-app" "$aid" sc >/dev/null 2>&1
    security_py list --project "Sec App" | "$JQ" -r --arg a "$aid" \
      '.[] | select(.id == ($a|tonumber)) | [.state,(.spend_usd|tostring)] | join(",")' \
    ) > "$sec/sc.state" 2>/dev/null
  [ "$(cat "$sec/sc.state" 2>/dev/null)" = "done,1.25" ] \
    && ok "a run that closes its own row keeps its verdict — the sweep is a no-op over it" \
    || bad "self-closing run -> $(cat "$sec/sc.state" 2>/dev/null)"

  echo "cmd_security_analyze() — a dead row cannot brick the Analyse button"
  # A row left `running` by a run that is GONE (killed, rebooted, or the 30s
  # SIGKILL above) disabled Analyse for that project for ever: the page reads
  # the ledger, and the ledger said an analysis was in flight. With no live slot
  # on the derived job there is no run behind it, and the preflight says so.
  local secstuck
  secstuck="$( ( sec_env; security_py open-analysis --project "Sec App" --repo "Sec App" \
                   --branch main --commit abc --profile quick --run-id "$secjid" \
                 | "$JQ" -r '.analysis_id' ) )"
  # The default grace protects a row whose own run has not reached acquire_slot
  # yet -- which is exactly what this row looks like, being seconds old.
  ( sec_env; run_job() { return 0; }
    cmd_security_analyze "Sec App" repo main quick ) >/dev/null 2>&1
  [ "$( ( sec_env; security_py list --project "Sec App" \
            | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )" = "running" ] \
    && ok "a row younger than the grace is left alone — its run may still be starting" \
    || bad "the sweep took a row that was seconds old"
  ( sec_env; SECURITY_STALE_GRACE=0; run_job() { return 0; }
    cmd_security_analyze "Sec App" repo main quick ) > "$sec/stuck.out" 2>&1
  [ "$( ( sec_env; security_py list --project "Sec App" \
            | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )" = "failed" ] \
    && ok "once the grace is up it is closed failed, and the button is usable again" \
    || bad "stale row left '$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .state' ) )'"
  [ "$( ( sec_env; security_py list --project "Sec App" \
            | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .coverage_note' ) )" = "engine: the run behind this analysis is gone" ] \
    && ok "with a note saying it was the engine's doing, not a verdict on the code" \
    || bad "coverage note: $( ( sec_env; security_py list --project "Sec App" | "$JQ" -r --argjson s "$secstuck" '.[] | select(.id==$s) | .coverage_note' ) )"
  grep -q "^analysis " "$sec/stuck.out" \
    && ok "and the analysis that was asked for is opened rather than refused" \
    || bad "the new analysis did not start: $(cat "$sec/stuck.out" 2>/dev/null)"

  echo "cmd_security_branches() — local and origin branches, HEAD excluded, deduped"
  # A real checkout with an origin, not faked refs: local-only never leaves the
  # repo, shared exists on both sides (the dedup this proves), and origin's
  # HEAD is the symbolic ref for-each-ref would otherwise surface as a branch
  # named "HEAD" once the "origin/" prefix is stripped from it.
  git init -q --bare "$sec/origin.git" >/dev/null 2>&1
  ( cd "$sec/repo" && git remote add origin "$sec/origin.git" \
      && git push -q -u origin main \
      && git branch local-only && git branch shared && git push -q origin shared \
      && git remote set-head origin main ) >/dev/null 2>&1
  local secbr
  secbr="$( ( sec_env; cmd_security_branches "Sec App" repo ) )"
  [ "$secbr" = "$(printf 'local-only\nmain\nshared')" ] \
    && ok "local-only (never pushed), main and shared (both local and origin) are each listed once" \
    || bad "branches: '$secbr'"
  printf '%s\n' "$secbr" | grep -qx 'HEAD' \
    && bad "origin/HEAD leaked into the branch list as 'HEAD': '$secbr'" \
    || ok "origin/HEAD is stripped and excluded, not offered as a branch to analyse"
  local secbrrc=0
  ( sec_env; cmd_security_branches "No Such Project" repo ) >/dev/null 2>&1 || secbrrc=$?
  [ "$secbrrc" -ne 0 ] \
    && ok "a project with no checkout is refused rather than silently listing nothing" \
    || bad "an unknown project/repo did not refuse (rc=$secbrrc)"

  # A checkout that exists but has no commits yet -- so for-each-ref prints
  # nothing at all. That used to pipe empty stdin into `grep -v '^HEAD$'`,
  # which exits 1 with nothing to invert; under `set -uo pipefail` the whole
  # pipeline's rc came out 1 with empty output, and the API route read that as
  # a failed command and answered a blank error instead of an empty picker.
  local secempty="$sec/empty-repo" secemptycfg="$sec/empty-cfg"
  mkdir -p "$secempty" "$secemptycfg"
  ( cd "$secempty" && git init -q . ) >/dev/null 2>&1
  cat > "$secemptycfg/projects.json" <<JSON
{"projects":[{"name":"Empty App","cwd":"$secempty"}]}
JSON
  local secemptyout secemptyrc=0
  secemptyout="$( ( PROJECTS_FILE="$secemptycfg/projects.json"
                     cmd_security_branches "Empty App" repo ) 2>&1 )" || secemptyrc=$?
  [ "$secemptyrc" -eq 0 ] && [ -z "$secemptyout" ] \
    && ok "a checkout with no branches yet is rc 0 with empty output, not a pipeline failure" \
    || bad "empty checkout: rc=$secemptyrc out='$secemptyout'"

  echo "security_close_analysis() — the run's own verdict closes the row"
  sec_close_state() { # sec_close_state <run-status> [wdreason] -> the state it lands on
    ( sec_env
      local a
      a="$(sec_open)"
      "$JQ" --argjson a "$a" '.analysis_id = $a' "$secreq" > "$secreq.t" && mv "$secreq.t" "$secreq"
      security_close_analysis "$secjid" "$1" "1.5" "${2:-}" >/dev/null 2>&1
      security_py list --project "Sec App" \
        | "$JQ" -r --argjson a "$a" '.[] | select(.id==$a) | [.state, (.spend_usd|tostring)] | join(",")' )
  }
  [ "$(sec_close_state success)" = "done,1.5" ] \
    && ok "success closes it done, carrying the run's real cost" || bad "success -> $(sec_close_state success)"
  [ "$(sec_close_state warning)" = "done,1.5" ] \
    && ok "a warning is a run that worked, so the analysis is done too" || bad "warning -> $(sec_close_state warning)"
  [ "$(sec_close_state warning "the agent put 3 lines on stderr")" = "done,1.5" ] \
    && ok "and a warning about stderr noise is still a finished analysis" \
    || bad "warning+stderr -> $(sec_close_state warning "the agent put 3 lines on stderr")"
  # The half of `warning` that is NOT a finished run. Closing these `done` is
  # what made a truncated analysis the baseline: the code the agent never
  # reached read as `fixed` that run and `regressed` the next, with no banner
  # anywhere saying the report was cut short.
  [ "$(sec_close_state warning "UNDECLARED ENDING: the agent stopped without saying its run was finished")" = "capped,1.5" ] \
    && ok "a warning that says the agent stopped mid-task closes it capped, not done" \
    || bad "warning+UNDECLARED -> $(sec_close_state warning "UNDECLARED ENDING: the agent stopped without saying its run was finished")"
  [ "$(sec_close_state warning "BUDGET LIMITED: spent \$4.80 of a \$5 cap")" = "capped,1.5" ] \
    && ok "and so does one that spent its whole budget — the agent wrapped up early" \
    || bad "warning+BUDGET -> $(sec_close_state warning "BUDGET LIMITED: spent \$4.80 of a \$5 cap")"
  [ "$(sec_close_state warning "UNDELIVERED: unpushed commits in repo.")" = "capped,1.5" ] \
    && ok "and one that left work undelivered" \
    || bad "warning+UNDELIVERED -> $(sec_close_state warning "UNDELIVERED: unpushed commits in repo.")"
  [ "$(sec_close_state error)" = "failed,1.5" ] \
    && ok "an error closes it failed, so the report says it is incomplete" || bad "error -> $(sec_close_state error)"
  [ "$(sec_close_state stopped)" = "failed,1.5" ] \
    && ok "a run the operator stopped leaves an incomplete analysis, not a clean one" \
    || bad "stopped -> $(sec_close_state stopped)"
  [ "$(sec_close_state capped)" = "capped,1.5" ] \
    && ok "and a capped run says it ran out of budget rather than that it broke" \
    || bad "capped -> $(sec_close_state capped)"

  # The engine's own close is the path an agent that SKIPPED `prepare` comes
  # home on: it exits cleanly, the classifier says `success`, and the row used
  # to close `done` with no findings, no coverage note and no banner -- then
  # became the baseline the next analysis was diffed against. Same close, same
  # `success`, the one difference being that nothing prepared this row.
  local secnoprep
  secnoprep="$( ( sec_env
    a="$(security_py open-analysis --project "Sec App" --repo repo --branch main \
           --commit noprep --profile quick --run-id "$secjid" | "$JQ" -r '.analysis_id')"
    AL_SECURITY_ANALYSIS_ID="$a" security_close_analysis "$secjid" success "0.75" "" \
      >/dev/null 2>&1
    security_py list --project "Sec App" | "$JQ" -r --argjson a "$a" \
      '.[] | select(.id==$a) | [.state, (.coverage_note | test("deterministic phases never ran") | tostring)] | join(",")' ) )"
  [ "$secnoprep" = "capped,true" ] \
    && ok "a success-close of an analysis whose deterministic phases never ran lands capped, and says so" \
    || bad "engine close of an unprepared analysis -> $secnoprep (want capped,true)"

  # The close used to overwrite the row unconditionally, which turned the one
  # honest thing an agent can say about its own run -- "I ran out of room" --
  # into `done`, because the PROCESS exited cleanly.
  local secupg
  secupg="$( ( sec_env
    a="$(security_py open-analysis --project "Sec App" --repo repo --branch main \
           --commit abc --profile quick --run-id "$secjid" | "$JQ" -r '.analysis_id')"
    security_py finish --analysis "$a" --state capped \
      --note "I stopped before the SAST phase" >/dev/null 2>&1
    AL_SECURITY_ANALYSIS_ID="$a" security_close_analysis "$secjid" success "2.5" "" >/dev/null 2>&1
    security_py list --project "Sec App" \
      | "$JQ" -r --argjson a "$a" '.[] | select(.id==$a) | [.state, (.spend_usd|tostring)] | join(",")' ) )"
  [ "$secupg" = "capped,2.5" ] \
    && ok "an agent's own 'capped' survives a success-close, which still records the run's real cost" \
    || bad "agent capped then engine success -> $secupg"

  # The id used to travel only through the request file, which the NEXT
  # analysis of the same project rewrites: the close then landed on that other
  # analysis's row and left its own running for ever.
  local seccross
  seccross="$( ( sec_env
    mine="$(sec_open abc)"
    other="$(sec_open def)"
    # exactly what a second `security analyze` does to the shared file while
    # the first run is still going
    "$JQ" --argjson a "$other" '.analysis_id = $a' "$secreq" > "$secreq.t" && mv "$secreq.t" "$secreq"
    AL_SECURITY_ANALYSIS_ID="$mine" security_close_analysis "$secjid" success "0.5" "" >/dev/null 2>&1
    security_py list --project "Sec App" | "$JQ" -r --argjson m "$mine" --argjson o "$other" \
      '[(.[] | select(.id==$m) | .state), (.[] | select(.id==$o) | .state)] | join(",")' ) )"
  [ "$seccross" = "done,running" ] \
    && ok "the close lands on the id its own run was started with, not on whatever rewrote the request file" \
    || bad "close with a rewritten request file -> $seccross (mine,other)"

  echo "the agent cannot vote on its own findings"
  # The marker the run carries (AL_SECURITY_AGENT) reaching the same door the
  # operator uses. `finish` is refused under it like every other engine verb
  # (Task 8) -- security_close_analysis still closes the row because it calls
  # through security_engine_py, which strips the flag for that one call, not
  # because `finish` itself stays open to the agent.
  local secfp="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local secrc=0
  ( sec_env; AL_SECURITY_AGENT=1 security_py decide --project "Sec App" \
      --fingerprint "$secfp" --state false_positive \
      --reason "I looked at it myself" --by "security team" ) > "$sec/agent-decide.out" 2>&1 || secrc=$?
  [ "$secrc" -ne 0 ] && grep -q "AL_SECURITY_AGENT" "$sec/agent-decide.out" \
    && ok "'decide' is refused inside an analysis, with a sentence saying why" \
    || bad "agent decide: rc=$secrc $(cat "$sec/agent-decide.out" 2>/dev/null)"
  secrc=0
  ( sec_env; AL_SECURITY_AGENT=1 security_py rename-project --from "Sec App" --to "Mine" ) \
    > "$sec/agent-rename.out" 2>&1 || secrc=$?
  [ "$secrc" -ne 0 ] && [ "$( ( sec_env; security_py list --project "Mine" | "$JQ" -r 'length' ) )" = "0" ] \
    && ok "and so is moving the ledger out from under the project being analysed" \
    || bad "agent rename-project: rc=$secrc $(cat "$sec/agent-rename.out" 2>/dev/null)"
  local secfin
  secfin="$( ( sec_env
    a="$(sec_open)"
    AL_SECURITY_AGENT=1 AL_SECURITY_ANALYSIS_ID="$a" \
      security_close_analysis "$secjid" success "0.25" "" >/dev/null 2>&1
    security_py list --project "Sec App" \
      | "$JQ" -r --argjson a "$a" '.[] | select(.id==$a) | .state' ) )"
  [ "$secfin" = "done" ] \
    && ok "the engine's own close still works under the same flag -- security_engine_py strips it" \
    || bad "close under AL_SECURITY_AGENT -> $secfin"

  echo "cmd_project_set() — a settings save files settings_changed only when security is on"
  # No test asserted this event's kind or gate anywhere: a wrong kind string
  # or an inverted security_enabled check would pass every other suite.
  ( sec_env; printf '{"name":"Sec App","note":"resaved"}' | cmd_project_set >/dev/null ) \
    > "$sec/project-set-on.out" 2>&1
  [ "$( ( sec_env; security_py events --project "Sec App" --kind settings_changed \
           | "$JQ" -r 'length' ) )" = "1" ] \
    && ok "a save on a security-enabled project files settings_changed" \
    || bad "settings_changed did not land for a security-enabled save"
  ( sec_env; printf '{"name":"Sec Disabled","security":{"enabled":false}}' \
      | cmd_project_set >/dev/null ) > "$sec/project-set-off.out" 2>&1
  [ "$( ( sec_env; security_py events --project "Sec Disabled" --kind settings_changed \
           | "$JQ" -r 'length' ) )" = "0" ] \
    && ok "and a save on a project with security disabled files none" \
    || bad "settings_changed was filed for a security-disabled save"

  echo "a second analysis of the same project is refused where the operator can read it"
  # A live slot on the derived id, built the way slots_active recognises one:
  # this process's own pid and this boot's id (see slot_alive).
  mkdir -p "$sec/data/locks/$secjid/$$"
  echo $$ > "$sec/data/locks/$secjid/$$/pid"; boot_id > "$sec/data/locks/$secjid/$$/boot"
  ( sec_env; run_job() { echo "RAN" > "$sec/should-not-run"; }
    cmd_security_analyze "Sec App" repo main quick ) > "$sec/second.out" 2>&1
  grep -q "already running" "$sec/second.out" && [ ! -f "$sec/should-not-run" ] \
    && ok "the refusal is a sentence on stdout, and no second run is launched" \
    || bad "second analyze: $(cat "$sec/second.out" 2>/dev/null)"

  echo "cmd_project_rename() — a rename cannot orphan an analysis in flight"
  # Renaming re-derives the job id, so the max_parallel=1 gate the running
  # analysis sits behind would stop applying to it. Refuse while it is live.
  ( sec_env; cmd_project_rename "Sec App" "Sec App Two" ) > "$sec/rename1.out" 2>&1
  grep -q "is running as '$secjid'" "$sec/rename1.out" \
    && ok "the rename is refused while an analysis of the old id is running" \
    || bad "rename1: $(cat "$sec/rename1.out" 2>/dev/null)"
  "$JQ" -e '.projects[0].name == "Sec App"' "$sec/cfg/projects.json" >/dev/null 2>&1 \
    && ok "and the project keeps its name, rather than half-renaming" \
    || bad "the project was renamed despite the refusal"

  rm -rf "$sec/data/locks/$secjid"
  local secjid2; secjid2="$(security_job_id "Sec App Two")"
  ( sec_env; cmd_project_rename "Sec App" "Sec App Two" ) > "$sec/rename2.out" 2>&1
  [ -f "$sec/data/security/requests/$secjid2.json" ] && [ ! -f "$secreq" ] \
    && ok "with nothing running, the pending request follows the derived id" \
    || bad "the request file did not move to $secjid2"
  [ "$("$JQ" -r '.project' "$sec/data/security/requests/$secjid2.json" 2>/dev/null)" = "Sec App Two" ] \
    && ok "and names the project it now belongs to" \
    || bad "the moved request still names the old project"
  # The ledger keys an analysis by the project NAME, with no id to key it by:
  # without the rename-project call the whole history would stay behind under
  # a name no project has any more.
  [ "$( ( sec_env; security_py list --project "Sec App" | "$JQ" -r 'length' ) )" = "0" ] \
    && [ "$( ( sec_env; security_py list --project "Sec App Two" | "$JQ" -r 'length' ) )" -ge 1 ] \
    && ok "and every past analysis is carried onto the new name in the ledger" \
    || bad "the security history stayed behind under the old project name"

  echo "check_ui_artifacts() — an untracked file in bin/static/ must go red, not pass unnoticed"
  # Reproduces, on a throwaway mirror rather than the real bin/static/, what
  # dropping a fourth built artifact into that directory looks like: a
  # genuine, correctly-stamped file (control -- it must stay ok) sitting next
  # to one nothing ever stamped (refusal -- it must go bad). The genuine one
  # is hand-stamped with the SAME two scripts build/build-ui.sh itself calls
  # (ui-bundle-digest.sh, then ui-digest.sh), against a one-file ui/ tree of
  # its own -- so this needs no esbuild and no dependence on the real repo's
  # current ui/ state, which a selftest step has no business needing anyway.
  local uidir="$tmp/uicheck"
  mkdir -p "$uidir/bin/static" "$uidir/build" "$uidir/ui"
  cp "$BASE_DIR/build/ui-digest.sh" "$BASE_DIR/build/ui-bundle-digest.sh" \
     "$BASE_DIR/build/build-ui.sh" "$uidir/build/"
  # ui-digest.sh's own _inputs() fingerprints these three alongside ui/ (see
  # its own comment on why); `find ... -maxdepth 0` on a path that does not
  # exist fails the whole pipeline under this script's `set -eo pipefail`,
  # so a mirror missing package.json would abort ui-digest.sh here, not
  # merely fingerprint one file short.
  [ -f "$BASE_DIR/package.json" ] && cp "$BASE_DIR/package.json" "$uidir/package.json"
  echo 'console.log("fake ui source");' > "$uidir/ui/fake.js"
  echo 'console.log("built from ui/fake.js");' > "$uidir/bin/static/fake.js"
  (
    BASE_DIR="$uidir"
    printf '/* ui-bundle: %s */\n' \
      "$(bash "$BASE_DIR/build/ui-bundle-digest.sh" "$BASE_DIR/bin/static/fake.js")" \
      >> "$BASE_DIR/bin/static/fake.js"
    printf '/* ui-sources: %s */\n' "$(bash "$BASE_DIR/build/ui-digest.sh")" \
      >> "$BASE_DIR/bin/static/fake.js"
  )
  # Nothing stamped this one -- exactly the fourth artifact the reviewer
  # dropped in as bin/static/extra.js.
  echo 'console.log("nobody stamped me");' > "$uidir/bin/static/extra.js"
  (
    BASE_DIR="$uidir"; _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); }
    bad() { _ufail=$(( _ufail + 1 )); echo "BAD: $1"; }
    check_ui_artifacts
    echo "RESULT ok=$_upass bad=$_ufail"
  ) > "$tmp/uicheck.out" 2>&1
  grep -q "^RESULT ok=1 bad=1$" "$tmp/uicheck.out" \
    && ok "an untracked bin/static/extra.js fails the check while the genuine artifact beside it still passes" \
    || bad "check_ui_artifacts did not flag the untracked file the way it should: $(cat "$tmp/uicheck.out")"

  echo "check_ui_artifacts() — two committed artifacts swapped must be caught by name, not both read ok"
  # Reproduces "cp bin/static/app.js bin/static/app.css" against a throwaway
  # mirror of its own: ui-bundle used to hash a file's own body against
  # itself with no mention anywhere of WHICH artifact that body belonged to,
  # so overwriting one committed artifact with another's bytes -- stamp
  # included -- left the stamp matching perfectly, because it was computed
  # on exactly the bytes now sitting under the wrong name. Two genuinely
  # built and stamped artifacts, hand-stamped with the same two scripts
  # build/build-ui.sh itself calls, then one is copied over the other
  # exactly as a botched rebase or a copy-paste in build/ would leave it.
  local swapdir="$tmp/uiswap"
  mkdir -p "$swapdir/bin/static" "$swapdir/build" "$swapdir/ui"
  cp "$BASE_DIR/build/ui-digest.sh" "$BASE_DIR/build/ui-bundle-digest.sh" \
     "$BASE_DIR/build/build-ui.sh" "$swapdir/build/"
  [ -f "$BASE_DIR/package.json" ] && cp "$BASE_DIR/package.json" "$swapdir/package.json"
  echo 'console.log("fake ui source");' > "$swapdir/ui/fake.js"
  echo 'console.log("this is app.js");' > "$swapdir/bin/static/app.js"
  echo 'body { color: red; }' > "$swapdir/bin/static/app.css"
  (
    BASE_DIR="$swapdir"
    for art in bin/static/app.js bin/static/app.css; do
      printf '/* ui-bundle: %s */\n' \
        "$(bash "$BASE_DIR/build/ui-bundle-digest.sh" "$BASE_DIR/$art")" \
        >> "$BASE_DIR/$art"
      printf '/* ui-sources: %s */\n' "$(bash "$BASE_DIR/build/ui-digest.sh")" \
        >> "$BASE_DIR/$art"
    done
  )
  (
    BASE_DIR="$swapdir"; _wpass=0; _wfail=0
    ok()  { _wpass=$(( _wpass + 1 )); }
    bad() { _wfail=$(( _wfail + 1 )); echo "BAD: $1"; }
    check_ui_artifacts
    echo "RESULT ok=$_wpass bad=$_wfail"
  ) > "$tmp/uiswap-before.out" 2>&1
  grep -q "^RESULT ok=2 bad=0$" "$tmp/uiswap-before.out" \
    && ok "before the swap, both freshly built artifacts genuinely check out" \
    || bad "setup did not produce two clean artifacts: $(cat "$tmp/uiswap-before.out")"
  # The swap itself: app.js's committed bytes, stamp included, land verbatim
  # under app.css's name -- app.css's previous content is gone, exactly as a
  # plain `cp` would leave it.
  cp "$swapdir/bin/static/app.js" "$swapdir/bin/static/app.css"
  (
    BASE_DIR="$swapdir"; _wpass=0; _wfail=0
    ok()  { _wpass=$(( _wpass + 1 )); }
    bad() { _wfail=$(( _wfail + 1 )); echo "BAD: $1"; }
    check_ui_artifacts
    echo "RESULT ok=$_wpass bad=$_wfail"
  ) > "$tmp/uiswap-after.out" 2>&1
  grep -q "^RESULT ok=1 bad=1$" "$tmp/uiswap-after.out" \
    && grep -q "BAD: bin/static/app.css" "$tmp/uiswap-after.out" \
    && ok "app.js's bytes copied onto app.css's name are caught by name, not read as a clean app.css" \
    || bad "the swap was not caught the way it should: $(cat "$tmp/uiswap-after.out")"

  echo "the rename — install retires the pre-rename agents and symlinks, and keeps the pinned account"
  mkdir -p "$tmp/mig/fakehome/Library/LaunchAgents" "$tmp/mig/fakehome/.local/bin" "$tmp/mig/fakebin"
  printf '%s\n' '#!/bin/sh' 'echo "launchctl $*" >> "$MIG_LOG"' > "$tmp/mig/fakebin/launchctl"
  chmod +x "$tmp/mig/fakebin/launchctl"
  cat > "$tmp/mig/fakehome/Library/LaunchAgents/$LEGACY_PLIST_LABEL.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>x</string>
  <key>EnvironmentVariables</key><dict><key>CLAUDE_CONFIG_DIR</key><string>/tmp/pinned-account</string></dict>
</dict></plist>
PLIST
  : > "$tmp/mig/fakehome/Library/LaunchAgents/$LEGACY_SERVER_LABEL.plist"
  ln -s "$BASE_DIR/bin/$LEGACY_CLI_NAME" "$tmp/mig/fakehome/.local/bin/$LEGACY_CLI_NAME"
  ln -s "/somewhere/else/$LEGACY_CLI_NAME-server" "$tmp/mig/fakehome/.local/bin/$LEGACY_CLI_NAME-server"
  got="$( HOME="$tmp/mig/fakehome" LAUNCH_AGENTS_DIR="$tmp/mig/fakehome/Library/LaunchAgents" MIG_LOG="$tmp/mig/log" PATH="$tmp/mig/fakebin:$PATH" install_migrate_legacy 2>/dev/null )"
  [ "$got" = "/tmp/pinned-account" ] && ok "the account pinned in the old agent is handed on" || bad "install_migrate_legacy printed '$got'"
  [ ! -e "$tmp/mig/fakehome/Library/LaunchAgents/$LEGACY_PLIST_LABEL.plist" ] \
    && [ ! -e "$tmp/mig/fakehome/Library/LaunchAgents/$LEGACY_SERVER_LABEL.plist" ] \
    && ok "both old plists are gone" || bad "an old plist survived"
  grep -q "launchctl unload .*$LEGACY_PLIST_LABEL" "$tmp/mig/log" 2>/dev/null \
    && grep -q "launchctl unload .*$LEGACY_SERVER_LABEL" "$tmp/mig/log" 2>/dev/null \
    && ok "and both were unloaded" || bad "unload was not called: $(cat "$tmp/mig/log" 2>/dev/null)"
  [ ! -L "$tmp/mig/fakehome/.local/bin/$LEGACY_CLI_NAME" ] && ok "the old symlink into this folder is removed" || bad "the old symlink was kept"
  [ -L "$tmp/mig/fakehome/.local/bin/$LEGACY_CLI_NAME-server" ] && ok "a symlink pointing elsewhere is left alone" || bad "somebody else's symlink was removed"
  loglines_before="$(num "$(wc -l < "$tmp/mig/log" 2>/dev/null)")"
  got="$( HOME="$tmp/mig/fakehome" LAUNCH_AGENTS_DIR="$tmp/mig/fakehome/Library/LaunchAgents" MIG_LOG="$tmp/mig/log" PATH="$tmp/mig/fakebin:$PATH" install_migrate_legacy 2>/dev/null )"
  loglines_after="$(num "$(wc -l < "$tmp/mig/log" 2>/dev/null)")"
  [ -z "$got" ] && [ "$loglines_after" -eq "$loglines_before" ] \
    && ok "a second run finds nothing to migrate" \
    || bad "second run printed '$got', log went from $loglines_before to $loglines_after lines"

  echo "the rename — the statusline that still points at the old folder is named"
  mkdir -p "$tmp/mig/fakehome2/.claude"
  printf '{"statusLine":{"type":"command","command":"/Users/me/%s/bin/statusline-rate-limits.sh"}}\n' "$LEGACY_CLI_NAME" \
    > "$tmp/mig/fakehome2/.claude/settings.json"
  got="$( HOME="$tmp/mig/fakehome2" statusline_path_warning )"
  case "$got" in *"statusline-rate-limits.sh"*"$BIN_DIR/statusline-rate-limits.sh"*) ok "the warning names the old path and the new one" ;;
                 *) bad "the warning was: '$got'" ;; esac
  printf '{"statusLine":{"type":"command","command":"%s/statusline-rate-limits.sh"}}\n' "$BIN_DIR" \
    > "$tmp/mig/fakehome2/.claude/settings.json"
  got="$( HOME="$tmp/mig/fakehome2" statusline_path_warning )"
  [ -z "$got" ] && ok "a statusline already on the new path gets no warning" || bad "warned anyway: '$got'"

  echo "the rename — a run, its hooks and its prechecks see AL_* and CC_* alike for one release"
  mkdir -p "$tmp/hookcfg/hooks"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s|%s|%s|%s\n" "$AL_JOB_ID" "$CC_JOB_ID" "$AL_STATUS" "$CC_STATUS" > "$AL_HOOK_OUT"' \
    > "$tmp/hookcfg/hooks/on-run-end.sh"
  export AL_HOOK_OUT="$tmp/hook-twins.seen"; rm -f "$AL_HOOK_OUT"
  ( CONFIG_DIR="$tmp/hookcfg"; run_end_hook j7 warning 0.2 "n" P sess /tmp/l.json 1 2 ) >/dev/null 2>&1
  waited=0
  while [ ! -f "$AL_HOOK_OUT" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
  got="$(cat "$AL_HOOK_OUT" 2>/dev/null)"
  [ "$got" = "j7|j7|warning|warning" ] && ok "on-run-end sees AL_JOB_ID and CC_JOB_ID with one value" \
    || bad "the hook saw '$got'"
  unset AL_HOOK_OUT
  rm -f "$tmp/hookcfg/hooks/on-run-end.sh"

  mkdir -p "$tmp/twins/cfg/provision" "$tmp/twins/run/repoA"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|%s\n" "$AL_REPO_NAME" "$CC_REPO_NAME" > "$AL_WORKTREE/twins"' \
    > "$tmp/twins/cfg/provision/twins.up.sh"
  ( CONFIG_DIR="$tmp/twins/cfg"; PROJECTS_FILE="$tmp/proj/projects.json"
    wt_provision up twins j1 "$tmp/twins/run" repoA /x/a "$tmp/twins/run/repoA" develop ) >/dev/null 2>&1
  got="$(cat "$tmp/twins/run/repoA/twins" 2>/dev/null)"
  [ "$got" = "repoA|repoA" ] && ok "a provisioning hook sees AL_REPO_NAME and CC_REPO_NAME with one value" \
    || bad "the provisioning hook saw '$got'"

  # Structural, like the bind_session call-site count above: the three places
  # a precheck is run dry all export the marker under both names, and a
  # fourth caller added later has to as well.
  got="$(sed -n '/^cmd_selftest()/,/^}/!p' "$SELF" | grep -c 'export AL_PRECHECK_DRY_RUN=1 CC_PRECHECK_DRY_RUN=1')"
  [ "$got" = "3" ] && ok "every dry precheck exports the marker under both names ($got sites)" \
    || bad "$got sites export both spellings of the dry-run marker, expected 3"

  echo "the rename — install and status name the personal scripts still reading CC_*"
  mkdir -p "$tmp/legacy/prechecks" "$tmp/legacy/provision" "$tmp/legacy/hooks"
  printf '%s\n' '#!/bin/bash' "echo \"\$${LEGACY_RUN_PREFIX}JOB_ID\"" > "$tmp/legacy/prechecks/old.sh"
  printf '%s\n' '#!/bin/bash' 'echo "$AL_JOB_ID"' > "$tmp/legacy/provision/new.up.sh"
  got="$( CONFIG_DIR="$tmp/legacy" legacy_scripts_warnings )"
  case "$got" in *"prechecks/old.sh reads ${LEGACY_RUN_PREFIX}"*) ok "a script still on the old prefix is named" ;;
                 *) bad "the warning was: '$got'" ;; esac
  case "$got" in *"new.up.sh"*) bad "a script already on AL_ was named" ;; *) ok "a script already on AL_ is not" ;; esac

  printf '{"jobs":[{"id":"jinline","prompt":"read $%sRUN_MANIFEST then stop","precheck":"test -f /tmp/x"},{"id":"jclean","prompt":"read $AL_RUN_MANIFEST","precheck":"test -f /tmp/y"}]}\n' \
    "$LEGACY_RUN_PREFIX" > "$tmp/legacy/jobs.json"
  got="$( CONFIG_DIR="$tmp/legacy" JOBS_FILE="$tmp/legacy/jobs.json" legacy_scripts_warnings )"
  case "$got" in *"job jinline: its prompt reads ${LEGACY_RUN_PREFIX}"*) ok "an inline prompt still on the old prefix is named, with its job" ;;
                 *) bad "the inline warning was: '$got'" ;; esac
  case "$got" in *"jclean"*) bad "a job already on AL_ was named" ;; *) ok "a job already on AL_ is not" ;; esac

  echo "the rename — the pre-rename environment names still work for one release"
  mkdir -p "$tmp/legacy/config" "$tmp/legacy/data"
  got="$( env -i HOME="$HOME" PATH="$PATH" "${LEGACY_ENV_PREFIX}PORT=9876" \
            AGENTLOOP_CONFIG="$tmp/legacy/config" AGENTLOOP_DATA="$tmp/legacy/data" \
            bash "$SELF" status 2>/dev/null )"
  case "$got" in *"http://127.0.0.1:9876/"*) ok "a port set only under the old name is honoured" ;;
                 *) bad "status said: $got" ;; esac
  case "$got" in *"${LEGACY_ENV_PREFIX}PORT is set"*) ok "and status says which old name it found" ;;
                 *) bad "no warning about the old name in: $got" ;; esac
  got="$( env -i HOME="$HOME" PATH="$PATH" "${LEGACY_ENV_PREFIX}PORT=9876" AGENTLOOP_PORT=1111 \
            AGENTLOOP_CONFIG="$tmp/legacy/config" AGENTLOOP_DATA="$tmp/legacy/data" \
            bash "$SELF" status 2>/dev/null )"
  case "$got" in *"http://127.0.0.1:1111/"*) ok "the new name wins when both are set" ;;
                 *) bad "status said: $got" ;; esac

  echo "the committed UI artifacts — built from the sources sitting next to them"
  check_ui_artifacts

  rm -rf "$tmp"
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
