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

  # No test may reach the network or touch the developer's real cache. The
  # pty-driven cases give the script a real tty on stdin and stderr, which is
  # all the update check's gate asks for, so without this every local run would
  # make a request to GitHub per test. Cases that exercise the check turn this
  # back on against a stubbed curl and this isolated cache directory.
  export CLAUDE_WORK_NO_UPDATE_CHECK=1
  export XDG_CACHE_HOME="${TESTDIR}/cache"
  mkdir -p "$XDG_CACHE_HOME"

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

# --- update check ------------------------------------------------------------

# Turn the update check back on for this test, against a stubbed curl and the
# fixture's own cache directory. setup_fixture disables it for everything else.
setup_update_check() {
  unset CLAUDE_WORK_NO_UPDATE_CHECK
  # GitHub Actions always sets CI, and the gate skips when it is set — leaving
  # it would make every case in update-check.bats a no-op that still passes.
  unset CI
  unset NO_UPDATE_NOTIFIER
  unset DO_NOT_TRACK

  CACHE_DIR="${XDG_CACHE_HOME}/claude-work"
  CACHE_FILE="${CACHE_DIR}/update"
  mkdir -p "$CACHE_DIR"
  chmod 0700 "$CACHE_DIR"

  CURL_LOG="${TESTDIR}/curl.log"
  export CURL_LOG

  # The region of bin/claude-work the unit-level cases source directly.
  UPDATE_LIB="${TESTDIR}/update-lib.sh"
  sed -n '/^# --- update check begin ---$/,/^# --- update check end ---$/p' \
    "$CW_SCRIPT" >"$UPDATE_LIB"
}

# Write the cache directly: <checked> <latest> <declined>.
seed_cache() {
  printf '%s %s %s\n' "$1" "$2" "$3" >"$CACHE_FILE"
}

# A curl that logs its arguments and answers with a release-tag redirect.
# $CURL_FAIL makes it fail the way an offline machine would.
stub_curl() {
  stub_curl_url "https://github.com/bjornjohansen/claude-work/releases/tag/v9.9.9"
}

# As stub_curl, but answering with an arbitrary redirect target.
stub_curl_url() {
  CURL_REDIRECT="$1"
  export CURL_REDIRECT
  cat >"${TESTDIR}/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
[ -z "${CURL_FAIL:-}" ] || exit 7
printf '%s' "$CURL_REDIRECT"
EOF
  chmod +x "${TESTDIR}/bin/curl"
}

# Run the background check's body in the foreground, so a test can assert on
# what it did without racing a detached child.
run_fetch() {
  "$CW_BASH" -c '. "$1"; set +e; cw_update_fetch' _ "$UPDATE_LIB"
}

# Run a command with a deadline, exiting 124 if it is exceeded. Not `timeout`:
# that is GNU coreutils and macOS does not ship it. python3 is already required
# by the pty harness, so this adds no new dependency.
with_timeout() {
  local secs="$1"
  shift
  python3 -c '
import subprocess, sys
try:
    sys.exit(subprocess.call(sys.argv[2:], timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    sys.exit(124)
' "$secs" "$@"
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
