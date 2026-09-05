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
- **Select several `.zip` files and open them together** → they are
  extracted as one job: one progress bar across the whole set ("2 of 3 —
  foo.zip"), one question if the destination is set to *ask every time*,
  one password tried across the set, one result, one Finder reveal. An
  archive that fails does not stop the rest — the result says "2 of 3
  extracted" and names what failed
- Both operations show a status dialog with a byte-accurate progress bar
  while they run. How a clean finish is announced is up to you — a
  notification (default), a dialog, or nothing (Settings › General).
  Clicking the notification shows the result in Finder. The result dialog
  appears regardless when something needs reading — skipped unsafe paths,
  skipped symlinks, renamed duplicates, or an archive that failed. Excluded
  macOS metadata is routine and just goes in the completion line. A ZIP
  being created exists as `name.zip.part` until it is complete. An archive
  opened by double-click shows only that dialog — no droplet window — and
  the app leaves as soon as the work is done; dropping onto the window
  leaves it open for the next file. Archives opened while one is still
  running are queued and handled in turn
- **Settings** (the gear in the window, or ⌘,) — The Unarchiver-style
  extraction preferences:
  destination (same folder / ask every time / a fixed folder), when to
  create a wrapper folder (never / only for multiple top-level items /
  always), the created folder's modification date, reveal-in-Finder, and
  move-archive-to-Trash. Creating has the same destination choice (next to
  the originals / a fixed folder / ask every time), plus whether to show
  the options sheet and whether to reveal the new archive in Finder
- **Keyboard** — the usual editing shortcuts work in the password fields
  (⌘X / ⌘C / ⌘V / ⌘A / ⌘Z), and ⌘W closes the droplet window, which ends
  the session just like clicking its red button

The GUI is single-instance: starting a second copy (for example, a
completion-banner click resolving to a different copy of the .app) logs
to stderr and exits, leaving the running instance alone. CLI runs are
not affected — concurrent `pack`/`unpack` invocations keep working.

## CLI

The same binary inside the app doubles as a CLI. Installing the cask puts
`zip-porter` on your PATH:

```bash
brew install --cask nlink-jp/tap/zip-porter
zip-porter --version
```

If you installed the `.app` by hand instead, the executable lives inside
the bundle — link it yourself:

```bash
ln -s "/Applications/ZipPorter.app/Contents/MacOS/ZipPorter" /usr/local/bin/zip-porter
```

Commands:

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
(see [ADR-0001](docs/en/adr/0001-extraction-hardening.md)):

- **zip-slip protection** — absolute paths, `..`, drive letters, and NTFS
  alternate-data-stream names are skipped and reported; symlink entries
  are skipped in both directions
- **Decompression bombs** — an entry that expands past the size its header
  declares is aborted mid-stream, and the whole archive is refused up front
  when its declared content cannot fit in the destination's free space
- **Overlapping entries** — archives whose entries share compressed data
  (the `42.zip` construction) are rejected while parsing; the ranges are
  taken from the same local headers extraction reads, so an extra field
  cannot hide the overlap
- **Quarantine propagation** — `com.apple.quarantine` on a downloaded
  archive is copied onto everything extracted — files and folders alike,
  including folders the archive only implies — so Gatekeeper still
  evaluates an app that arrives inside a ZIP. If the attribute cannot be
  set, the items are named in the result rather than passed over
- **Permissions** — the modes an archive asks for are masked with your
  umask, the way `unzip` does it, so a ZIP cannot drop world-writable
  files into your folders
- **Duplicate names** — collisions (including case-only and NFC/NFD
  differences, which APFS treats as one name) are extracted under numbered
  names instead of silently overwriting each other
- **Clean failure** — an extraction that fails part-way removes only the
  items it created itself. Something that appeared at one of its names in
  the meantime (another extraction, a download, a stale symlink) makes the
  extraction fail rather than being reused or deleted
- Integrity is verified for every entry: HMAC for AES, CRC-32 otherwise

### Performance

Entries are compressed in parallel and written in order, so archives remain
byte-for-byte deterministic. Files whose head does not compress are stored
rather than deflated — faster, and smaller. Large files additionally
compress as independent blocks in parallel (zlib, the pigz join), so a
single 180 MB file packs in under a second on a 12-core machine; a
310 MB / 150-file mixed corpus takes 1.8 s where Apple `ditto` needs 6.9 s
— at the same output size. Design notes:
[ADR-0002](docs/en/adr/0002-parallel-compression.md),
[ADR-0003](docs/en/adr/0003-zlib-parallel-deflate.md).

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
