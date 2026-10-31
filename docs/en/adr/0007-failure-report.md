# ADR-0007: A Copyable Failure Report That Carries No Names

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-11-01 |
| Decision makers | nlink-jp maintainers |
| Triggered by | The Deflate64 failure (ADR-0006) reached the maintainer as "an extraction error" — the one clue on screen did not survive the relay |

## Context

The failure that led to ADR-0006 was diagnosed by inference. The archive
was confidential and could not be shared, and the person who hit the error
reported only that extraction failed. Through v0.12.0 the alert actually
showed `unsupportedMethod(9)` — the exact cause — but alert text is hard to
select, means nothing to the person reading it, and is the first thing
dropped when a problem is passed along by word of mouth. The problem is
less that ZipPorter says too little than that what it says does not travel.

Reading the code turned up three further gaps:

1. **CRC and authentication failures drop the entry.** Both read as
   "damaged or tampered with", with no hint of which entry.
2. **Unexpected errors lose their identity.** The fallback is the enum's
   Swift spelling or `localizedDescription`; for an `NSError` the domain
   and code — the part a developer can act on — are discarded. A broken
   Deflate stream surfaces as "ZipPorterCore.DeflateStream.Failure error 1".
3. **A batch keeps failures as strings.** `ExtractionBatch.Failure` holds
   the sentence already rendered for the screen, so nothing more can be
   recovered from it afterwards.

The people who receive Windows ZIPs are exactly the people who cannot
share them. Whatever the report contains, they must be able to send it
without first checking it for confidential content.

## Decision

**Failures offer a "Copy Details" action that puts a plain-text report on
the clipboard. The report describes the archive's structure and the error;
it never contains a file name, path, content, or password.**

### What the person sees

- The on-screen sentence stays as it is: plain, localized, no technical
  detail (the rule from the organization's status-output guidance).
- The error alert (pack failure; extraction where nothing came out) gains a
  second button, **Copy Details**. It copies the report and closes the
  alert, as any NSAlert button does. OK stays the default button.
- The result sheet of a batch where some archives failed gains the same
  button beside Done, shown only when there is a failure. It copies without
  closing — the sheet still holds the results the person is reading.
- `zip-porter unpack --report` prints the same report to stderr after the
  error line, so a terminal user can be asked for the same text.

No new window, no disclosure triangle: one button in the dialogs that
already appear.

### What the report contains

English only, fixed format, ASCII only — the reader is the developer, a
localized report would be harder to compare across reports, and the text
passes through whatever mail client the sender uses. The macOS line is
built from version numbers and the build, because the ready-made
`operatingSystemVersionString` is localized.

- ZipPorter version, macOS version, the operation (create / extract).
- Per failed archive, numbered (`archive 2 of 3`), never named:
  - the error: type and case, plus only those payload fields that cannot
    hold a name (method numbers, byte counts, offsets, Deflate64 reasons).
    For an error ZipPorter did not define: the `NSError` domain and code,
    and the same for its underlying error — never `localizedDescription`,
    which routinely quotes a file name.
  - the archive's structure: file size, entry count, whether a ZIP64
    end-of-central-directory record is present, entries per compression
    method, per encryption kind, per "made by" host and version, per
    "version needed", counts of entries using a data descriptor and the
    UTF-8 name flag, and the extra-field IDs that occur.
  - the failing entry, when extraction had reached one: its position in
    the central directory, method, flags, made-by and version-needed,
    compressed and uncompressed size, extra-field IDs.
- The structure comes from the central directory alone, so an archive
  refused at open for its local headers or overlapping ranges is still
  described. Only when the central directory itself does not parse is the
  structure reported as unreadable — the error line then carries what the
  parser saw.
- Extra-field IDs are reported only when the fields' lengths add up to
  exactly the extra area. A walk that goes astray at one bad length reads
  field data as IDs, and a Unicode Path field (0x7075) holds the entry
  name; such an entry reads "malformed".
- CRCs and timestamps are left out too: a CRC fingerprints the content,
  and a time says when the work was done.
- A failed **create** reports the environment and the error case only.
  Every `ZipWriterError` and `Packer.Failure` payload is a name, a path, or
  a sentence quoting one, so none is printed. The person creating the
  archive holds the files and can describe them; this residual is accepted
  rather than given a structure of its own.

The archive's own file name is excluded too: it is as likely as any entry
name to say what the content is.

### What changes underneath

- `ZipReaderError.entryCorrupt(entryName:detail:)` replaces the two
  `.corrupt` strings that embedded an entry name (Deflate64 failure, size
  mismatch), and also carries a Deflate stream failure, which until now
  escaped as a bare `DeflateStream.Failure`. With every name in a labeled
  `entryName` field, the report can omit names by construction instead of
  by scrubbing strings.
- `ZipEntry` keeps `versionNeeded` and the central directory's extra-field
  IDs; `ZipReader` records whether a ZIP64 EOCD was present.
- `Unpacker.unpack` takes a `failingEntry` callback that receives the
  central-directory index of the entry being extracted when the extraction
  throws. The thrown error itself is unchanged, so every existing `catch`
  (the password retry, the CLI's per-case messages) keeps working.
- `ExtractionBatch.Failure` carries the report alongside the sentence. A
  declined password prompt carries one too: an authentication failure can
  be damage rather than a wrong password, and the report is how the two are
  told apart.
- The failing entry carries no phase (create, decode, write, close). The
  error line already separates them — `ZipReaderError` for what the reader
  found, a POSIX or Cocoa domain and code for what the filesystem refused —
  and a directory entry is marked as one.
- The report is assembled by pure functions — the structure summary in
  ZipPorterCore, the report text in the app module next to
  `ErrorMessages` — and tested, including a test that the report of an
  archive whose own name and every entry name carry a marker contains no
  marker. The error is rendered by an explicit switch, never by
  `String(describing:)`, which prints associated values — the names.
- Free-text details (`corrupt`, `entryCorrupt`'s detail, Inflate64's
  reasons) stay name-free by a source-scanning test that fails on a detail
  interpolating a name, path or URL. Closed detail enums would make it a
  compile-time fact; the test is the proportionate guard for a handful of
  throw sites.
- On screen, CRC failures and damaged entries now name the entry, as the
  size messages already did. (An authentication failure goes to the
  password prompt, as before.) The CLI's one-line message may still name
  the file; the report under `--report` never does.

## Alternatives considered

- **Include entry names.** Easier triage — the name often hints at the
  writer — but it makes the report something the person has to vet before
  sending, and the people this is for are the ones who cannot share
  contents. Rejected by the maintainer (2026-11-01).
- **Show the details in the alert itself** (a disclosure area or a longer
  informative text). More on screen does not travel any better than the
  `unsupportedMethod(9)` that was already there, and it puts implementation
  detail in front of everyone.
- **Write a log file.** Nobody finds a log file when asked; a clipboard is
  one paste into the reply to whoever asked.
- **Always print the report in the CLI.** Scripts would get a multi-line
  block on every failure; an opt-in flag keeps stderr to the one line.
- **`pack --report`.** A create report holds the error case and nothing
  else, which the one-line message already says.

## Consequences

- A report answers "which writer, which method, which entry shape" without
  the file — the questions that took inference in ADR-0006.
- Some triage information is given up deliberately: names, comments, and
  `localizedDescription` texts. A report may say `NSCocoaErrorDomain 640`
  where the on-screen sentence said which file could not be written; the
  person still sees the sentence.
- New error cases must keep names in labeled `entryName` fields; the
  report's rendering switch is exhaustive over ZipPorter's own errors, so
  a new case does not compile until someone decides what it reports.
