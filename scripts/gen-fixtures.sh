#!/bin/bash
# Regenerate cross-verification ZIP fixtures under Tests/ZipPorterCoreTests/testdata.
#
# Fixtures are produced by INDEPENDENT tools (Info-ZIP zip, Apple ditto, a
# spec-derived Python generator, and 7-Zip when installed) so the reader is
# tested against real third-party output, not our own writer. Outputs are
# committed; rerun only when the fixture set needs to change.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
td="$repo/Tests/ZipPorterCoreTests/testdata"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$td"
src="$work/src"
mkdir -p "$src/サブフォルダ"
printf 'こんにちは Windows\n' > "$src/日本語ファイル.txt"
printf 'plain ascii content\n' > "$src/readme.txt"
printf '月,売上\n1月,100\n' > "$src/サブフォルダ/データ.csv"

# --- infozip.zip: Info-ZIP zip 3.0 (deflate, UTF-8 names) ------------------
(cd "$src" && zip -q -r "$work/infozip.zip" .)
cp "$work/infozip.zip" "$td/infozip.zip"

# --- infozip-crypto.zip: Info-ZIP ZipCrypto (-P) ---------------------------
(cd "$src" && zip -q -r -P 's3cret-pass' "$work/infozip-crypto.zip" .)
cp "$work/infozip-crypto.zip" "$td/infozip-crypto.zip"

# --- ditto.zip: Apple ditto (NFD UTF-8 names, mac metadata included) -------
ditto -c -k "$src" "$work/ditto.zip"
cp "$work/ditto.zip" "$td/ditto.zip"

# --- cp932.zip: spec-derived generator, CP932 names, no UTF-8 flag ---------
python3 - "$td/cp932.zip" <<'PY'
import struct, sys, zlib

entries = [
    ("日本語.txt", "こんにちは\r\n"),
    ("フォルダ/データ.csv", "a,b\r\n1,2\r\n"),
]
out = b""
cd = b""
offset = 0
DOSTIME, DOSDATE = 0x6F3C, 0x5B01  # arbitrary fixed timestamp
for name, text in entries:
    nb = name.encode("cp932")
    data = text.encode("cp932")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    local = struct.pack("<I5H3I2H", 0x04034B50, 20, 0, 0, DOSTIME, DOSDATE,
                        crc, len(data), len(data), len(nb), 0)
    out += local + nb + data
    central = struct.pack("<I6H3I5H2I", 0x02014B50, 20, 20, 0, 0, DOSTIME,
                          DOSDATE, crc, len(data), len(data), len(nb),
                          0, 0, 0, 0, 0, offset)
    cd += central + nb
    offset += len(local) + len(nb) + len(data)
eocd = struct.pack("<I4H2IH", 0x06054B50, 0, 0, len(entries), len(entries),
                   len(cd), offset, 0)
open(sys.argv[1], "wb").write(out + cd + eocd)
PY

# --- 7z AES fixtures (requires 7zz; skipped when absent) -------------------
if command -v 7zz >/dev/null 2>&1; then
    (cd "$src" && 7zz a -tzip -mem=AES256 -p's3cret-pass' "$work/sevenzip-aes256.zip" . >/dev/null)
    cp "$work/sevenzip-aes256.zip" "$td/sevenzip-aes256.zip"
    (cd "$src" && 7zz a -tzip -mem=AES128 -p's3cret-pass' "$work/sevenzip-aes128.zip" . >/dev/null)
    cp "$work/sevenzip-aes128.zip" "$td/sevenzip-aes128.zip"

    # --- Deflate64 (method 9, ADR-0006) --------------------------------------
    # long-match.bin repeats a 40 KiB random block four times: the repeats
    # sit 40960 bytes back (distance code 30, Deflate64 only); the tests
    # assert that code was decoded rather than trusting this comment.
    # 7-Zip never emits the 16-extra-bit length code 285 even here, so that
    # one is covered by hand-built streams in Inflate64Tests.
    d64="$work/d64"
    cp -R "$src" "$d64"
    python3 -I -c '
import random, sys
r = random.Random(64)
block = bytes(r.getrandbits(8) for _ in range(40960))
open(sys.argv[1], "wb").write(block * 4)' "$d64/long-match.bin"
    # Compressible text, so an ordinary-looking entry is Deflate64 too (the
    # three small files above come out stored).
    for i in $(seq 1 400); do printf '%d 行目: 売上データの集計結果\n' "$i"; done > "$d64/text.txt"
    (cd "$d64" && 7zz a -tzip -mm=Deflate64 "$work/sevenzip-deflate64.zip" . >/dev/null)
    cp "$work/sevenzip-deflate64.zip" "$td/sevenzip-deflate64.zip"
    (cd "$d64" && 7zz a -tzip -mm=Deflate64 -mem=AES256 -p's3cret-pass' "$work/sevenzip-deflate64-aes256.zip" . >/dev/null)
    cp "$work/sevenzip-deflate64-aes256.zip" "$td/sevenzip-deflate64-aes256.zip"
else
    echo "[gen-fixtures] WARN: 7zz not found — AES and Deflate64 fixtures not regenerated" >&2
fi

ls -la "$td"
