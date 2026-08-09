# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- `install.sh` did not validate `--version` or `--ref` before interpolating them into the download
  URL. curl resolves `../` in a path before sending the request, so a crafted value moved the
  download to an entirely different repository — and because the artifact and `SHA256SUMS` are
  fetched from the same base, both moved together and the installer reported `Checksum verified.`
  for an attacker-supplied file. Both options are now restricted to a safe character set with no
  `..`, and rejected before any request is made.
- `install.sh` treated a malformed or empty `SHA256SUMS` as verified. The verdict came from
  `sha*sum -c`, whose exit status is not usable for this: on macOS's `/sbin/sha256sum` an
  improperly formatted checksum line exits 0 with only a warning on stderr, which `sha_check`
  discarded, and an empty checksum file exits 0 as well. Both are what a truncated or tampered
  download looks like. The installer now requires a full 64-character hex entry for the file it
  actually downloaded and compares the hashes itself.

### Added

- `install.sh --require-checksum` fails instead of warning when no `sha256sum` or `shasum` is
  available to verify the download.
- `install.sh` is now published as a release asset and covered by `SHA256SUMS`, so it can be
  verified before it is run.

### Fixed

- `install.sh` replaced the installed command with `install`, which unlinks and recreates the
  target. That leaves a window where the command does not exist, and then one where it exists but
  is incompletely written; a concurrent `claude-work` can hit either. It now stages the new file
  under an unpredictable name in the target directory and renames it into place, which is atomic
  and lets an already-running copy keep reading the version it started with.
- `install.sh --uninstall` left the update-check cache behind.

## [0.2.2] - 2026-08-09

### Fixed

- `install.sh` gave install instructions for tools that were not missing. Any missing dependency
  triggered `Install git and tmux with: brew install git tmux`, so someone missing only `claude`
  was told to install two tools they already had. Instructions are now built from the actual set of
  missing tools, and the wording is singular when only one is missing.
- `claude-work` exited on the first missing command, so a run missing both `tmux` and `claude`
  reported only `tmux`. It now names every missing command in one go and, like the installer,
  offers install instructions for exactly those.

### Added

- `install.sh` detects the Linux package manager (apt, dnf, pacman, zypper) instead of always
  suggesting apt.
- When the installer runs as root under `sudo`, a missing-dependency warning now notes that the
  check saw root's `PATH`, so a per-user install of `claude` can look missing when it is not.
- Tests for the installer's dependency check (`test/install.bats`), which previously had none, and
  a CI assertion that an install on a runner with git present never suggests installing git.

### Security

- The suggested `sudo <package manager> install ...` command is now chosen by probing `/usr/bin`,
  `/bin`, `/usr/sbin` and `/sbin` directly instead of searching `PATH`. An executable planted in a
  user-writable `PATH` directory could otherwise decide the text of a command the user is being
  asked to paste into a root shell. `/usr/local/bin` is excluded because it is frequently
  user-writable.
- `SUDO_USER` is checked against the character set a username can contain before it is printed. It
  is an ordinary environment variable, so echoing it verbatim would let it carry terminal escape
  sequences into output that elsewhere reports things like a checksum mismatch.

## [0.2.1] - 2026-08-09

### Fixed

- The post-release smoke test piped `claude-work` into `grep` under `set -o pipefail`, so the
  command's intentional exit status 1 when printing usage failed the job even though the install
  had succeeded.

## [0.2.0] - 2026-08-09

### Added

- `install.sh` — one-line installer for macOS and Linux. Downloads a released build, verifies it
  against the `SHA256SUMS` published with that release, and installs to `/usr/local/bin` when
  writable or `~/.local/bin` otherwise. Supports `--version`, `--prefix`, `--modify-path`,
  `--uninstall` and `--dry-run`, and never escalates privileges on its own.
- Continuous integration: shellcheck, a 16-case bats suite on Linux and macOS, a dedicated job
  pinned to macOS `/bin/bash` so the documented bash 3.2 support is enforced, and an end-to-end
  `install.sh` run on both platforms.
- Tag-driven releases that publish the script and its `SHA256SUMS`, with release notes taken from
  this changelog and a post-release smoke test that installs the published artifact.
- `scripts/bump-version.sh` to move the version forward in the script and changelog together.

### Changed

- **Breaking:** `claude-work.sh` moved to `bin/claude-work`. The installed command is now
  `claude-work`, with no extension. Anyone running the script from a clone should use the new path
  or install it properly.

## [0.1.0] - 2026-08-09

### Added

- `claude-work.sh` — creates a git worktree and branch per issue slug, opens a tmux session running
  Claude Code in it, and offers cleanup when the session ends.
- Reuse of an existing worktree, branch or tmux session, so re-running the same command is safe.
- Detach vs. quit handling: detaching leaves the session running, quitting Claude Code triggers the
  cleanup prompt.
- `switch-client` handling when already inside tmux, instead of failing on a nested attach.
- Cleanup guards: warnings for uncommitted changes and for commits not on the branch's upstream, a
  second confirmation before a forced removal, and `git branch -d` so unmerged branches survive.
- Cleanup is skipped entirely when stdin is not a terminal, so nothing is deleted non-interactively.
- Slug validation restricting slugs to `[A-Za-z0-9._-]`, since the slug becomes a filesystem path, a
  git refname and a tmux target.
- `GIT_REMOTE` and `BRANCH_PREFIX` environment variables.
- Offline fallback to the local base branch, with a warning, when the remote cannot be fetched.

[Unreleased]: https://github.com/bjornjohansen/claude-work/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/bjornjohansen/claude-work/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/bjornjohansen/claude-work/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/bjornjohansen/claude-work/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bjornjohansen/claude-work/releases/tag/v0.1.0
