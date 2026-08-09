#!/usr/bin/env bats
#
# Tests for the background release check and the notice it produces.
#
# Two things make this file easy to get wrong, and both are asserted rather than
# assumed. The gate wants a tty on stdin and stderr, so every positive case has
# to run through cw_pty — a plain `run cw ...` would silently exercise nothing.
# And the gate skips when $CI is set, which GitHub Actions always sets, so
# setup_update_check unsets it; without that the whole file would pass as a
# no-op on CI while proving nothing.

load helpers/common

setup() {
  setup_fixture
  setup_update_check
}

teardown() {
  teardown_fixture
}

# --- the pure helpers, sourced out of the script ----------------------------

# Source the sentinel-delimited region and run $1 in that context.
in_lib() {
  run "$CW_BASH" -c '. "$1"; set +e; shift; eval "$@"' _ "$UPDATE_LIB" "$@"
}

@test "the sentinels the tests source are present exactly once" {
  [ "$(grep -c '^# --- update check begin ---$' "$CW_SCRIPT")" -eq 1 ]
  [ "$(grep -c '^# --- update check end ---$' "$CW_SCRIPT")" -eq 1 ]
}

# Sourcing a slice of the script only tests what the slice contains. If a cw_*
# function is ever defined outside the sentinels, the cases below would quietly
# stop covering it, so the two sets must match exactly.
@test "every cw_ function in the script lives inside the sentinels" {
  local in_script in_region
  in_script=$(grep -oE '^cw_[a-z_]+\(\)' "$CW_SCRIPT" | sort)
  in_region=$(grep -oE '^cw_[a-z_]+\(\)' "$UPDATE_LIB" | sort)
  [ -n "$in_script" ]
  [ "$in_script" = "$in_region" ]
}

@test "cw_version_gt compares numerically, not lexically" {
  local pair
  for pair in "0.3.0 0.2.2 0" "0.10.0 0.9.9 0" "0.2.10 0.2.9 0" "1.0.0 0.99.99 0" \
    "0.2.2 0.2.2 1" "0.2.2 0.3.0 1" "0.9.9 0.10.0 1"; do
    # shellcheck disable=SC2086
    set -- $pair
    in_lib "cw_version_gt $1 $2"
    [ "$status" -eq "$3" ]
  done
}

# A dev build ahead of the latest release must never be told to downgrade.
@test "cw_version_gt is strict, so a newer local version is not an update" {
  in_lib "cw_version_gt 0.1.0 9.9.9"
  [ "$status" -eq 1 ]
}

@test "cw_is_semver rejects prereleases, escapes and traversal" {
  local bad
  for bad in "" "-" "1.2" "0.3.0-rc1" "99999.1.1" "1.2.3.4" \
    "x/../../../evil/repo/main/install.sh?" '0,a[0$(touch P)]'; do
    in_lib "cw_is_semver \"\$1\"" "$bad"
    [ "$status" -eq 1 ]
  done
  in_lib "cw_is_semver 0.3.0"
  [ "$status" -eq 0 ]
}

# 10# fixes octal, but $(( )) still evaluates command substitutions and array
# subscripts. Each payload below was confirmed to execute without the guard.
@test "no cache value can reach arithmetic as code" {
  local payload
  for payload in '0$(touch PWNED)' '0,a[0$(touch PWNED)]' '0+a[0$(touch PWNED)]' \
    '1?a[0$(touch PWNED)]:0' '`touch PWNED`'; do
    seed_cache "$payload" "0.3.0" "-"
    in_lib "cw_cache_read; echo \"\$CW_CHECKED\""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]

    in_lib "cw_version_gt \"\$1\" 0.0.0" "$payload"
    [ ! -e "${TESTDIR}/PWNED" ]
    [ ! -e "${CACHE_DIR}/PWNED" ]
  done
}

# --- the cache is untrusted input -------------------------------------------

@test "cw_cache_read defaults every field when the file is empty or junk" {
  local content
  for content in "" " " "garbage" "1 2 3 4 5" "notanumber notaversion notaversion"; do
    printf '%s\n' "$content" >"$CACHE_FILE"
    in_lib 'cw_cache_read; echo "$CW_CHECKED|$CW_LATEST|$CW_DECLINED"'
    [ "$status" -eq 0 ]
    # A non-numeric stamp must become 0, never empty — an empty value would make
    # the later `-le` comparison an error rather than a decision.
    [[ "$output" =~ ^[0-9]+\| ]]
    [[ "$output" != *"garbage"* ]]
    [[ "$output" != *"notaversion"* ]]
  done
}

@test "a version that is not a version is discarded on read" {
  seed_cache 1 "x/../../../evil-owner/evil-repo/main/install.sh?" "-"
  in_lib 'cw_cache_read; echo "$CW_LATEST"'
  [ "$output" = "-" ]
}

# `read` on a fifo blocks forever, which for a tool whose job is to launch an
# editor is the worst possible failure. -f is what prevents it.
@test "a fifo in place of the cache file does not hang" {
  rm -f "$CACHE_FILE"
  mkfifo "$CACHE_FILE"
  run with_timeout 20 "$CW_BASH" -c '. "$1"; set +e; cw_cache_read; echo "$CW_LATEST"' _ "$UPDATE_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "-" ]
}

# -f follows a symlink to a regular file, so it is not sufficient on its own.
@test "a symlinked cache file is ignored" {
  printf '1 9.9.9 -\n' >"${TESTDIR}/planted"
  rm -f "$CACHE_FILE"
  ln -s "${TESTDIR}/planted" "$CACHE_FILE"
  in_lib 'cw_cache_read; echo "$CW_LATEST"'
  [ "$output" = "-" ]
}

@test "a directory in place of the cache file is ignored" {
  rm -f "$CACHE_FILE"
  mkdir -p "$CACHE_FILE"
  in_lib 'cw_cache_read; echo "$CW_LATEST"'
  [ "$output" = "-" ]
}

@test "a symlinked cache directory is refused outright" {
  rm -rf "$CACHE_DIR"
  mkdir -p "${TESTDIR}/elsewhere"
  ln -s "${TESTDIR}/elsewhere" "$CACHE_DIR"
  in_lib 'cw_cache_file; echo "rc=$?"'
  [[ "$output" == *"rc=1"* ]]
}

@test "a relative XDG_CACHE_HOME is not used as a cache directory" {
  run "$CW_BASH" -c '
    . "$1"
    cd "$2" || exit 1
    XDG_CACHE_HOME=relative-cache
    export XDG_CACHE_HOME
    cw_cache_file
  ' _ "$UPDATE_LIB" "$REPO_DIR"
  [ "$status" -eq 0 ]
  # It must fall back to $HOME/.cache, never land inside the repository.
  [[ "$output" != *"relative-cache"* ]]
  [ ! -e "${REPO_DIR}/relative-cache" ]
}

@test "the cache is written atomically and leaves nothing behind" {
  in_lib 'cw_cache_write 123 0.3.0 -'
  [ "$status" -eq 0 ]
  [ "$(cat "$CACHE_FILE")" = "123 0.3.0 -" ]
  [ -z "$(find "$CACHE_DIR" -name '.update.*' -print -quit)" ]
}

# --- the fetch ---------------------------------------------------------------

@test "a fetch records the version and asks GitHub only for the redirect" {
  stub_curl
  run_fetch
  [ "$(cut -d' ' -f2 "$CACHE_FILE")" = "9.9.9" ]

  grep -q -- '--proto =https' "$CURL_LOG"
  grep -q -- '--max-time 8' "$CURL_LOG"
  grep -q -- '--connect-timeout 3' "$CURL_LOG"
  grep -q -- '%{redirect_url}' "$CURL_LOG"
  grep -q -- 'releases/latest' "$CURL_LOG"
  # -L would follow the redirect and download a page we have no use for.
  ! grep -qE '(^| )-L( |$)' "$CURL_LOG"
  # A custom agent or a cookie jar would make an ambient request identifying.
  ! grep -qE -- '(-A|--user-agent|--cookie)' "$CURL_LOG"
}

@test "a second run inside the interval does not fetch again" {
  stub_curl
  run_fetch
  run_fetch
  [ "$(grep -c 'releases/latest' "$CURL_LOG")" -eq 1 ]
}

@test "CLAUDE_WORK_UPDATE_INTERVAL=0 forces a refetch" {
  stub_curl
  run_fetch
  CLAUDE_WORK_UPDATE_INTERVAL=0 run_fetch
  [ "$(grep -c 'releases/latest' "$CURL_LOG")" -eq 2 ]
}

# The stamp is written before the request, so an offline machine backs off
# instead of retrying every run — but it must not lose a version it already had.
@test "a failed fetch keeps the known version and still backs off" {
  stub_curl
  run_fetch
  [ "$(cut -d' ' -f2 "$CACHE_FILE")" = "9.9.9" ]

  CURL_FAIL=1 CLAUDE_WORK_UPDATE_INTERVAL=0 run_fetch
  [ "$(cut -d' ' -f2 "$CACHE_FILE")" = "9.9.9" ]
}

@test "a redirect that is not the release page is refused" {
  local url
  for url in "https://portal.example/login?r=/releases/tag/v9.9.9" \
    "http://github.com/bjornjohansen/claude-work/releases/tag/v9.9.9" \
    "https://evil.example/bjornjohansen/claude-work/releases/tag/v9.9.9" \
    "https://github.com/bjornjohansen/claude-work/releases/tag/v9.9.9-rc1"; do
    seed_cache 1 "-" "-"
    stub_curl_url "$url"
    CLAUDE_WORK_UPDATE_INTERVAL=0 run_fetch
    [ "$(cut -d' ' -f2 "$CACHE_FILE")" = "-" ]
  done
}

# --- the gate ----------------------------------------------------------------

@test "the check does not run without a terminal" {
  stub_curl
  run cw issue-nogate
  [ ! -e "$CURL_LOG" ]
}

@test "each opt-out switch stops the check" {
  local var

  # The control, and the reason the rest of this test means anything: on a pty
  # with nothing opted out, the check really does make its request. Without it
  # every assertion below would hold just as well if cw_update_spawn returned
  # early for some unrelated reason — which is precisely what the earlier
  # version of this test did. It ran under bats' `run`, which supplies no
  # terminal, so it stopped at the tty gate and never reached the opt-out
  # checks it is named for; deleting all four of them left it passing.
  stub_curl
  rm -f "$CURL_LOG"
  run_spawn_on_pty
  [ -e "$CURL_LOG" ]

  for var in CLAUDE_WORK_NO_UPDATE_CHECK NO_UPDATE_NOTIFIER DO_NOT_TRACK CI; do
    stub_curl
    rm -f "$CURL_LOG"
    run_spawn_on_pty "${var}=1"
    [ ! -e "$CURL_LOG" ]
  done
}

# --- the notice --------------------------------------------------------------

@test "a newer cached version is announced when the session ends" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -
  run cw_pty n n -- issue-notice
  [[ "$output" == *"claude-work 9.9.9 is available (you have "* ]]
  [[ "$output" == *"releases/tag/v9.9.9"* ]]
}

@test "the notice comes after the cleanup prompt, not before" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -
  run cw_pty y n -- issue-order
  local cleanup notice
  cleanup=$(printf '%s\n' "$output" | grep -n 'Removed worktree' | head -1 | cut -d: -f1)
  notice=$(printf '%s\n' "$output" | grep -n 'is available' | head -1 | cut -d: -f1)
  [ -n "$cleanup" ]
  [ -n "$notice" ]
  [ "$notice" -gt "$cleanup" ]
}

@test "an older cached version says nothing" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 0.0.1 -
  run cw_pty n n -- issue-older
  [[ "$output" != *"is available"* ]]
}

@test "an empty cache says nothing" {
  claude_exits_after 1
  run cw_pty n -- issue-nocache
  [[ "$output" != *"is available"* ]]
}

@test "a declined version is not announced again" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 9.9.9
  run cw_pty n n -- issue-declined
  [[ "$output" != *"is available"* ]]
}

@test "a failed run says nothing about updates" {
  seed_cache "$(date +%s)" 9.9.9 -
  run cw --not-a-valid-slug!
  [ "$status" -ne 0 ]
  [[ "$output" != *"is available"* ]]
}

# --- the upgrade ------------------------------------------------------------

# Detaching means the user has stepped away mid-task and wants their shell
# back. A blocking question there would be worse than no feature at all.
@test "detaching shows the notice but never asks a question" {
  claude_exits_after 300
  seed_cache "$(date +%s)" 9.9.9 -

  # Detach by killing the session's client; the session itself stays alive.
  (
    sleep 3
    tmux detach-client -s "cc-${REPO_NAME}-issue-detach" 2>/dev/null
  ) &
  run with_timeout 45 python3 "${CW_ROOT}/test/helpers/ptyrun.py" -- \
    "$CW_BASH" "$CW_SCRIPT" issue-detach
  wait

  [ "$status" -ne 124 ]
  [[ "$output" == *"Detached from"* ]]
  [[ "$output" == *"is available"* ]]
  [[ "$output" == *"claude-work --upgrade"* ]]
  [[ "$output" != *"Upgrade claude-work to"* ]]
}

@test "running from a git checkout is never overwritten" {
  stub_upgrade_curl
  run "$CW_BASH" "$CW_SCRIPT" --upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside a git checkout"* ]]
  # Nothing was even fetched.
  [ ! -e "$CURL_LOG" ]
}

@test "--upgrade verifies the installer and hands it the running prefix" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"

  run "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE-INSTALL --require-checksum --prefix ${TESTDIR}/prefix"* ]]

  # Only fixed URLs: no version is ever interpolated into a request.
  grep -q 'releases/latest/download/install.sh' "$CURL_LOG"
  grep -q 'releases/latest/download/SHA256SUMS' "$CURL_LOG"
  ! grep -qE 'releases/download/v' "$CURL_LOG"
}

@test "--upgrade through a symlink upgrades the real directory" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"
  mkdir -p "${TESTDIR}/linkdir"
  ln -s "${TESTDIR}/prefix/claude-work" "${TESTDIR}/linkdir/claude-work"

  run "$CW_BASH" "${TESTDIR}/linkdir/claude-work" --upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"--prefix ${TESTDIR}/prefix"* ]]
  [[ "$output" != *"--prefix ${TESTDIR}/linkdir"* ]]
}

@test "an installer that fails its checksum is not run" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"
  # Change the installer without regenerating the sums.
  printf '#!/bin/sh\ntouch "%s/OWNED"\n' "$TESTDIR" >"${REL_DIR}/install.sh"

  run "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed checksum verification"* ]]
  [ ! -e "${TESTDIR}/OWNED" ]
}

@test "a release with no checksum for the installer is refused" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"
  (cd "$REL_DIR" && shasum -a 256 claude-work >SHA256SUMS)

  run "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"no checksum for install.sh"* ]]
}

@test "a download failure is reported, not ignored" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"

  run env CURL_FAIL=1 "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not download the installer"* ]]
}

# cw_do_upgrade is shared by --upgrade and the exit prompt, so it must not
# depend on either caller's state. Reading the trap's exit-status variable here
# would abort under `set -u` — after the new binary had already been written.
@test "--upgrade exits cleanly with the installer's status" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"

  run "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [[ "$output" != *"unbound variable"* ]]
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\nexit 3\n' >"${REL_DIR}/install.sh"
  regenerate_release_sums
  run "$CW_BASH" "${TESTDIR}/prefix/claude-work" --upgrade
  [ "$status" -eq 3 ]
  [[ "$output" != *"unbound variable"* ]]
}

@test "accepting the prompt runs the upgrade once the session has ended" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -

  run cw_pty_script "${TESTDIR}/prefix/claude-work" n y -- issue-accept
  [[ "$output" == *"Upgrade claude-work to 9.9.9 now?"* ]]
  [[ "$output" == *"FAKE-INSTALL --require-checksum --prefix ${TESTDIR}/prefix"* ]]
}

@test "declining records the version and keeps the check interval" {
  stub_upgrade_curl
  install_copy_at "${TESTDIR}/prefix"
  claude_exits_after 1
  seed_cache 4242 9.9.9 -
  # An ancient timestamp is stale, so without a long interval the background
  # check would refetch mid-test and overwrite the very field being asserted.
  export CLAUDE_WORK_UPDATE_INTERVAL=9999999999

  run cw_pty_script "${TESTDIR}/prefix/claude-work" n n -- issue-decline
  [[ "$output" == *"Upgrade claude-work to 9.9.9 now?"* ]]
  [[ "$output" != *"FAKE-INSTALL"* ]]
  # Declined is remembered; the timestamp is untouched so declining does not
  # also postpone the next check.
  [ "$(cat "$CACHE_FILE")" = "4242 9.9.9 9.9.9" ]
}

@test "the notice goes to stderr, not stdout" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -

  # Still on a pty, so the tty gate is satisfied, but with the tool's stdout
  # sent to a file — so whatever arrives on the pty is what it wrote to stderr.
  run python3 "${CW_ROOT}/test/helpers/ptyrun.py" n n -- \
    "$CW_BASH" -c '"$0" "$1" issue-stderr >"$2"' \
    "$CW_BASH" "$CW_SCRIPT" "${TESTDIR}/stdout.txt"

  # The notice reached stderr...
  [[ "$output" == *"is available"* ]]
  # ...the redirect really was in effect...
  grep -q 'has ended' "${TESTDIR}/stdout.txt"
  # ...and the notice is not in the tool's own output.
  ! grep -q 'is available' "${TESTDIR}/stdout.txt"
}
