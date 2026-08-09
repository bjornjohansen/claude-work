#!/usr/bin/env bats
#
# These cases mirror the defects found in the code review that produced this
# script: worktree state detected by directory existence rather than the git
# registry, worktree names nesting when run from inside a worktree, `set -e`
# aborting on `read` with no tty, and errors swallowed by 2>/dev/null.

load helpers/common

setup() {
  setup_fixture
}

teardown() {
  teardown_fixture
}

# --- argument and slug validation -----------------------------------------

@test "no arguments prints usage and exits 1" {
  run cw
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: claude-work <issue-slug>"* ]]
}

@test "rejects slugs that are unsafe as a path, refname or tmux target" {
  for slug in "../evil" "a:b" "a..b" "-lead" ".hidden" "has space"; do
    run cw "$slug"
    [ "$status" -eq 1 ]
    [[ "$output" == *"slug must start with a letter or digit"* ]]
  done
  # Nothing may be created as a side effect of a rejected slug.
  run find "$TESTDIR" -maxdepth 1 -name "${REPO_NAME}-*"
  [ -z "$output" ]
}

@test "accepts a slug containing dots, dashes and underscores" {
  run cw "issue_1.2-b"
  [ -d "${TESTDIR}/${REPO_NAME}-issue_1.2-b" ]
}

@test "names every missing command, and only instructs on those" {
  # A PATH with git but neither tmux nor claude, built from stubs so the result
  # does not depend on what the machine running the tests has installed. `uname`
  # is needed because the message picks a package manager.
  local stub="${TESTDIR}/depstub"
  mkdir -p "$stub"
  printf '#!/bin/sh\n:\n' >"${stub}/git"
  printf '#!/bin/sh\necho Darwin\n' >"${stub}/uname"
  chmod +x "${stub}/git" "${stub}/uname"

  run env PATH="$stub" "$(command -v "$CW_BASH")" "$CW_SCRIPT" some-slug
  [ "$status" -eq 1 ]
  # Both missing commands named in one run, not just the first one found.
  [[ "$output" == *"not on your PATH: tmux claude"* ]]
  [[ "$output" == *"brew install tmux"* ]]
  [[ "$output" == *"https://claude.com/claude-code"* ]]
  # git is present, so it must not turn up in the instructions.
  [[ "$output" != *"install git"* ]]
}

# --- worktree creation ------------------------------------------------------

# The script attaches to tmux as its last act, which fails without a controlling
# terminal, so these assert on the worktree side effects rather than exit status.

@test "creates a worktree and branch off the remote base branch" {
  run cw issue-1
  [ -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
  run git -C "${TESTDIR}/${REPO_NAME}-issue-1" rev-parse --abbrev-ref HEAD
  [ "$output" = "fix/issue-1" ]

  expected="$(git -C "$REPO_DIR" rev-parse origin/main)"
  actual="$(git -C "${TESTDIR}/${REPO_NAME}-issue-1" rev-parse HEAD)"
  [ "$actual" = "$expected" ]
}

@test "honours BRANCH_PREFIX" {
  BRANCH_PREFIX=feat run cw issue-1
  run git -C "${TESTDIR}/${REPO_NAME}-issue-1" rev-parse --abbrev-ref HEAD
  [ "$output" = "feat/issue-1" ]
}

@test "reuses an existing registered worktree" {
  cw issue-1 || true
  run cw issue-1
  [[ "$output" == *"reusing it"* ]]
}

@test "refuses a directory that is not a registered worktree" {
  mkdir -p "${TESTDIR}/${REPO_NAME}-foreign"
  touch "${TESTDIR}/${REPO_NAME}-foreign/keepme"
  run cw foreign
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a registered worktree"* ]]
  # The directory and its contents must be left untouched.
  [ -f "${TESTDIR}/${REPO_NAME}-foreign/keepme" ]
}

@test "recovers when a registered worktree directory was deleted by hand" {
  cw issue-1 || true
  rm -rf "${TESTDIR}/${REPO_NAME}-issue-1"
  run cw issue-1
  [ -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
  [[ "$output" != *"already registered"* ]]
}

@test "does not nest worktree names when run from inside a worktree" {
  cw issue-1 || true
  cd "${TESTDIR}/${REPO_NAME}-issue-1"
  run cw issue-2
  [ -d "${TESTDIR}/${REPO_NAME}-issue-2" ]
  [ ! -d "${TESTDIR}/${REPO_NAME}-issue-1-issue-2" ]
}

# --- base branch resolution -------------------------------------------------

@test "fails clearly when the base branch cannot be resolved" {
  run cw issue-1 nosuchbranch
  [ "$status" -eq 1 ]
  [[ "$output" == *"nor a local nosuchbranch"* ]]
  [ ! -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
}

@test "falls back to the local base branch when the remote is unreachable" {
  run env GIT_REMOTE=nosuchremote "$CW_BASH" "$CW_SCRIPT" issue-1
  [[ "$output" == *"branching off local main"* ]]
  [ -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
}

# --- cleanup ----------------------------------------------------------------

@test "a non-interactive run never destroys the worktree or branch" {
  # Exit status is not asserted: without a controlling terminal the script dies
  # at `tmux attach` before cleanup is ever offered. The property that matters
  # is that a run with no tty cannot delete anything, whichever way it exits.
  claude_exits_after 1
  cw issue-1 </dev/null || true
  sleep 3
  run cw issue-1 </dev/null
  [ -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
  run git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/fix/issue-1
  [ "$status" -eq 0 ]
}

@test "removes a clean worktree and deletes its branch when confirmed" {
  claude_exits_after 1
  run cw_pty y -- issue-1
  [ ! -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
  run git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/fix/issue-1
  [ "$status" -ne 0 ]
}

@test "warns and preserves the branch when there is uncommitted and unpushed work" {
  claude_exits_after 1
  cw issue-1 || true
  sleep 3

  wt="${TESTDIR}/${REPO_NAME}-issue-1"
  echo "committed but unpushed" >"${wt}/wip.txt"
  git -C "$wt" add wip.txt
  git -C "$wt" commit -qm "unpushed work"
  echo "uncommitted" >"${wt}/dirty.txt"

  run cw_pty y y -- issue-1
  [[ "$output" == *"has uncommitted changes"* ]]
  [[ "$output" == *"not on its upstream"* ]]
  [ ! -d "$wt" ]
  # Committed work must survive: git branch -d refuses an unmerged branch.
  run git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/fix/issue-1
  [ "$status" -eq 0 ]
}

@test "declining the cleanup prompt leaves the worktree in place" {
  claude_exits_after 1
  run cw_pty n -- issue-1
  [[ "$output" == *"Skipping cleanup"* ]]
  [ -d "${TESTDIR}/${REPO_NAME}-issue-1" ]
}
