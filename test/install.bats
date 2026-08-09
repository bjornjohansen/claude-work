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

# --- --version / --ref must not be able to move the download ----------------
#
# Both are interpolated into the download URL, and curl resolves "../" in a path
# before sending — so an unvalidated value picks a different *repository*, not
# just a different file. The artifact and SHA256SUMS come from the same base, so
# both move together and the checksum would verify an attacker's file against an
# attacker's checksum. Each case asserts the installer dies before curl runs at
# all, which is why the stub records every invocation.

# A curl stub that logs its arguments; $CURL_LOG must not exist afterwards.
stub_logging_curl() {
  CURL_LOG="${TESTDIR}/curl.log"
  make_stub curl "printf '%s\n' \"\$*\" >>'${CURL_LOG}'; exit 1"
}

# Run the real installer with the logging curl on PATH.
run_installer() {
  run env PATH="${STUB}:${PATH}" sh "$INSTALL_SH" "$@" --prefix "${TESTDIR}/out"
}

@test "--version rejects path traversal before making any request" {
  stub_logging_curl
  run_installer --version 'x/../../../evil-owner/evil-repo/main/install.sh?'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --version"* ]]
  [ ! -e "$CURL_LOG" ]
}

@test "--version rejects a value that is not plain digits and dots" {
  stub_logging_curl
  run_installer --version '1.2.3;id'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --version"* ]]
  [ ! -e "$CURL_LOG" ]
}

@test "--ref rejects path traversal before making any request" {
  stub_logging_curl
  run_installer --ref '../../evil-owner/evil-repo/main'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --ref"* ]]
  [ ! -e "$CURL_LOG" ]
}

# --modify-path writes the prefix into a shell startup file inside double
# quotes, and both branches of report_path_situation show it to the user.
# Anything able to close that quote is arbitrary code in every login shell from
# then on, which this proves is rejected before it can be written.
@test "--prefix rejects values that could break out of the shell rc line" {
  local bad
  for bad in '/tmp/x";touch /tmp/pwned;echo "' '/tmp/$(id)' '/tmp/`id`' '/tmp/a\b' "/tmp/it's"; do
    stub_logging_curl
    run env PATH="${STUB}:${PATH}" sh "$INSTALL_SH" --modify-path --prefix "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid --prefix"* ]]
    [ ! -e "$CURL_LOG" ]
  done
}

@test "--prefix still accepts an ordinary path containing spaces" {
  stub_release_curl
  real_sums
  run env PATH="${STUB}:${PATH}" sh "$INSTALL_SH" --version 0.2.2 --prefix "${TESTDIR}/my bin"
  [ "$status" -eq 0 ]
  [ -x "${TESTDIR}/my bin/claude-work" ]
}

# A flag whose whole purpose is "fail rather than warn when verification is
# impossible" must never be silently inert. --ref installs are unverified by
# design, so the combination is refused rather than ignored.
@test "--require-checksum refuses to be combined with --ref" {
  stub_logging_curl
  run env PATH="${STUB}:${PATH}" sh "$INSTALL_SH" --require-checksum --ref main --prefix "${TESTDIR}/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be used with --ref"* ]]
  [ ! -e "$CURL_LOG" ]
}

@test "a plain version is accepted and does reach the download" {
  stub_logging_curl
  run_installer --version 0.2.2
  [[ "$output" != *"invalid --version"* ]]
  [ -e "$CURL_LOG" ]
  grep -q 'releases/download/v0.2.2/claude-work' "$CURL_LOG"
}

# --- checksum verification --------------------------------------------------
#
# sha*sum -c is not used to decide this: on macOS's /sbin/sha256sum a malformed
# checksum line exits 0 with only a warning on stderr, and so does an empty
# checksum file. Both are exactly what a truncated or tampered SHA256SUMS looks
# like, so the verdict comes from comparing the hashes as strings instead.

# Serve a fake release from $CW_REL_DIR via a curl stub. The stub reads that
# directory from the environment rather than having it baked in, so the body can
# be a fully quoted heredoc with no escaping to get wrong.
stub_release_curl() {
  export CW_REL_DIR="${TESTDIR}/rel"
  mkdir -p "$CW_REL_DIR"
  printf '#!/usr/bin/env bash\n# Version: 0.2.2\necho hi\n' >"${CW_REL_DIR}/claude-work"
  printf '#!/bin/sh\n: installer\n' >"${CW_REL_DIR}/install.sh"

  cat >"${STUB}/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
f=$(basename "${url%%\?*}")
[ -f "${CW_REL_DIR}/$f" ] || exit 22
cat "${CW_REL_DIR}/$f" >"$out"
EOF
  chmod +x "${STUB}/curl"
}

# Regenerate SHA256SUMS covering every published asset, as release.yml does.
real_sums() {
  (cd "$CW_REL_DIR" && shasum -a 256 claude-work install.sh >SHA256SUMS)
}

@test "a valid multi-asset SHA256SUMS verifies and installs" {
  stub_release_curl
  real_sums
  run_installer --version 0.2.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checksum verified."* ]]
  [ -x "${TESTDIR}/out/claude-work" ]
}

@test "a malformed (short) checksum line is refused, not treated as verified" {
  stub_release_curl
  printf 'deadbeef  claude-work\ndeadbeef  install.sh\n' >"${CW_REL_DIR}/SHA256SUMS"
  run_installer --version 0.2.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable entry for claude-work"* ]]
  [ ! -e "${TESTDIR}/out/claude-work" ]
}

@test "an empty SHA256SUMS is refused, not treated as verified" {
  stub_release_curl
  : >"${CW_REL_DIR}/SHA256SUMS"
  run_installer --version 0.2.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable entry for claude-work"* ]]
  [ ! -e "${TESTDIR}/out/claude-work" ]
}

@test "a well-formed but wrong checksum is refused" {
  stub_release_curl
  printf '%064d  claude-work\n' 0 >"${CW_REL_DIR}/SHA256SUMS"
  run_installer --version 0.2.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "${TESTDIR}/out/claude-work" ]
}

@test "SHA256SUMS covering only other assets is refused" {
  stub_release_curl
  (cd "$CW_REL_DIR" && shasum -a 256 install.sh >SHA256SUMS)
  run_installer --version 0.2.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable entry for claude-work"* ]]
}

@test "--require-checksum turns an unverifiable download into a failure" {
  run env PATH="${STUB}:${PATH}" "$BASH_BIN" -c '
    . "$1"
    TMPDIR_CW=$(mktemp -d); OPT_REF=""; OPT_VERSION="0.2.2"; OPT_REQUIRE_CHECKSUM="yes"
    have() { case "$1" in sha256sum | shasum) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }
    # A well-formed SHA256SUMS entry, so the run reaches the hashing step
    # instead of stopping at the entry check. The value is irrelevant: with no
    # hashing tool there is nothing to compare it against.
    download() { case "$2" in *SHA256SUMS) printf "%064d  claude-work\n" 0 > "$2" ;; *) printf "x\n" > "$2" ;; esac; }
    fetch_binary "${TMPDIR_CW}/claude-work" 2>&1
  ' _ "$SOURCEABLE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot verify the download"* ]]
}

@test "without --require-checksum an unverifiable download only warns" {
  run env PATH="${STUB}:${PATH}" "$BASH_BIN" -c '
    . "$1"
    TMPDIR_CW=$(mktemp -d); OPT_REF=""; OPT_VERSION="0.2.2"; OPT_REQUIRE_CHECKSUM="no"
    have() { case "$1" in sha256sum | shasum) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }
    # A well-formed SHA256SUMS entry, so the run reaches the hashing step
    # instead of stopping at the entry check. The value is irrelevant: with no
    # hashing tool there is nothing to compare it against.
    download() { case "$2" in *SHA256SUMS) printf "%064d  claude-work\n" 0 > "$2" ;; *) printf "x\n" > "$2" ;; esac; }
    fetch_binary "${TMPDIR_CW}/claude-work" 2>&1
  ' _ "$SOURCEABLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify the download"* ]]
}

# --- the binary is replaced by rename, not rewritten in place ---------------

@test "installing over an existing copy replaces the inode" {
  stub_release_curl
  real_sums
  mkdir -p "${TESTDIR}/out"
  printf '#!/usr/bin/env bash\n# Version: 0.0.1\n' >"${TESTDIR}/out/claude-work"
  chmod +x "${TESTDIR}/out/claude-work"
  ln "${TESTDIR}/out/claude-work" "${TESTDIR}/out/hardlink"
  local before after
  before=$(ls -i "${TESTDIR}/out/claude-work" | awk '{print $1}')

  run_installer --version 0.2.2
  [ "$status" -eq 0 ]

  after=$(ls -i "${TESTDIR}/out/claude-work" | awk '{print $1}')
  [ "$before" != "$after" ]
  # A copy already open elsewhere keeps reading the bytes it started with.
  grep -q '0.0.1' "${TESTDIR}/out/hardlink"
  # And nothing is left staged in the install directory.
  [ -z "$(find "${TESTDIR}/out" -name '.claude-work.*' -print -quit)" ]
}
