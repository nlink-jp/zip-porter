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
  (`brew test` depends on this). The cask symlinks the embedded CLI onto
  PATH (`BREW_BINARY` in the Makefile); launched that way `Bundle.main` is
  NOT the .app, so `AppInfo.version` falls back to the Info.plist beside
  the resolved executable — keep that fallback or the symlink reports
  "dev".
- `scripts/gen-fixtures.sh` regenerates the benign `Tests/.../testdata`
  fixtures with external tools (zip, ditto, python3, 7zz —
  `brew install 7zip`); `scripts/gen-hostile-fixtures.py <dir>` regenerates
  the ADR-012 attack fixtures. Both sets are committed; rerun only to
  change what the fixtures contain.

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
- **Security invariants** (ADR-012 — do not relax any of these without a
  superseding ADR): zip-slip guard in `Unpacker.sanitize`; symlinks skipped
  both directions; passwords via prompt only (never argv); passwordRequired
  and the space-budget check fire before any disk write; failed extractions
  clean up only what they created; per-entry output is bounded by the
  declared size (fail-fast); overlapping/past-EOF entry ranges are rejected
  at open; `com.apple.quarantine` propagates to extracted items; duplicate
  names are uniquified, never overwritten.
- **Hostile fixtures live in `scripts/gen-hostile-fixtures.py`** — bombs,
  overlap, duplicates, truncation. Our own writer cannot produce these
  structures, which is the point: they are built from the format spec.
- **Packing compresses in parallel and writes sequentially** (ADR-013).
  Entry order comes from `Packer`'s sort, so output stays byte-for-byte
  deterministic — there is a test for that; keep it. Encryption stays in
  the sequential write phase (per-entry salts), and `ParallelCompressor`
  spills compressed output above 16 MB to scratch files that the writer
  drains and `cleanUp` deletes on every exit path.
- **Deflate is zlib (CZlib system library), inflate is the Compression
  framework** (ADR-014). Files ≥ 32 MB compress as ~16 MB blocks in
  bounded waves: every data block ends with Z_SYNC_FLUSH (no BFINAL), and
  a trailing empty Z_FINISH block closes the stream — so no EOF lookahead
  is needed and an exact-multiple-of-blockSize file still ends properly
  (there is a test). Never "optimize away" that empty final block.
  Cross-verified against unzip / 7zz / ditto / Python zipfile.
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
- **Never make an NSStackView the window's contentView directly.** It sizes
  itself to its own fitting width and clips wider subviews (the settings
  popup vanished off the right edge); `setContentSize` does not override
  that. Pin the stack inside a plain container with an explicit width
  constraint instead — see `SettingsWindowController.buildUI`.
- Borderless buttons in a window with no other focusable view come up
  wearing a focus ring: set `focusRingType = .none` and
  `refusesFirstResponder = true` (the drop window's gear button).
- **`application(_:open:)` fires before `applicationDidFinishLaunching`**
  on a Finder double-click, so the main window does not exist yet and any
  sheet silently goes nowhere. AppDelegate queues those URLs in
  `pendingURLs` and handles them once the window is up — keep that queue if
  you touch the launch path.
- The one-shot launch rule lives in AppDelegate: `isOneShotLaunch` is set
  only for open events that predate launch completion, and cleared by any
  drop, a Dock-icon reopen, or opening Settings, so an app the user opened
  themselves never quits under them. In that mode the droplet window is
  never created, so `MainViewController.hostWindow` is nil and every dialog
  goes through `DialogPresenter`, which falls back to a standalone window.
  Keep `hostWindow` guarded by `isViewLoaded` — touching `view` would build
  the droplet UI the mode exists to avoid.
- **A foreground notification dies with its app.** Terminating right after
  posting cuts the banner short (v0.8.0/v0.8.1). The one-shot path drops to
  `.accessory` so the Dock icon goes away at once, then terminates after
  `CompletionNotifier.remainingBannerTime()` — which is zero when no banner
  was shown, so the dialog path still quits at once. Keep that gating if
  you touch the quit path.
- **The app claims only `public.zip-archive`**, so one-shot *packing* is
  effectively unreachable from Finder (folders never launch an app; the
  icon rejects undeclared types). It survives for `open -a` and scripts.
  Declaring `public.folder`/`public.item` would enable Dock-icon packing at
  the cost of appearing in every file's "Open With" menu — considered and
  declined 2026-08-01.
- **Never gate a notification on a cached authorization flag.**
  `requestAuthorization` is async; an operation that finishes first then
  skips its banner silently (this shipped in v0.8.0). Resolve
  authorization inside the posting chain, and let the post settle before a
  one-shot launch terminates — the banner survives the quit once shown.
- Dialogs that hold fixed-width fields need the container-plus-explicit-
  width treatment too (the password field was being squeezed against the
  right edge). Inside them use `alignment = .leading` plus width
  constraints on the rows that should span; stack-wide `.width` alignment
  drags label text to the right.
- Signing: pure AppKit needs **no entitlements** (see CONVENTIONS.md).
- Interactive password E2E uses `/usr/bin/expect` (`script -q` piping
  hangs); see the session E2E notes.
- New behaviour ships with tests, README.md + README.ja.md updated in the
  same commit, and a CHANGELOG entry (org pre-completion checklist).
