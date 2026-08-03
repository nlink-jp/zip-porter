# ADR-0004: Batch Completion Reporting and Trigger-Scheduled Notifications

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-08-03 |
| Decision makers | nlink-jp maintainers |
| Triggered by | Real use: selecting several ZIPs in Finder and opening them in one shot reports each archive separately, and only the last banner is readable |

> Originally recorded as organization ADR-016 in `nlink-jp/.github`.
> Moved here on 2026-08-03: the organization ADR log is for decisions
> that bind the whole organization, and this one binds one app.

## Context

Two problems, one root.

**Per-archive reporting.** Finder delivers a multi-selection as a *single*
`application(_:open:)` with all the URLs (measured: three archives arrive in
one event). The app nonetheless treats each archive as its own job with its
own announcement. Measured on three archives:

```
open(3): m-1.zip,m-2.zip,m-3.zip
announce: … m-1  (+0.10 s)
announce: … m-2  (+1.12 s)
announce: … m-3  (+2.37 s)
```

macOS replaces one banner with the next from the same app, so at t=4.0 s only
the third was on screen — the user extracted three archives and could read
about one. The rest of the per-archive repetition follows: N entries left in
Notification Center, N `activateFileViewerSelecting` calls making Finder jump,
N OK clicks when the completion style is *dialog*, N destination panels when
the destination is *ask*, N password prompts for a set of archives that
almost always share one password, a progress sheet rebuilt from zero N times
with no sense of "2 of 3", and N separate error alerts.

**Deferred quit.** Since v0.8.2 a Finder-launched run posts its banner and
then keeps the process alive ~4.5 s, demoted to `.accessory`, because a
foreground-presented notification is withdrawn when its app exits. That
window — visibly gone, actually alive, still receiving open events — is
exactly what caused the v0.10.3 data loss (an extraction terminated
mid-write, leaving a truncated file and no error). v0.10.3 made the quit
cancellable and re-evaluated; the window itself remained. It also costs
~1.2 s of idle time *between* archives in a batch, since each archive waits
out its own banner ceremony before the next starts.

Measured on the real signed binary (screenshots at fixed offsets):

| Variant | Process alive | Banner |
|---------|---------------|--------|
| v0.10.3 as shipped | 0.2 → **6.3 s** | visible at 3.0 s, gone by 7.0 s |
| `trigger: nil`, quit at presentation | 0.16 → 1.17 s | **absent at 1.5 s** |
| **`UNTimeIntervalNotificationTrigger(0.5)`, quit after `add`** | 0.16 → **0.57 s** | visible at 1.5 s **and** 5.0 s |
| same, 0.1 s | 0.12 → **0.47 s** | visible at 2.0 s |

The second row confirms the v0.8.2 observation. The third and fourth show its
scope: it is a property of *immediate* delivery via `willPresent`, not of
notifications. Scheduled with a trigger, presentation belongs to
`notificationd`, and the banner appears and lives its full life with the
posting process long dead.

## Decision

**Schedule completion notifications with a time-interval trigger, and report
a whole request once rather than per archive.**

1. **Trigger-scheduled notifications.** Post with
   `UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)` and
   run the caller's completion as soon as `add` succeeds. The 0.1 s delay is
   imperceptible; the app no longer has to witness its own banner.
2. **No deferred quit.** `bannerLifetime`, `remainingBannerTime`, the
   `.accessory` demotion, the cancellable `DispatchWorkItem`, and
   `OneShotQuit.afterBanner` all go. `OneShotQuit` reduces to `.now` / `.stay`.
   The rules that actually protect work stay and stay first: busy — running,
   queued, or waiting on the user — always wins, requests that arrive during
   a run are queued rather than dropped, and a user who claims the app (drop,
   Dock click, Settings) ends the one-shot session.
3. **A request is a batch.** One `handle(urls)` — one Finder multi-selection,
   one drop — produces exactly one progress sheet, one completion
   announcement, and one Finder reveal.
   - Progress: a single determinate bar over the sum of all archives, with
     "2 of 3 — foo.zip" as the status line.
   - Completion: "Extracted 3 archives — 24 files, 3 folders". Notes
     (skipped symlinks, unsafe paths, renamed duplicates, quarantine
     failures) merge across the batch, and per ADR-0001 their presence still
     forces the dialog regardless of the completion-style setting.
   - Failures do not abort the batch. The remaining archives run, and the
     result reads "2 of 3 extracted — 1 failed", with the failures listed.
     A partially failed batch always uses the dialog: a banner is not a
     place to report a failure.
   - Finder reveal happens once, at the end, over the batch's top-level
     items.
4. **Ask once per batch.** The destination panel (destination = *ask*) is
   shown once and applies to every archive in the batch. A password entered
   for one archive is tried first on the next; only if it fails is the user
   asked again.

Single-archive behaviour is the N=1 case of the same code path — the wording
stays what it is today.

## Consequences

**Positive**

- A multi-selection produces one readable result instead of N banners of
  which one survives, and one Notification Center entry instead of N.
- The "gone from the Dock but still alive" window disappears, so the whole
  class of bug behind v0.10.3 stops being reachable rather than being
  guarded against. One-shot process lifetime drops from ~6.3 s to ~0.4 s,
  and the ~1.2 s inter-archive stall in a batch disappears.
- Fewer interruptions per batch: one destination panel, one password for a
  set that shares one, one Finder jump.

**Negative / accepted trade-offs**

- Clicking a banner after the app has exited relaunches ZipPorter. Handled
  by revealing the result in Finder on notification response instead of
  presenting the droplet window.
- Batch reporting is coarser: with 30 archives the summary states totals and
  lists notes for the first few, not every archive. The dialog carries the
  full list when there is something to report.
- Reveal-once means a batch whose archives extract into different folders
  opens whatever Finder chooses for a multi-folder selection — accepted over
  N sequential jumps.
- Carrying a password to the next archive keeps it in memory for the
  duration of the batch (already true within one archive's retry loop); it
  is never written anywhere and is dropped when the batch ends.
