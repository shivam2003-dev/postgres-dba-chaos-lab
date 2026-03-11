#!/usr/bin/env python3
"""
===================================================================
RECORD-LEVEL CORRUPTION SIMULATOR — PostgreSQL 18.3
===================================================================
Corrupts SPECIFIC ROWS in a PostgreSQL heap file by:
  1. Querying each row's physical location (ctid) before shutdown
  2. Seeking directly to that byte offset in the heap file
  3. Overwriting only that tuple's data bytes

PostgreSQL 18 changes handled here:
  - Checksums are ON by default (PG18 initdb default). After
    corrupting bytes, the page checksum is recalculated and
    rewritten so PG18 accepts the page but still sees corrupt
    tuple data. Without this, PG rejects the whole page before
    reaching the individual row.
  - Block numbers are BIGINT in PG18 pageinspect — all ctid
    decomposition queries use ::bigint casts.
  - pg_relation_filepath() used instead of manual OID joins.

Usage:
  # Corrupt specific rows by PK
  sudo python3 18_corrupt_data.py --table payment_transactions \
       --pk txn_id --pk-values 101 205 398

  # Corrupt N randomly chosen rows
  sudo python3 18_corrupt_data.py --table payment_transactions \
       --pk txn_id --random-rows 10 --mode data

  # List all corruption modes
  python3 18_corrupt_data.py --list-modes
===================================================================
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import shutil
import time
from dataclasses import dataclass

# ── Constants ─────────────────────────────────────────────────────────────────
PG_DATA_DIR      = "/data/primary"           # PostgreSQL data directory
PG_SERVICE       = "postgresql@18-primary"   # systemctl unit for PRIMARY only.
                                             # NEVER use the generic "postgresql"
                                             # unit — it controls ALL instances
                                             # on the host (primary + all replicas)
                                             # and will stop/start replicas too.
PG_PORT          = 5432                      # Primary port. Replicas use 5433/5434.
                                             # All psql and pg_isready calls must
                                             # specify -p PG_PORT to avoid
                                             # accidentally hitting a replica.
PG_BLOCK_SIZE    = 8192          # default page size (bytes)
PG_PAGE_HEADER   = 24            # PageHeaderData fixed size (bytes)
ITEM_ID_SIZE     = 4             # ItemIdData (line pointer) size in bytes

# PageHeaderData checksum is at byte offset 8 (2 bytes, little-endian)
PD_CHECKSUM_OFFSET = 8

# FNV/multiply-based constants matching src/include/storage/checksum_impl.h
N_SUMS           = 32
PRIME_MULTIPLIER = 1540483477


# ── Helpers ───────────────────────────────────────────────────────────────────
def run(cmd: str) -> str:
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout.strip()


def check_postgres_stopped():
    """Verify the PRIMARY instance is stopped before writing to heap files."""
    status = run(f"pg_isready -U postgres -p {PG_PORT} 2>/dev/null")
    if "accepting connections" in status:
        print("\n[ERROR] PostgreSQL primary is still running!")
        print(f"  Stop it first:  sudo systemctl stop {PG_SERVICE}")
        sys.exit(1)


def get_pg_data_dir() -> str:
    """Return the fixed PostgreSQL data directory."""
    if not os.path.isdir(PG_DATA_DIR):
        raise RuntimeError(
            f"PostgreSQL data directory not found: {PG_DATA_DIR}\n"
            "  Check the path exists and is accessible."
        )
    return PG_DATA_DIR


def get_heap_file(table: str, db: str) -> str:
    """
    Use pg_relation_filepath() — the clean PG18 way to locate the heap
    file. Returns path relative to PGDATA; prefix with PG_DATA_DIR.
    PostgreSQL must be running when this is called.
    Connects to PRIMARY on PG_PORT — never to a replica.
    """
    rel_path = run(
        f"psql -U postgres -p {PG_PORT} -d {db} -At "
        f"-c \"SELECT pg_relation_filepath('{table}');\" 2>/dev/null"
    )
    if not rel_path:
        raise ValueError(
            f"Table '{table}' not found in database '{db}'."
        )
    full_path = os.path.join(PG_DATA_DIR, rel_path)
    if not os.path.isfile(full_path):
        raise FileNotFoundError(
            f"Heap file not found: {full_path}\n"
            "  Stop PostgreSQL before corrupting the file."
        )
    return full_path


def checksums_enabled(db: str) -> bool:
    """Check whether data checksums are active. ON by default in PG18.
    Connects to PRIMARY on PG_PORT only."""
    result = run(
        f"psql -U postgres -p {PG_PORT} -d {db} -At "
        f"-c \"SELECT current_setting('data_checksums');\" 2>/dev/null"
    )
    return result.strip().lower() == "on"


# ── PG18 Page Checksum ────────────────────────────────────────────────────────
# PostgreSQL computes a per-page checksum seeded with the block number.
# Algorithm: src/include/storage/checksum_impl.h
# After corrupting tuple bytes we must recalculate the checksum and
# embed it at pd_checksum (offset 8), otherwise PG18 rejects the
# entire page before it ever reads the tuple we corrupted.

def _pg18_checksum(data: bytes, blkno: int) -> int:
    """
    Compute PostgreSQL page checksum for block blkno.
    The checksum field itself is zeroed before the computation.
    """
    assert len(data) == PG_BLOCK_SIZE
    page = bytearray(data)
    page[PD_CHECKSUM_OFFSET:PD_CHECKSUM_OFFSET + 2] = b'\x00\x00'

    sums = [blkno & 0xFFFFFFFF] * N_SUMS

    words = struct.unpack_from(f'<{PG_BLOCK_SIZE // 4}I', page)
    for i, word in enumerate(words):
        sums[i % N_SUMS] = (
            sums[i % N_SUMS] * PRIME_MULTIPLIER + word
        ) & 0xFFFFFFFF

    result = 0
    for s in sums:
        s ^= s >> 17
        s  = (s * 0x45D9F3B) & 0xFFFFFFFF
        s ^= s >> 17
        result = (result + s) & 0xFFFFFFFF

    checksum = (result & 0xFFFF) ^ (result >> 16)
    return checksum if checksum != 0 else 1


def embed_checksum(page: bytearray, blkno: int) -> bytearray:
    """Recalculate checksum and write it into the page header."""
    cs = _pg18_checksum(bytes(page), blkno)
    struct.pack_into('<H', page, PD_CHECKSUM_OFFSET, cs)
    return page


# ── Row Location ──────────────────────────────────────────────────────────────
@dataclass
class RowLocation:
    pk_value:   int
    block_num:  int     # bigint in PG18
    item_index: int
    ctid:       str


def get_row_locations(db: str, table: str,
                      pk_col: str, pk_values: list) -> list:
    """
    Resolve physical location (ctid) for each primary key.
    PG18: block number is bigint — use ::bigint cast on regexp groups.
    Connects to PRIMARY on PG_PORT only.
    """
    pk_list = ",".join(str(v) for v in pk_values)
    result = run(
        f"psql -U postgres -p {PG_PORT} -d {db} -At -c \""
        f"SELECT {pk_col}, ctid::text,"
        f" (regexp_match(ctid::text,'\\\\(([0-9]+),([0-9]+)\\\\)'))[1]::bigint,"
        f" (regexp_match(ctid::text,'\\\\(([0-9]+),([0-9]+)\\\\)'))[2]::int"
        f" FROM {table}"
        f" WHERE {pk_col} IN ({pk_list})"
        f" ORDER BY 3,4;\" 2>/dev/null"
    )
    locations = []
    for line in result.splitlines():
        parts = line.strip().split("|")
        if len(parts) == 4:
            try:
                locations.append(RowLocation(
                    pk_value=int(parts[0]),
                    ctid=parts[1],
                    block_num=int(parts[2]),
                    item_index=int(parts[3])
                ))
            except ValueError:
                pass
    return locations


def get_random_row_pks(db: str, table: str, pk_col: str, count: int) -> list:
    """Select N random PKs from the table. Connects to PRIMARY on PG_PORT."""
    result = run(
        f"psql -U postgres -p {PG_PORT} -d {db} -At "
        f"-c \"SELECT {pk_col} FROM {table} "
        f"ORDER BY random() LIMIT {count};\" 2>/dev/null"
    )
    return [int(r) for r in result.splitlines() if r.strip().isdigit()]


# ── ItemId (line pointer) parser ───────────────────────────────────────────────
def get_item_offset_and_len(page: bytearray, item_index: int) -> tuple:
    """
    Decode the ItemId for item_index (1-based) from the page.
    ItemId layout (4 bytes, little-endian uint32):
      bits  0-14 : lp_off   — byte offset of tuple in page
      bits 15-16 : lp_flags — 0=UNUSED 1=NORMAL 2=REDIRECT 3=DEAD
      bits 17-31 : lp_len   — byte length of tuple
    Returns (offset, length). Returns (0,0) for dead/invalid entries.
    """
    lp_pos = PG_PAGE_HEADER + (item_index - 1) * ITEM_ID_SIZE
    if lp_pos + 4 > len(page):
        return 0, 0
    raw      = struct.unpack_from('<I', page, lp_pos)[0]
    lp_off   = raw & 0x7FFF
    lp_flags = (raw >> 15) & 0x3
    lp_len   = (raw >> 17) & 0x3FFF
    # lp_flags must be 1 (LP_NORMAL); offset and length must be sane
    if lp_flags != 1 or lp_off < PG_PAGE_HEADER or lp_len < 24:
        return 0, 0
    return lp_off, lp_len


# ── Corruption Modes ──────────────────────────────────────────────────────────
def corrupt_full(page, off, ln):
    """Overwrite entire tuple (header + data) with random bytes."""
    for i in range(off, min(off + ln, len(page))):
        page[i] = random.randint(0, 255)
    return page


def corrupt_data(page, off, ln):
    """
    Keep the 23-byte HeapTupleHeader, corrupt column data only.
    Row is visible to PostgreSQL but column values are garbage.
    """
    for i in range(off + 23, min(off + ln, len(page))):
        page[i] = random.randint(0, 255)
    return page


def corrupt_xmin(page, off, ln):
    """
    Write 0xFFFFFFFF into t_xmin (first 4 bytes of tuple header).
    Row fails MVCC visibility check — effectively disappears.
    Detected by: xmin::text::bigint > 2000000000 check in scanner.
    """
    struct.pack_into('<I', page, off, 0xFFFFFFFF)
    return page


def corrupt_infomask(page, off, ln):
    """
    Corrupt t_infomask (offset +16, 2 bytes) and t_infomask2 (+18, 2 bytes).
    In PG18 heap_tuple_infomask_flags() will decode these as contradictory.
    Sets all bits — triggers conflicting HEAP_XMIN_COMMITTED +
    HEAP_XMIN_INVALID simultaneously.
    """
    struct.pack_into('<H', page, off + 16, 0xFFFF)
    struct.pack_into('<H', page, off + 18, 0xFFFF)
    return page


def corrupt_nullbitmap(page, off, ln):
    """
    Flip null bitmap bytes (start at offset +23 in tuple header).
    Non-null columns appear null, null columns appear to have values.
    """
    for i in range(off + 23, min(off + 23 + 8, off + ln)):
        page[i] ^= 0xFF
    return page


def corrupt_partial(page, off, ln):
    """Randomly flip ~30% of bytes within the tuple."""
    for i in range(off, min(off + ln, len(page))):
        if random.random() < 0.30:
            page[i] = random.randint(0, 255)
    return page


RECORD_MODES = {
    "full":       ("Entire tuple header + data overwritten",                     corrupt_full),
    "data":       ("Column data corrupted; header kept intact",                  corrupt_data),
    "xmin":       ("t_xmin=0xFFFFFFFF — row becomes invisible (MVCC failure)",   corrupt_xmin),
    "infomask":   ("t_infomask/t_infomask2 all bits set (PG18: infomask_flags shows contradiction)", corrupt_infomask),
    "nullbitmap": ("Null bitmap flipped — null/not-null inverted per column",    corrupt_nullbitmap),
    "partial":    ("Random 30% byte flips within the tuple",                     corrupt_partial),
}


# ── Main Corruption Function ───────────────────────────────────────────────────
def corrupt_records(table: str, db: str, pk_col: str,
                    locations: list, mode: str,
                    heap_file: str, has_checksums: bool):
    """
    Accepts pre-resolved RowLocation objects (resolved while PG was up).
    PG must be STOPPED before this function is called.
    """
    if not locations:
        print("[ERROR] No rows resolved. Check PK values and table name.")
        return

    print(f"\n[INFO] Corrupting {len(locations)} pre-resolved row(s):")
    for loc in locations:
        print(f"       PK={loc.pk_value:>10}  ctid={loc.ctid:<14}"
              f"  block={loc.block_num}  item={loc.item_index}")

    if has_checksums:
        print("[INFO] PG18 checksums ON — checksum will be "
              "recalculated after each page write.")

    # Backup the heap file once before any writes
    backup = heap_file + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(heap_file, backup)
        print(f"[BACKUP] Saved to {backup}")
    else:
        print(f"[BACKUP] Exists: {backup} (not overwriting)")

    corrupt_fn = RECORD_MODES[mode][1]
    manifest   = []

    with open(heap_file, "r+b") as f:
        for loc in locations:
            block_byte_offset = loc.block_num * PG_BLOCK_SIZE
            f.seek(block_byte_offset)
            page = bytearray(f.read(PG_BLOCK_SIZE))

            if len(page) < PG_BLOCK_SIZE:
                print(f"  [SKIP] Block {loc.block_num}: short read.")
                continue

            tup_off, tup_len = get_item_offset_and_len(page, loc.item_index)

            if tup_off == 0:
                print(f"  [SKIP] PK={loc.pk_value}: "
                      f"dead or invalid line pointer at item {loc.item_index}")
                continue

            print(f"\n  [CORRUPT] PK={loc.pk_value}"
                  f"  ctid=({loc.block_num},{loc.item_index})")
            print(f"            tuple_offset={tup_off}  tuple_len={tup_len}")
            print(f"            mode={mode} — {RECORD_MODES[mode][0]}")

            page = corrupt_fn(page, tup_off, tup_len)

            # PG18: recalculate checksum so page loads cleanly
            # but tuple content remains corrupt
            if has_checksums:
                page = embed_checksum(page, loc.block_num)
                print(f"            checksum recalculated (blk {loc.block_num})")

            f.seek(block_byte_offset)
            f.write(page)
            print(f"            ✓ Written.")

            manifest.append({
                "pk": loc.pk_value, "ctid": loc.ctid,
                "block": loc.block_num, "item": loc.item_index,
                "tup_off": tup_off, "tup_len": tup_len, "mode": mode,
            })

    # Write manifest file
    manifest_path = f"/tmp/record_corruption_{table}.txt"
    with open(manifest_path, "w") as mf:
        mf.write(f"Table      : {table}\n")
        mf.write(f"Database   : {db}\n")
        mf.write(f"PK column  : {pk_col}\n")
        mf.write(f"Mode       : {mode}\n")
        mf.write(f"Heap file  : {heap_file}\n")
        mf.write(f"Checksums  : {'enabled (recalculated)' if has_checksums else 'disabled'}\n\n")
        mf.write(f"{'PK':<12} {'ctid':<14} {'Block':<10} "
                 f"{'Item':<6} {'Offset':<8} {'Len':<6} Mode\n")
        mf.write("-" * 70 + "\n")
        for r in manifest:
            mf.write(f"{r['pk']:<12} {r['ctid']:<14} {r['block']:<10} "
                     f"{r['item']:<6} {r['tup_off']:<8} "
                     f"{r['tup_len']:<6} {r['mode']}\n")

    print(f"\n{'=' * 65}")
    print(f" DONE — {len(manifest)} record(s) corrupted")
    print(f" Manifest : {manifest_path}")
    print(f"{'=' * 65}")
    print(f"\nNext steps:")
    print(f"  1. Start PostgreSQL : sudo systemctl start {PG_SERVICE}")
    print(f"  2. Connect          : psql -U postgres -p {PG_PORT} -d {db}")
    print(f"  3. Run detection    : CALL scan_table_for_corruption('{table}');")
    print("=" * 65)


# ── Entry Point ───────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Record-level corruption simulator — PostgreSQL 18.3")
    parser.add_argument("--table",       default="payment_transactions")
    parser.add_argument("--db",          default="postgres")
    parser.add_argument("--pk",          default="txn_id",
                        help="Primary key column (default: txn_id)")
    parser.add_argument("--pk-values",   nargs="+", type=int,
                        help="PK values to corrupt e.g. --pk-values 101 205")
    parser.add_argument("--random-rows", type=int,
                        help="Corrupt N randomly selected rows")
    parser.add_argument("--mode",        default="data",
                        choices=list(RECORD_MODES.keys()))
    parser.add_argument("--list-modes",  action="store_true")
    args = parser.parse_args()

    if args.list_modes:
        print("\nCorruption modes (PostgreSQL 18.3):")
        for k, (desc, _) in RECORD_MODES.items():
            print(f"  {k:<12} : {desc}")
        sys.exit(0)

    if not args.pk_values and not args.random_rows:
        print("[ERROR] Provide --pk-values or --random-rows")
        sys.exit(1)

    # ── Start PRIMARY temporarily to resolve PKs / heap file path ─────────────
    # pg_isready targets PG_PORT (primary only) — replicas on other ports
    # are not checked or affected.
    pg_was_up = "accepting connections" in run(
        f"pg_isready -U postgres -p {PG_PORT} 2>/dev/null"
    )

    if not pg_was_up:
        print("[INFO] Starting PostgreSQL temporarily to resolve row info ...")
        # Use the specific service unit — not the generic "postgresql" meta-service
        # which would start ALL instances including replicas.
        run(f"sudo systemctl start {PG_SERVICE}")
        time.sleep(2)

    try:
        has_checksums = checksums_enabled(args.db)
        heap_file     = get_heap_file(args.table, args.db)

        if args.random_rows:
            pk_values = get_random_row_pks(
                args.db, args.table, args.pk, args.random_rows)
            print(f"[INFO] Sampled PKs: {pk_values}")
        else:
            pk_values = args.pk_values

        # Pre-resolve all row locations while PG is still running.
        # corrupt_records() receives the resolved RowLocation objects directly
        # so it never needs PG to be up — it only writes to the heap file.
        locations = get_row_locations(
            args.db, args.table, args.pk, pk_values)

    except Exception as e:
        print(f"[ERROR] {e}")
        if not pg_was_up:
            run(f"sudo systemctl stop {PG_SERVICE}")
        sys.exit(1)

    if not pg_was_up:
        # Stop PRIMARY only — replicas on their own ports are untouched.
        run(f"sudo systemctl stop {PG_SERVICE}")
        time.sleep(2)
        print("[INFO] PostgreSQL stopped. Starting corruption ...")

    # Verify PRIMARY is stopped before writing to heap files.
    check_postgres_stopped()

    corrupt_records(
        table=args.table,
        db=args.db,
        pk_col=args.pk,
        locations=locations,   # pass pre-resolved locations directly
        mode=args.mode,
        heap_file=heap_file,
        has_checksums=has_checksums,
    )


if __name__ == "__main__":
    main()
