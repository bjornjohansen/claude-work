# Tasks

Known work that is deliberately not done yet. Each entry says what it is, why it was
deferred, and what would have to change for it to matter.

## Sign the releases

`claude-work --upgrade` downloads `install.sh` from the latest release and verifies it
against that release's `SHA256SUMS` before running it. That is **transport integrity, not
provenance**: `SHA256SUMS` is published by the same release and fetched from the same base
URL, so anything able to publish a release can publish a checksum that matches whatever it
likes. The check proves the file arrived intact. It does not prove who wrote it.

Signing with minisign or GPG, and verifying the signature rather than the digest, is the
only thing that closes that gap. It needs a key with somewhere safe to live, a decision
about what happens when the key is unavailable at upgrade time, and a way for a user
installing for the first time to obtain the public key over a path they already trust.

Until then, tag protection on `v*` is what prevents a published tag from being moved under
a checksum that has already been read, and the README says out loud what the checksum does
and does not cover.

## TOCTOU between the cache guard and the read

`cw_cache_read` (`bin/claude-work:235`) tests `-f`, `! -L`, `-O` and `-r`, then reads the
file on the next line. The file can be replaced between the two. The guards are what make
the common case safe — they stop a planted symlink and stop `read` blocking forever on a
fifo — but they are checks against a path, not against the thing eventually opened.

The exposure is small: the cache lives in a `0700` directory the tool creates and refuses
to use unless it is owned by the caller and is not a symlink, so winning this race already
requires write access inside that directory. The value of the parsed content is bounded
too — the timestamp passes a digit-only `case` guard before it reaches `$(( ))`, and both
version fields must satisfy `cw_is_semver` or become `-`.

The fix is to open the file once and validate the descriptor rather than the name, which
POSIX shell does not really give us. Worth revisiting if the cache ever holds anything that
is interpolated into a URL or a command.

## Prune the cache directory

`~/.cache/claude-work/` accumulates only `update`, plus a `.update.XXXXXX` temp file if a
write dies between `mktemp` and `mv`. Nothing removes those strays. It is a handful of
bytes each and `install.sh --uninstall` clears the directory, so this is tidiness rather
than a leak — but a long-lived machine that never uninstalls will keep them forever.
