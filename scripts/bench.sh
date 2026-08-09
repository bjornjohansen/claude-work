#!/usr/bin/env bash
#
# What does the update check cost at startup?
#
# The answer has to stay well under 100ms, and the only reason it does is that
# the check forks a detached child and never waits for it. This is a manual
# target rather than a CI gate on purpose: a wall-clock assertion on a shared
# runner is a flake generator, but "it's obviously cheap" is not a measurement
# either, so the measurement lives here where it can be re-run.
#
# It has to run on a terminal, because the check's gate skips when stdin and
# stderr are not one — measuring it without a tty would report the cost of
# doing nothing.
#
# Usage: scripts/bench.sh [iterations]

set -euo pipefail

ITERATIONS="${1:-200}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/bin/claude-work"

if [ ! -t 0 ] || [ ! -t 2 ]; then
  echo "bench.sh must run on a terminal — the update check skips without one." >&2
  echo "If you are piping this, try: scripts/bench.sh | cat  (won't work either)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A curl that answers instantly, so the child's own runtime never colours the
# figure. The foreground cost is the gate plus the fork; the child is asynchronous.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/curl" <<'EOF'
#!/bin/sh
printf 'https://github.com/bjornjohansen/claude-work/releases/tag/v9.9.9'
EOF
chmod +x "${WORK}/bin/curl"

sed -n '/^# --- update check begin ---$/,/^# --- update check end ---$/p' \
  "$SCRIPT" >"${WORK}/lib.sh"

now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
per_call() { perl -e 'printf "%.3f ms\n", ($ARGV[1] - $ARGV[0]) * 1000 / $ARGV[2]' "$@"; }

# $1 and $2 inside the single-quoted body are the arguments passed to `bash -c`,
# not something for this shell to expand.
# shellcheck disable=SC2016
measure() {
  local label="$1" setting="$2" t0 t1
  t0=$(now)
  env "$setting" \
    HOME="$WORK" XDG_CACHE_HOME="${WORK}/cache" PATH="${WORK}/bin:${PATH}" \
    bash -c '
      . "$1"
      i=0
      while [ "$i" -lt "$2" ]; do cw_update_spawn; i=$((i + 1)); done
    ' _ "${WORK}/lib.sh" "$ITERATIONS"
  t1=$(now)
  printf '  %-22s %s\n' "$label" "$(per_call "$t0" "$t1" "$ITERATIONS")"
}

echo "claude-work startup cost of the update check (${ITERATIONS} iterations)"
echo
measure "check enabled" "CW_BENCH=1"
measure "opted out" "CLAUDE_WORK_NO_UPDATE_CHECK=1"
measure "CI=true" "CI=true"
echo
echo "For scale, on the same machine:"
REPO="${WORK}/repo"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m bench
t0=$(now)
git -C "$REPO" worktree prune
t1=$(now)
printf '  %-22s %s\n' "git worktree prune" "$(per_call "$t0" "$t1" 1)"
echo
echo "The check must stay far below 100 ms. It is one fork; the network happens"
echo "in the child, which nothing waits for."
