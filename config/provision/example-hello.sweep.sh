#!/usr/bin/env bash
# Example SWEEP hook. Copy it to <your project>.sweep.sh and edit.
#
# The other two hooks belong to a RUN: `.up.sh` before an agent starts, `.down.sh`
# when it finishes. This one belongs to the PROJECT. The tick calls it on a timer
# — every AGENTLOOP_SWEEP_INTERVAL seconds, 300 by default — whether or not
# anything is running, and it is the only hook that gets a second look at
# whatever a `down` failed to clean up.
#
# You want one as soon as a run starts anything that outlives its own process:
# containers, a database, a daemon, a tunnel, a registered site. `down` gets ONE
# chance at those. Miss it — the tick that would have called it was killed, the
# run dir was already removed so nothing was left to enumerate, the agent cut a
# worktree of its own that no manifest ever named — and nothing calls it again
# for that run, ever. What it left keeps holding memory, ports and disk. If those
# services also restart themselves at boot, escaping once is escaping for good.
#
# WHAT THE ENGINE GUARANTEES BEFORE CALLING THIS
#
#   * No run of this project is alive. Not "no run holds this directory" — no
#     run at all. An agent creates working directories of its own mid-run that
#     no manifest names and no lock points at, and they are indistinguishable
#     from garbage until the run ends.
#   * The working directory is the project's `.cwd`.
#
# WHAT ARRIVES IN THE ENVIRONMENT
#
#   AL_PROJECT               the project's name
#   AL_LIVE_WORKTREES        a FILE: paths live runs are working in, one per
#                            line. Empty when nothing is running. Never reclaim
#                            anything at or under one of these.
#   AL_CANONICALS            a FILE: every project's canonical checkouts, one per
#                            line. These are where a human's own environment
#                            lives. Never reclaim anything at or under one.
#   AL_SWEEP_GRACE_SECONDS   how old something must be before it is fair game
#                            (AGENTLOOP_SWEEP_GRACE, 21600 by default)
#   AL_PROVISION_LIB         source it for al_port and friends, as in `.up.sh`
#
# It is killed if it outlives `.worktree.sweep_timeout_seconds` (300 by default):
# it runs inside the tick's own mutex, so a sweep that blocks on an unresponsive
# daemon would stop the scheduler launching anything at all.
#
# THE ONE RULE
#
# This hook deletes things on a machine nobody is watching, on a timer, for ever.
# Write every test so that being WRONG costs disk rather than data: prove a thing
# is yours before reclaiming it, rather than assuming it is yours because nothing
# proved otherwise. Give the humans an opt-out and honour it.
set -uo pipefail          # NOT -e: a sweep must finish, whatever one step says

# A file a human can drop anywhere to say "leave my stuff alone". Cheap to
# support, and the thing that makes an automatic reaper tolerable to live with.
keep() { # <dir> — 0 if this directory, or one just above it, is spoken for
  local d="${1:-}" i=0
  while [ "$i" -lt 4 ] && [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.agentloop-keep" ] && return 0
    d="$(dirname "$d")"; i=$(( i + 1 ))
  done
  return 1
}

# 0 = <path> is at or under one of the paths listed in <file>.
# awk, not a bash `case` glob: these paths are data and may contain glob
# metacharacters, and a macOS home directory routinely contains a space —
# which is exactly where a `case "$p" in "$a"/*)` built from a variable starts
# matching the wrong thing.
listed() { # <path> <file>
  [ -n "${1:-}" ] && [ -s "${2:-}" ] || return 1
  awk -v p="$1" 'NF && ($0 == p || index(p, $0 "/") == 1) { found = 1; exit }
                 END { exit !found }' "$2"
}

# Replace everything below with your project's own reaping. This example just
# reports what it would consider, so that copying it and forgetting to edit it
# destroys nothing.
now="$(date +%s)"
grace="${AL_SWEEP_GRACE_SECONDS:-21600}"
echo "sweep: $AL_PROJECT — grace ${grace}s, $(grep -c . "${AL_LIVE_WORKTREES:-/dev/null}" 2>/dev/null || echo 0) live path(s), nothing to do in the example hook"
true
