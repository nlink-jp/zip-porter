# ADR-0002: Compression Throughput — Parallel Entries and an Incompressible-Data Early-Out

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-01 |
| Decision makers | nlink-jp maintainers |
| Triggered by | Measured baseline: one core busy, eleven idle, on a machine with twelve |

> Originally recorded as organization ADR-013 in `nlink-jp/.github`.
> Moved here on 2026-08-03: the organization ADR log is for decisions
> that bind the whole organization, and this one binds one app.

## Context

Benchmarking v0.4.1 against a 310 MB / 150-file corpus (240 MB compressible
text, 100 MB incompressible random data, 30 MB JPEG) on a 12-core machine:

| Tool | Wall clock | Output |
|------|-----------|--------|
| zip-porter | 5.43 s | 162.4 MB |
| Apple `ditto` | 6.93 s | 160.0 MB |
| Info-ZIP `zip -r` | 7.00 s | 160.0 MB |

zip-porter is already the fastest of the three, because Apple's Compression
framework encoder trades ratio for speed (our archive is 1.5 % larger
overall; 10 % larger on pure text). Two findings say the remaining headroom
is large:

1. **User time 4.75 s ≈ wall clock 5.43 s.** Everything runs on one core.
   I/O is not the constraint: the `store` path moves 300 MB/s, and
   extraction (inflate) runs at roughly three times compression speed.
2. **Deflating incompressible data costs the most and buys nothing.** The
   100 MB of random data takes 2.07 s — the slowest phase of the run — and
   comes out about 0.03 % *larger* than storing it would be.

ZIP entries are independent by construction: each has its own compressed
stream, its own CRC, and its own header. Nothing in the format requires
compressing them in the order they are written.

## Decision

**Compress entries in parallel, and stop deflating data that does not
compress.** Both changes live in `ZipPorterCore`, so the GUI and the CLI
gain them together, and neither changes the bytes a reader sees.

### 1. Parallel per-entry compression, sequential writing

Split packing into two phases:

- **Compress (parallel).** Entries are compressed concurrently, each
  producing its compressed bytes, CRC, and sizes. Concurrency is bounded by
  the core count.
- **Write (sequential).** The writer emits entries in the archive's
  established order — the sorted order `Packer` already computes — so
  archives stay byte-for-byte deterministic and diffable across runs.

Encryption stays in the write phase. It is a transform over the compressed
bytes, each entry carrying its own random salt or header, so it composes
with either phase; keeping it sequential keeps the key material handling in
one place.

**Memory is bounded by spilling.** A compressed entry is held in memory
only below a threshold; larger ones stream to a temporary file that the
write phase drains and deletes. Worst-case memory is therefore
`concurrency × threshold`, not "the whole archive".

> **Amended by ADR-0005 (2026-09-05).** The threshold as first shipped
> bounded each entry *while it was being compressed*; finished results
> below it stayed in memory until every entry was done, so the retained
> total grew with the input count. An aggregate budget of
> `cores × threshold` now applies to the retained results as well — a
> result that would exceed it is spilled like an over-threshold entry — so
> peak memory is about `2 × cores × threshold` regardless of input size.

Single-entry archives skip the parallel path entirely — there is nothing to
overlap, and the streaming path already handles them with less bookkeeping.

### 2. Incompressible data is stored, decided by a probe

Before compressing a file, deflate a sample of its head. If the sample
barely shrinks, store the entry instead of deflating it.

This generalizes the existing extension list (`jpg`, `mp4`, `zip`, …) from a
guess about names to a measurement of contents: an already-compressed file
with an unhelpful extension now gets stored too, and a `.bin` full of text
still gets deflated. Storing incompressible data is not only faster, it is
also *smaller* — deflate adds framing overhead to data it cannot shrink.

Files decided to be stored need no parallel work at all: the existing
streaming path copies them and computes the CRC in one pass, at I/O speed.

### 3. What this deliberately does not do

**A single large file still compresses on one core.** Parallelising *within*
one deflate stream (the `pigz` scheme: independent blocks joined with sync
flushes) cannot be expressed through Apple's Compression framework, whose
finalize step ends each stream with a final block. That work needs libz, and
libz would also unlock a user-facing compression level (our output is
1.5–10 % larger than `ditto`'s today). Both are deferred to their own
investigation and, if pursued, their own ADR.

## Consequences

**Positive**

- Multi-file archives — the drop-a-folder case the GUI exists for — should
  compress several times faster on any modern multi-core Mac.
- Archives containing already-compressed data get faster *and* smaller.
- Output stays a plain ZIP with the same entry order; the cross-verification
  suite (Info-ZIP, ditto, 7-Zip, Python zipfile) remains the gate.

**Negative / accepted trade-offs**

- More moving parts in the pack path: a compression phase, a spill file
  lifecycle, and error/cancellation propagation across threads. Cancellation
  must now stop work in flight and clean up spill files, not just stop a
  loop.
- Peak memory rises from "one entry's buffers" to `concurrency × threshold`.
  This is a deliberate, bounded trade for throughput.
- The probe reads and compresses a sample that the full compression then
  redoes. It is a fixed, small cost per entry, repaid many times over on the
  files it diverts to `store`.
- A file whose head is unrepresentative of its body (a compressible tail
  behind an incompressible header) may be stored when deflating would have
  helped. Correctness is unaffected; only ratio is, and only for a shape
  that is rare in practice.

**Verification**

Benchmarks are rerun on the same corpus, with the existing round-trip and
cross-verification tests as the correctness gate. Determinism is checked by
packing the same input twice and comparing the archives byte for byte.
