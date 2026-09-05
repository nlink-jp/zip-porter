# ADR-0005: Ownership-Recorded Cleanup, Local-Header Entry Ranges, and an Aggregate Compression Memory Budget

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-09-05 |
| Binds | zip-porter |
| Decision makers | nlink-jp maintainers |
| Triggered by | External code review of v0.11.2 (2026-09-05): four findings, three reproduced against the CLI and Core, one measured |

## Context

An independent review of the released code reported four defects. Each
was reproduced or measured by the reviewer and re-verified here against
the source before anything was changed:

| ID | Observation | Where |
|----|-------------|-------|
| ZP-01 | A failed extraction deletes files it did not create. `topItems` is the list of *planned* top-level paths, filled before anything exists; the failure path removes every entry of it. A file that appears between the name check and the `O_EXCL` create makes the create fail — and the catch block then deletes that file. A dangling symlink at the planned name meets the same fate. Under the `.never` folder policy the permissive `createDirectory` even extracts *into* a folder another writer just made. | `Unpacker.unpack` |
| ZP-02 | The overlap check (ADR-0001 §3) computes each entry's range as `localHeaderOffset + 30 + <central-directory name length> + compressedSize`, while extraction starts reading at `localHeaderOffset + 30 + <local name length> + <local extra length>`. Two entries whose local headers nest inside each other's extra field pass the check and read the same byte. | `ZipReader.validateEntryRanges` vs `ZipReader.extract` |
| ZP-03 | A scratch file created for spilled compressed output is not remembered until the first buffer has been written into it; a write that fails part-way leaves a file nobody knows about. Independently, `compressLarge` calls `abandon()` on two of its failure branches and not on the others (read, emit, close). | `ParallelCompressor.SpillSink`, `compressLarge`, `compressOne` |
| ZP-04 | The 16 MiB spill threshold bounds one entry's output while it is being compressed. Finished results below it stay in memory until every entry is done, so the retained total grows with the input — 64 one-megabyte inputs held 50 MB — although ADR-0002 states the bound as `concurrency × threshold`. | `ParallelCompressor.compress`, `Packer` |

The organization rule for review findings (CONVENTIONS §*Root cause before
patch*) is to classify before fixing. The four findings fall into three
classes, and the first class has three instances:

- **Class A — ownership inferred from a plan, not recorded at creation.**
  ZP-01 (planned `topItems` deleted on failure), ZP-03a (`spillURL`
  assigned after the first write), ZP-03b (release called on an
  enumerated subset of exit paths). In each case the code knows what it
  *intended* to create and cleans up by that intention; whether the
  creating syscall actually succeeded, and for which path, is not what the
  cleanup consults.
- **Class B — one fact derived twice from two sources.** ZP-02: the data
  range is computed from the central directory for the check and from the
  local header for the read. The check can only ever be as strong as the
  agreement between two derivations that the format does not require to
  agree.
- **Class C — a bound applied per unit and claimed for the aggregate.**
  ZP-04: the threshold is enforced on each sink; nothing enforces it on
  the sum of what the sinks hand back.

A fifth observation from the review is not a product defect: under a UTF-8
locale, `unzip -t` prints Japanese names with some bytes replaced by `?`
*inside* multibyte sequences, so its output is not valid UTF-8 and the
test helper's strict decode yields an empty string. Reproduced here; the
test passes under `LC_ALL=C`.

**Independent design review.** The first draft of this record went
through the design-verification pass CONVENTIONS requires (a fresh-context
reviewer cross-checking it against the knowledge base and the workspace
lessons). Four of its findings changed the design and are marked *after
review* below: claims of top-level folders moved ahead of the first
write; the uniqueness check moved to `lstat` semantics; per-entry scratch
files were replaced by one arena per pack; the compressor's knobs became
a per-call parameter instead of process-wide statics. Two were recorded
as accepted residuals, and one (a two-process race E2E) was declined as
non-deterministic — the progress-callback interposition reproduces the
same syscall outcome deterministically.

## Decision

**Close each class structurally, in `ZipPorterCore`, and pin the class
with a test that names it — behaviour tests for the instances, and
`ArchitectureTests`, which reads the engine source and fails on a second
remover, a second derivation, a second scratch lifecycle. The reviewer's
reproductions are adopted as regression tests; the reviewer's proposed
remedies are not adopted as written (see *Alternatives*).**

### A. Ownership is recorded at the creating syscall and released from one place

**Extraction.** Top-level items — the wrapper folder, or under `.never`
each top-level file or directory — are created *exclusively*: files with
`open(O_CREAT|O_EXCL)` as before, directories with `mkdir(2)`
(`PathUtil.createDirectoryExclusively`), which fails with `EEXIST` on
anything already at the path, dangling symlinks included. The URL is
appended to an `OwnedItems` ledger only after that call returns success.
The failure path calls `owned.removeAll()` and has no access to the
planned names; the per-entry `removeItem` after a failed write is gone,
so the ledger is the extractor's only remover. A name taken between the
uniqueness check and the create is therefore an *error* for this
extraction (`File exists`), never a reuse of someone else's directory and
never a deletion of someone else's file.

*After review:* every top-level **folder** is claimed before the first
entry is written, inside the same `do/catch` as extraction. A lazy
first-use claim would have left the check-to-create window open for the
whole extraction — minutes, under `.never` with many folders. Top-level
**files** are claimed by their own `O_EXCL` create when reached; a file
cannot be claimed without being written, and a collision there still
fails safely. *After review:* the uniqueness check (`PathUtil.uniqueName`,
`PathUtil.uniqueURL`) answers "exists" with `lstat` semantics
(`PathUtil.somethingExists`), because `fileExists(atPath:)` follows
symlinks and reports a dangling one as absent — the check would pick a
name the exclusive create then fails on, deterministically. The entry now
lands on "name 2" and the link is untouched.

**Compression scratch.** *After review*, replacing the draft's per-entry
scratch files with defer-based release: one `ScratchArena` per `compress`
call. It is created on the first spill — exclusively, under a hidden
random name (`.zp-scratch-<uuid>`) beside the archive — with the handle
recorded under the same lock in the same step, so there is no moment at
which the file exists unowned. Workers append under the lock and receive
byte ranges; a result's storage is `.memory(Data)` or
`.arena(ScratchArena, [Range<UInt64>])`, and the writer reads the ranges
back. The arena has one owner: `compress` removes it on any failure, and
the `Output` it returns hands it to `Packer`, whose single `defer` calls
`cleanUp()`. There is no per-entry lifecycle left to get right on every
exit path — the shape of ZP-03 cannot recur — and the memory budget (C)
cannot litter the user's folder with thousands of scratch files.

*After review:* the compressor's knobs — spill threshold, memory budget,
and the scratch opener — travel in `ParallelCompressor.Limits`, passed
per call (`Packer` gains an internal `pack(limits:)` overload), instead of
process-wide statics that tests mutate and restore. The opener is
injectable because no real filesystem fails a write on cue.

### B. Entry ranges are resolved once, from the local header, at open

`ZipReader.resolveEntryRanges` reads each file entry's 30-byte local
header while opening the archive, computes `dataOffset =
localHeaderOffset + 30 + localNameLength + localExtraLength`, stores it
on the `ZipEntry`, and runs the overlap and EOF checks on
`[localHeaderOffset, dataOffset + compressedSize)`. `extract` starts at
`entry.dataOffset` and reads no header. There is one derivation and both
consumers use it. Every bound is phrased as a subtraction from the
known-good file size (`headerLength <= fileSize - start`,
`compressedSize <= fileSize - dataOffset`), never as an addition of
header values inside the check — the AGENTS rule from the v0.10.0
crashes. An extra field or name length that pushes the payload past EOF
is rejected at open rather than during extraction.

*After review:* entries are visited in offset order and the headers are
served from a 256 KiB window, so a hundred thousand small entries cost a
few hundred reads rather than one each — the difference between a blink
and minutes on a network volume. Large entries fall back to one read per
header, but then there are few of them. Measured: a 100 000-entry archive
(10.8 MB) opens and lists in 0.4 s locally.

### C. Retained compressed output has an aggregate budget

A `MemoryLedger` shared by one `compress` call reserves bytes for every
finished result that would stay in memory. A result that would push the
retained total past `cores × spillThreshold` is appended to the arena
instead, exactly as an over-threshold entry is. The bytes written to the
archive do not depend on where a result was held, so output stays
deterministic; the existing determinism test is the gate, and a new one
packs the same input with an unlimited and a zero budget and compares the
files byte for byte. Peak memory is now bounded independently of the
input count: in-flight buffers plus the retained budget during the
small-file phase (about `2 × cores × 16 MiB`), and the large-file waves'
`cores × 2 × blockSize` plus the retained budget during the large-file
phase (about `3 × cores × 16 MiB`, the worst case). ADR-0002's memory
statement is amended to point here.

### Test harness

External tool runs in the test suite pin `LC_ALL=C` so their output is
decodable regardless of the developer's locale.

## Consequences

**Positive**

- A failed extraction can no longer remove anything it did not create;
  the ADR-0001 invariant "failed extractions clean up only what they
  created" now rests on recorded facts instead of a plan, and a taken
  folder name fails the extraction before anything is written.
- The overlap check sees the same bytes extraction reads, restoring the
  ADR-0001 §3 guarantee that overlapping or past-EOF ranges are rejected
  at open.
- A scratch file cannot outlive a failed pack, whichever step failed, and
  a pack leaves at most one hidden scratch file while it runs.
- Memory during packing is bounded independently of the input count, as
  ADR-0002 already claimed.
- Three classes are closed by structure and pinned by source-reading
  tests: a ledger the failure path must go through, one derivation of the
  range, one budget over the aggregate, one scratch lifecycle.

**Negative / accepted trade-offs**

- A top-level name taken by another process in the window between the
  uniqueness check and the create now fails the extraction with `File
  exists`. Previously the extraction proceeded (into the other party's
  directory, or failed and deleted their file). Failing is the safe
  behaviour; for folders the window is now the few milliseconds before
  the first write, for top-level files it lasts until the file is reached.
- *Residual:* anything a third party drops inside an owned folder while
  the extraction runs (Finder's `.DS_Store`, a user save) is removed with
  that folder on failure. The ledger records top-level items, not every
  path beneath them.
- Opening an archive costs one read of each file entry's local header —
  windowed, so it is a few hundred reads per hundred thousand small
  entries. A local header with a bad signature or lengths that run past
  EOF now rejects the whole archive at open, `inspect` included, where it
  used to fail that one entry during extraction. Consistent with "refuse
  rather than repair"; directory entries stay excluded from the check, as
  before.
- Packing a large corpus of small files spills more results than before,
  into the arena beside the archive. The write phase drains them
  sequentially anyway; the extra cost is disk traffic in exchange for a
  memory bound. The arena occupies space on the destination volume for
  the duration of the pack, roughly the size of the archive being made.

## Alternatives considered

- **A: a `created` flag per planned item** instead of a separate ledger.
  Same information, but the failure path would still iterate the planned
  list and depend on every creation site setting the flag. The ledger
  makes the planned names unreachable from the cleanup, which is the
  property that closes the class.
- **A: retry the next numbered name when the exclusive create hits
  `EEXIST`.** Repairs a race by guessing and complicates the rename
  report. Declined: refuse rather than repair (ADR-0001); the case is a
  race between two concurrent writers, which the user should see.
- **A: claim top-level items lazily, on first use** (the first draft).
  Simpler, but it leaves the check-to-create window open for the whole
  extraction. Rejected by the design review; folders are claimed up front.
- **A: keep per-entry scratch files and release them from one `defer`**
  (the first draft). Closes the enumerated-branches instance but keeps a
  lifecycle per entry, and with the budget it would have put thousands of
  files in the user's folder, each a create/write/open/unlink over the
  network on a file server. Rejected by the design review in favour of
  the arena.
- **A: keep per-branch `abandon()` calls and add the missing ones.** That
  is the instance fix the class rules out — the next new exit path would
  miss again.
- **B: read the local header in the check *and* in `extract`.** Two
  derivations that happen to agree today; the class is "two derivations",
  so the fix is one.
- **B: validate ranges lazily at extract time.** Cheaper at open, but the
  archive would be accepted, `inspect` would report it clean, and a
  rejection could arrive after files were written. ADR-0001 §3 requires
  rejection at open.
- **C: a streaming pipeline that writes finished entries while others
  compress**, bounding memory by a window rather than a budget. The right
  long-term shape and the reviewer's suggestion, but it dissolves
  ADR-0002's two-phase structure and its determinism argument. Deferred;
  revisit if the budget proves insufficient in practice.
- **C: a fixed budget constant (e.g. 256 MiB).** Any constant is wrong for
  some machine; `cores × spillThreshold` reuses the existing knob and is
  the bound ADR-0002 already documents.
- **Knobs as `static var`s the tests mutate** (the project's earlier
  pattern, `blockParallelThreshold`). Process-wide state that leaks
  between tests and needs `nonisolated(unsafe)` under Swift 6. Rejected by
  the design review; `Limits` is passed per call. `blockParallelThreshold`
  itself is left as it was — out of scope.
- **A two-process race E2E for ZP-01.** Non-deterministic by nature; the
  progress-callback interposition makes the other writer's create land in
  the exact window and exercises the same `EEXIST` outcome every run.
- **Harness: lossy decoding of tool output.** Would pass, but the output
  would differ by locale; pinning the locale makes the output the same
  everywhere.

**Reviewer proposals not adopted as written.** The proposal to
"distinguish reused from newly created directories" is superseded by
never reusing a top-level item at all. The proposal to interleave
compression and ordered writing is the deferred pipeline above.

## Verification

- Behaviour tests per instance (`HardeningTests`, `ScratchLifecycleTests`):
  the reviewer's competing-writer reproduction, a dangling symlink at the
  planned name, folders present at the first progress callback, a
  competitor's top-level file surviving while ours is removed; three
  spec-built fixtures (`hostile-overlap-local-extra`,
  `hostile-overlap-local-name`, `hostile-extra-past-eof`) rejected at
  open; arena removed on first-write, later-write, close, block-parallel
  and mid-batch failures and on pack success, cancellation and failure;
  retained bytes within a 100 KiB budget; the ledger exact under 64
  concurrent reservations; budget-∞ and budget-0 packs byte-identical;
  forced spills round-tripping through AES-256 and ZipCrypto.
- `ArchitectureTests` reads the engine source (comment lines dropped):
  no `removeItem` and no permissive wrapper create in `Unpacker`; no
  `fileExists` in `PathUtil` or the top-level check; the local
  name/extra lengths read once and `dataOffset` assigned once in
  `ZipReader`; one scratch opener, one remover, no new statics in
  `ParallelCompressor`.
- Real binary: the reviewer's ZP-03 method — `pack` of a 40 MiB
  compressible-probe input under `RLIMIT_FSIZE` = 20 MiB — fails with
  "The file couldn't be saved" and leaves nothing in the output folder.
  The same pack onto a genuinely full 20 MiB RAM disk (HFS+) fails with
  "not enough space" and leaves nothing; an `unpack` of an archive
  declaring 30 MiB onto it is refused before writing. A 100 000-entry
  archive opens and lists in 0.4 s. The eight existing hostile fixtures
  regenerate byte-identically.

## References

- ADR-0001 §3 (overlap rejection) and the "clean up only what it created"
  invariant — amended by this record.
- ADR-0002 (memory bound statement) — amended by this record.
- Consumers of the superseded statements, updated with this record:
  ADR-0001 §3 and ADR-0002 §1 (amendment notes), AGENTS *Security
  invariants* and *Packing compresses in parallel* rules, the O_EXCL and
  local-header *Gotchas*, README *Extraction safety* and *Performance*,
  and the doc comments on `resolveEntryRanges`, `ScratchArena`,
  `MemoryLedger` and `OwnedItems`.
- `nlink-jp/.github` CONVENTIONS §*Build small, fix small* — "Root cause
  before patch", "Reviewers observe; contributors decide"; §*Verify with
  an independent pass*.
- `nlink-jp/knowledge` docs/*/development-process.md — the same rule with
  its originating incident.
