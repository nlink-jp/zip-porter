# Changelog

## [Unreleased]

### Added

- **GUI (RFP Phase 2)**: drag-and-drop window (files/folders → pack,
  `.zip` → extract), `.zip` double-click handling, per-drop pack options
  sheet (password AES-256/ZipCrypto, CP932, remembered defaults,
  skippable), progress sheets with cancel, password prompt-on-demand
- **Settings window (⌘,)** — The Unarchiver-style extraction preferences:
  destination (same folder / ask / fixed), wrapper-folder policy
  (never / only-multiple / always), created-folder modification date,
  reveal in Finder, move archive to Trash
- en/ja localization; app icon

- **Engine (RFP Phase 1)**: ZIP reader/writer in `ZipPorterCore`
  - Central-directory parsing (ZIP64-aware), streaming extraction with CRC
    verification; streaming creation with local-header patch-back
  - File-name encoding: NFC-normalized UTF-8 (flagged) or CP932 on pack;
    auto-detection on unpack (UTF-8 flag > UTF-8 validation > CP932)
  - Encryption: ZipCrypto and WinZip AES (AE-1/AE-2) decrypt; ZipCrypto and
    AES-256 (AE-2) encrypt — cross-verified against Info-ZIP, Apple ditto,
    7-Zip, and a spec-derived CP932 generator
  - Junk filter (`.DS_Store`, `__MACOSX/`, AppleDouble, `Icon\r`, …)
- **CLI**: `pack` / `unpack` / `inspect` fully implemented
  - pack: junk filtering (`--no-clean`), `--cp932`, `--password` (interactive
    prompt, AES-256 default), `--zipcrypto` with weakness warning, store for
    compressed extensions, unique output names
  - unpack: encoding auto-detect with `--encoding` override, zip-slip guard,
    symlink skip, single-item vs wrapper-folder policy, "name 2" collisions,
    prompt-on-demand password, mtime/permission restore
  - inspect: per-entry method/encryption/flag table, archive encoding
    verdict, junk contamination report
- Project scaffold: SPM two-target layout, single-binary CLI routing,
  signed .app assembly, RFP (design of record)
