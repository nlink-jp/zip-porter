# AGENTS.md — zip-porter

## What it is

Windows-safe ZIP creation/extraction for macOS (Swift, AppKit). Replaces
MacWinZipper (creation) and The Unarchiver (extraction, ZIP only) with one
clean, ad-free, fully-local app. **Apple Silicon, macOS 14+.**

**Status:** Scaffold complete — SPM structure, single-binary CLI routing
(`--version` working; `pack`/`unpack`/`inspect` stubs), junk filter and
file-name transforms with tests, minimal GUI window. Engine (Phase 1: ZIP
R/W, crypto, encoding auto-detect) not started. Design of record:
`docs/en/zip-porter-rfp.md` / `docs/ja/zip-porter-rfp.ja.md`.

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
- Icon and real version can only be verified in the `.app`; bare `swift run`
  has no bundle so `AppInfo.version` falls back to `"dev"`.

## Layout

```
Package.swift               SPM manifest; ZipPorterCore lib + ZipPorter exe + 2 test targets
Info.plist                  bundle template; ${APP_NAME}/${BUNDLE_ID}/${VERSION} substituted by make;
                            declares the ZIP document type (Viewer, LSHandlerRank Default)
Makefile                    build / build-app / package / brew
Sources/ZipPorterCore/      UI-independent ZIP engine (junk filter, name transforms; later:
                            ZIP R/W, crypto, encoding detection). No AppKit imports.
Sources/ZipPorter/          AppKit app: entry point + CLI routing, main menu, (scaffold) window
Tests/ZipPorterCoreTests/   engine unit tests
Tests/ZipPorterTests/       app-layer unit tests (CLI routing)
scripts/                    vendored org templates: codesign/notarize/make-icns/brew
docs/{en,ja}/               RFP (design of record)
assets/                     AppIcon-1024.png source (not yet added)
```

## Project rules

- **ZipPorterCore never imports AppKit.** ZIP reading/writing, file-name
  encoding (NFC / CP932), junk filtering, and crypto live here as pure,
  unit-tested logic. UI code consumes them.
- **Feature scope is the RFP.** ZIP only — no 7z/RAR/tar, no Windows/Linux
  binaries, no cloud. These are deliberate, documented rejections; propose
  an ADR before revisiting.
- **Crypto is self-implemented on CommonCrypto** (WinZip AE-2, ZipCrypto).
  Cross-verification fixtures against ZIPs produced by 7-Zip / Info-ZIP /
  Windows built-in tooling are an acceptance criterion — never ship crypto
  changes on unit tests alone.
- **Modern defaults, legacy opt-in.** UTF-8 + NFC names and AES-256 by
  default; `--cp932` / `--zipcrypto` are explicit flags with warnings.
- **zip-slip protection is mandatory** in the extractor; symlink entries are
  skipped by default.
- **Passwords never appear in argv** — interactive prompt only (no echo).
- `make build`, never bare `swift build` outputs into the repo root;
  artifacts belong in `dist/` and `.build/`.
- `--version` must keep answering on stdout without launching the UI.

## Gotchas

- **CP932 needs the CF DOS-Japanese encoding** — `String.Encoding.shiftJIS`
  rejects the Microsoft extension characters (①, ㈱, …); see
  `FileNameTransform.cp932`.
- **CLI routing must let flag-style argv fall through to the GUI** —
  LaunchServices injects `-psn_…` / `-NS…` arguments at launch; only an
  unrecognized bare word is a CLI error.
- The entry point is `@MainActor` (`ZipPorterMain`) — AppKit setup calls
  MainActor-isolated code from `main()`.
- Signing: pure AppKit needs **no entitlements** — `codesign-darwin-app.sh`
  is called with the entitlements argument intentionally omitted (see
  CONVENTIONS.md §Native Swift / AppKit).
- New behaviour ships with tests, README.md + README.ja.md updated in the
  same commit, and a CHANGELOG entry (org pre-completion checklist).
