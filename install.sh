#!/bin/sh
#
# install.sh — install the claude-work command
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/bjornjohansen/claude-work/main/install.sh | bash
#
# Inspect first (recommended):
#   curl -fsSL https://raw.githubusercontent.com/bjornjohansen/claude-work/main/install.sh -o install.sh
#   less install.sh
#   sh install.sh
#
# This is POSIX sh on purpose: it has to run under dash, busybox ash and the
# bash 3.2 that ships with macOS. The tool it installs requires bash; this
# script does not.
#
# Everything lives in functions and main() is called on the very last line, so
# a download truncated mid-transfer defines some functions and then does
# nothing, rather than executing half an installer.

set -eu

REPO="bjornjohansen/claude-work"
BIN_NAME="claude-work"
RELEASE_BASE="https://github.com/${REPO}/releases"
RAW_BASE="https://raw.githubusercontent.com/${REPO}"
PATH_MARKER="# added by claude-work install.sh"

TMPDIR_CW=""

# --- output helpers -------------------------------------------------------

info() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
err() { printf 'Error: %s\n' "$*" >&2; }

die() {
  err "$*"
  exit 1
}

cleanup() {
  [ -n "$TMPDIR_CW" ] && [ -d "$TMPDIR_CW" ] && rm -rf "$TMPDIR_CW"
  return 0
}

usage() {
  cat <<EOF
Install the ${BIN_NAME} command.

Usage: install.sh [options]

Options:
  --version X.Y.Z   Install a specific release (default: latest)
  --ref REF         Install straight from a git ref (branch, tag or SHA).
                    For testing unreleased code — skips checksum verification.
  --prefix DIR      Install into DIR (default: /usr/local/bin if writable,
                    otherwise \$HOME/.local/bin)
  --modify-path     Append the install dir to your shell rc file if it is not
                    already on PATH. Off by default.
  --uninstall       Remove an installed ${BIN_NAME} and exit
  --dry-run         Report what would happen without changing anything
  -h, --help        Show this help

Environment:
  CLAUDE_WORK_INSTALL_DIR   Same as --prefix

Examples:
  curl -fsSL .../install.sh | bash
  curl -fsSL .../install.sh | bash -s -- --version 0.2.0
  curl -fsSL .../install.sh | bash -s -- --prefix ~/bin --modify-path
EOF
}

# --- environment probing --------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Echo a command that downloads \$1 to \$2, honouring whichever fetcher exists.
download() {
  url="$1"
  dest="$2"
  if have curl; then
    # --fail so an HTML 404 page is never written out as if it were the tool.
    curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  elif have wget; then
    wget -qO "$dest" "$url"
  else
    die "need curl or wget to download ${BIN_NAME}"
  fi
}

# sha256sum on Linux, shasum on macOS. Both read the same checksum format.
sha_check() {
  if have sha256sum; then
    sha256sum -c "$1" >/dev/null 2>&1
  elif have shasum; then
    shasum -a 256 -c "$1" >/dev/null 2>&1
  else
    return 2
  fi
}

script_version() {
  [ -f "$1" ] || return 1
  sed -n 's/^# Version:[[:space:]]*//p' "$1" | head -n 1
}

on_path() {
  case ":${PATH}:" in
  *":$1:"*) return 0 ;;
  *) return 1 ;;
  esac
}

# Best guess at the rc file for the user's login shell.
rc_file() {
  shell_name=$(basename "${SHELL:-/bin/sh}")
  case "$shell_name" in
  zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash)
    # macOS login shells read .bash_profile; Linux reads .bashrc.
    if [ "$(uname -s)" = "Darwin" ]; then
      printf '%s\n' "$HOME/.bash_profile"
    else
      printf '%s\n' "$HOME/.bashrc"
    fi
    ;;
  *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

# True if $1 exists as an executable in one of the system binary directories.
# Deliberately not `have`: PATH is user-controlled, and the caller uses this to
# decide the text of a sudo command.
system_bin() {
  # /usr/local/bin is intentionally absent: it is frequently user-writable —
  # this installer writes there without sudo when it can.
  for d in /usr/bin /bin /usr/sbin /sbin; do
    [ -x "${d}/$1" ] && return 0
  done
  return 1
}

# Echo the command that installs the given packages ($1, space separated) with
# the system package manager, or nothing if we have no sensible suggestion.
pkg_install_cmd() {
  case "$(uname -s)" in
  Darwin) printf 'brew install %s\n' "$1" ;;
  Linux)
    # Probed at absolute paths rather than through PATH: this text is a command
    # we are asking someone to paste into a root shell, so a stray executable
    # named "dnf" in a writable PATH directory must not get to choose it.
    #
    # apt is the fallback rather than a probe: it covers Debian/Ubuntu, which is
    # the common case, and a wrong-but-obvious hint beats no hint at all.
    if system_bin dnf; then
      printf 'sudo dnf install %s\n' "$1"
    elif system_bin pacman; then
      printf 'sudo pacman -S %s\n' "$1"
    elif system_bin zypper; then
      printf 'sudo zypper install %s\n' "$1"
    else
      printf 'sudo apt install %s\n' "$1"
    fi
    ;;
  esac
}

resolve_target_dir() {
  if [ -n "$OPT_PREFIX" ]; then
    printf '%s\n' "$OPT_PREFIX"
  elif [ -w /usr/local/bin ]; then
    printf '%s\n' /usr/local/bin
  else
    printf '%s\n' "$HOME/.local/bin"
  fi
}

# --- actions --------------------------------------------------------------

# Under sudo the probes below see root's PATH, not the invoking user's, so a
# per-user install of claude (npm, nvm, ~/.local/bin) looks missing when it is
# not. Say so rather than sending the user off to reinstall something they have.
root_path_note() {
  [ "$(id -u)" = "0" ] || return 0
  [ -n "${SUDO_USER:-}" ] || return 0

  # SUDO_USER is an ordinary environment variable, not a fact. Anything that is
  # not shaped like a username is not echoed back: it could otherwise smuggle
  # terminal escapes into output that elsewhere carries lines like
  # "checksum mismatch".
  case "$SUDO_USER" in
  *[!A-Za-z0-9._-]*) who="the invoking user" ;;
  *) who="$SUDO_USER" ;;
  esac

  info ""
  info "  Note: this check ran as root, so tools installed for ${who} may not"
  info "  be visible here. If they work in your own shell, you can ignore this."
}

# Only ever give instructions for the tools that are actually missing — telling
# someone to install git when git is present is how this message gets misread.
check_runtime_deps() {
  missing=""
  pkgs=""
  for dep in git tmux claude; do
    have "$dep" && continue
    missing="${missing}${missing:+ }${dep}"
    # git and tmux come from the system package manager; claude does not.
    case "$dep" in
    git | tmux) pkgs="${pkgs}${pkgs:+ }${dep}" ;;
    esac
  done
  [ -z "$missing" ] && return 0

  case "$missing" in
  *" "*) warn "${BIN_NAME} needs these at runtime, but they are not on your PATH: ${missing}" ;;
  *) warn "${BIN_NAME} needs ${missing} at runtime, but it is not on your PATH." ;;
  esac

  if [ -n "$pkgs" ]; then
    cmd=$(pkg_install_cmd "$pkgs")
    [ -n "$cmd" ] && info "  Install with:             ${cmd}"
  fi

  # Delimited match, so this cannot be triggered by some other dep whose name
  # merely contains "claude".
  case " ${missing} " in
  *" claude "*) info "  Install Claude Code from: https://claude.com/claude-code" ;;
  esac

  root_path_note
}

do_uninstall() {
  found=""
  # Split on newline only, so a prefix containing spaces survives, and iterate
  # in the current shell — piping into `while` would hide `found` in a subshell.
  old_ifs=$IFS
  IFS='
'
  set -f
  for dir in $(printf '%s\n%s\n%s\n%s\n' \
    "${OPT_PREFIX:-}" /usr/local/bin "$HOME/.local/bin" "$HOME/bin"); do
    if [ -f "${dir}/${BIN_NAME}" ]; then
      found="${dir}/${BIN_NAME}"
      if [ "$OPT_DRY_RUN" = "yes" ]; then
        info "Would remove ${found}"
      elif rm -f "$found" 2>/dev/null; then
        info "Removed ${found}"
      else
        die "could not remove ${found} — try: sudo rm ${found}"
      fi
    fi
  done
  set +f
  IFS=$old_ifs
  [ -n "$found" ] || info "No installed ${BIN_NAME} found."
}

report_path_situation() {
  target_dir="$1"
  on_path "$target_dir" && return 0

  rc=$(rc_file)
  line="export PATH=\"${target_dir}:\$PATH\""

  if [ "$OPT_MODIFY_PATH" = "yes" ]; then
    if [ -f "$rc" ] && grep -Fq "$PATH_MARKER" "$rc" 2>/dev/null; then
      info "PATH entry already present in ${rc}."
    else
      printf '\n%s\n%s\n' "$PATH_MARKER" "$line" >>"$rc"
      info "Added ${target_dir} to PATH in ${rc}."
      info "Run 'exec \$SHELL' or open a new terminal to pick it up."
    fi
    return 0
  fi

  warn "${target_dir} is not on your PATH."
  info "Add it by running:"
  info ""
  info "  echo '${line}' >> ${rc}"
  info ""
  info "or re-run this installer with --modify-path."
}

warn_if_shadowed() {
  installed="$1"
  resolved=$(command -v "$BIN_NAME" 2>/dev/null || true)
  [ -n "$resolved" ] || return 0
  [ "$resolved" = "$installed" ] && return 0
  warn "another ${BIN_NAME} earlier on your PATH will win: ${resolved}"
}

fetch_binary() {
  dest="$1"

  if [ -n "$OPT_REF" ]; then
    warn "installing from ref '${OPT_REF}' — checksum verification is skipped"
    download "${RAW_BASE}/${OPT_REF}/bin/${BIN_NAME}" "$dest" ||
      die "could not download ${BIN_NAME} at ref ${OPT_REF}"
    return 0
  fi

  if [ -n "$OPT_VERSION" ]; then
    base="${RELEASE_BASE}/download/v${OPT_VERSION#v}"
  else
    base="${RELEASE_BASE}/latest/download"
  fi

  download "${base}/${BIN_NAME}" "$dest" ||
    die "could not download ${BIN_NAME} from ${base}"

  sums="${TMPDIR_CW}/SHA256SUMS"
  if ! download "${base}/SHA256SUMS" "$sums"; then
    die "could not download SHA256SUMS from ${base} — refusing to install unverified"
  fi

  # sha*sum -c resolves filenames relative to the working directory.
  # `|| rc=$?` keeps this a condition context, so `set -e` cannot abort us
  # before the mismatch message below is printed.
  rc=0
  (
    cd "$TMPDIR_CW" || exit 1
    sha_check SHA256SUMS
  ) || rc=$?
  case $rc in
  0) info "Checksum verified." ;;
  2) warn "no sha256sum or shasum available — could not verify the download" ;;
  *) die "checksum mismatch — refusing to install ${BIN_NAME}" ;;
  esac
}

install_binary() {
  target_dir="$1"
  src="$2"
  target="${target_dir}/${BIN_NAME}"

  new_version=$(script_version "$src" || true)
  [ -n "$new_version" ] || die "downloaded file does not look like ${BIN_NAME} (no version header)"

  old_version=$(script_version "$target" 2>/dev/null || true)
  if [ -n "$old_version" ]; then
    if [ "$old_version" = "$new_version" ]; then
      info "${BIN_NAME} ${new_version} is already installed at ${target}."
    else
      info "Upgrading ${BIN_NAME} ${old_version} -> ${new_version} in ${target_dir}."
    fi
  else
    info "Installing ${BIN_NAME} ${new_version} into ${target_dir}."
  fi

  if [ "$OPT_DRY_RUN" = "yes" ]; then
    info "Dry run — nothing written."
    return 0
  fi

  mkdir -p "$target_dir" 2>/dev/null ||
    die "could not create ${target_dir}"
  install -m 0755 "$src" "$target" 2>/dev/null ||
    die "could not write ${target} — try 'sudo sh install.sh' or --prefix DIR"

  info "Installed ${target}"
  report_path_situation "$target_dir"
  warn_if_shadowed "$target"
}

# --- main -----------------------------------------------------------------

main() {
  OPT_VERSION=""
  OPT_REF=""
  OPT_PREFIX="${CLAUDE_WORK_INSTALL_DIR:-}"
  OPT_MODIFY_PATH="no"
  OPT_UNINSTALL="no"
  OPT_DRY_RUN="no"

  while [ $# -gt 0 ]; do
    case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version needs a value"
      OPT_VERSION="$2"
      shift 2
      ;;
    --ref)
      [ $# -ge 2 ] || die "--ref needs a value"
      OPT_REF="$2"
      shift 2
      ;;
    --prefix)
      [ $# -ge 2 ] || die "--prefix needs a value"
      OPT_PREFIX="$2"
      shift 2
      ;;
    --modify-path)
      OPT_MODIFY_PATH="yes"
      shift
      ;;
    --uninstall)
      OPT_UNINSTALL="yes"
      shift
      ;;
    --dry-run)
      OPT_DRY_RUN="yes"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
    esac
  done

  if [ -n "$OPT_VERSION" ] && [ -n "$OPT_REF" ]; then
    die "--version and --ref are mutually exclusive"
  fi

  if [ "$OPT_UNINSTALL" = "yes" ]; then
    do_uninstall
    exit 0
  fi

  case "$(uname -s)" in
  Darwin | Linux) ;;
  *) warn "untested platform: $(uname -s). ${BIN_NAME} needs a Unix-like system with tmux." ;;
  esac

  have bash || warn "bash was not found on PATH — ${BIN_NAME} requires bash to run"

  trap cleanup EXIT INT TERM
  TMPDIR_CW=$(mktemp -d 2>/dev/null) || die "could not create a temporary directory"

  staged="${TMPDIR_CW}/${BIN_NAME}"
  fetch_binary "$staged"
  chmod 0755 "$staged"

  install_binary "$(resolve_target_dir)" "$staged"
  check_runtime_deps
}

main "$@"
