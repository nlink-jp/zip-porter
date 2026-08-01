# zip-porter

Windows-safe ZIP creation and extraction for macOS, built with Swift/AppKit.

zip-porter replaces the combination of MacWinZipper (creation) and
The Unarchiver (extraction, for ZIPs) with a single clean, ad-free, MIT-licensed
app that works fully offline:

- **Create** ZIPs that open correctly on Windows: macOS junk files
  (`.DS_Store`, `__MACOSX/`, AppleDouble `._*`) are excluded, file names are
  stored as NFC-normalized UTF-8 (no more split-dakuten "テ゛ータ"), and
  password protection (AES-256) is built in
- **Extract** ZIPs made on Windows: CP932 (Shift_JIS) file names are
  auto-detected and decoded, and both ZipCrypto and AES encrypted archives
  are supported
- **Legacy compatibility on demand**: `--cp932` stores file names for old
  Japanese Windows tools; `--zipcrypto` produces archives Windows Explorer
  can open standalone (with a weakness warning)

> See the [RFP](docs/en/zip-porter-rfp.md) for the full specification.
> Output verified on Windows Explorer with real archives (UTF-8 names,
> junk-free trees, ZipCrypto extraction).

## Install

```
brew install --cask nlink-jp/tap/zip-porter
```

Or download the notarized `.app` from
[Releases](https://github.com/nlink-jp/zip-porter/releases).

## GUI

Launch ZipPorter and drop things on the window:

- **Drop files or folders** → an options sheet (password, CP932, ZipCrypto)
  appears, then a Windows-safe ZIP is created next to the input. The sheet
  remembers its settings and can be skipped ("Don't show these options
  again"; re-enable in Settings)
- **Drop a `.zip`** (or double-click one — ZipPorter registers as a ZIP
  handler) → it is extracted. Encrypted archives prompt for the password
- **Settings** (the gear in the window, or ⌘,) — The Unarchiver-style
  extraction preferences:
  destination (same folder / ask every time / a fixed folder), when to
  create a wrapper folder (never / only for multiple top-level items /
  always), the created folder's modification date, reveal-in-Finder, and
  move-archive-to-Trash

## CLI

The same app binary doubles as a CLI:

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

Run with no command to launch the GUI.

### pack

- Excludes macOS junk (`.DS_Store`, `__MACOSX/`, AppleDouble `._*`,
  Finder `Icon\r`, Spotlight/fseventsd/Trashes) — disable with `--no-clean`
- File names are NFC-normalized UTF-8 with the UTF-8 flag; `--cp932` stores
  CP932 names instead (names CP932 cannot represent are an error)
- `--password` prompts interactively (passwords never appear in argv) and
  encrypts with AES-256 (WinZip AE-2); `--zipcrypto` selects the weaker
  Explorer-compatible cipher, with a warning
- Already-compressed extensions (jpg, png, mp4, zip, …) are stored, the
  rest deflated; symlinks are skipped
- An existing output name is never overwritten — "name 2.zip" is used

### unpack

- Name encoding auto-detection: the UTF-8 flag wins; unflagged names are
  validated as UTF-8 first and treated as CP932 otherwise. Override with
  `--encoding utf8|cp932`
- Extracts ZipCrypto and AES-128/192/256 (AE-1/AE-2) archives; prompts for
  a password on demand
- A single top-level item extracts as itself; anything else is wrapped in
  a folder named after the archive. Existing files are never overwritten
  ("name 2")
- Extracts to the archive's own folder by default, or `-o <dir>`
  (created if missing, like `unzip -d`)

### Extraction safety

An unarchiver runs attacker-chosen structure against your filesystem, so
extraction refuses malformed archives rather than trying to salvage them
(see [ADR-012](https://github.com/nlink-jp/.github/blob/main/adr/012-zip-porter-hardening.md)):

- **zip-slip protection** — absolute paths, `..`, drive letters, and NTFS
  alternate-data-stream names are skipped and reported; symlink entries
  are skipped in both directions
- **Decompression bombs** — an entry that expands past the size its header
  declares is aborted mid-stream, and the whole archive is refused up front
  when its declared content cannot fit in the destination's free space
- **Overlapping entries** — archives whose entries share compressed data
  (the `42.zip` construction) are rejected while parsing
- **Quarantine propagation** — `com.apple.quarantine` on a downloaded
  archive is copied onto everything extracted, so Gatekeeper still
  evaluates executables that arrive inside a ZIP
- **Duplicate names** — collisions (including case-only and NFC/NFD
  differences, which APFS treats as one name) are extracted under numbered
  names instead of silently overwriting each other
- Integrity is verified for every entry: HMAC for AES, CRC-32 otherwise

### inspect

Prints each entry's size, method, encryption, and UTF-8-flag state, plus
the archive-wide detected name encoding and any macOS junk entries —
useful for diagnosing mojibake before extracting.

## Requirements

- macOS 14+ (Apple Silicon)

## Build

```
make build      # swift build -c release
make test       # swift test
make build-app  # assemble + Developer-ID sign dist/ZipPorter.app
make package    # notarize + staple + zip the release asset
```

## Notes for recipients on Windows

- AES-256 encrypted ZIPs require 7-Zip (or similar) on Windows — Explorer
  alone cannot open them. Use `--zipcrypto` when the recipient can only use
  Explorer (weaker encryption; a warning is shown).

## License

MIT
