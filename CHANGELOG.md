# Changelog

## [v0.12.0] - 2026-09-05

### Changed

- **An archive with a damaged local header is now refused when it is
  opened** — `inspect` and the GUI listing included — rather than failing
  that one entry during extraction. Consequence of resolving every entry's
  data offset from its local header at open (ADR-0005 §B); consistent with
  "refuse rather than repair". Directory entries stay outside the check
- **The new failure paths read as sentences in both front ends.** A name
  another process took while the extraction ran ("Another item appeared at
  a name this extraction was about to use… Try again." plus the name), a
  scratch file that could not be created ("The archive could not be
  written." plus the cause), and a malformed archive refused at open ("The
  archive is malformed and was refused." plus the detail) were shown as a
  bare POSIX line or a Swift enum dump. The error-to-message mapping moved
  out of the view controller into `ErrorMessages`, shared with the CLI and
  tested; strings added to en/ja

### Fixed

- **A failed extraction could delete files it did not create.** The
  cleanup path removed every *planned* top-level path, so a file another
  process created between the name check and the exclusive create — the
  very file that made the create fail — was deleted, and a pre-existing
  dangling symlink at that name met the same fate. Under the `never`
  folder policy a folder another writer had just made was even extracted
  into. Top-level items are now created exclusively (`mkdir(2)` /
  `O_EXCL`) and recorded in an ownership ledger only when that create
  succeeds; the failure path removes what the ledger holds and nothing
  else. Top-level folders are claimed before the first byte is written, so
  a name taken in that window fails the extraction up front with `File
  exists` rather than after minutes of work. A dangling symlink at a
  planned name now counts as taken (the name moves to "name 2") instead
  of failing the extraction, and top-level folders that differ only by
  case (`Docs/` and `docs/` from a case-sensitive system) are kept apart
  as "docs 2" instead of meeting in one folder
  ([ADR-0005](docs/en/adr/0005-review-response-ownership-ranges-budget.md),
  review finding ZP-01)
- **The overlap check could be bypassed through the local header.** Entry
  ranges were computed from the central directory's name length while
  extraction read from the local header's name and extra lengths, so two
  entries whose local headers nested inside each other's extra field
  passed the ADR-0001 §3 check and extracted the same bytes; an extra
  length pushing the payload past EOF was likewise only caught
  mid-extraction. Each file entry's payload offset is now resolved once,
  from its local header, when the archive is opened; the overlap and EOF
  checks use it and so does extraction. Opening now reads each file
  entry's local header, through a 256 KiB window so small entries cost a
  few hundred reads per hundred thousand entries rather than one each
  (ADR-0005, review finding ZP-02)
- **A failed pack could leave a partial scratch file behind.** Compressed
  output beyond 16 MB per entry went to a scratch file that was remembered
  only after its first write completed, and the large-file path released
  it on some failure branches but not others — a write failing part-way
  (disk full, a size limit) left a `zp-*.deflate` of up to 16 MB beside
  the archive, holding pre-encryption data. Scratch storage is now one
  hidden arena file per pack, created on first need and owned by the pack
  itself; one release removes it on every exit path, and there are no
  per-entry scratch files to track. When the arena cannot be created (a
  read-only destination) the error names the cause, not the hidden file
  (ADR-0005, review finding ZP-03)
- **Memory while packing grew with the number of files.** The 16 MB spill
  threshold bounded each entry while it was being compressed, but finished
  results below it stayed in memory until every entry was done — 64
  one-megabyte files held 50 MB, ten thousand would have held their whole
  compressed size. Finished results now share an aggregate budget of
  cores × 16 MB; results beyond it go to the scratch arena like oversized
  ones, so peak memory is bounded regardless of input size. The archive
  bytes do not depend on where a result was held (ADR-0005, review finding
  ZP-04)

## [v0.11.2] - 2026-08-25

### Fixed

- Clicking a completion banner could start a second copy of the app
  while one was still running: notificationd opens the app via
  LaunchServices by bundle identifier, and with more than one registered
  copy of the .app (dev build in `dist/`, `/Applications`) it may launch
  a different copy than the running one. The GUI is now single-instance
  at two layers: `LSMultipleInstancesProhibited` in Info.plist makes
  LaunchServices route the click to the running instance, and a startup
  guard in the GUI path exits with a stderr note when another instance
  is already running (covers direct binary exec and `open -n`). CLI
  subcommands are not guarded — concurrent `pack`/`unpack` runs keep
  working. The one-shot flow is unchanged: with no instance running, a
  banner click still launches a fresh process to reveal the result

## [v0.11.1] - 2026-08-09

### Fixed

- **Extraction onto a network volume (SMB/NFS) was refused as "no free
  space: 0 KB" no matter how much space the server had.** The pre-flight
  space budget (ADR-0001 §2) read
  `volumeAvailableCapacityForImportantUsage`, which only answers for local
  APFS volumes and reports 0 on network mounts. A 0 from that key now falls
  back to the plain `volumeAvailableCapacity` (statfs) figure, which
  network filesystems report correctly; a genuinely full disk is still
  refused because statfs reports ~0 there too.

### Documentation

- The four design records for this app moved out of the organization ADR
  log into `docs/{en,ja}/adr/` (0001 extraction hardening, 0002 parallel
  compression, 0003 zlib parallel deflate, 0004 batch completion), now
  mirrored in Japanese as well as English. The organization log is for
  decisions that bind the whole organization; these bind one app. The old
  numbers (012/013/014/016) remain in `nlink-jp/.github` as redirects, so
  links in earlier release notes still resolve.

## [v0.11.0] - 2026-08-03

### Changed

- **Several archives opened together are now one job, not N** (ADR-0004).
  Selecting three ZIPs in Finder and opening them produced three
  completion banners about a second apart — and macOS replaces one banner
  with the next from the same app, so only the last was readable while the
  rest piled up in Notification Center. It also meant three Finder reveals
  jumping around, three OK clicks when the completion style is *dialog*,
  three destination panels when the destination is *ask every time*, and a
  separate password prompt for each archive of a set that shares one.
  A request is now reported once: a single progress bar weighted across the
  whole selection ("2 of 3 — foo.zip"), one destination question, a password
  carried to the next archive, one summary, one Finder reveal.
- **A failed archive no longer stops the rest.** The remaining archives are
  extracted and the result reads "2 of 3 archives extracted" with the
  failures named — previously an alert interrupted the run for each one.
- **Clicking a completion notification reveals the result in Finder.**

### Fixed

- **The app no longer lingers after a Finder-launched run.** It used to
  post its completion banner, drop out of the Dock (`.accessory`) and stay
  alive ~4.5 s, because a notification presented by the app is withdrawn
  when the app exits. That gap — invisible but still receiving open events
  — is what truncated an extraction mid-write in v0.10.3. Notifications are
  now *scheduled* with a trigger, so the system owns the presentation and
  the banner outlives the process: measured 6.3 s of process lifetime down
  to 0.35 s, with the banner appearing and lasting exactly as before. The
  deferred quit, the Dock demotion and the "wait out the banner" state are
  gone rather than guarded, and the ~1.2 s stall between archives in a
  batch went with them.

## [v0.10.3] - 2026-08-03

### Fixed

- **Opening a second archive right after the first no longer kills the work
  in progress.** After a Finder-launched run finishes, the app leaves the
  Dock but stays alive for a few seconds so its completion banner is not cut
  short. The quit scheduled for the end of that wait was unconditional, so
  anything that arrived during it was destroyed on a timer belonging to the
  previous job: an extraction in progress was terminated mid-write, leaving a
  **truncated file and no error** (a 700 MB archive reproducibly left 543 MB
  on disk); an encrypted archive's password prompt vanished about three
  seconds into typing; and clicking the Dock icon to keep the app open got
  the window taken away again. The quit is now cancelled by anything that
  gives the process new purpose, and re-evaluated when it fires rather than
  acting on a decision made seconds earlier.
- **A second archive opened while one is still running is now queued instead
  of dropped.** It answered with a beep and did nothing — inaudible from a
  Finder launch, where there is no window on screen, so the second archive
  simply never extracted.

## [v0.10.2] - 2026-08-03

### Fixed

- ⌘V (and ⌘X / ⌘C / ⌘A / ⌘Z) now work in the password fields, and ⌘W
  closes the droplet window. Both were missing for the same reason: the
  app had no Edit menu and no Close item, and macOS routes those
  shortcuts to the focused control *through* main-menu key equivalents —
  with no matching item, the keystroke never reaches the text field.
  The menu bar also draws the top-level menu item's own title, so the
  new File and Edit menus carry titles rather than relying on their
  submenu's (an untitled item is an invisible menu).

## [v0.10.1] - 2026-08-03

### Fixed

- The app no longer crashes at launch on any machine other than the one
  that built it. SwiftPM's generated `Bundle.module` looks for the
  localization bundle beside the `.app`, never in `Contents/Resources`
  where it is installed, and then falls back to an absolute `.build`
  path baked in at compile time — so on a fresh install both lookups
  missed and the first localized string trapped (`EXC_BREAKPOINT`).
  The resource bundle is now located with an app-aware search that falls
  back to English strings instead of trapping.

## [v0.10.0] - 2026-08-02

A security review of the extractor, and the five defects it found. Two of
them were crashes on malformed input; two were holes in guarantees the app
already claimed (Gatekeeper propagation, "never overwrite"); one let an
archive decide the permissions of the files it dropped on you.

### Changed

- **Hardening pass over the unchecked arithmetic and boundaries the two
  crashes came from** (#6): the little-endian readers are bounds-checked
  and throwing, so a read added to the parser later cannot forget the
  guard; entry ranges, the writer's 16/32-bit header conversions and the
  extraction budget all reject values that would trap; archives and
  extracted files are created with `O_EXCL`, so "never overwrite" no
  longer rests on the gap between the check and the write; AES key
  material is wiped once it stops being needed

### Fixed

- **A malformed ZIP64 header crashed the process instead of being
  rejected** (#1). Two bounds checks in the central-directory parser did
  their own arithmetic on attacker-supplied 64-bit values: the ZIP64
  locator address (`eocd - 20`, underflowing on a 22-byte file whose EOCD
  claims ZIP64) and the directory bounds (`cdOffset + cdSize`, overflowing
  while checking themselves). Both trapped, taking the GUI down on a
  double-clicked `.zip`. The checks now subtract from the file size instead
  of adding to the offsets, and two hostile fixtures cover the shapes

- **The pre-extraction free-space budget could be switched off from inside
  the archive** (#2). The declared total was summed with wrapping
  arithmetic, so two ZIP64 entries declaring 2^63 apiece summed to exactly
  zero and the budget check approved anything. Since per-entry fail-fast
  only bounds an entry by *its own* declared size, that left a decompression
  bomb free to fill the volume. The sum now saturates at `UInt64.max`, and
  the check subtracts the margin from the free space instead of adding it
  to the requirement

- **Quarantine did not reach directories the extractor created
  implicitly** (#3), so an archive with no directory entries — 7-Zip writes
  them that way routinely — produced a `.app` whose files each carried
  `com.apple.quarantine` but whose bundle root, the thing Gatekeeper
  actually evaluates, did not. `ditto` marks the bundle root; now so do we.
  This was the ADR-0001 §4 gap re-opening through a different door

- **Extraction applied the archive's permission bits verbatim** (#4), so an
  archive asking for `0777` produced world-writable — and executable —
  files in the user's folder. On a shared Mac another local account could
  rewrite them. The requested mode is now masked with the process umask,
  the rule `unzip` and `ditto` follow (`0777` → `0755`, `0666` → `0644`
  under the default umask); setuid/setgid never survived and still do not

- **A failure to mark an extracted item as quarantined was silent** (#5),
  and the result claimed propagation had happened as long as the *archive*
  carried the attribute. Failures are now collected per item and reported
  the way every other security-relevant outcome is: a warning line in the
  CLI, and the result dialog (never the quiet notification) in the GUI

## [v0.9.3] - 2026-08-02

### Fixed

- `zip-porter --version` printed "dev" when run through the cask's symlink:
  launched that way, `Bundle.main` is not the `.app`, so the version was
  never found. It now falls back to the Info.plist beside the real
  executable — which `brew test` and release verification depend on

## [v0.9.2] - 2026-08-02

### Fixed

- **The CLI was documented but not reachable.** The README described
  `zip-porter pack …` while the executable sat inside the app bundle with
  nothing on PATH. The cask now symlinks it as `zip-porter`, and both
  READMEs say how to invoke it — including the manual `ln -s` for a
  hand-installed `.app`
- The shared cask template gained an optional `binary` stanza
  (`BREW_BINARY` / `BREW_BINARY_EXE`), so other GUI apps with an embedded
  CLI get the same treatment

## [v0.9.1] - 2026-08-02

### Changed

- **Excluded macOS metadata is reported in the completion line, not a
  dialog.** Dropping `.DS_Store` and friends is what this app is for —
  routine, not a warning — so it no longer forces the result dialog on
  every pack of a folder Finder has ever opened. It now rides along in the
  notification (or dialog, or nothing) chosen in Settings. Skipped
  symlinks, unsafe paths and renamed duplicates are real deviations and
  still force the dialog

## [v0.9.0] - 2026-08-01

### Added

- **Settings › General › "When finished successfully"** — choose how a
  clean finish is announced: a **notification** (the default, as before), a
  **dialog** to dismiss, or **nothing** at all. Runs that have something to
  report — skipped unsafe paths, renamed duplicates, excluded metadata —
  still use the dialog whatever this is set to, and errors still alert
  (ADR-0001: those must not be silent)

## [v0.8.3] - 2026-08-01

### Fixed

- A Finder-launched run waited out the banner's display time even when no
  banner was shown — after a result dialog the user had already dismissed,
  or when notifications are off. It now waits only for a banner actually on
  screen, and quits immediately otherwise

## [v0.8.2] - 2026-08-01

### Fixed

- **The completion banner was cut short on a Finder-launched run.** A
  foreground notification lives only as long as the app that posted it, and
  the app was quitting a fraction of a second later — the banner flashed
  and vanished, or never rendered. The one-shot run now leaves the Dock
  immediately (nothing lingers visually) and exits a few seconds later, so
  the banner gets its normal time on screen. Verified for both packing and
  extracting

## [v0.8.1] - 2026-08-01

### Fixed

- **The completion notification never appeared in v0.8.0.** Authorization
  was requested asynchronously at operation start and read from a cached
  flag at the end, so any operation that finished before the callback
  landed — which is most of them — silently skipped its banner.
  Authorization is now resolved inside the notification chain, and the
  post is given a moment to display before a Finder-launched run quits

## [v0.8.0] - 2026-08-01

### Changed

- **Clean completions no longer stop for an OK button.** When packing or
  extracting finishes with nothing to report, the status dialog simply
  goes away and the completion arrives as a Notification Center banner —
  so reveal-in-Finder happens immediately instead of after a click, and a
  Finder-launched run quits on its own. The result dialog still appears
  when there is something to read: skipped unsafe paths, skipped symlinks,
  renamed duplicates, or excluded metadata (per ADR-0001 those must not be
  silent), and errors keep their alerts
- The first run asks for notification permission; if declined, clean
  completions rely on the revealed Finder window as the signal

## [v0.7.0] - 2026-08-01

### Changed

- **The progress bar is now a real bar.** Pack and extract report
  byte-based progress against totals known up front (input sizes when
  packing, the central directory's declared total when extracting), so the
  dialog shows an accurate fraction instead of an indeterminate barber
  pole. Progress callbacks are delivered serially; the GUI coalesces them
  so the bar repaints only on visible movement
- **A ZIP being created is no longer named `.zip` until it is finished.**
  The archive is written as `name.zip.part` and renamed on success, so a
  half-written file is never mistaken for a finished archive (by Finder,
  a sync client, or a person); failures and cancellations delete the
  `.part` file

## [v0.6.0] - 2026-08-01

Single-file parallel deflate on zlib ([ADR-0003](docs/en/adr/0003-zlib-parallel-deflate.md)).

### Changed

- **Deflate now runs on the system zlib at level 6**, and entries above
  32 MB compress as independent ~16 MB blocks in parallel, joined with
  sync flushes into one standard deflate stream (the pigz technique).
  A single 180 MB text file: 2.82 s → 0.87 s, and 9 % smaller. Every
  archive now matches `ditto`/Info-ZIP output size, removing the size
  penalty carried since v0.1.0
- Verified against five independent readers: Info-ZIP unzip, 7-Zip,
  Apple ditto, Python zipfile, and our own extractor
- Peak memory for the block path stays around cores × 32 MB regardless
  of file size; inflate is unchanged (Compression framework)
- Trade-off, accepted per the ADR: many-small-file text workloads pay
  zlib's slower per-stream speed for the smaller output (240 MB of text:
  0.73 s → 1.21 s, 9 % smaller; still ~6× faster than `ditto`)

## [v0.5.0] - 2026-08-01

Compression throughput ([ADR-0002](docs/en/adr/0002-parallel-compression.md)).

### Changed

- **Entries are compressed in parallel** and written in the same order as
  before, so archives stay byte-for-byte deterministic. On a 12-core
  machine, a 310 MB / 150-file corpus went from 5.43 s to 1.72 s (3.2×);
  240 MB of text from 2.87 s to 0.73 s (3.9×). Memory stays bounded:
  compressed output above 16 MB spills to a scratch file that the writer
  drains and deletes
- **Data that does not compress is stored instead of deflated**, decided by
  test-compressing the head of each file rather than trusting its
  extension. 100 MB of random data went from 2.07 s to 0.39 s (5.3×), and
  the archive is slightly *smaller* — deflate adds framing to data it
  cannot shrink
- A single-entry archive keeps the old streaming path; there is nothing to
  overlap

Not included: parallelising a single large file's deflate stream, and a
user-facing compression level. Both need libz and are under investigation.

## [v0.4.1] - 2026-08-01

### Fixed

- The destination popup's "ask" item was worded for extraction ("展開先
  フォルダを確認") and read wrong in the creation section; both now say
  "毎回確認する" / "Ask every time"

## [v0.4.0] - 2026-08-01

### Added

- **The creation side gets the same destination choice as extraction** —
  Settings › Creating › "Create in:" offers the same folder as the original
  items (the previous behavior), a fixed folder, or asking every time via a
  save panel where the name can be changed too. When a path is chosen in
  that panel, replacing an existing archive is honored instead of falling
  back to a numbered name

## [v0.3.1] - 2026-08-01

### Changed

- **A ZIP opened from Finder no longer opens the droplet window** — the
  double-click already said what to do, so only the status dialog appears,
  and the app leaves when the work is done. Clicking the Dock icon brings
  the droplet window back and keeps the app around

### Fixed

- The password dialog squeezed its input field against the right edge; it
  and the pack options dialog now share even margins with their fields
  spanning the full width

## [v0.3.0] - 2026-08-01

### Added

- **Operation status dialog** — packing and extracting now show a sheet with
  live status while they run, which then turns into a result summary (what
  was created or extracted, how many files and folders) instead of finishing
  invisibly. Skipped unsafe paths, skipped symlinks, renamed duplicates and
  excluded macOS metadata are listed there too, replacing the separate
  post-extraction alert

### Changed

- **Opening a ZIP from Finder no longer leaves the app running.** When
  ZipPorter is started by a double-clicked archive, it quits once the work
  is done and its result dialog is dismissed. Dropping onto the window, or
  opening an archive while the app is already running, keeps it around as
  before

### Fixed

- Open events that arrived before the window existed (the Finder
  double-click path) ran without any dialog and left the app idling

## [v0.2.2] - 2026-08-01

### Added

- Settings: "Reveal the created archive in Finder" — creating a ZIP always
  jumped to Finder, while extraction had a toggle for it. Now both do
  (on by default, matching the previous behavior)

## [v0.2.1] - 2026-08-01

### Changed

- Settings window: wider, with each labelled choice indented into its own
  group and more breathing room between them. It was cramped, and the
  destination popup was clipped at the window edge
- The drop window gets a settings button, so preferences are reachable
  without going through the menu bar

## [v0.2.0] - 2026-08-01

Extraction hardening ([ADR-0001](docs/en/adr/0001-extraction-hardening.md)).
An unarchiver executes attacker-chosen structure against the user's
filesystem; these checks make malformed archives fail early and loudly
instead of consuming resources or silently losing data.

### Added

- **Fail-fast size enforcement** — an entry producing more output than its
  header declares is aborted mid-stream (`sizeExceedsDeclared`) instead of
  writing an unbounded amount and only then failing the size check
- **Pre-flight space budget** — the archive's declared total is checked
  against the destination volume's free space (64 MiB margin) before
  anything is written (`insufficientSpace`)
- **Overlapping-entry rejection** — archives whose entry byte ranges
  coincide (the `42.zip` construction) are refused while parsing
  (`overlappingEntries`); entries running past EOF are refused too
- **Quarantine propagation** — `com.apple.quarantine` on the source archive
  is copied onto every extracted file and directory, restoring the
  Gatekeeper coverage Archive Utility and The Unarchiver provide
- **Duplicate-name uniquification** — colliding entry names (including
  case-only and NFC/NFD differences, which APFS resolves to one file) are
  extracted as "name 2", "name 3", … instead of overwriting each other
- The GUI now surfaces skipped unsafe paths, skipped symlinks, and renamed
  duplicates after extraction; `inspect` reports the declared total size
  and any unsafe paths or symlinks extraction would skip

### Changed

- Central-directory size ceiling lowered from 2 GiB to 256 MiB
- Extraction and archive errors get specific, localized messages in the GUI

## [v0.1.0] - 2026-08-01

### Added

- **Engine**: ZIP reader/writer in `ZipPorterCore`
  - Central-directory parsing (ZIP64-aware), streaming extraction with CRC
    verification; streaming creation with local-header patch-back
  - File-name encoding: NFC-normalized UTF-8 (flagged) or CP932 on pack;
    auto-detection on unpack (UTF-8 flag > UTF-8 validation > CP932)
  - Encryption: ZipCrypto and WinZip AES (AE-1/AE-2) decrypt; ZipCrypto and
    AES-256 (AE-2) encrypt — cross-verified against Info-ZIP, Apple ditto,
    7-Zip, and a spec-derived CP932 generator; real-machine verified on
    Windows Explorer (UTF-8 names, junk-free trees, ZipCrypto extraction)
  - Junk filter (`.DS_Store`, `__MACOSX/`, AppleDouble, `Icon\r`, …)
- **CLI**: `pack` / `unpack` / `inspect`
  - pack: junk filtering (`--no-clean`), `--cp932`, `--password` (interactive
    prompt, AES-256 default), `--zipcrypto` with weakness warning, store for
    compressed extensions, unique output names
  - unpack: encoding auto-detect with `--encoding` override, zip-slip guard,
    symlink skip, folder policies, "name 2" collisions, prompt-on-demand
    password, mtime/permission restore
  - inspect: per-entry method/encryption/flag table, archive encoding
    verdict, junk contamination report
- **GUI**: drag-and-drop window (files/folders → pack, `.zip` → extract),
  `.zip` double-click handling, per-drop pack options sheet (password
  AES-256/ZipCrypto, CP932, remembered defaults, skippable), progress
  sheets with cancel, password prompt-on-demand
- **Settings window (⌘,)** — The Unarchiver-style extraction preferences:
  destination (same folder / ask / fixed), wrapper-folder policy
  (never / only-multiple / always), created-folder modification date,
  reveal in Finder, move archive to Trash
- en/ja localization; app icon

[Unreleased]: https://github.com/nlink-jp/zip-porter/compare/v0.11.1...HEAD
[v0.11.2]: https://github.com/nlink-jp/zip-porter/compare/v0.11.1...v0.11.2
[v0.11.1]: https://github.com/nlink-jp/zip-porter/compare/v0.11.0...v0.11.1
[v0.11.0]: https://github.com/nlink-jp/zip-porter/compare/v0.10.3...v0.11.0
[v0.10.3]: https://github.com/nlink-jp/zip-porter/compare/v0.10.2...v0.10.3
[v0.10.2]: https://github.com/nlink-jp/zip-porter/compare/v0.10.1...v0.10.2
[v0.10.1]: https://github.com/nlink-jp/zip-porter/compare/v0.10.0...v0.10.1
[v0.10.0]: https://github.com/nlink-jp/zip-porter/compare/v0.9.3...v0.10.0
[v0.9.3]: https://github.com/nlink-jp/zip-porter/compare/v0.9.2...v0.9.3
[v0.9.2]: https://github.com/nlink-jp/zip-porter/compare/v0.9.1...v0.9.2
[v0.9.1]: https://github.com/nlink-jp/zip-porter/compare/v0.9.0...v0.9.1
[v0.9.0]: https://github.com/nlink-jp/zip-porter/compare/v0.8.3...v0.9.0
[v0.8.3]: https://github.com/nlink-jp/zip-porter/compare/v0.8.2...v0.8.3
[v0.8.2]: https://github.com/nlink-jp/zip-porter/compare/v0.8.1...v0.8.2
[v0.8.1]: https://github.com/nlink-jp/zip-porter/compare/v0.8.0...v0.8.1
[v0.8.0]: https://github.com/nlink-jp/zip-porter/compare/v0.7.0...v0.8.0
[v0.7.0]: https://github.com/nlink-jp/zip-porter/compare/v0.6.0...v0.7.0
[v0.6.0]: https://github.com/nlink-jp/zip-porter/compare/v0.5.0...v0.6.0
[v0.5.0]: https://github.com/nlink-jp/zip-porter/compare/v0.4.1...v0.5.0
[v0.4.1]: https://github.com/nlink-jp/zip-porter/compare/v0.4.0...v0.4.1
[v0.4.0]: https://github.com/nlink-jp/zip-porter/compare/v0.3.1...v0.4.0
[v0.3.1]: https://github.com/nlink-jp/zip-porter/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/nlink-jp/zip-porter/compare/v0.2.2...v0.3.0
[v0.2.2]: https://github.com/nlink-jp/zip-porter/compare/v0.2.1...v0.2.2
[v0.2.1]: https://github.com/nlink-jp/zip-porter/compare/v0.2.0...v0.2.1
[v0.2.0]: https://github.com/nlink-jp/zip-porter/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/nlink-jp/zip-porter/releases/tag/v0.1.0
