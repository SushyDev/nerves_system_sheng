#
# Splits the real captured userdata GPT entry (gpt-userdata-live-capture.bin,
# LUN0 primary GPT, dumped live over the USB serial console - see
# OTA_UPDATE_GUIDE.md) into rootfs_a/rootfs_b (4GiB each) + data (remainder).
# Preserves every other entry, the MBR, and all header fields byte-for-byte
# except the two CRC32s. Re-run and re-validate (validate-userdata-gpt.py)
# any time the split size or target device's live capture changes - don't
# hand-edit the .bin outputs.
#
import os, struct, zlib, uuid

SECTOR = 4096
HERE = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.join(HERE, "gpt-userdata-live-capture.bin")

with open(LIVE, "rb") as f:
    live = f.read()
assert len(live) == 24576

mbr = live[0:SECTOR]
hdr = bytearray(live[SECTOR:SECTOR*2])
entries_region = bytearray(live[SECTOR*2:SECTOR*3])  # 4096 bytes = 32*128
tail_padding = live[SECTOR*3:]  # sectors 3-5, preserve verbatim

def h_get(off, fmt):
    return struct.unpack_from(fmt, hdr, off)[0]

sig = bytes(hdr[0:8])
revision = h_get(8, '<I')
header_size = h_get(12, '<I')
my_lba = h_get(24, '<Q')
alt_lba = h_get(32, '<Q')
first_usable = h_get(40, '<Q')
last_usable = h_get(48, '<Q')
disk_guid = bytes(hdr[56:72])
part_entries_lba = h_get(72, '<Q')
num_entries = h_get(80, '<I')
entry_size = h_get(84, '<I')

print(f"sig={sig} rev={revision} hdr_size={header_size} my_lba={my_lba} alt_lba={alt_lba}")
print(f"first_usable={first_usable} last_usable={last_usable} disk_guid={disk_guid.hex()}")
print(f"part_entries_lba={part_entries_lba} num_entries={num_entries} entry_size={entry_size}")
assert num_entries == 32 and entry_size == 128

# parse entries
entries = []
userdata_idx = None
for i in range(num_entries):
    off = i*128
    e = bytes(entries_region[off:off+128])
    type_guid = e[0:16]
    if type_guid == b'\x00'*16:
        entries.append(None)
        continue
    part_guid = e[16:32]
    start_lba = struct.unpack_from('<Q', e, 32)[0]
    end_lba = struct.unpack_from('<Q', e, 40)[0]
    attrs = struct.unpack_from('<Q', e, 48)[0]
    name = e[56:56+72].decode('utf-16-le', errors='ignore').split('\x00')[0]
    entries.append({'idx': i, 'name': name, 'type_guid': type_guid, 'part_guid': part_guid,
                     'start': start_lba, 'end': end_lba, 'attrs': attrs})
    if name == 'userdata':
        userdata_idx = i

assert userdata_idx is not None
ud = entries[userdata_idx]
print(f"\nuserdata found at idx={userdata_idx}: start={ud['start']} end={ud['end']} attrs=0x{ud['attrs']:016x} type_guid={ud['type_guid'].hex()}")

free_slots = [i for i,e in enumerate(entries) if e is None]
print(f"free slots: {free_slots}")
assert len(free_slots) >= 2, "not enough free GPT entry slots for the split"

# ---- compute new layout ----
GIB = 1024*1024*1024
slot_size_sectors = (4*GIB) // SECTOR  # 4 GiB
assert slot_size_sectors * SECTOR == 4*GIB

rootfs_a_start = ud['start']
rootfs_a_end = rootfs_a_start + slot_size_sectors - 1
rootfs_b_start = rootfs_a_end + 1
rootfs_b_end = rootfs_b_start + slot_size_sectors - 1
data_start = rootfs_b_end + 1
data_end = ud['end']  # unchanged tail of disk

assert data_end > data_start
print(f"\nrootfs_a: {rootfs_a_start}..{rootfs_a_end} ({(rootfs_a_end-rootfs_a_start+1)*SECTOR/GIB:.3f} GiB)")
print(f"rootfs_b: {rootfs_b_start}..{rootfs_b_end} ({(rootfs_b_end-rootfs_b_start+1)*SECTOR/GIB:.3f} GiB)")
print(f"data:     {data_start}..{data_end} ({(data_end-data_start+1)*SECTOR/GIB:.3f} GiB)")

def guid_to_mixed_endian(u: uuid.UUID) -> bytes:
    b = u.bytes  # big-endian RFC4122
    return b[0:4][::-1] + b[4:6][::-1] + b[6:8][::-1] + b[8:16]

def make_entry(name, start, end, type_guid, attrs, part_guid_bytes):
    name_bytes = name.encode('utf-16-le')
    name_bytes = name_bytes + b'\x00' * (72 - len(name_bytes))
    return (type_guid + part_guid_bytes + struct.pack('<QQQ', start, end, attrs) + name_bytes)

new_slots = {
    userdata_idx: make_entry('rootfs_a', rootfs_a_start, rootfs_a_end, ud['type_guid'], ud['attrs'], guid_to_mixed_endian(uuid.uuid4())),
    free_slots[0]: make_entry('rootfs_b', rootfs_b_start, rootfs_b_end, ud['type_guid'], ud['attrs'], guid_to_mixed_endian(uuid.uuid4())),
    free_slots[1]: make_entry('data', data_start, data_end, ud['type_guid'], ud['attrs'], guid_to_mixed_endian(uuid.uuid4())),
}

new_entries_region = bytearray(entries_region)
for idx, blob in new_slots.items():
    assert len(blob) == 128
    new_entries_region[idx*128:(idx+1)*128] = blob

entries_crc32 = zlib.crc32(bytes(new_entries_region)) & 0xffffffff

def build_header(my, alt, part_entries_at, entries_crc):
    h = bytearray(hdr)  # start from live header, preserve reserved/unknown bytes
    struct.pack_into('<Q', h, 24, my)
    struct.pack_into('<Q', h, 32, alt)
    struct.pack_into('<Q', h, 40, first_usable)
    struct.pack_into('<Q', h, 48, last_usable)
    struct.pack_into('<Q', h, 72, part_entries_at)
    struct.pack_into('<I', h, 80, num_entries)
    struct.pack_into('<I', h, 84, entry_size)
    struct.pack_into('<I', h, 88, entries_crc)
    struct.pack_into('<I', h, 16, 0)  # zero header CRC before computing
    crc = zlib.crc32(bytes(h[0:header_size])) & 0xffffffff
    struct.pack_into('<I', h, 16, crc)
    return bytes(h)

primary_header = build_header(my_lba, alt_lba, part_entries_lba, entries_crc32)
backup_entries_lba = alt_lba - 1  # entries sit immediately before the backup header
backup_header = build_header(alt_lba, my_lba, backup_entries_lba, entries_crc32)

# ---- assemble output blobs ----
primary_blob = mbr + primary_header + bytes(new_entries_region) + tail_padding
assert len(primary_blob) == 24576

backup_blob = bytes(new_entries_region) + backup_header
assert len(backup_blob) == SECTOR*2

OUT = HERE
with open(f"{OUT}/gpt-userdata-primary.bin", "wb") as f:
    f.write(primary_blob)
with open(f"{OUT}/gpt-userdata-backup.bin", "wb") as f:
    f.write(backup_blob)

backup_write_offset_bytes = backup_entries_lba * SECTOR
print(f"\nbackup blob write offset: LBA {backup_entries_lba} = byte {backup_write_offset_bytes} (512B-blocks: {backup_write_offset_bytes//512})")
print(f"primary blob write offset: byte 0")
print(f"rootfs_a start byte offset: {rootfs_a_start*SECTOR} (512B-blocks: {rootfs_a_start*SECTOR//512})")
print(f"rootfs_b start byte offset: {rootfs_b_start*SECTOR} (512B-blocks: {rootfs_b_start*SECTOR//512})")
print(f"data start byte offset: {data_start*SECTOR} (512B-blocks: {data_start*SECTOR//512})")
print("\nWrote:", f"{OUT}/gpt-userdata-primary.bin", f"{OUT}/gpt-userdata-backup.bin")
