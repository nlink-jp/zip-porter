# CLAUDE.md — zip-porter

Organization rules: https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md
Workspace rules also apply (see the parent `nlink-jp/CLAUDE.md`).

## What this is

Windows-safe ZIP creation/extraction for macOS (Swift, AppKit; GUI-first with
an embedded CLI in the same binary). Replaces MacWinZipper and The Unarchiver
(ZIP use only). **Apple Silicon, macOS 14+.** Design of record:
`docs/ja/zip-porter-rfp.ja.md` / `docs/en/zip-porter-rfp.md` — read it before
changing scope.

## Project rules

- **ZipPorterCore stays UI-free.** No `import AppKit` in the engine module;
  all engine logic is unit-tested pure code.
- **Scope is closed.** ZIP only — no 7z/RAR/tar, no Windows/Linux builds,
  no cloud integration, no file-name encryption. Explicitly rejected in the
  RFP; propose an ADR before revisiting.
- **Crypto changes require cross-verification fixtures** (7-Zip / Info-ZIP /
  Windows built-in ZIPs), not just unit tests.
- **Security invariants**: zip-slip guard in the extractor, symlinks skipped
  by default, passwords via interactive prompt only (never argv).
- **Defaults are modern** (UTF-8+NFC, AES-256); CP932 / ZipCrypto stay
  opt-in flags with warnings.
- `make build`, never bare `swift build` outputs into the repo root;
  artifacts belong in `dist/` and `.build/`.
- `--version` must keep answering on stdout without launching the UI.
