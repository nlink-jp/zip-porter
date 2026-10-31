# ADR-0006: Deflate64 Extraction with an In-House Decoder

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-10-31 |
| Decision makers | nlink-jp maintainers |
| Triggered by | A 2.8 GB ZIP made with Windows Server 2012's Explorer ("Send to → Compressed folder") failed in ZipPorter and extracted fine with `unzip` |

## Context

Windows Explorer's built-in ZIP writer switches from Deflate (method 8) to
**Deflate64** (method 9, "enhanced deflate") once the files it packs exceed
roughly 2 GB. Microsoft does not document the threshold; it is consistently
reported by users and by tools that had to add Deflate64 support for the
same reason. Through v0.12.0 ZipPorter extracted only store (0) and Deflate
(8), so every large Explorer archive failed with `unsupportedMethod(9)` —
shown in the GUI as that raw enum text, untranslated. Info-ZIP `unzip`
(built with `USE_DEFLATE64` on macOS) and 7-Zip read it, which is why the
same file "works in the terminal". ZipPorter exists to receive ZIPs from
Windows; a Windows-made ZIP it cannot open is squarely in scope.

Deflate64 is Deflate with three changes:

1. The window is 64 KiB instead of 32 KiB; distance codes 30 and 31
   (unused in Deflate) mean 32769 and 49153 plus 14 extra bits.
2. Length code 285 means 3 plus **16 extra bits** (lengths up to 65538)
   instead of the fixed length 258.
3. Nothing else: block types, Huffman construction, and code-length
   coding are Deflate's.

No decoder for it ships with macOS. The Compression framework knows only
raw Deflate; the system zlib does not export `infback9` (a contrib module,
never part of the library). The organization does not adopt community
libraries (supply-chain policy). That leaves our own decoder.

## Decision

**Extract method 9 with an in-house, pure-Swift streaming decoder
(`Inflate64`) in ZipPorterCore. Do not create Deflate64.**

1. **One decoder, two variants.** `Inflate64` implements RFC 1951 with a
   `variant` switch (`.deflate` / `.deflate64`) that changes only the two
   tables above and the window size. Production uses it for method 9 only;
   method 8 stays on the Compression framework (ADR-0003). The `.deflate`
   variant exists so the decoder is tested against streams the system zlib
   produces in volume, not only against the handful of Deflate64 fixtures.
2. **Pull-based input, push-based output.** The decoder pulls payload
   chunks from a closure and pushes output through the same `out` sink the
   other methods use, so the per-entry fail-fast size bound, CRC check,
   ZipCrypto/AES decryption, and AES trailer handling are shared, not
   reimplemented. After the final block, the reader drains whatever payload
   remains so the AES HMAC sees every byte.
3. **Strict, like zlib.** Over-subscribed and incomplete Huffman codes are
   rejected (except the single one-bit code RFC 1951 permits), as are
   distances reaching before the start of output, invalid symbols, a stored
   block whose `NLEN` is not `~LEN`, repeat codes overrunning the code
   counts, a literal/length code with no end-of-block, and input ending
   before the final block. Every failure surfaces as `corrupt(…)` — the
   existing "malformed and refused" message — never as a trap.
4. **Bounded memory.** A 64 KiB history plus a fixed staging buffer,
   independent of entry size. Every decode step consumes input or emits
   output, so there is no loop an archive can make spin.
5. **No writing.** Creating Deflate64 would buy nothing (zlib output is
   readable everywhere) and would make archives others cannot open.
6. **Unsupported methods get a sentence.** Methods ZipPorter still cannot
   read (bzip2, LZMA, …) now produce a translated message naming the
   method number instead of the raw enum.

## Consequences

**Positive**

- Large ZIPs from Windows Explorer extract in the app, from Finder and the
  CLI alike — the case the app was built for.
- The decoder is cross-checked three ways: 7-Zip Deflate64 fixtures whose
  data forces the far distance codes (asserted by decoder counters, not
  assumed), zlib-produced Deflate streams through the `.deflate` variant,
  and hand-built streams — for the 16-extra-bit length, which 7-Zip's
  encoder was measured never to emit, and for each rejection rule.

**Negative / accepted**

- A pure-Swift inflater is slower than the Compression framework. It runs
  only for method 9, i.e. for archives whose writer chose it; the measured
  throughput is recorded in the CHANGELOG entry of the release that ships
  it.
- One more parser of attacker-supplied data. It is held to ADR-0001: the
  output bound and CRC still apply, and the strictness rules above leave
  no input that is accepted without being fully decoded.
- The Explorer threshold is community-reported. Nothing depends on it:
  method 9 is decoded wherever it appears.
