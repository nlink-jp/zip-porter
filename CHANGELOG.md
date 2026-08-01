# Changelog

## [Unreleased]

### Added

- Project scaffold: SPM two-target layout (`ZipPorterCore` UI-independent
  engine + `ZipPorter` AppKit app with single-binary CLI routing)
- CLI skeleton: `--version` answers on stdout without launching the UI;
  `pack` / `unpack` / `inspect` are routed but not yet implemented
- Engine seed: junk-file filter (`.DS_Store`, `__MACOSX/`, AppleDouble,
  Finder `Icon\r`, Spotlight/fsevents/Trashes) and file-name transforms
  (NFC normalization, CP932 encode/decode) with tests
- RFP (design of record): `docs/ja/zip-porter-rfp.ja.md` /
  `docs/en/zip-porter-rfp.md`
