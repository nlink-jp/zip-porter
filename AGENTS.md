# AGENTS.md — zip-porter

## What it is

Windows-safe ZIP creation/extraction for macOS (Swift, AppKit). Replaces
MacWinZipper (creation) and The Unarchiver (extraction, ZIP only) with one
clean, ad-free, fully-local app. **Apple Silicon, macOS 14+.**

**Status:** Released (see `git tag` for the current version) — engine
(`ZipPorterCore`: ZIP R/W, ZIP64, ZipCrypto + WinZip AES, encoding
auto-detect, junk filter), full CLI (`pack` / `unpack` / `inspect`), and
the AppKit GUI (drop window, pack options sheet, Unarchiver-style
extraction settings window, `.zip` handling, en/ja l10n, icon). ~200 tests
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
make verify-release  # gate: .notarized marker + stapler validate (run before upload)
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
  the ADR-0001 attack fixtures. Both sets are committed; rerun only to
  change what the fixtures contain.

## Layout

```
Package.swift               SPM manifest; ZipPorterCore lib + ZipPorter exe + 2 test targets
Info.plist                  bundle template; declares the ZIP document type (Viewer, Default)
Makefile                    build / build-app / package / brew
Sources/ZipPorterCore/      UI-independent engine (no AppKit): CRC32, DOSDateTime,
                            ZipStructures, DeflateStream, ZipReader, ZipWriter,
                            ZipCryptoCipher, WinZipAES, EncodingDetector,
                            JunkFilter, FileNameTransform, Packer, Unpacker, PathUtil,
                            PosixPermissions, XattrUtil, ZeroingBytes, SingleInstance,
                            ParallelCompressor (+ ScratchArena, MemoryLedger), ZlibDeflate
Sources/ZipPorter/          AppKit app + CLI: App (entry/routing/delegate), CLI (usage),
                            CLICommands (parse + run), PasswordPrompt, MainMenu,
                            MainViewController (flows), OneShotQuit (lifetime
                            rule), ExtractionBatch (per-request result +
                            BatchProgress), CompletionNotifier, DropView,
                            Sheets (options/
                            password/progress), SettingsWindow, Preferences, L10n,
                            ErrorMessages (engine errors → sentences, shared
                            with the CLI, tested), Resources/{en,ja}.lproj
Tests/ZipPorterCoreTests/   engine tests + testdata/ cross-verification fixtures
Tests/ZipPorterTests/       CLI routing/parsing, localization, main-menu, quit rule,
                            batch reporting tests
scripts/                    vendored org templates + gen-fixtures.sh
docs/{en,ja}/               RFP (design of record) + adr/ (0001 hardening,
                            0002 parallel compression, 0003 zlib parallel deflate,
                            0004 batch completion, 0005 review response: ownership
                            ledger / local-header ranges / memory budget) — mirrored en/ja
```

## Project rules

- **ZipPorterCore never imports AppKit.** All engine logic is pure,
  unit-tested code; the GUI (Phase 2) and CLI both consume Packer/Unpacker.
- **Scope is the RFP.** ZIP only — no 7z/RAR/tar, no Windows/Linux builds,
  no cloud. Propose an ADR before revisiting — in `docs/{en,ja}/adr/`,
  four-digit numbered and mirrored in both languages. This app's decisions
  live here, not in the organization ADR log (`nlink-jp/.github` keeps
  only decisions that bind the whole organization; 012/013/014/016 there
  are redirects left behind by the 2026-08-03 move).
- **Crypto changes require cross-verification fixtures**, not just unit
  tests (7-Zip / Info-ZIP / Windows-made ZIPs; see gen-fixtures.sh).
- **Security invariants** (ADR-0001 — do not relax any of these without a
  superseding ADR): zip-slip guard in `Unpacker.sanitize`; symlinks skipped
  both directions; passwords via prompt only (never argv); passwordRequired
  and the space-budget check fire before any disk write; failed extractions
  remove only what they created — recorded in an `OwnedItems` ledger when
  the exclusive create returns, never derived from the planned names
  (ADR-0005); per-entry output is bounded by the
  declared size (fail-fast); overlapping/past-EOF entry ranges are rejected
  at open; `com.apple.quarantine` propagates to every extracted item,
  **including directories created implicitly** on the way to a nested file
  (an archive with no directory entries must not yield an unquarantined
  `.app` bundle root); duplicate names are uniquified, never overwritten.
- **Hostile fixtures live in `scripts/gen-hostile-fixtures.py`** — bombs,
  overlap, duplicates, truncation, malformed ZIP64 headers. Our own writer
  cannot produce these structures, which is the point: they are built from
  the format spec.
- **Packing compresses in parallel and writes sequentially** (ADR-0002).
  Entry order comes from `Packer`'s sort, so output stays byte-for-byte
  deterministic — there is a test for that; keep it. Encryption stays in
  the sequential write phase (per-entry salts). `ParallelCompressor`
  spills compressed output above 16 MB per entry — and finished results
  beyond an aggregate budget of cores × 16 MB (ADR-0005) — into **one
  hidden scratch arena per pack** (`.zp-scratch-<uuid>` beside the
  archive, created on first need). `Packer` creates it and one `defer`
  removes it on every exit path; the compressor owns nothing on disk.
  Results reference byte ranges in it and the writer reads them back
  through one shared descriptor. Deliberately no per-entry scratch files: a file per entry
  meant a lifecycle per entry to get right on every failure branch
  (shipped wrong through v0.11.2), and with the budget it would have meant
  thousands of files flickering in the user's folder. The knobs travel in
  `ParallelCompressor.Limits`, passed per call — tests pass small ones and
  a failing scratch opener rather than mutating statics.
  `ArchitectureTests` pins one opener, one remover.
- **Deflate is zlib (CZlib system library), inflate is the Compression
  framework** (ADR-0003). Files ≥ 32 MB compress as ~16 MB blocks in
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

- **Notification clicks launch by bundle ID — enforce a single GUI instance.**
  Clicking a completion banner makes notificationd open the app via
  LaunchServices, which resolves `jp.nlink.zip-porter` among *all*
  registered copies (`dist/` dev builds, release-verification
  extractions, `/Applications`) and may start a different copy than a
  still-running one. Guarded at two layers: `LSMultipleInstancesProhibited`
  (Info.plist — with an instance running, LS routes the click to it and
  its `CompletionNotifier` reveals the result) and a startup check at the
  top of `runGUI()` (`singleInstanceDecision` in ZipPorterCore, tested)
  that exits with a stderr note (covers direct exec / `open -n`). The
  guard deliberately covers only the GUI path: `pack`/`unpack`/`inspect`
  stay concurrent, and the ADR-0004 one-shot flow is unchanged — with no
  instance running, a banner click still launches a fresh process. Side
  effect: to run a `dist/` build's GUI, quit the installed instance first.
- **Never use SwiftPM's `Bundle.module`; use `Bundle.appResources`.** The
  generated `Bundle.module` accessor only tries `<name>.bundle` beside
  `Bundle.main.bundleURL` (the `.app` root, not `Contents/Resources`) and
  then an absolute `.build` path baked in at compile time. Both resolve on
  the build machine and neither resolves anywhere else, so it trapped at
  launch on every fresh install through v0.10.0. `ResourceBundleLocator`
  searches the app layout first and degrades to English instead of
  trapping. This class of bug is invisible locally — verify a packaged
  build with the `.build` resource bundles moved aside.
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
- **`Data.readU16/32/64` are throwing and bounds-checked** — every offset
  they take comes from a header field, and an out-of-range `Data`
  subscript is a trap. Keep new reads on these accessors; do not add an
  unchecked one back for convenience.
- **Files are created with `O_EXCL`** (`PathUtil.createExclusively`), for
  the archive and for every extracted file. `FileManager.createFile`
  truncates what it finds, which would make "never overwrite" only as
  strong as the gap after the existence check.
- **`createDirectory(withIntermediateDirectories: true)` calls an existing
  directory a success.** On a top-level path that would pour an extraction
  into a folder some other process just made — and the failure cleanup
  would then delete that folder (shipped that way through v0.11.2). The
  top-level items (the wrapper; under `.never` each top-level file or
  directory) are claimed with `PathUtil.createDirectoryExclusively`
  (`mkdir(2)`: EEXIST on anything, dangling symlinks included) or `O_EXCL`,
  and enter `OwnedItems` only on success; the failure path removes the
  ledger's contents and cannot see the planned names. Folders are claimed
  *before the first byte is written* — a lazy first-use claim would leave
  the check-to-create window open for the whole extraction; files are
  claimed by their own create when reached. Directories *below* an owned
  item may use the permissive call — they are ours by construction (what a
  third party drops into them mid-extraction goes with them on failure; an
  accepted residual). Uniqueness checks use `PathUtil.somethingExists`
  (`lstat`), not `fileExists(atPath:)`, which follows symlinks and calls a
  dangling one absent — the check and the exclusive create must agree on
  what "exists". `ArchitectureTests` pins all of this by reading the
  source.
- **Never do arithmetic on header values inside a bounds check.** Offsets
  and sizes out of a ZIP64 record are attacker-chosen 64-bit values, so
  `offset + size <= fileSize` overflows while evaluating itself and
  `eocd - 20` underflows on a tiny file — both are Swift traps, i.e. a
  crash on a double-clicked `.zip`. Subtract from the known-good bound
  instead (`size <= fileSize - offset`), or check the operand first.
- **Local-header name/extra lengths can differ from the central directory's**
  — data offsets come from the local copies; sizes/CRC from the central
  directory (authoritative). `ZipReader.resolveEntryRanges` reads every
  file entry's local header once at open, stores `ZipEntry.dataOffset`,
  and runs the overlap/EOF check on it; `extract` starts there and reads
  no header. Do not add a second derivation of the offset anywhere: the
  check used to compute it from the central directory's name length while
  extraction used the local lengths, and an extra field big enough to hide
  another local header passed the check (shipped that way through
  v0.11.2; ADR-0005).
- **`volumeAvailableCapacityForImportantUsage` answers only for local APFS
  volumes — on a network mount (SMB/NFS) it reports 0, not nil.** Taken at
  face value that 0 turns the ADR-0001 §2 space budget into "refuse every
  extraction onto a file server: 0 KB free" (shipped that way through
  v0.11.0). `Unpacker.resolveFreeSpace` treats 0/negative from that key as
  "no answer" and falls back to `volumeAvailableCapacity` (statfs), which
  network filesystems do report; a genuinely full disk still refuses
  because statfs is ~0 there too. Don't "simplify" it back to one key.
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
- **Standard editing shortcuts only exist if the main menu carries them.**
  ⌘X/⌘C/⌘V/⌘A/⌘Z and ⌘W are delivered to the first responder as main-menu
  key equivalents, not by the text field itself — with no Edit menu, ⌘V in
  a password field does nothing, and there is no code anywhere to breakpoint
  (shipped that way through v0.10.1). `MainMenu` builds File/Edit/Window;
  `MainMenuTests` pins the bindings.
- **The menu bar draws the top-level `NSMenuItem`'s title, not its
  submenu's.** An `NSMenuItem()` with a fully populated submenu is an
  *invisible* menu. The app and Window menus mislead here — AppKit
  special-cases both (process name; `NSApp.windowsMenu`), so they appear
  untitled and everything else does not.
- `MainMenu.build()` is deliberately free of `NSApp` access so tests can
  inspect the menu; `MainMenu.install(into:)` does the wiring. `NSApp` is
  nil in the test process — touching it there is a trap.
- Borderless buttons in a window with no other focusable view come up
  wearing a focus ring: set `focusRingType = .none` and
  `refusesFirstResponder = true` (the drop window's gear button).
- **`application(_:open:)` fires before `applicationDidFinishLaunching`**
  on a Finder double-click, so the main window does not exist yet and any
  sheet silently goes nowhere. AppDelegate queues those URLs in
  `pendingURLs` and handles them once the window is up — keep that queue if
  you touch the launch path.
- **Do not re-introduce a deferred quit.** Until ADR-0004 a finished
  one-shot run dropped to `.accessory` and lingered ~4.5 s so its banner
  survived — visibly gone, still receiving open events — and the timer that
  ended that wait fired into whatever was happening by then: a live
  extraction (truncated file, no error), an open password prompt, a window
  the user had just reclaimed from the Dock. The fix is not a better timer;
  it is having nothing to wait for (see the notification note below).
  `OneShotQuit.decide(isOneShot:isBusy:)` is a pure function with no clock
  in it, and `applicationShouldTerminate` refuses while `isBusy` as a last
  guard against an open event arriving mid-exit. If some future change needs
  the process to outlive its work again, it needs a cancellable handle *and*
  a re-decision at fire time — but prefer removing the need.
- The one-shot launch rule lives in AppDelegate: `isOneShotLaunch` is set
  only for open events that predate launch completion, and cleared by any
  drop, a Dock-icon reopen, or opening Settings, so an app the user opened
  themselves never quits under them. In that mode the droplet window is
  never created, so `MainViewController.hostWindow` is nil and every dialog
  goes through `DialogPresenter`, which falls back to a standalone window.
  Keep `hostWindow` guarded by `isViewLoaded` — touching `view` would build
  the droplet UI the mode exists to avoid.
- **A notification the app presents dies with the app; one it schedules
  does not.** With `trigger: nil` the banner goes up through `willPresent`
  and belongs to this process — quit and it is withdrawn (measured: a
  one-shot run that quit at presentation left no banner at all). With a
  `UNTimeIntervalNotificationTrigger`, presentation belongs to
  `notificationd`: measured, the banner appeared and was still on screen at
  t=5 s with the process gone since t=0.57 s. That is why `notify` schedules
  at +0.1 s and runs its completion as soon as `add` succeeds. Do not
  "simplify" it back to an immediate post — that reinstates the lingering
  process and everything above.
- **The app claims only `public.zip-archive`**, so one-shot *packing* is
  effectively unreachable from Finder (folders never launch an app; the
  icon rejects undeclared types). It survives for `open -a` and scripts.
  Declaring `public.folder`/`public.item` would enable Dock-icon packing at
  the cost of appearing in every file's "Open With" menu — considered and
  declined 2026-08-01.
- **Never gate a notification on a cached authorization flag.**
  `requestAuthorization` is async; an operation that finishes first then
  skips its banner silently (this shipped in v0.8.0). Resolve
  authorization inside the posting chain, and wait for `add` to succeed
  before letting a one-shot launch terminate.
- **A request is a batch, not N archives.** A Finder multi-selection
  arrives as one `application(_:open:)`, and `ExtractionBatch` turns it into
  one result — one progress bar (`BatchProgress`, weighted by archive size),
  one destination question, one password carried forward, one summary, one
  Finder reveal (ADR-0004). Announcing per archive meant only the last banner
  was readable, since macOS replaces one banner with the next from the same
  app. Per-archive housekeeping (folder date, trashing the archive) stays in
  `finishUnpack`; anything the *user* sees belongs to the batch. A password
  prompt during a batch hangs off `sheet.nestedDialogHost`, not the droplet
  window — a second sheet on the same parent would queue behind the
  operation sheet and never appear.
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
