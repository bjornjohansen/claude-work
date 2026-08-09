#!/usr/bin/env bats
#
# Tests for install.sh's runtime dependency check.
#
# The point of these cases is the defect that prompted them: the installer used
# to print "Install git and tmux with: brew install git tmux" whenever *any*
# dependency was missing, so a user missing only `claude` was told to install
# two tools they already had. Every case below therefore asserts on what is
# *absent* from the message as much as what is present.
#
# Each test runs check_runtime_deps against a PATH containing nothing but
# purpose-built stubs — including `uname` and `id` — so the results do not
# depend on what the machine running the suite happens to have installed, and
# both the macOS and Linux branches are exercised on either runner.

CW_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
INSTALL_SH="${CW_ROOT}/install.sh"

setup() {
  TESTDIR="$(mktemp -d)"
  STUB="${TESTDIR}/bin"
  mkdir -p "$STUB"

  # env replaces PATH before it resolves the command, so bash must be absolute.
  BASH_BIN="$(command -v bash)"

  # install.sh calls main() on its very last line. Strip that line to get a
  # sourceable copy of just the functions — deliberately done here rather than
  # with a "don't run main" switch inside install.sh, because the shipped
  # installer should carry no way to turn itself into a silent no-op. The
  # last-line assumption is itself asserted below.
  SOURCEABLE="${TESTDIR}/install-functions.sh"
  sed '$d' "$INSTALL_SH" >"$SOURCEABLE"

  stub_uname Darwin
  stub_id 1000
}

teardown() {
  cd / || true
  [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
  return 0
}

# --- stub helpers -----------------------------------------------------------

# An executable stub named $1 whose body is $2 (a no-op by default — presence on
# PATH is all `command -v` cares about).
make_stub() {
  printf '#!/bin/sh\n%s\n' "${2:-:}" >"${STUB}/$1"
  chmod +x "${STUB}/$1"
}

stub_uname() { make_stub uname "printf '%s\\n' '$1'"; }
stub_id() { make_stub id "printf '%s\\n' '$1'"; }

# Make each named command look installed.
present() {
  local dep
  for dep in "$@"; do make_stub "$dep"; done
}

# Run check_runtime_deps with the stub PATH. Leading VAR=value arguments are
# added to the environment.
check_deps() {
  run env -u SUDO_USER PATH="$STUB" "$@" "$BASH_BIN" -c \
    '. "$1"; check_runtime_deps 2>&1' _ "$SOURCEABLE"
}

# --- only the missing tools get instructions --------------------------------

@test "only claude missing: says claude, does not mention git or tmux" {
  present git tmux
  check_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs claude at runtime, but it is not on your PATH."* ]]
  [[ "$output" == *"https://claude.com/claude-code"* ]]
  [[ "$output" != *"Install with:"* ]]
  [[ "$output" != *"brew"* ]]
  [[ "$output" != *"git"* ]]
  [[ "$output" != *"tmux"* ]]
}

@test "only tmux missing: says tmux, does not mention git or Claude Code" {
  present git claude
  check_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs tmux at runtime, but it is not on your PATH."* ]]
  [[ "$output" == *"Install with:"*"brew install tmux"* ]]
  [[ "$output" != *"git"* ]]
  [[ "$output" != *"claude.com"* ]]
}

@test "only git missing: says git, does not mention tmux or Claude Code" {
  present tmux claude
  check_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs git at runtime, but it is not on your PATH."* ]]
  [[ "$output" == *"Install with:"*"brew install git"* ]]
  [[ "$output" != *"tmux"* ]]
  [[ "$output" != *"claude.com"* ]]
}

@test "tmux and claude missing: both instructions, still no git" {
  present git
  check_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs these at runtime, but they are not on your PATH: tmux claude"* ]]
  [[ "$output" == *"brew install tmux"* ]]
  [[ "$output" == *"https://claude.com/claude-code"* ]]
  [[ "$output" != *"install git"* ]]
  [[ "$output" != *"git tmux"* ]]
}

@test "all three missing: one package line for git and tmux, plus Claude Code" {
  check_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"not on your PATH: git tmux claude"* ]]
  [[ "$output" == *"brew install git tmux"* ]]
  [[ "$output" == *"https://claude.com/claude-code"* ]]
}

@test "nothing missing: no output at all" {
  present git tmux claude
  check_deps
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- package manager detection ----------------------------------------------

@test "linux always suggests a package manager command" {
  stub_uname Linux
  present git claude
  check_deps
  [[ "$output" == *"Install with:"*"sudo "*"tmux"* ]]
}

# The suggestion is a command we ask someone to paste into a root shell, so it
# is chosen by probing absolute system paths, never PATH.
@test "system_bin ignores PATH and looks in the system directories" {
  present notarealpackagemanager
  run env -u SUDO_USER PATH="$STUB" "$BASH_BIN" -c '
    . "$1"
    system_bin sh || { echo "did not find /bin/sh"; exit 1; }
    system_bin notarealpackagemanager && { echo "a PATH stub was accepted"; exit 1; }
    echo ok' _ "$SOURCEABLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "a package manager planted on PATH cannot change the suggestion" {
  stub_uname Linux
  present git claude
  check_deps
  local baseline="$output"

  present dnf pacman zypper
  check_deps
  [ "$output" = "$baseline" ]
}

@test "unknown platform gives no package manager line" {
  stub_uname OpenBSD
  present git claude
  check_deps
  [[ "$output" == *"needs tmux at runtime"* ]]
  [[ "$output" != *"Install with:"* ]]
}

# --- the sudo case that produced the original report ------------------------

@test "running as root under sudo explains that the check saw root's PATH" {
  stub_id 0
  present git tmux
  check_deps SUDO_USER=someuser
  [ "$status" -eq 0 ]
  [[ "$output" == *"this check ran as root"* ]]
  [[ "$output" == *"someuser"* ]]
}

@test "root without SUDO_USER gets no note" {
  stub_id 0
  present git tmux
  check_deps
  [[ "$output" != *"ran as root"* ]]
}

# SUDO_USER is just an environment variable. Echoing it back verbatim would let
# it carry terminal escapes into output that elsewhere says "checksum mismatch".
@test "a SUDO_USER that is not shaped like a username is not echoed back" {
  stub_id 0
  present git tmux
  local evil=$'bob\e[2K\rInstalled /usr/local/bin/claude-work'
  check_deps "SUDO_USER=${evil}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran as root"* ]]
  [[ "$output" == *"the invoking user"* ]]
  [[ "$output" != *"Installed"* ]]
}

@test "non-root gets no note even with SUDO_USER set" {
  present git tmux
  check_deps SUDO_USER=someuser
  [[ "$output" != *"ran as root"* ]]
}

# --- the installer itself still behaves -------------------------------------

# setup() strips the last line to source the functions. If that line ever stops
# being the main() call, these tests would silently test nothing.
@test "the line stripped for sourcing is the main() call" {
  [ "$(tail -n 1 "$INSTALL_SH")" = 'main "$@"' ]
}

@test "install.sh still runs normally" {
  run sh "$INSTALL_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: install.sh"* ]]
}

# install.sh and bin/claude-work duplicate this logic because neither can source
# a shared file — the installer is delivered by `curl | sh` and the tool is a
# single script. Nothing but this test stops the two from drifting apart.
@test "the tool and the installer give identical instructions" {
  local from_installer from_tool

  check_deps
  from_installer=$(printf '%s\n' "$output" | grep '^  Install')

  run env -u SUDO_USER PATH="$STUB" "$BASH_BIN" "${CW_ROOT}/bin/claude-work" some-slug
  [ "$status" -eq 1 ]
  from_tool=$(printf '%s\n' "$output" | grep '^  Install')

  [ -n "$from_installer" ]
  [ "$from_installer" = "$from_tool" ]
}
