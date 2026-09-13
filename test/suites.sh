#!/usr/bin/env bash
# The whole battery, from one command, with the four numbers at the end.
#
#   bash test/suites.sh
#
# Three suites, not four. test/e2e.test.sh is NOT run on its own: `agentloop
# selftest` runs it inside itself and counts its checks -- running it again
# here cost about five minutes for nothing, and the two collide on
# test/sandbox. The "end-to-end suite (N checks)" line below is read back out
# of the selftest's own output.
#
# Run in sequence, on purpose. Running the three side by side was measured
# (2026-09-13) and gained nothing on this machine: the selftest spawns
# hundreds of processes and the security suite runs four engines, and under
# contention the selftest stretched by exactly what the others saved. What
# does make the battery faster is the e2e's own workers (E2E_WORKERS, see
# test/e2e.test.sh), which the selftest inherits.
#
# Exit status is non-zero if any suite failed, and the tail of the one that
# failed is printed -- the four numbers are printed either way.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SUITES_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/agentloop-suites.XXXXXX")}"
mkdir -p "$OUT"
PY="${PYTHON:-python3.13}"
began=$(date +%s)

bash "$REPO/bin/agentloop" selftest > "$OUT/selftest.log" 2>&1; rc_self=$?
"$PY" -m pytest "$REPO/tests" --ignore="$REPO/tests/security" -p no:cacheprovider -q > "$OUT/pytest.log" 2>&1; rc_py=$?
TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true \
  "$PY" -m pytest "$REPO/tests/security" -p no:cacheprovider -q \
  --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on \
  > "$OUT/security.log" 2>&1; rc_sec=$?

ended=$(date +%s)
printf '\nselftest  %s\n' "$(grep -E '^ *[0-9]+ passed, [0-9]+ failed' "$OUT/selftest.log" | tail -1 | sed 's/^ *//')"
printf 'e2e       %s\n' "$(grep -oE 'end-to-end suite \([0-9]+ checks\)' "$OUT/selftest.log" | tail -1)"
printf 'pytest    %s\n' "$(tail -1 "$OUT/pytest.log")"
printf 'security  %s\n' "$(tail -1 "$OUT/security.log")"
printf 'wall      %ss   (logs in %s)\n' "$((ended - began))" "$OUT"

rc=0
for pair in "selftest:$rc_self" "pytest:$rc_py" "security:$rc_sec"; do
  name="${pair%%:*}"; code="${pair##*:}"
  if [ "$code" -ne 0 ]; then
    rc=1
    printf '\n--- %s failed (rc %s); its last lines: ---\n' "$name" "$code"
    grep -E 'FAIL|Error|error' "$OUT/$name.log" | tail -12
  fi
done
exit "$rc"
