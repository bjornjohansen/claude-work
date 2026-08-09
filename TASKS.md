# Tasks

Things worth doing that are not blocking, captured so they are not rediscovered from
scratch. Ordered roughly by value.

## Sign the releases

`claude-work --upgrade` downloads `install.sh` from the latest release and runs it after
checking it against that release's `SHA256SUMS`. That proves the file arrived intact. It
does not prove the release is genuine: the checksums are produced by the same workflow,
from the same tag, with the same token as the artifacts, and git tags can be moved. So
anything able to publish a release can publish a matching checksum.

That was an acceptable trade when installing was a deliberate `curl | bash`. It is a
weaker position now that the tool offers to re-run the installer on its own.

Closing it means signing (minisign or GPG), publishing the public key out of band, and
verifying the signature in both `install.sh` and `cw_run_installer` before anything is
executed. Enabling tag protection on `v*` is a much smaller step in the same direction and
worth doing first.

## Reconsider the typeahead drain

`cw_drain_input` is a no-op on bash 3.2, because `read -t 0` there reports no pending input
even when there is some. So on macOS's stock bash a `y` typed ahead of the cleanup prompt
can still be read as consent to upgrade. The prompt defaults to no, and the upgrade is
checksum-verified and prefix-scoped, so the exposure is small — but requiring a full `yes`
for that one prompt would close it portably.

Security review raised this above the tidiness items on sequencing grounds, and the point
is a fair one: the upgrade prompt is the *second* question in a run whose first ("Remove
worktree and delete branch?") users answer reflexively. A double-tapped `y` is not an
exotic input, and the result is fetching and executing a shell script nobody meant to run
— from the right repository, checksum-verified, and still unintended.

## `--modify-path` validates the option but writes the derived directory

`install.sh` rejects a `--prefix` containing quotes, `$`, backticks, backslashes or
newlines, because that value is written into a shell startup file inside double quotes.
But `report_path_situation` writes `resolve_target_dir()`, which is `${HOME}/.local/bin`
when no prefix was given, and `$HOME` is never checked.

Security review reproduced it: with `HOME` containing `$(touch RCPWN)`, `--modify-path`
wrote `export PATH="…/$(touch RCPWN)/.local/bin:$PATH"` into `.zshrc`, and sourcing the rc
file ran it. Exploitability is low — anyone who can set your `HOME` can usually just point
it at a directory holding their own `.zshrc` — but the comment above the existing check
claims an invariant the code does not actually enforce, which is the part worth fixing.
Move the `case` guard so it covers `target_dir` rather than only `OPT_PREFIX`.

## Cache directory mode is only enforced at creation

`cw_cache_file` chmods `0700` inside its `[ ! -d "$d" ]` branch, so a pre-existing
world-writable `~/.cache/claude-work` is accepted and never corrected. The file guards mean
the only plant that survives is a hardlink to another file the user already owns and can
read, and every field is re-validated afterwards, so the worst outcome is a spoofed version
number in the notice — the download URL is hardcoded either way. `(umask 077; mkdir -p …)`
plus rejecting a group- or other-writable directory closes it in about a line.

## Cache read is TOCTOU-racy, and unbounded

`cw_cache_read` checks `-f`, `! -L` and `-O` and then opens the path. Between the two, the
same user could swap a regular file for a fifo and reintroduce the hang those checks exist
to prevent. The honest fix is to open the descriptor once (`exec 3<"$f"`) and test the open
descriptor rather than the path.

Same entry, same threat model: `read -r c l d <"$f"` has no size bound, so an arbitrarily
long first line is pulled into memory inside the EXIT trap. Only reachable by someone
already running as the user.

## `now` is not normalised the way the cache field is

`cw_update_fetch` digit-checks `$(date +%s)` but does not bound its length or apply `10#`
before `$((now - CW_CHECKED))`, while the value read from the cache gets all three. Only
reachable through a hostile `date` on `PATH`, and the child runs `set +e` so it degrades to
fetching anyway. Worth making symmetric regardless: the asymmetry reads as though the
guard were optional.

## Drop the token from the release checkout

The `release` job runs with `contents: write` and checks out without
`persist-credentials: false`, so `.git/config` holds a push-capable token for the rest of
the job. Nothing in the job pushes. For a repository whose artifacts are downloaded and
executed by `--upgrade`, denying that is a one-line change on each checkout step.

## The wget fallback has no total-time cap

`install.sh`'s wget branch uses `--timeout=30`, which is a per-stall timeout — a slow-drip
server can hold an install open indefinitely. The curl path is bounded by `--max-time 120`.
Either bound wget the same way or document curl as the supported fetcher.

## Prune the cache directory

Nothing ever removes `${XDG_CACHE_HOME}/claude-work`. `install.sh --uninstall` now does,
but a user who deletes the binary by hand leaves it behind. Harmless — three fields in one
file — just untidy.

## `declined` is preference data living in a cache

Clearing caches resurrects a nag the user already dismissed. Moving it to a state
directory would be more correct, but would mean introducing a second location for one
field. Left as is deliberately; revisit if anything else ever needs to be remembered.

## Cover the `CLAUDE_WORK_UPDATE_DEBUG` branch

`cw_update_spawn` has two spawn branches that differ only in whether the child keeps
stderr. The debug one is untested.

## `--prefix` permits control characters

CR and ESC are not in the rejected set, and the value is echoed back through `info`/`warn`.
Not an injection — only `$`, backtick, `\` and `"` matter inside the double-quoted rc line,
and those are already rejected — purely output spoofing, and self-inflicted.
`bin/claude-work` applies a charset guard to the analogous field, so this is an
inconsistency more than a defect.

## `BRANCH_PREFIX` and `GIT_REMOTE` are unvalidated

Pre-existing, and outside the update-check work. Both come from the environment without the
validation `SLUG` gets. They are only ever passed to git as separate argv elements and
security review found nothing exploitable, but they are the last unvalidated environment
inputs in the script.
