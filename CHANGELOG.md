# Changelog

## [Unreleased]

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

[Unreleased]: https://github.com/nlink-jp/zip-porter/compare/v0.2.0...HEAD
[v0.2.0]: https://github.com/nlink-jp/zip-porter/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/nlink-jp/zip-porter/releases/tag/v0.1.0
