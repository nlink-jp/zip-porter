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
| ZP-01 | A failed extraction deletes files it did not create. `topItems` is the list of *planned* top-level paths, filled before anything exists; the failure path removes every entry of it. A file that appears between the name check and the `O_EXCL` create makes the create fail — and the catch block then deletes that file. A dangling symlink at the planned name meets the same fate. | `Unpacker.unpack` |
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

## Decision

**Close each class structurally, in `ZipPorterCore`, and pin the class
with a test that names it. The reviewer's reproductions are adopted as
regression tests; the reviewer's proposed remedies are not adopted as
written (see *Alternatives*).**

### A. Ownership is recorded at the creating syscall and released from one place

**Extraction.** Top-level items — the wrapper folder, or under `.never`
each top-level file or directory — are created *exclusively*: files with
`open(O_CREAT|O_EXCL)` as before, directories with `mkdir(2)`, which
fails with `EEXIST` on anything already at the path, dangling symlinks
included. The URL is appended to an `OwnedItems` ledger only after that
call returns success. The failure path calls `owned.removeAll()` and has
no access to the planned names. Consequently a name taken between the
uniqueness check and the create is an *error* for this extraction (`File
exists`), never a reuse of someone else's directory and never a deletion
of someone else's file. Everything created beneath an owned top-level
item is owned by construction.

**Compression scratch files.** `SpillSink` owns its scratch file from the
moment the exclusive create returns, *before* the first byte is written.
`finish()` transfers ownership to the `Storage` it returns; `abandon()`
releases whatever the sink still owns and is idempotent. Each call site
holds exactly one `defer { sink.abandon() }`, so every exit path — read
failure, deflate failure, write failure, close failure, cancellation —
releases the file without a branch of its own. The scratch file is opened
through an injectable `ScratchFile` factory, because no real filesystem
fails a write on cue and the class cannot be tested otherwise.

### B. Entry ranges are resolved once, from the local header, at open

`ZipReader` reads each file entry's 30-byte local header while opening the
archive, computes `dataOffset = localHeaderOffset + 30 + localNameLength +
localExtraLength`, stores it on the `ZipEntry`, and runs the overlap and
EOF checks on `[localHeaderOffset, dataOffset + compressedSize)`. `extract`
starts at `entry.dataOffset` and reads no header. There is one derivation
and both consumers use it. Entries are visited in offset order so the
extra reads are sequential; the cost is one small read per file entry at
open, on top of the central-directory parse that already touches every
entry. An extra field or name length that pushes the payload past EOF is
now rejected at open rather than during extraction.

### C. Retained compressed output has an aggregate budget

A `MemoryLedger` shared by one `compress` call reserves bytes for every
result that would stay in memory. A result that would push the retained
total past `cores × spillThreshold` is spilled to a scratch file instead,
exactly as an over-threshold entry is. The bytes written to the archive do
not depend on where a result was held, so output stays deterministic; the
existing determinism test is the gate. Peak memory is now bounded by
in-flight buffers plus the retained budget — about `2 × cores × 16 MiB` —
regardless of how many files are packed. ADR-0002's memory statement is
amended to point here.

### Test harness

External tool runs in the test suite pin `LC_ALL=C` so their output is
decodable regardless of the developer's locale.

## Consequences

**Positive**

- A failed extraction can no longer remove anything it did not create;
  the ADR-0001 invariant "failed extractions clean up only what they
  created" now rests on recorded facts instead of a plan.
- The overlap check sees the same bytes extraction reads, restoring the
  ADR-0001 §3 guarantee that overlapping or past-EOF ranges are rejected
  at open.
- Scratch files cannot outlive a failed pack, whichever step failed.
- Memory during packing is bounded independently of the input count, as
  ADR-0002 already claimed.
- Three classes are closed by structure: a ledger the failure path must go
  through, one derivation of the range, one budget over the aggregate.

**Negative / accepted trade-offs**

- A top-level name taken by another process in the window between the
  uniqueness check and the create now fails the extraction with `File
  exists`. Previously the extraction proceeded (into the other party's
  directory, or failed and deleted their file). Failing is the safe
  behaviour; the window is milliseconds wide.
- Opening an archive costs one 30-byte read per file entry. For archives
  with a hundred thousand entries this is a fraction of a second; the
  central-directory ceiling (256 MiB) already bounds the count.
- Packing a large corpus of small files spills more results to scratch
  files than before. The write phase drains them sequentially anyway; the
  extra cost is disk traffic in exchange for a memory bound.

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
- **Harness: lossy decoding of tool output.** Would pass, but the output
  would differ by locale; pinning the locale makes the output the same
  everywhere.

**Reviewer proposals not adopted as written.** The proposal to
"distinguish reused from newly created directories" is superseded by
never reusing a top-level item at all. The proposal to interleave
compression and ordered writing is the deferred pipeline above.

## References

- ADR-0001 §3 (overlap rejection) and the "clean up only what it created"
  invariant — amended by this record.
- ADR-0002 (memory bound statement) — amended by this record.
- `nlink-jp/.github` CONVENTIONS §*Build small, fix small* — "Root cause
  before patch", "Reviewers observe; contributors decide".
- `nlink-jp/knowledge` docs/*/development-process.md — the same rule with
  its originating incident.
