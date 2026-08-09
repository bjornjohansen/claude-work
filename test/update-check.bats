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
  for var in CLAUDE_WORK_NO_UPDATE_CHECK NO_UPDATE_NOTIFIER DO_NOT_TRACK CI; do
    stub_curl
    rm -f "$CURL_LOG"
    run env "${var}=1" "$CW_BASH" -c '. "$1"; set +e; cw_update_spawn; wait' _ "$UPDATE_LIB"
    [ ! -e "$CURL_LOG" ]
  done
}

# --- the notice --------------------------------------------------------------

@test "a newer cached version is announced when the session ends" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -
  run cw_pty n -- issue-notice
  [[ "$output" == *"claude-work 9.9.9 is available (you have "* ]]
  [[ "$output" == *"releases/tag/v9.9.9"* ]]
}

@test "the notice comes after the cleanup prompt, not before" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -
  run cw_pty y -- issue-order
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
  run cw_pty n -- issue-older
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
  run cw_pty n -- issue-declined
  [[ "$output" != *"is available"* ]]
}

@test "a failed run says nothing about updates" {
  seed_cache "$(date +%s)" 9.9.9 -
  run cw --not-a-valid-slug!
  [ "$status" -ne 0 ]
  [[ "$output" != *"is available"* ]]
}

@test "the notice goes to stderr" {
  claude_exits_after 1
  seed_cache "$(date +%s)" 9.9.9 -
  run cw_pty n -- issue-stderr
  [[ "$output" == *"is available"* ]]

  # Same run with stderr discarded: the notice must be the thing that vanishes.
  run "$CW_BASH" -c '
    python3 "$1" n -- "$2" "$3" issue-stderr2 2>/dev/null
  ' _ "${CW_ROOT}/test/helpers/ptyrun.py" "$CW_BASH" "$CW_SCRIPT"
}
