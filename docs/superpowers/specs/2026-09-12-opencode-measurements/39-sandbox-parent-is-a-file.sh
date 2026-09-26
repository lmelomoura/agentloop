#!/bin/bash
# Reproduces the OpenCode 1.18.30 startup crash on a sandbox whose parent path became a file.
# Everything OpenCode writes stays under $S (XDG_* redirected); the real ~/.local/share/opencode is never touched.
set -u
S="${1:?usage: $0 <empty scratch dir>}"; OC="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
[ -z "$(ls -A "$S" 2>/dev/null)" ] || { echo "refusing: $S is not empty" >&2; exit 2; }
mkdir -p "$S"/{xdg-data,xdg-state,xdg-cache,xdg-config,runs}
export XDG_DATA_HOME=$S/xdg-data XDG_STATE_HOME=$S/xdg-state XDG_CACHE_HOME=$S/xdg-cache XDG_CONFIG_HOME=$S/xdg-config
run_oc() { perl -e 'alarm shift; exec @ARGV' 90 "$OC" "$@"; }
echo "== opencode $("$OC" --version)"; run_oc debug paths 2>&1 | grep -iE "data|state" | head -3
git init -q "$S/main" && git -C "$S/main" -c user.email=r@r -c user.name=r commit -q --allow-empty -m root
for r in A B C; do mkdir -p "$S/runs/$r"; git -C "$S/main" worktree add -q --detach "$S/runs/$r/repo"; done
step() { # <label> <dir> <opencode args...>
  local label="$1" dir="$2"; shift 2
  echo; echo "== $label  (cwd ${dir#$S/})"
  ( cd "$dir" && run_oc "$@" >"$S/out.txt" 2>"$S/err.txt"; echo "rc=$?" )
  grep -aE "Error|BadResource|access" "$S/err.txt" | head -3
  echo "sandboxes: $(sqlite3 "$S/xdg-data/opencode/opencode.db" "select sandboxes from project where vcs='git'" 2>/dev/null | sed "s#$S/##g")"
}
CMD=(${OC_CMD:-debug config})
step "1. start in A" "$S/runs/A/repo" "${CMD[@]}"
step "2. start in C" "$S/runs/C/repo" "${CMD[@]}"
git -C "$S/main" worktree remove --force "$S/runs/A/repo"; rm -rf "$S/runs/A"
step "3. A removed cleanly (ENOENT); start in B" "$S/runs/B/repo" "${CMD[@]}"
git -C "$S/main" worktree remove --force "$S/runs/C/repo"; rm -rf "$S/runs/C"; touch "$S/runs/C"
step "4. C removed, then its run dir re-created as a 0-byte file (what touch did); start in B" "$S/runs/B/repo" "${CMD[@]}"
step "5. same poison; start in the main checkout" "$S/main" "${CMD[@]}"
rm -f "$S/runs/C"
step "6. the 0-byte file removed; start in B" "$S/runs/B/repo" "${CMD[@]}"
