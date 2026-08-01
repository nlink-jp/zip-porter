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

> **Status: scaffold.** The engine (Phase 1) is in development. See the
> [RFP](docs/en/zip-porter-rfp.md) for the full specification and plan.

## Usage

The GUI app binary doubles as a CLI:

```
zip-porter pack <input>... [-o <output.zip>] [--password] [--cp932] [--zipcrypto] [--no-clean]
zip-porter unpack <input.zip> [-o <dest-dir>] [--password] [--encoding auto|utf8|cp932]
zip-porter inspect <input.zip>
zip-porter --version
```

Run with no command to launch the GUI (drop files to pack, drop a `.zip` to
unpack).

`pack`, `unpack`, and `inspect` are not implemented yet.

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
