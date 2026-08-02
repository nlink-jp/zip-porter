#!/usr/bin/env python3
"""Generate hostile ZIP fixtures for the ADR-012 hardening tests.

These structures cannot be produced by our own writer (that is the point):
they are built here straight from the PKWARE format so the extractor is
tested against real attacker-shaped input.

Usage: gen-hostile-fixtures.py <output-dir>
"""
import os
import struct
import sys
import unicodedata
import zlib

LOCAL_SIG = 0x04034B50
CENTRAL_SIG = 0x02014B50
EOCD_SIG = 0x06054B50
ZIP64_EOCD_SIG = 0x06064B50
ZIP64_LOCATOR_SIG = 0x07064B50
DOSTIME, DOSDATE = 0x6F3C, 0x5B01  # fixed timestamp — fixtures stay byte-stable


def local_header(name: bytes, crc: int, comp_size: int, uncomp_size: int, method: int) -> bytes:
    return struct.pack("<I5H3I2H", LOCAL_SIG, 20, 0, method, DOSTIME, DOSDATE,
                       crc, comp_size, uncomp_size, len(name), 0) + name


def central_header(name: bytes, crc: int, comp_size: int, uncomp_size: int,
                   method: int, offset: int) -> bytes:
    return struct.pack("<I6H3I5H2I", CENTRAL_SIG, 20, 20, 0, method, DOSTIME,
                       DOSDATE, crc, comp_size, uncomp_size, len(name),
                       0, 0, 0, 0, 0, offset) + name


def eocd(count: int, cd_size: int, cd_offset: int) -> bytes:
    return struct.pack("<I4H2IH", EOCD_SIG, 0, 0, count, count, cd_size, cd_offset, 0)


def write_zip(path: str, body: bytes, central: bytes, count: int) -> None:
    with open(path, "wb") as f:
        f.write(body + central + eocd(count, len(central), len(body)))
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def size_lying_bomb(path: str) -> None:
    """One entry declaring 1 KiB that actually inflates to 64 MiB.

    The declared size is a lie in the *local and central* headers alike, so
    an extractor that trusts the declaration and only checks at the end
    writes 64 MiB before noticing.
    """
    payload = b"\0" * (64 << 20)
    compressed = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = compressed.compress(payload) + compressed.flush()
    name = b"bomb.bin"
    declared = 1024
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    body = local_header(name, crc, len(data), declared, 8) + data
    central = central_header(name, crc, len(data), declared, 8, 0)
    write_zip(path, body, central, 1)


def overlap_bomb(path: str, entries: int = 200) -> None:
    """42.zip-shaped: many central-directory entries, one shared data range.

    Every entry's localHeaderOffset points at the same local header, so the
    declared total dwarfs the file size and the byte ranges coincide.
    """
    payload = b"A" * (8 << 20)
    compressed = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = compressed.compress(payload) + compressed.flush()
    name = b"shared.bin"
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    body = local_header(name, crc, len(data), len(payload), 8) + data
    central = b"".join(
        central_header(f"copy{i:03d}.bin".encode(), crc, len(data), len(payload), 8, 0)
        for i in range(entries))
    write_zip(path, body, central, entries)


def duplicate_names(path: str) -> None:
    """Three colliding names: exact, case-only, and NFD-vs-NFC.

    APFS is case-insensitive by default and normalizes nothing, so all
    three pairs land on one file if the extractor does not uniquify.
    """
    nfc = unicodedata.normalize("NFC", "デ" + "ータ.txt")
    nfd = unicodedata.normalize("NFD", nfc)
    assert nfc != nfd, "fixture needs genuinely different byte sequences"
    entries = [
        ("report.txt", "first\n"),
        ("report.txt", "second — exact duplicate\n"),
        ("REPORT.TXT", "third — case-only collision\n"),
        (nfc, "fourth — NFC\n"),
        (nfd, "fifth — NFD of the same name\n"),
    ]
    body = b""
    central = b""
    for name, text in entries:
        nb = name.encode("utf-8")
        data = text.encode("utf-8")
        crc = zlib.crc32(data) & 0xFFFFFFFF
        offset = len(body)
        body += local_header(nb, crc, len(data), len(data), 0) + data
        # bit 11 (UTF-8 name flag) matters for the NFC/NFD pair
        header = bytearray(central_header(nb, crc, len(data), len(data), 0, offset))
        struct.pack_into("<H", header, 8, 1 << 11)
        central += bytes(header)
    write_zip(path, body, central, len(entries))


def truncated_data(path: str) -> None:
    """Central directory promises more data than the file contains."""
    name = b"short.bin"
    data = b"only-8b!"
    crc = zlib.crc32(data) & 0xFFFFFFFF
    body = local_header(name, crc, 1 << 20, 1 << 20, 0) + data
    central = central_header(name, crc, 1 << 20, 1 << 20, 0, 0)
    write_zip(path, body, central, 1)


def zip64_locator_underflow(path: str) -> None:
    """22 bytes: an EOCD at offset 0 that claims to be ZIP64.

    The ZIP64 locator is defined to sit 20 bytes before the EOCD, which here
    would be a negative file offset. A reader that computes that address
    before checking it underflows.
    """
    with open(path, "wb") as f:
        f.write(eocd(0xFFFF, 0, 0))
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def zip64_size_overflow(path: str) -> None:
    """A well-formed ZIP64 locator whose central-directory size and offset
    sum past UInt64. A bounds check written as `offset + size <= fileSize`
    overflows while evaluating itself.
    """
    z64 = struct.pack("<IQ2H2I4Q", ZIP64_EOCD_SIG, 44, (3 << 8) | 45, 45, 0, 0,
                      0, 0, 0xFFFFFFFFFFFFFF00, 0x100)
    locator = struct.pack("<2IQI", ZIP64_LOCATOR_SIG, 0, 0, 1)
    with open(path, "wb") as f:
        f.write(z64 + locator + eocd(0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF))
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: gen-hostile-fixtures.py <output-dir>")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    size_lying_bomb(os.path.join(out, "hostile-size-lie.zip"))
    overlap_bomb(os.path.join(out, "hostile-overlap.zip"))
    duplicate_names(os.path.join(out, "hostile-duplicate-names.zip"))
    truncated_data(os.path.join(out, "hostile-truncated.zip"))
    zip64_locator_underflow(os.path.join(out, "hostile-zip64-locator-underflow.zip"))
    zip64_size_overflow(os.path.join(out, "hostile-zip64-size-overflow.zip"))


if __name__ == "__main__":
    main()
