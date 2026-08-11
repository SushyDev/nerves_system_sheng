// Called by fwup-ops.conf/fwup.conf's execute() (a separate process) and
// pre-erlang-init.sh (runs before the BEAM starts) - Elixir can't reach
// those call sites, so this stays a standalone CLI, not a NIF.
//
// GPT attribute byte (offset 54 within each 128-byte entry):
//   bit0-1 priority, bit2 ACTIVE, bit3-5 retry count, bit6 SUCCESSFUL, bit7 UNBOOTABLE.
//
// DUPLICATED at deps/nerves_system_br/package/ab_ops/src and
// nerves_system_sheng/deps/nerves_system_br/package/ab_ops/src (Buildroot
// only scans the latter) - copy to both after every edit, or you build the
// stale binary silently. See nerves_sheng_edl_brick_2026_08_11.md.
const std = @import("std");
const linux = std.os.linux;

extern "c" fn system(command: [*:0]const u8) c_int;

const boot_a_attr_offset: u64 = 9910;
const boot_b_attr_offset: u64 = 13750;
const active_bit: u8 = 0x04;
const retry_mask: u8 = 0x38;
const retry_max: u8 = 0x38;
const success_bit: u8 = 0x40;

const gpt_header_offset: u64 = 4096;
const gpt_entries_offset: u64 = 8192;
const gpt_disk_guid_offset: u64 = gpt_header_offset + 56;
const gpt_disk_guid_len: usize = 16;
const gpt_max_entries_bytes: usize = 16384; // real table is 96*128=12288; rounded up

pub const gpt_blob_dir = "/usr/share/nerves_sheng/gpt";
const sys_block = "/sys/class/block";

pub const Slot = enum(u8) { a = 'a', b = 'b' };

pub const OpsError = error{
    OpenFailed,
    ReadFailed,
    WriteFailed,
    PartnameNotFound,
    UnexpectedSymlink,
    ImplausibleGptHeader,
    AmbiguousSlotState,
    BlobStale,
    BlobEmpty,
    WriteIncomplete,
};

fn sysOpen(path: [:0]const u8, flags: linux.O) !linux.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return OpsError.OpenFailed;
    return @intCast(rc);
}

fn sysClose(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

fn sysPread(fd: linux.fd_t, buf: []u8, offset: u64) !void {
    const rc = linux.pread(fd, buf.ptr, buf.len, @bitCast(offset));
    const signed: isize = @bitCast(rc);
    if (signed != @as(isize, @intCast(buf.len))) return OpsError.ReadFailed;
}

fn sysPwrite(fd: linux.fd_t, buf: []const u8, offset: u64) !void {
    const rc = linux.pwrite(fd, buf.ptr, buf.len, @bitCast(offset));
    const signed: isize = @bitCast(rc);
    if (signed != @as(isize, @intCast(buf.len))) return OpsError.WriteIncomplete;
    _ = linux.fsync(fd);
}

/// Same sysfs PARTNAME walk as ab_update.ex's disk_device_for_partname/1 - no
/// /dev/disk/by-partlabel/ and no dirname/basename/readlink in this device's
/// busybox, so this can't shell out either; must do it natively.
pub fn resolveDisk(partname: []const u8, out: []u8) ![]const u8 {
    const dir_fd = try sysOpen(sys_block, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    defer sysClose(dir_fd);

    var want_buf: [256]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "PARTNAME={s}\n", .{partname}) catch return OpsError.PartnameNotFound;

    var link_target_buf: [512]u8 = undefined;

    var dents_buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
        const signed: isize = @bitCast(n);
        if (signed <= 0) break;

        var pos: usize = 0;
        while (pos < n) {
            const dent: *align(1) linux.dirent64 = @ptrCast(&dents_buf[pos]);
            const name_ptr: [*:0]const u8 = @ptrCast(&dent.name);
            const name = std.mem.span(name_ptr);
            pos += dent.reclen;

            if (name.len == 0 or name[0] == '.') continue;

            var path_buf: [300]u8 = undefined;
            const uevent_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/uevent", .{ sys_block, name }) catch continue;

            const f = sysOpen(uevent_path, .{ .ACCMODE = .RDONLY }) catch continue;
            defer sysClose(f);

            var content_buf: [4096]u8 = undefined;
            const read_n = linux.read(f, &content_buf, content_buf.len);
            const read_signed: isize = @bitCast(read_n);
            if (read_signed <= 0) continue;
            const content = content_buf[0..@intCast(read_signed)];

            if (std.mem.indexOf(u8, content, want) != null) {
                var link_path_buf: [300]u8 = undefined;
                const link_path = std.fmt.bufPrintZ(&link_path_buf, "{s}/{s}", .{ sys_block, name }) catch return OpsError.UnexpectedSymlink;

                const link_rc = linux.readlinkat(linux.AT.FDCWD, link_path, &link_target_buf, link_target_buf.len);
                const link_signed: isize = @bitCast(link_rc);
                if (link_signed < 0) return OpsError.UnexpectedSymlink;

                const link_target = link_target_buf[0..@intCast(link_signed)];

                // link_target looks like ../../devices/.../block/sde/sde13 -
                // parent disk is the second-to-last path component.
                const last_slash = std.mem.lastIndexOfScalar(u8, link_target, '/') orelse return OpsError.UnexpectedSymlink;
                const trimmed = link_target[0..last_slash];
                const disk_start = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0;
                const disk_name = trimmed[disk_start..];

                return std.fmt.bufPrint(out, "/dev/{s}", .{disk_name}) catch OpsError.UnexpectedSymlink;
            }
        }
    }

    return OpsError.PartnameNotFound;
}

fn readByte(disk: [:0]const u8, offset: u64) !u8 {
    const fd = try sysOpen(disk, .{ .ACCMODE = .RDONLY });
    defer sysClose(fd);
    var b: [1]u8 = undefined;
    try sysPread(fd, &b, offset);
    return b[0];
}

fn writeByte(disk: [:0]const u8, offset: u64, value: u8) !void {
    const fd = try sysOpen(disk, .{ .ACCMODE = .WRONLY });
    defer sysClose(fd);
    try sysPwrite(fd, &.{value}, offset);
}

fn readBytes(path: [:0]const u8, offset: u64, out: []u8) !void {
    const fd = try sysOpen(path, .{ .ACCMODE = .RDONLY });
    defer sysClose(fd);
    try sysPread(fd, out, offset);
}

// No zlib in this build - GPT's CRC32 is the standard IEEE 802.3 one, same
// polynomial as zlib's crc32.
fn crc32Compute(data: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (data) |byte| {
        crc ^= byte;
        var b: u8 = 0;
        while (b < 8) : (b += 1) {
            const mask = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xedb88320 & mask);
        }
    }
    return ~crc;
}

fn readU32Le(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

fn writeU32Le(p: []u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .little);
}

/// Recomputes entries_crc32/header_crc32 from the live entries table and
/// rewrites them if they don't match what the header currently claims. A
/// HyperOS stock restore left this LUN's GPT with a self-consistent header
/// but a stale entries_crc32 - ABL tolerated it for a while, then fell to
/// EDL. Repair only: never touches entry data, just the two checksum fields.
pub fn fixGptCrc(disk: [:0]const u8) !void {
    var hdr: [512]u8 = undefined;
    try readBytes(disk, gpt_header_offset, &hdr);

    const header_size = readU32Le(hdr[12..]);
    const num_entries = readU32Le(hdr[80..]);
    const entry_size = readU32Le(hdr[84..]);
    const stored_entries_crc = readU32Le(hdr[88..]);
    const entries_len: usize = @as(usize, num_entries) * @as(usize, entry_size);

    if (header_size > hdr.len or entries_len == 0 or entries_len > gpt_max_entries_bytes) {
        return OpsError.ImplausibleGptHeader;
    }

    var entries: [gpt_max_entries_bytes]u8 = undefined;
    try readBytes(disk, gpt_entries_offset, entries[0..entries_len]);

    const calc_entries_crc = crc32Compute(entries[0..entries_len]);

    var hdr_zeroed = hdr;
    writeU32Le(hdr_zeroed[16..], 0);
    const stored_header_crc = readU32Le(hdr[16..]);
    const calc_header_crc_asis = crc32Compute(hdr_zeroed[0..header_size]);

    if (calc_entries_crc == stored_entries_crc and calc_header_crc_asis == stored_header_crc) {
        return; // already valid
    }

    writeU32Le(hdr_zeroed[88..], calc_entries_crc);
    const calc_header_crc = crc32Compute(hdr_zeroed[0..header_size]);
    writeU32Le(hdr_zeroed[16..], calc_header_crc);

    const fd = try sysOpen(disk, .{ .ACCMODE = .WRONLY });
    defer sysClose(fd);
    try sysPwrite(fd, hdr_zeroed[0..header_size], gpt_header_offset);
}

/// Mirrors active_slot/0 exactly: raise (here, the caller reports failure)
/// rather than guess on an ambiguous both/neither-active state.
pub fn activeSlot(disk: [:0]const u8) !Slot {
    const a_attr = try readByte(disk, boot_a_attr_offset);
    const b_attr = try readByte(disk, boot_b_attr_offset);

    const a_active = (a_attr & active_bit) != 0;
    const b_active = (b_attr & active_bit) != 0;

    if (a_active and !b_active) return .a;
    if (b_active and !a_active) return .b;
    return OpsError.AmbiguousSlotState;
}

/// disk_guid only (not the whole table) - catches a stale
/// gpt-primary-slot-*.bin before it's written.
fn diskGuidMatchesBlob(disk: [:0]const u8, blob_path: [:0]const u8) bool {
    var live_guid: [gpt_disk_guid_len]u8 = undefined;
    readBytes(disk, gpt_disk_guid_offset, &live_guid) catch return false;

    var blob_guid: [gpt_disk_guid_len]u8 = undefined;
    readBytes(blob_path, gpt_disk_guid_offset, &blob_guid) catch return false;

    return std.mem.eql(u8, &live_guid, &blob_guid);
}

fn resolveBootDisk(out: []u8) ![:0]const u8 {
    const disk = try resolveDisk("boot_a", out);
    out[disk.len] = 0;
    return out[0..disk.len :0];
}

/// Emits fwup's --framing WN-frame format directly to stdout so
/// Nerves.Runtime.FwupOps.status/0 can decode it - fwup's info() can't take
/// a runtime-computed string, so this bypasses it. Frame =
/// <<len::32, "WN", _code::16, message>> per fwup_ops.ex's decode/1.
pub fn cmdStatus() u8 {
    var disk_buf: [64]u8 = undefined;
    const disk = resolveBootDisk(&disk_buf) catch return 1;
    const slot = activeSlot(disk) catch return 1;

    const frame = [9]u8{ 0, 0, 0, 5, 'W', 'N', 0, 0, @intFromEnum(slot) };
    const rc = linux.write(1, &frame, frame.len);
    const signed: isize = @bitCast(rc);
    if (signed != frame.len) return 1;
    return 0;
}

/// Mirrors write_success_bit/1 exactly: clear retry nibble, set it to max,
/// set the SUCCESSFUL bit. Only ever touches the active slot's own entry.
pub fn cmdValidate() u8 {
    var disk_buf: [64]u8 = undefined;
    const disk = resolveBootDisk(&disk_buf) catch return 1;
    const slot = activeSlot(disk) catch return 1;

    const offset: u64 = if (slot == .a) boot_a_attr_offset else boot_b_attr_offset;

    const current = readByte(disk, offset) catch return 1;
    const new_byte = (current & ~retry_mask) | success_bit | retry_max;
    writeByte(disk, offset, new_byte) catch return 1;

    const verify = readByte(disk, offset) catch return 1;
    if (verify != new_byte) return 1;

    // A single-byte attribute patch invalidates entries_crc32 unless
    // recomputed - don't reintroduce the same corruption we're fixing.
    fixGptCrc(disk) catch {};

    std.debug.print("validated slot {c} (0x{x:0>2} -> 0x{x:0>2})\n", .{ @intFromEnum(slot), current, new_byte });
    return 0;
}

/// Mirrors revert!/1 exactly: raw-write the OTHER slot's pre-shipped GPT
/// blob (real fastboot set_active capture, not synthesized), then flip the
/// UFS boot-LUN to match via the existing, separately-reviewed ufs_boot_lun
/// tool (not reimplemented here).
pub fn cmdRevert() u8 {
    var disk_buf: [64]u8 = undefined;
    const disk = resolveBootDisk(&disk_buf) catch return 1;
    const slot = activeSlot(disk) catch return 1;
    const good_slot: Slot = if (slot == .a) .b else .a;

    var blob_path_buf: [256]u8 = undefined;
    const blob_path = std.fmt.bufPrintZ(&blob_path_buf, "{s}/gpt-primary-slot-{c}.bin", .{ gpt_blob_dir, @intFromEnum(good_slot) }) catch return 1;

    // Same staleness check the upgrade.a/b GPT write runs before it -
    // revert is the unattended auto-rollback path, needs it too.
    if (!diskGuidMatchesBlob(disk, blob_path)) {
        std.debug.print("revert: disk_guid mismatch - blob is stale, refusing to write\n", .{});
        return 1;
    }

    const blob_fd = sysOpen(blob_path, .{ .ACCMODE = .RDONLY }) catch {
        std.debug.print("revert: fopen(blob) failed\n", .{});
        return 1;
    };
    defer sysClose(blob_fd);

    var blob: [24576]u8 = undefined;
    const read_rc = linux.read(blob_fd, &blob, blob.len);
    const read_signed: isize = @bitCast(read_rc);
    if (read_signed <= 0) {
        std.debug.print("revert: empty or unreadable GPT blob at {s}\n", .{blob_path});
        return 1;
    }
    const blob_len: usize = @intCast(read_signed);

    const disk_fd = sysOpen(disk, .{ .ACCMODE = .WRONLY }) catch {
        std.debug.print("revert: open(disk) failed\n", .{});
        return 1;
    };
    defer sysClose(disk_fd);
    sysPwrite(disk_fd, blob[0..blob_len], 0) catch {
        std.debug.print("revert: GPT write incomplete\n", .{});
        return 1;
    };

    fixGptCrc(disk) catch {}; // cheap insurance if the blob itself wasn't fully valid

    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "ufs_boot_lun write {c}", .{@intFromEnum(good_slot)}) catch return 1;
    const status = system(cmd.ptr);
    if (status != 0) {
        std.debug.print("revert: ufs_boot_lun failed (status {d})\n", .{status});
        return 1;
    }

    std.debug.print("reverted to slot {c}\n", .{@intFromEnum(good_slot)});
    return 0;
}

pub fn cmdVerifyBootGpt() u8 {
    var disk_buf: [64]u8 = undefined;
    const disk = resolveBootDisk(&disk_buf) catch return 1;

    var blob_path_buf: [256]u8 = undefined;
    const blob_path = std.fmt.bufPrintZ(&blob_path_buf, "{s}/gpt-primary-slot-a.bin", .{gpt_blob_dir}) catch return 1;

    if (!diskGuidMatchesBlob(disk, blob_path)) {
        std.debug.print("verify-boot-gpt: disk_guid mismatch - blob is stale, recapture it\n", .{});
        return 1;
    }
    return 0;
}

pub fn cmdFixBootGptCrc() u8 {
    var disk_buf: [64]u8 = undefined;
    const disk = resolveBootDisk(&disk_buf) catch return 1;
    fixGptCrc(disk) catch return 1;
    return 0;
}
