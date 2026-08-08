# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/bjornjohansen/claude-work/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bjornjohansen/claude-work/releases/tag/v0.1.0
