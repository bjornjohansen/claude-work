# claude-work

Spin up a git worktree, a tmux session and [Claude Code](https://claude.com/claude-code) for a single
issue — with one command, and clean up afterwards.

Working on several issues at once means either stashing constantly or juggling checkouts by hand.
`claude-work.sh` gives each issue its own worktree, its own branch and its own long-lived tmux
session, so you can leave a Claude Code session running on one issue, detach, and start another.

## Usage

```bash
cd ~/dev/myrepo
./claude-work.sh issue-123            # branch off main
./claude-work.sh issue-456 develop    # branch off develop
```

For the slug `issue-123` in a repo called `myrepo`, this:

1. creates a worktree at `../myrepo-issue-123`,
2. creates branch `fix/issue-123` off `origin/main` (fetched first),
3. opens tmux session `cc-myrepo-issue-123` in that worktree,
4. launches `claude` inside it.

Re-running the same command is safe: an existing worktree, branch or session is reused rather than
recreated.

### Detaching vs quitting

The distinction matters, and the script treats them differently:

- **Detach** (`Ctrl-b d`) — the session keeps running. The script prints how to reattach and exits.
- **Quit Claude Code** — the session ends, and the script offers to remove the worktree and delete
  the branch.

If you are already inside tmux, the script switches your client to the new session instead of
nesting, and skips the cleanup prompt.

### Cleanup

The cleanup prompt defaults to no. Before removing anything it warns about uncommitted changes and
about commits not yet on the branch's upstream, then asks a second time. Branch deletion uses
`git branch -d`, so an unmerged branch is never silently thrown away — you get the reason and a
`git branch -D` command to run yourself if you really mean it.

When stdin is not a terminal, cleanup is always skipped. Nothing is deleted non-interactively.

## Requirements

- `bash` 3.2 or newer (the stock `/bin/bash` on macOS is 3.2 — the script deliberately stays
  compatible with it)
- `git` with worktree support
- `tmux`
- `claude` on your `PATH`

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `GIT_REMOTE` | `origin` | Remote to fetch the base branch from |
| `BRANCH_PREFIX` | `fix` | Prefix for the created branch |

```bash
BRANCH_PREFIX=feat ./claude-work.sh new-onboarding
```

If the base branch cannot be fetched, the script warns and falls back to the local branch rather
than failing outright — useful offline.

## Notes

- Slugs are restricted to `[A-Za-z0-9._-]`, must start with a letter or digit, and may not contain
  `..`. The slug becomes a filesystem path, a git refname and a tmux target, so it has to be
  unambiguous in all three.
- Run it from anywhere in the repo, including from inside a worktree it created — it resolves the
  main checkout, so worktree names never nest.
- Claude Code runs as the tmux session's command rather than being typed into a shell. That avoids
  racing shell startup, but means a shell alias or function named `claude` is not picked up.
- Each worktree gets its own dependencies. Nothing is symlinked between them, because two branches
  that disagree on dependencies would otherwise share the wrong ones.

## License

MIT — see [LICENSE](LICENSE).
