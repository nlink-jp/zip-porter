# ADR-0001: Extraction Hardening — Decompression Bombs, Overlap, Quarantine, Duplicate Names

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-01 |
| Decision makers | nlink-jp maintainers |
| Triggered by | Post-v0.1.0 threat review: an unarchiver is a program that executes attacker-chosen structure on the user's filesystem |

> Originally recorded as organization ADR-012 in `nlink-jp/.github`.
> Moved here on 2026-08-03: the organization ADR log is for decisions
> that bind the whole organization, and this one binds one app.

## Context

`zip-porter` v0.1.0 ships extraction that already refuses the classic
filesystem-escape attacks: `Unpacker.sanitize` rejects absolute paths,
`..` traversal, Windows drive prefixes, and NTFS alternate-data-stream
names; symlink entries are skipped in both directions; AES entries are
HMAC-authenticated and everything else CRC-verified; permission bits are
masked to `0o777` so setuid/setgid cannot survive.

A threat review of what remains found four gaps. Three are resource- or
integrity-related; one is a Gatekeeper bypass that matters more than the
rest, because it silently removes a protection macOS users rely on.

**1. Decompression bombs are detected too late.** Sizes come from the
central directory and are checked *after* an entry finishes. An entry that
declares 1 KB but inflates to 50 GB fails the size check eventually — after
writing 50 GB. Correctness holds; availability does not.

**2. Overlapping entries are not detected.** In a legitimate ZIP each
entry's local header + data occupies a disjoint byte range. Bombs of the
`42.zip` family instead point thousands of central-directory entries at
*the same* compressed data, so a 42 KB file expands to petabytes. Nothing
in v0.1.0 notices that the ranges coincide.

**3. Quarantine is not propagated.** macOS marks downloaded files with the
`com.apple.quarantine` extended attribute; Archive Utility and The
Unarchiver copy that attribute onto everything they extract, so an
executable that arrives inside a ZIP still faces Gatekeeper. zip-porter
v0.1.0 writes fresh, unmarked files. A user who replaces Archive Utility
with zip-porter therefore loses Gatekeeper on ZIP contents — a regression
against the tool we are replacing, and the most consequential of the four.

**4. Duplicate entry names overwrite silently.** Two entries whose decoded
names collide — including case-only or NFC/NFD differences, which APFS
treats as the same file by default — resolve last-one-wins. An archive can
show a benign file in a listing and quietly replace it during extraction.

The stakes differ from a library's: zip-porter is a GUI users drop
untrusted downloads onto, and it registers as the system `.zip` handler.

## Decision

**Harden extraction along five axes, all enforced in `ZipPorterCore` so the
GUI and the CLI cannot diverge. Refuse rather than repair: a structurally
invalid archive is an error, not something to salvage.**

### 1. Fail-fast size enforcement during streaming

Track bytes written per entry while inflating and abort the moment output
exceeds the size the central directory declared (`sizeExceedsDeclared`).
The partial file is deleted by the existing per-entry cleanup path. This
converts "unbounded write, then complain" into "bounded write, then
complain", and costs one comparison per output chunk.

Declared sizes stay authoritative rather than being replaced by a fixed
ratio cap: compression ratio alone is a poor discriminator (legitimate
archives of sparse or highly repetitive data reach four digits), while the
declared-size contract is exact and already part of the format.

### 2. Whole-archive budget checked before writing

Before the first byte, sum the declared uncompressed sizes and compare
against the free space on the destination volume, requiring the total to
fit with a 64 MiB margin. Insufficient space is `insufficientSpace`, raised
*before* extraction starts.

This is what actually stops the overlap-bomb class from consuming a disk
even when each individual entry is honest about its own size, and it also
turns the ordinary "disk was already nearly full" case into a clear message
instead of a partial extraction. No fixed byte ceiling is imposed: the
user's free space is the natural budget, and any constant we picked would
be wrong for someone.

### 3. Overlapping entry data is rejected outright

At open time, compute each entry's `[localHeaderOffset, dataEnd)` range and
verify the ranges are disjoint and within the file. Any overlap fails the
archive with `overlappingEntries`. Legitimate writers never produce
overlap, so this is a structural-validity check, not a heuristic — and it
rejects the `42.zip` construction at parse time rather than by resource
exhaustion.

The check is O(n log n) over the entry count, on data already parsed.

### 4. Quarantine propagation

If the source archive carries `com.apple.quarantine`, copy that attribute
onto every file and directory produced from it. This restores parity with
Archive Utility and The Unarchiver, and is the difference between "the app
opened a downloaded binary" and "Gatekeeper evaluated a downloaded binary".

Implemented with `getxattr`/`setxattr` at `XattrUtil`, applied in the same
place extraction sets mtime and permissions. When the source has no
quarantine attribute (a locally built archive), nothing is added.

### 5. Duplicate entry names are uniquified, not overwritten

Detect collisions on a normalized key (NFC + case-folded, matching APFS
default behavior) across the whole archive, and extract the later entries
under `name 2`, `name 3`, … reusing the existing collision policy, with a
warning listing what was renamed. Lossless: the user still gets every
entry, and nothing pre-existing or previously extracted is replaced.

Rejecting such archives was considered and declined — duplicate names occur
in the wild from concatenating tools, and the safe behavior (keep both)
loses nothing.

### Supporting change

The central-directory size ceiling drops from 2 GiB to 256 MiB. A million
entries occupy roughly 100 MB of central directory, so this stays far above
real archives while bounding the pre-extraction allocation.

## Consequences

**Positive**

- The three resource-exhaustion paths (single-entry bomb, overlap bomb,
  disk-full) fail early with named errors instead of filling a volume.
- Gatekeeper coverage of ZIP contents is preserved, closing the one gap
  that made zip-porter less safe than the tool it replaces.
- Both front ends inherit every check: the enforcement lives below them.
- Structural rejection of overlap gives `inspect` a meaningful verdict on
  hostile archives.

**Negative / accepted trade-offs**

- The pre-flight space check reads the destination's free space and can
  refuse an extraction that would in fact have fit (a mostly-`store`
  archive on a volume with compression). Accepted: the 64 MiB margin and
  the fact that the check uses declared sizes — not a multiplier — keep
  false refusals rare, and the error names the shortfall.
- Quarantine propagation means files extracted from a downloaded archive
  now prompt on first open. That is the intended macOS behavior and matches
  every other unarchiver, but it is a visible change for users who had
  grown used to v0.1.0 output being unmarked.
- Duplicate-name uniquification can surprise a user who expected the
  archive's last entry to win. The warning names each rename.

**Verification**

Hostile fixtures are generated by a spec-derived Python builder rather than
by our own writer (which cannot produce these structures): a
declared-size-lying bomb, an overlap bomb whose central directory points
many entries at one data range, and a duplicate-name archive including a
case-only collision. Quarantine propagation is verified end-to-end by
marking a real archive with `xattr` and checking the extracted tree.

Shipped as **v0.2.0** (behavior additions, 0.x minor bump per the org
versioning rule).
