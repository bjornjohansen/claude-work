# shellcheck shell=bash
#
# Shared fixture for the claude-work test suite.
#
# Each test gets a throwaway origin + clone, a fake `claude` on PATH, and an
# isolated tmux server. The tmux isolation matters: TMUX_TMPDIR gives us our own
# socket directory, so `tmux kill-server` in teardown can never touch a tmux
# session the developer running the tests is using.

CW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CW_SCRIPT="${CW_ROOT}/bin/claude-work"

# CI overrides this to pin a specific interpreter (e.g. /bin/bash for 3.2).
CW_BASH="${CW_BASH:-bash}"

# Run the tool under test.
cw() {
  "$CW_BASH" "$CW_SCRIPT" "$@"
}

setup_fixture() {
  TESTDIR="$(mktemp -d)"

  # Unique per run, so tmux session names can never collide between tests.
  REPO_NAME="cwtest$(printf '%s' "$TESTDIR" | tr -dc 'a-zA-Z0-9' | tail -c 8)"
  REPO_DIR="${TESTDIR}/${REPO_NAME}"

  # Isolated tmux server — see the note at the top of this file.
  TMUX_TMPDIR="${TESTDIR}/tmux"
  mkdir -p "$TMUX_TMPDIR"
  export TMUX_TMPDIR
  # A stale $TMUX would make the script take its switch-client path.
  unset TMUX

  # Fake `claude`. The sleep duration is read from a file whose path is baked in
  # at creation time, so tests can change it without depending on tmux
  # propagating environment variables into new sessions.
  mkdir -p "${TESTDIR}/bin"
  printf '300\n' >"${TESTDIR}/claude_sleep"
  # SC2016 is the point here: the $(cat ...) must stay literal so it is
  # evaluated when the shim runs, not when the shim is written.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nexec sleep "$(cat %s/claude_sleep 2>/dev/null || echo 300)"\n' \
    "$TESTDIR" >"${TESTDIR}/bin/claude"
  chmod +x "${TESTDIR}/bin/claude"
  PATH="${TESTDIR}/bin:${PATH}"
  export PATH

  git init -q --bare "${TESTDIR}/origin.git"
  git clone -q "${TESTDIR}/origin.git" "$REPO_DIR" 2>/dev/null
  cd "$REPO_DIR" || return 1
  git config user.email test@example.com
  git config user.name "Test User"
  git config commit.gpgsign false
  echo "hello" >README.md
  git add README.md
  git commit -qm "init"
  git branch -M main
  git push -qu origin main
}

teardown_fixture() {
  if [ -n "${TMUX_TMPDIR:-}" ] && [ -d "${TMUX_TMPDIR}" ]; then
    tmux kill-server 2>/dev/null || true
  fi
  cd / || true
  [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
  return 0
}

# Make claude exit quickly, so the tmux session ends and the cleanup prompt runs.
claude_exits_after() {
  printf '%s\n' "$1" >"${TESTDIR}/claude_sleep"
}

# Drive the tool through a pty, answering the given prompts in order.
cw_pty() {
  local answers=()
  while [ "$1" != "--" ]; do
    answers+=("$1")
    shift
  done
  shift
  python3 "${CW_ROOT}/test/helpers/ptyrun.py" "${answers[@]}" -- "$CW_BASH" "$CW_SCRIPT" "$@"
}
