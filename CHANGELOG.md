# Changelog

## [Unreleased]

## [v0.6.0] - 2026-08-01

Single-file parallel deflate on zlib ([ADR-014](https://github.com/nlink-jp/.github/blob/main/adr/014-zip-porter-zlib-parallel-deflate.md)).

### Changed

- **Deflate now runs on the system zlib at level 6**, and entries above
  32 MB compress as independent ~16 MB blocks in parallel, joined with
  sync flushes into one standard deflate stream (the pigz technique).
  A single 180 MB text file: 2.82 s → 0.87 s, and 9 % smaller. Every
  archive now matches `ditto`/Info-ZIP output size, removing the size
  penalty carried since v0.1.0
- Verified against five independent readers: Info-ZIP unzip, 7-Zip,
  Apple ditto, Python zipfile, and our own extractor
- Peak memory for the block path stays around cores × 32 MB regardless
  of file size; inflate is unchanged (Compression framework)
- Trade-off, accepted per the ADR: many-small-file text workloads pay
  zlib's slower per-stream speed for the smaller output (240 MB of text:
  0.73 s → 1.21 s, 9 % smaller; still ~6× faster than `ditto`)

## [v0.5.0] - 2026-08-01

Compression throughput ([ADR-013](https://github.com/nlink-jp/.github/blob/main/adr/013-zip-porter-parallel-compression.md)).

### Changed

- **Entries are compressed in parallel** and written in the same order as
  before, so archives stay byte-for-byte deterministic. On a 12-core
  machine, a 310 MB / 150-file corpus went from 5.43 s to 1.72 s (3.2×);
  240 MB of text from 2.87 s to 0.73 s (3.9×). Memory stays bounded:
  compressed output above 16 MB spills to a scratch file that the writer
  drains and deletes
- **Data that does not compress is stored instead of deflated**, decided by
  test-compressing the head of each file rather than trusting its
  extension. 100 MB of random data went from 2.07 s to 0.39 s (5.3×), and
  the archive is slightly *smaller* — deflate adds framing to data it
  cannot shrink
- A single-entry archive keeps the old streaming path; there is nothing to
  overlap

Not included: parallelising a single large file's deflate stream, and a
user-facing compression level. Both need libz and are under investigation.

## [v0.4.1] - 2026-08-01

### Fixed

- The destination popup's "ask" item was worded for extraction ("展開先
  フォルダを確認") and read wrong in the creation section; both now say
  "毎回確認する" / "Ask every time"

## [v0.4.0] - 2026-08-01

### Added

- **The creation side gets the same destination choice as extraction** —
  Settings › Creating › "Create in:" offers the same folder as the original
  items (the previous behavior), a fixed folder, or asking every time via a
  save panel where the name can be changed too. When a path is chosen in
  that panel, replacing an existing archive is honored instead of falling
  back to a numbered name

## [v0.3.1] - 2026-08-01

### Changed

- **A ZIP opened from Finder no longer opens the droplet window** — the
  double-click already said what to do, so only the status dialog appears,
  and the app leaves when the work is done. Clicking the Dock icon brings
  the droplet window back and keeps the app around

### Fixed

- The password dialog squeezed its input field against the right edge; it
  and the pack options dialog now share even margins with their fields
  spanning the full width

## [v0.3.0] - 2026-08-01

### Added

- **Operation status dialog** — packing and extracting now show a sheet with
  live status while they run, which then turns into a result summary (what
  was created or extracted, how many files and folders) instead of finishing
  invisibly. Skipped unsafe paths, skipped symlinks, renamed duplicates and
  excluded macOS metadata are listed there too, replacing the separate
  post-extraction alert

### Changed

- **Opening a ZIP from Finder no longer leaves the app running.** When
  ZipPorter is started by a double-clicked archive, it quits once the work
  is done and its result dialog is dismissed. Dropping onto the window, or
  opening an archive while the app is already running, keeps it around as
  before

### Fixed

- Open events that arrived before the window existed (the Finder
  double-click path) ran without any dialog and left the app idling

## [v0.2.2] - 2026-08-01

### Added

- Settings: "Reveal the created archive in Finder" — creating a ZIP always
  jumped to Finder, while extraction had a toggle for it. Now both do
  (on by default, matching the previous behavior)

## [v0.2.1] - 2026-08-01

### Changed

- Settings window: wider, with each labelled choice indented into its own
  group and more breathing room between them. It was cramped, and the
  destination popup was clipped at the window edge
- The drop window gets a settings button, so preferences are reachable
  without going through the menu bar

## [v0.2.0] - 2026-08-01

Extraction hardening ([ADR-012](https://github.com/nlink-jp/.github/blob/main/adr/012-zip-porter-hardening.md)).
An unarchiver executes attacker-chosen structure against the user's
filesystem; these checks make malformed archives fail early and loudly
instead of consuming resources or silently losing data.

### Added

- **Fail-fast size enforcement** — an entry producing more output than its
  header declares is aborted mid-stream (`sizeExceedsDeclared`) instead of
  writing an unbounded amount and only then failing the size check
- **Pre-flight space budget** — the archive's declared total is checked
  against the destination volume's free space (64 MiB margin) before
  anything is written (`insufficientSpace`)
- **Overlapping-entry rejection** — archives whose entry byte ranges
  coincide (the `42.zip` construction) are refused while parsing
  (`overlappingEntries`); entries running past EOF are refused too
- **Quarantine propagation** — `com.apple.quarantine` on the source archive
  is copied onto every extracted file and directory, restoring the
  Gatekeeper coverage Archive Utility and The Unarchiver provide
- **Duplicate-name uniquification** — colliding entry names (including
  case-only and NFC/NFD differences, which APFS resolves to one file) are
  extracted as "name 2", "name 3", … instead of overwriting each other
- The GUI now surfaces skipped unsafe paths, skipped symlinks, and renamed
  duplicates after extraction; `inspect` reports the declared total size
  and any unsafe paths or symlinks extraction would skip

### Changed

- Central-directory size ceiling lowered from 2 GiB to 256 MiB
- Extraction and archive errors get specific, localized messages in the GUI

## [v0.1.0] - 2026-08-01

### Added

- **Engine**: ZIP reader/writer in `ZipPorterCore`
  - Central-directory parsing (ZIP64-aware), streaming extraction with CRC
    verification; streaming creation with local-header patch-back
  - File-name encoding: NFC-normalized UTF-8 (flagged) or CP932 on pack;
    auto-detection on unpack (UTF-8 flag > UTF-8 validation > CP932)
  - Encryption: ZipCrypto and WinZip AES (AE-1/AE-2) decrypt; ZipCrypto and
    AES-256 (AE-2) encrypt — cross-verified against Info-ZIP, Apple ditto,
    7-Zip, and a spec-derived CP932 generator; real-machine verified on
    Windows Explorer (UTF-8 names, junk-free trees, ZipCrypto extraction)
  - Junk filter (`.DS_Store`, `__MACOSX/`, AppleDouble, `Icon\r`, …)
- **CLI**: `pack` / `unpack` / `inspect`
  - pack: junk filtering (`--no-clean`), `--cp932`, `--password` (interactive
    prompt, AES-256 default), `--zipcrypto` with weakness warning, store for
    compressed extensions, unique output names
  - unpack: encoding auto-detect with `--encoding` override, zip-slip guard,
    symlink skip, folder policies, "name 2" collisions, prompt-on-demand
    password, mtime/permission restore
  - inspect: per-entry method/encryption/flag table, archive encoding
    verdict, junk contamination report
- **GUI**: drag-and-drop window (files/folders → pack, `.zip` → extract),
  `.zip` double-click handling, per-drop pack options sheet (password
  AES-256/ZipCrypto, CP932, remembered defaults, skippable), progress
  sheets with cancel, password prompt-on-demand
- **Settings window (⌘,)** — The Unarchiver-style extraction preferences:
  destination (same folder / ask / fixed), wrapper-folder policy
  (never / only-multiple / always), created-folder modification date,
  reveal in Finder, move archive to Trash
- en/ja localization; app icon

[Unreleased]: https://github.com/nlink-jp/zip-porter/compare/v0.6.0...HEAD
[v0.6.0]: https://github.com/nlink-jp/zip-porter/compare/v0.5.0...v0.6.0
[v0.5.0]: https://github.com/nlink-jp/zip-porter/compare/v0.4.1...v0.5.0
[v0.4.1]: https://github.com/nlink-jp/zip-porter/compare/v0.4.0...v0.4.1
[v0.4.0]: https://github.com/nlink-jp/zip-porter/compare/v0.3.1...v0.4.0
[v0.3.1]: https://github.com/nlink-jp/zip-porter/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/nlink-jp/zip-porter/compare/v0.2.2...v0.3.0
[v0.2.2]: https://github.com/nlink-jp/zip-porter/compare/v0.2.1...v0.2.2
[v0.2.1]: https://github.com/nlink-jp/zip-porter/compare/v0.2.0...v0.2.1
[v0.2.0]: https://github.com/nlink-jp/zip-porter/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/nlink-jp/zip-porter/releases/tag/v0.1.0
