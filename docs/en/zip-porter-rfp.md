# RFP: zip-porter

> Generated: 2026-08-01
> Status: Draft

## 1. Problem Statement

When exchanging ZIP files between macOS and Windows, the OS-bundled tools have
unavoidable problems.

- **Creating**: Finder's "Compress" injects `.DS_Store` / `__MACOSX/` / `._*`
  (AppleDouble) files and stores file names in UTF-8 NFD (decomposed dakuten),
  which renders as broken text like "テ゛ータ" on Windows and garbles entirely in
  legacy extraction tools. The GUI also cannot create password-protected ZIPs.
- **Extracting**: Archive Utility garbles Windows-made ZIPs whose file names are
  encoded in CP932 (Shift_JIS), and cannot extract AES-encrypted ZIPs.

These gaps were traditionally filled by MacWinZipper (creation side) and
The Unarchiver (extraction side), but MacWinZipper is no longer suitable for
daily use due to distribution-license constraints and the introduction of
in-app ads. **zip-porter** replaces this with a single clean native macOS app
(MIT licensed, ad-free, fully local) for "creating and extracting ZIPs that
round-trip safely with Windows."

Target users: macOS users who routinely exchange ZIPs containing Japanese file
names with Windows environments (business partners, in-house Windows users).

## 2. Functional Specification

### Commands / API Surface

Single binary. The GUI app executable also answers CLI subcommands (argv
routing before `NSApplicationMain`; a pattern proven by shell-agent v0.7.0 and
grid-edit's `--version`).

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

**pack** — default behavior:

- File names in UTF-8 (general purpose bit 11 set) with **NFC normalization**
- Exclusion list applied: `.DS_Store`, `._*`, `__MACOSX/`, `Icon\r`,
  `.fseventsd`, `.Spotlight-V100`, `.Trashes` (disable with `--no-clean`)
- When a password is given, **AES-256 (WinZip AE-2 format)**
- Opt-in flags: `--cp932` (store names in CP932 for legacy Windows),
  `--zipcrypto` (traditional cipher extractable by Explorer alone; a weakness
  warning is shown)
- Output name: single input produces `<basename>.zip` alongside it; multiple
  inputs require `-o`
- Resource forks and extended attributes are not stored (the tool targets
  Windows round-trips)

**unpack** — default behavior:

- Automatic file-name-encoding detection: bit 11 → definitively UTF-8. Without
  the flag, **UTF-8 validation runs first**; only invalid-UTF-8 names are
  treated as CP932 (ASCII-only names are compatible either way). Force with
  `--encoding`. Note: the original draft said CP932-first, but UTF-8 Japanese
  bytes usually "decode successfully" as CP932 (as mojibake) while CP932
  Japanese is almost never valid UTF-8 — so UTF-8-first is the correct order
  (corrected during implementation)
- Extracts both ZipCrypto and AES-128/192/256 (AE-1/AE-2). Passwords are read
  via an interactive prompt (no terminal echo)
- Destination: alongside the ZIP. If the archive has multiple top-level
  entries, wrap them in a `<zip name>/` folder (The Unarchiver behavior)
- On collision with existing paths, never overwrite — pick a unique name in
  the "name 2" style (Archive Utility behavior)
- **zip-slip protection is mandatory**: paths containing `../` or absolute
  paths must never escape the destination. Symlink entries are skipped by
  default

**inspect** — in addition to the entry list, shows the detected file-name
encoding, encryption method, UTF-8 flag presence, and any junk-file
contamination. Used to diagnose garbled ZIPs and to decide on `--encoding`.

**GUI**:

- A simple single-window drop zone. Version string always visible
- Dropping folders/files shows an **option sheet** every time (destination,
  password on/off, compatibility toggles for CP932/ZipCrypto) before creating.
  The sheet remembers previous values as defaults; a settings option can skip
  the sheet (create immediately)
- Dropping a `.zip` extracts it (with a password sheet if encrypted)
- `.zip` double-click association (`LSHandlerRank` claims Default, same policy
  as grid-edit) → extract alongside the archive
- Progress display with cancellation. Errors surfaced via dialogs

### Input / Output

- Input: local files/folders, and ZIP files
- Output: ZIP files, extracted file trees
- CLI diagnostic output (inspect) is human-readable text; success/failure via
  exit codes
- No network I/O whatsoever

### Configuration

- CLI: flags only (no config file — config would be overkill for a
  single-purpose tool)
- GUI: UserDefaults (remembered sheet defaults, sheet skipping, default
  compatibility mode)

### External Dependencies

None. Fully local. Apple system frameworks only (AppKit, Foundation,
CommonCrypto, Compression) — no third-party dependencies.

## 3. Design Decisions

- **Native Swift/AppKit (the grid-edit line)**: this is a GUI-first tool;
  Finder/Dock integration (drop, file association) and native feel take top
  priority. Follows the conclusion from the csv-editor (Wails) → grid-edit
  replacement that WebView-based UI cannot reach the native macOS experience
- **Single binary with embedded CLI**: bundling a separate binary multiplies
  build targets and complicates path resolution and signing — rejected per
  established org knowledge
- **SPM two-target layout**: `ZipPorterCore` (UI-independent engine: ZIP R/W,
  encoding conversion, crypto; AppKit imports forbidden; tests mandatory) +
  `ZipPorter` (AppKit app + CLI routing). Same shape as grid-edit
- **Self-implemented crypto**: WinZip AES (AE-2: PBKDF2-HMAC-SHA1 at 1000
  iterations, AES-CTR with little-endian counter, HMAC-SHA1 authentication)
  and ZipCrypto, built on CommonCrypto (`CCKeyDerivationPBKDF` / `CCCrypt` in
  CTR mode). The specifications are public and deterministically testable.
  **Cross-verification against real ZIPs produced by 7-Zip, Info-ZIP, and
  Windows' built-in tooling is an acceptance criterion**
- **Modern-leaning defaults**: Windows 10/11 Explorer handles UTF-8-flagged
  ZIPs correctly, so the defaults are UTF-8+NFC / AES-256. CP932 / ZipCrypto
  are opt-ins for legacy receiving environments. The environment has moved on
  from the Windows 7 era that MacWinZipper assumed
- **Explicitly out of scope**: other formats such as 7z / RAR / tar (keep
  using The Unarchiver / Keka), Windows / Linux binaries, performance tuning
  for enormous ZIP64 archives (read/write correctness is guaranteed;
  optimization is deferred), file-name encryption (does not exist in the ZIP
  spec), cloud integration
- **Relationship to existing tools**: no overlap with existing nlink-jp
  tools; replaces two commercial third-party apps

## 4. Development Plan

### Phase 1: Core (engine + CLI)

- `ZipPorterCore`: ZIP reader/writer, NFC normalization, CP932⇔UTF-8
  conversion, encoding auto-detection, ZipCrypto/AES encryption/decryption,
  exclusion filter, zip-slip guard
- CLI subcommands (pack/unpack/inspect/--version) complete
- Tests: unit tests + cross-verification fixtures (extracting ZIPs produced
  by 7-Zip, Info-ZIP, and Windows' built-in "Compressed Folders"; verifying
  produced ZIPs extract correctly on Windows)
- **Independently reviewable**: complete as a CLI; real-data E2E possible

### Phase 2: GUI

- Drop window, option sheet, password sheet, progress/cancel
- `.zip` association (Info.plist document type + LSHandlerRank)
- en/ja localization (grid-edit's .lproj pattern)
- **Independently reviewable**: the Phase 1 CLI serves as the regression
  baseline

### Phase 3: Release

- Sign + notarize + staple, GitHub Releases (zip verification: Developer ID /
  `--version` response), homebrew-tap cask, util-series submodule
  integration, catalog / org profile updates, check-org.sh all green
- README.md / README.ja.md / CHANGELOG.md / AGENTS.md complete

## 5. Required API Scopes / Permissions

None (no external services, APIs, or credentials). No special macOS
permissions either (non-sandboxed; user-selected files only).

## 6. Series Placement

Series: **util-series**

Reason: a general-purpose data transformation/processing tool with no
security-investigation (cybersecurity) or LLM (lite) character. Placing
GUI-first tools in util-series matches the precedents of grid-edit,
url-shelf, and share-mounter. Per CONVENTIONS.md, development starts in
`_wip/zip-porter/` and integrates into util-series as a submodule at release.

## 7. External Platform Constraints

- **Windows Explorer (receiving side)**: Windows 10/11 supports
  UTF-8-flagged file names and extraction of ZipCrypto-encrypted ZIPs.
  **AES-encrypted ZIPs are not supported** (recipients need 7-Zip or
  similar) → document this for recipients in the README and recommend
  `--zipcrypto` for Explorer-only counterparts
- **Legacy Japanese environments**: old extraction tools (Lhaplus etc.)
  ignore the UTF-8 flag and assume CP932 → handled by the `--cp932` opt-in
- **ZipCrypto weakness**: breakable via known-plaintext attacks. Provided for
  compatibility only; both GUI and CLI warn when selected
- **macOS Gatekeeper**: distribution requires Developer ID signing +
  notarization (established org process)
- Target OS: macOS 14+ / arm64 prebuilt (same policy as grid-edit)

---

## Discussion Log

1. **Problem breakdown**: decomposed the OS-bundled-tool problems into the
   creation and extraction sides. Confirmed the existing division of roles —
   MacWinZipper = creation, The Unarchiver = extraction — and the decision to
   self-replace prompted by the ads/licensing situation
2. **Scope**: judged a full The Unarchiver replacement (multi-format
   extraction) too large; fixed scope to **ZIP only**. Keep using existing
   apps for 7z/RAR
3. **Form factor**: user specified "GUI-first with embedded CLI subcommands
   (single binary)," matching the org's proven pattern
4. **Default policy**: adopted "modern-leaning" (UTF-8+NFC / AES-256, legacy
   as opt-in), justified by Windows 10/11 UTF-8-flag support
5. **GUI technology**: compared Wails (mature Go engine libraries) against
   native Swift (best feel and integration, but requires self-implementing
   WinZip AES); chose **Swift/AppKit**, conditional on cross-verification
   fixtures backing the self-implemented crypto
6. **Naming**: chose **zip-porter** from zip-bridge / clean-zip / zip-porter
7. **UX details**: creation shows an option sheet every time (skippable via
   settings); extraction gets `.zip` association with same-folder extraction;
   the development plan is fixed at three phases — engine+CLI → GUI → release
