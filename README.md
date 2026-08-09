# claude-work

Spin up a git worktree, a tmux session and [Claude Code](https://claude.com/claude-code) for a single
issue — with one command, and clean up afterwards.

Working on several issues at once means either stashing constantly or juggling checkouts by hand.
`claude-work` gives each issue its own worktree, its own branch and its own long-lived tmux
session, so you can leave a Claude Code session running on one issue, detach, and start another.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bjornjohansen/claude-work/main/install.sh | bash
```

Piping a script from the internet into a shell runs code you have not read. If you would rather look
first — and you should — the installer is a single self-contained file:

```bash
curl -fsSL https://raw.githubusercontent.com/bjornjohansen/claude-work/main/install.sh -o install.sh
less install.sh
sh install.sh          # user install  → ~/.local/bin
sudo sh install.sh     # system-wide   → /usr/local/bin
```

The installer downloads the release build, checks it against the `SHA256SUMS` published with that
release, and refuses to install on a mismatch. It never runs `sudo` on your behalf: without root it
installs to `~/.local/bin` and tells you if that is not on your `PATH`.

Useful options — pass them after `--` when piping:

```bash
curl -fsSL .../install.sh | bash -s -- --version 0.2.0        # pin a release
curl -fsSL .../install.sh | bash -s -- --prefix ~/bin         # choose the directory
curl -fsSL .../install.sh | bash -s -- --modify-path          # add it to your shell rc
sh install.sh --uninstall                                     # remove it again
sh install.sh --help                                          # everything else
```

Re-running the installer upgrades in place, and reports when you are already on the newest version.

## Usage

```bash
cd ~/dev/myrepo
claude-work issue-123            # branch off main
claude-work issue-456 develop    # branch off develop
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
| `CLAUDE_WORK_NO_UPDATE_CHECK` | unset | Set to anything to disable the update check |
| `CLAUDE_WORK_UPDATE_INTERVAL` | `86400` | Seconds between update checks |
| `CLAUDE_WORK_UPDATE_DEBUG` | unset | Report why a check found nothing |

```bash
BRANCH_PREFIX=feat claude-work new-onboarding
```

If the base branch cannot be fetched, the script warns and falls back to the local branch rather
than failing outright — useful offline.

## Update checks

`claude-work` is installed by a script, not a package manager, so nothing else would tell you a new
version exists. It looks, and says so when your session ends.

**What it does.** Once a day at most, in a background process that startup never waits for, it makes
a single HTTPS request to `github.com` and reads the version out of the redirect. The response body
is discarded. Measured cost at startup: under 1 ms, against the ~15 ms `git worktree prune` already
spends a moment later.

**What it sends.** Nothing about you. No custom `User-Agent`, no cookies, no identifier of any kind
— an ordinary request, indistinguishable from opening the releases page in a browser. GitHub sees
your IP, as it would for any request you make to it.

**When it stays quiet.** When stdin or stderr is not a terminal, when `$CI` is set, and when any of
`CLAUDE_WORK_NO_UPDATE_CHECK`, `NO_UPDATE_NOTIFIER` or `DO_NOT_TRACK` is set. Turn it off for good
with:

```bash
echo 'export CLAUDE_WORK_NO_UPDATE_CHECK=1' >> ~/.zshrc
```

The notice appears on stderr when the session ends, naming both versions. If you decline the
upgrade, you are not asked about that version again. Detaching from a session never prompts — you
get the notice and your shell straight back.

## Upgrading

```bash
claude-work --upgrade
```

Be aware of what this does: **it downloads `install.sh` from the latest GitHub release and runs
it.** The installer is checked against the release's `SHA256SUMS` first and is not run if that
fails, and it installs into the directory the running copy already occupies rather than picking a
new one. It refuses outright to touch a copy inside a git checkout.

That checksum proves the file arrived intact. It does not prove the release is trustworthy —
`SHA256SUMS` is published by the same release, so anything able to publish a release could publish a
matching checksum. This is the same trust you extended by installing with `curl | bash` in the first
place, with the difference that the tool now re-extends it whenever you say yes. If you would rather
that were always a deliberate act, disable the check and upgrade by re-running the installer
yourself. Signing the releases, which is what would actually close that gap, is tracked in
[`TASKS.md`](TASKS.md).

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

## Development

```bash
brew install shellcheck bats-core   # or: sudo apt install shellcheck bats
shellcheck -x bin/claude-work
shellcheck -s sh install.sh
bats test/
CW_BASH=/bin/bash bats test/        # the bash 3.2 compatibility check
```

The suite creates throwaway repositories and runs tmux on an isolated socket, so it cannot disturb
your own sessions. Cleanup prompts are driven through a pty helper, because the tool refuses to act
on them without a terminal.

Releases are cut by tag. `scripts/bump-version.sh X.Y.Z` updates the version header and the
changelog together; pushing the `vX.Y.Z` tag builds the release and publishes it. CI fails the build
if the script version, the changelog and the tag ever disagree.

## License

MIT — see [LICENSE](LICENSE).
