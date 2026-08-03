# ADR-0003: Single-File Parallel Deflate on zlib

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-01 |
| Decision makers | nlink-jp maintainers |
| Triggered by | ADR-0002 shipped entry-level parallelism; a single large file — an LLM model archive, a disk image — still compresses on one core |

> Originally recorded as organization ADR-014 in `nlink-jp/.github`.
> Moved here on 2026-08-03: the organization ADR log is for decisions
> that bind the whole organization, and this one binds one app.

## Context

ADR-0002 parallelised *across* entries. Within one entry, Apple's Compression
framework cannot parallelise: its encoder finalizes every stream with a
BFINAL block, so independently compressed segments cannot be joined into
one valid deflate stream. The user's stated workloads — packing LLM model
files and disk images — are exactly the single-huge-file shape that gains
nothing from ADR-0002 (incompressible model weights already divert to
`store` via the probe; *compressible* large files run at one core's speed).

macOS ships zlib (1.2.12; `zlib.h` and `libz.tbd` in the SDK), so linking it
adds no bundled dependency. Measurements on a 180 MB text file, 12-core:

| Path | Wall clock | Output |
|------|-----------|--------|
| Compression framework, 1 core (shipped) | 2.82 s | 26.0 MB |
| zlib level 6, 1 thread | 4.23 s | 22.5 MB |
| **zlib level 6, 12 threads** | **0.44 s** | **22.5 MB** |
| zlib level 1, 12 threads | 0.10 s | 33.3 MB |
| zlib level 9, 1 thread | 21.25 s | 20.6 MB |

Three facts decide the shape: parallel scaling is near-linear (9.4× at 12
threads — not memory-bound); splitting into ~16 MB blocks costs no
measurable ratio; and level 9 is 5× slower than 6 for ~1 % — not worth
offering. zlib level 6 also matches `ditto`/Info-ZIP output size, removing
the 1.5–10 % size penalty we have carried since v0.1.0.

The join technique is pigz's: compress each block as raw deflate ended with
`Z_SYNC_FLUSH` (byte-aligned, no BFINAL), concatenate in order, end the last
block with `Z_FINISH`. The result is one standard deflate stream — nothing
nonstandard reaches a reader. Per-block CRCs merge with `crc32_combine`.
pigz additionally primes each block with the previous block's last 32 KB as
a dictionary; measurement shows the gain here is below noise, so we skip
that coupling and keep blocks fully independent.

## Decision

**Switch deflate to zlib at level 6 and compress large entries as
independent blocks in parallel.** Inflate stays on the Compression
framework — decompression was never the bottleneck and its input is
unchanged, a standard deflate stream.

1. **`CZlib` system-library target** in `ZipPorterCore`. The SDK's zlib
   only; no vendored source, no new bundled dependency.
2. **All deflate goes through zlib** — the parallel per-entry path, the
   block-parallel path, and the writer's sequential fallback — so one
   encoder produces every archive and output stays deterministic.
3. **Entries above a size threshold compress as ~16 MB blocks in bounded
   waves** (`cores` blocks in flight: read, compress concurrently, append
   in order, spill as ADR-0002 already does). Peak memory stays around
   `cores × 2 × blockSize`, independent of file size. Per-block CRCs are
   combined with `crc32_combine`.
4. **No user-facing compression level.** Level 6 is faster *and* smaller
   than what we ship today, level 9 buys ~1 % for 5× the time, and level 1
   trades 11 % more output for speed the wave pipeline already provides.
   A knob would be three ways to pick a worse point. Revisit only if a
   real workload shows otherwise.

The incompressibility probe (ADR-0002) still runs first: model weights and
other already-compressed giants divert to `store` at I/O speed and never
reach the deflate path at all.

## Consequences

**Positive**

- Compressible single large files gain roughly 6× wall clock at 13 %
  smaller output; every archive shrinks to `ditto`-class size.
- The deflate stream a reader sees remains fully standard; the existing
  cross-verification suite (Info-ZIP, ditto, 7-Zip, Windows Explorer via
  the fixture set) stays the gate.

**Negative / accepted trade-offs**

- Hand-assembled stream framing (sync-flush joins, one final block) is
  format-level code we now own; round-trip, external-tool, and determinism
  tests are the safety net.
- Archive bytes differ from v0.5.0's for the same input (different
  encoder). Determinism holds per version; nothing promises stability
  across versions.
- Small entries pay zlib's ~2× single-stream cost versus the Compression
  framework, which entry-level parallelism absorbs; the corpus benchmark
  guards against regression.
