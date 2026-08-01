# AGENTS.md — zip-porter

## What it is

Windows-safe ZIP creation/extraction for macOS (Swift, AppKit). Replaces
MacWinZipper (creation) and The Unarchiver (extraction, ZIP only) with one
clean, ad-free, fully-local app. **Apple Silicon, macOS 14+.**

**Status:** Released (see `git tag` for the current version) — engine
(`ZipPorterCore`: ZIP R/W, ZIP64, ZipCrypto + WinZip AES, encoding
auto-detect, junk filter), full CLI (`pack` / `unpack` / `inspect`), and
the AppKit GUI (drop window, pack options sheet, Unarchiver-style
extraction settings window, `.zip` handling, en/ja l10n, icon). ~90 tests
including cross-verification against Info-ZIP, ditto, 7-Zip, and Python
zipfile; output real-machine verified on Windows Explorer. Design of
record: `docs/en/zip-porter-rfp.md` / `docs/ja/zip-porter-rfp.ja.md`.

## Build / test / run

```sh
make build      # swift build -c release
make test       # swift test
make run        # swift run (debug)
make build-app  # assemble + Developer-ID sign dist/ZipPorter.app
make package    # notarize + staple + zip the release asset
make brew       # generate the Homebrew cask into ../homebrew-tap
```

- `zip-porter --version` prints the version and exits before AppKit starts
  (`brew test` depends on this).
- `scripts/gen-fixtures.sh` regenerates `Tests/.../testdata` with external
  tools (zip, ditto, python3, 7zz — `brew install 7zip`). Fixtures are
  committed; rerun only to change the fixture set.

## Layout

```
Package.swift               SPM manifest; ZipPorterCore lib + ZipPorter exe + 2 test targets
Info.plist                  bundle template; declares the ZIP document type (Viewer, Default)
Makefile                    build / build-app / package / brew
Sources/ZipPorterCore/      UI-independent engine (no AppKit): CRC32, DOSDateTime,
                            ZipStructures, DeflateStream, ZipReader, ZipWriter,
                            ZipCryptoCipher, WinZipAES, EncodingDetector,
                            JunkFilter, FileNameTransform, Packer, Unpacker, PathUtil
Sources/ZipPorter/          AppKit app + CLI: App (entry/routing/delegate), CLI (usage),
                            CLICommands (parse + run), PasswordPrompt, MainMenu,
                            MainViewController (flows), DropView, Sheets (options/
                            password/progress), SettingsWindow, Preferences, L10n,
                            Resources/{en,ja}.lproj
Tests/ZipPorterCoreTests/   engine tests + testdata/ cross-verification fixtures
Tests/ZipPorterTests/       CLI routing/parsing tests
scripts/                    vendored org templates + gen-fixtures.sh
docs/{en,ja}/               RFP (design of record)
```

## Project rules

- **ZipPorterCore never imports AppKit.** All engine logic is pure,
  unit-tested code; the GUI (Phase 2) and CLI both consume Packer/Unpacker.
- **Scope is the RFP.** ZIP only — no 7z/RAR/tar, no Windows/Linux builds,
  no cloud. Propose an ADR before revisiting.
- **Crypto changes require cross-verification fixtures**, not just unit
  tests (7-Zip / Info-ZIP / Windows-made ZIPs; see gen-fixtures.sh).
- **Security invariants**: zip-slip guard in Unpacker.sanitize, symlinks
  skipped both directions, passwords via prompt only (never argv),
  passwordRequired fires before any disk write, failed extractions clean up.
- **Defaults are modern** (UTF-8+NFC, AES-256); CP932 / ZipCrypto stay
  opt-in flags with warnings.
- `make build`, never bare `swift build` outputs into the repo root.
- `--version` must keep answering on stdout without launching the UI.

## Gotchas

- **Encoding detection order is UTF-8-first** (flag > UTF-8 validation >
  CP932). CP932-first looks right but silently mojibakes unflagged UTF-8
  archives — UTF-8 Japanese bytes usually "succeed" as CP932; the reverse
  almost never. Don't flip it back.
- **Foundation hides AppleDouble `._*` files from every directory listing**
  (enumerator, contentsOfDirectory — POSIX readdir sees them). Packing can
  therefore never include them, `--no-clean` or not. The `._` junk rule
  still matters for unpack/inspect, where foreign ZIPs contain them.
- **Use `enumerator(atPath:)`, not `enumerator(at: URL)`, for pack walks.**
  URL-based enumeration standardizes `/private/tmp` → `/tmp`, breaking
  relative-path prefix arithmetic; path-based enumeration returns relative
  paths directly (type via `enumerator.fileAttributes`).
- **Compression framework's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951)**
  — no zlib wrapper — which is exactly ZIP method 8. Don't add headers.
- **WinZip AES-CTR uses a little-endian counter starting at 1** (not the
  NIST big-endian variant); keystream generated via AES-ECB over bulk
  counter blocks. AE-2 zeroes the CRC field — skip CRC check, trust HMAC.
- **ZipCrypto needs the plaintext CRC before writing** (check byte). The
  writer does a CRC pre-pass over the source; entry sources must therefore
  be re-openable.
- **CP932 needs the CF DOS-Japanese encoding** — `String.Encoding.shiftJIS`
  rejects MS extension chars (①, ㈱); see `FileNameTransform.cp932`.
- **Extracted names become NFD on disk** (Foundation's fileSystemRepresentation
  decomposes). Byte-level name comparisons in tests must normalize; APFS
  resolves both forms to the same file, so users are unaffected.
- **Local-header name/extra lengths can differ from the central directory's**
  — data offsets must be computed from the local copies; sizes/CRC from the
  central directory (authoritative).
- CLI routing must let flag-style argv fall through to the GUI
  (LaunchServices injects `-psn_…` / `-NS…`); only an unrecognized bare
  word is a CLI error.
- The entry point is `@MainActor` (`ZipPorterMain`); AppKit setup calls
  MainActor-isolated code from `main()`.
- Signing: pure AppKit needs **no entitlements** (see CONVENTIONS.md).
- Interactive password E2E uses `/usr/bin/expect` (`script -q` piping
  hangs); see the session E2E notes.
- New behaviour ships with tests, README.md + README.ja.md updated in the
  same commit, and a CHANGELOG entry (org pre-completion checklist).
