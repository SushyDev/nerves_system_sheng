#
# Round-trip validation for generate-userdata-gpt.py's output: CRC32s,
# primary/backup mirror consistency, every non-userdata entry preserved
# byte-for-byte, no gaps/overlaps, disk bounds unchanged. Run this after
# any regeneration - don't trust the generator's own assertions alone.
#
import os, struct, zlib

SECTOR = 4096
HERE = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.join(HERE, "gpt-userdata-live-capture.bin")
OUT = HERE


def parse_header(hdr):
    sig = bytes(hdr[0:8])
    header_size = struct.unpack_from('<I', hdr, 12)[0]
    stored_crc = struct.unpack_from('<I', hdr, 16)[0]
    my_lba = struct.unpack_from('<Q', hdr, 24)[0]
    alt_lba = struct.unpack_from('<Q', hdr, 32)[0]
    first_usable = struct.unpack_from('<Q', hdr, 40)[0]
    last_usable = struct.unpack_from('<Q', hdr, 48)[0]
    disk_guid = bytes(hdr[56:72])
    part_entries_lba = struct.unpack_from('<Q', hdr, 72)[0]
    num_entries = struct.unpack_from('<I', hdr, 80)[0]
    entry_size = struct.unpack_from('<I', hdr, 84)[0]
    entries_crc = struct.unpack_from('<I', hdr, 88)[0]

    check = bytearray(hdr[0:header_size])
    struct.pack_into('<I', check, 16, 0)
    computed_crc = zlib.crc32(bytes(check)) & 0xffffffff

    return dict(sig=sig, header_size=header_size, stored_crc=stored_crc, computed_crc=computed_crc,
                my_lba=my_lba, alt_lba=alt_lba, first_usable=first_usable, last_usable=last_usable,
                disk_guid=disk_guid, part_entries_lba=part_entries_lba, num_entries=num_entries,
                entry_size=entry_size, entries_crc=entries_crc)


def parse_entries(region, num_entries=32, entry_size=128):
    out = {}
    for i in range(num_entries):
        off = i * entry_size
        e = region[off:off + entry_size]
        if e[0:16] == b'\x00' * 16:
            continue
        start = struct.unpack_from('<Q', e, 32)[0]
        end = struct.unpack_from('<Q', e, 40)[0]
        name = e[56:56 + 72].decode('utf-16-le', errors='ignore').split('\x00')[0]
        out[i] = (name, start, end, e)
    return out


with open(LIVE, "rb") as f:
    live = f.read()
with open(f"{OUT}/gpt-userdata-primary.bin", "rb") as f:
    new_primary = f.read()
with open(f"{OUT}/gpt-userdata-backup.bin", "rb") as f:
    new_backup = f.read()

errors = []

p_hdr = parse_header(new_primary[SECTOR:SECTOR * 2])
if p_hdr['stored_crc'] != p_hdr['computed_crc']:
    errors.append("primary header CRC mismatch")
if p_hdr['sig'] != b'EFI PART':
    errors.append("primary sig wrong")
if p_hdr['my_lba'] != 1:
    errors.append("primary my_lba != 1")

b_hdr = parse_header(new_backup[SECTOR:SECTOR * 2])
if b_hdr['stored_crc'] != b_hdr['computed_crc']:
    errors.append("backup header CRC mismatch")
if b_hdr['my_lba'] != p_hdr['alt_lba']:
    errors.append("backup my_lba != primary alt_lba")
if b_hdr['alt_lba'] != p_hdr['my_lba']:
    errors.append("backup alt_lba != primary my_lba")
if b_hdr['disk_guid'] != p_hdr['disk_guid']:
    errors.append("disk_guid mismatch between primary/backup")
if b_hdr['first_usable'] != p_hdr['first_usable'] or b_hdr['last_usable'] != p_hdr['last_usable']:
    errors.append("usable range mismatch between primary/backup")

p_entries_region = new_primary[SECTOR * 2:SECTOR * 2 + 4096]
b_entries_region = new_backup[0:4096]
if p_entries_region != b_entries_region:
    errors.append("primary/backup entries tables differ (should be identical mirror)")
computed_entries_crc = zlib.crc32(p_entries_region) & 0xffffffff
if computed_entries_crc != p_hdr['entries_crc'] or computed_entries_crc != b_hdr['entries_crc']:
    errors.append("entries CRC doesn't match header-declared value")

old_entries = parse_entries(live[SECTOR * 2:SECTOR * 2 + 4096])
new_entries = parse_entries(p_entries_region)

if len(new_entries) != len(old_entries) + 2:
    errors.append(f"expected {len(old_entries) + 2} entries, got {len(new_entries)}")

for idx, (name, start, end, raw) in old_entries.items():
    if name == 'userdata':
        continue
    if idx not in new_entries:
        errors.append(f"old entry idx={idx} name={name} missing from new table")
        continue
    if new_entries[idx][3] != raw:
        errors.append(f"old entry idx={idx} name={name} bytes changed unexpectedly")

new_only = {idx: v for idx, v in new_entries.items() if v[0] in ('rootfs_a', 'rootfs_b', 'data')}
print("new/changed entries:")
for idx, (name, start, end, raw) in sorted(new_only.items()):
    print(f"  idx={idx} name={name:<10} start={start:>10} end={end:>10} "
          f"sectors={end - start + 1:>10} GiB={((end - start + 1) * SECTOR) / (1024**3):>8.3f}")

all_spans = sorted([(v[1], v[2], v[0]) for v in new_entries.values()])
for i in range(1, len(all_spans)):
    prev_end = all_spans[i - 1][1]
    cur_start = all_spans[i][0]
    if cur_start <= prev_end:
        errors.append(f"OVERLAP: {all_spans[i - 1][2]} ends {prev_end}, {all_spans[i][2]} starts {cur_start}")
    elif cur_start != prev_end + 1:
        errors.append(
            f"GAP: {all_spans[i - 1][2]} ends {prev_end}, {all_spans[i][2]} starts {cur_start} "
            f"(gap of {cur_start - prev_end - 1})"
        )

old_last = max(e for s, e, n in [(v[1], v[2], v[0]) for v in old_entries.values()])
new_last = max(e for s, e, n in [(v[1], v[2], v[0]) for v in new_entries.values()])
if old_last != new_last:
    errors.append(f"last partition end changed: old={old_last} new={new_last}")

if new_primary[0:SECTOR] != live[0:SECTOR]:
    errors.append("MBR (sector 0) changed unexpectedly")
if new_primary[SECTOR * 3:] != live[SECTOR * 3:]:
    errors.append("tail padding (sectors 3-5) changed unexpectedly")

print("\n" + ("ALL CHECKS PASSED" if not errors else "ERRORS:"))
for e in errors:
    print("  -", e)
if errors:
    raise SystemExit(1)
