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

## Cache read is TOCTOU-racy

`cw_cache_read` checks `-f`, `! -L` and `-O` and then opens the path. Between the two, the
same user could swap a regular file for a fifo and reintroduce the hang those checks exist
to prevent. Only reachable by someone already running as the user, so the value is low —
but the honest fix is to open the descriptor once (`exec 3<"$f"`) and test the open
descriptor rather than the path.

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

## Reconsider the typeahead drain

`cw_drain_input` is a no-op on bash 3.2, because `read -t 0` there reports no pending input
even when there is some. So on macOS's stock bash a `y` typed ahead of the cleanup prompt
can still be read as consent to upgrade. The prompt defaults to no, and the upgrade is
checksum-verified and prefix-scoped, so the exposure is small — but requiring a full `yes`
for that one prompt would close it portably.
