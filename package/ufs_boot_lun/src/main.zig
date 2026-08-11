const std = @import("std");
const core = @import("core.zig");

fn usage(prog: []const u8) void {
    std.debug.print("Usage:\n  {s} read        Print the current bBootLunEn value\n  {s} write <a|b> Select boot LUN A or B\n", .{ prog, prog });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = init.args.iterate();
    const prog = it.next() orelse "ufs_boot_lun";

    const cmd = it.next() orelse {
        usage(prog);
        return 2;
    };

    const fd = core.openDevice() catch |err| {
        std.debug.print("Failed to open {s}: {s}\n", .{ core.ufs_bsg_dev, @errorName(err) });
        return 1;
    };
    defer _ = std.os.linux.close(fd);

    if (std.mem.eql(u8, cmd, "read")) {
        const val = core.readBootLun(fd) catch |err| {
            std.debug.print("UFS query failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("{d}\n", .{val});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "write")) {
        const target_str = it.next() orelse {
            std.debug.print("Error: missing target ('a' or 'b')\n", .{});
            return 2;
        };
        const target: u32 = if (std.mem.eql(u8, target_str, "a"))
            core.boot_lun_a
        else if (std.mem.eql(u8, target_str, "b"))
            core.boot_lun_b
        else {
            std.debug.print("Error: Invalid target '{s}'. Must be 'a' or 'b'.\n", .{target_str});
            return 2;
        };

        core.writeBootLun(fd, target) catch |err| {
            std.debug.print("write failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("{d}\n", .{target});
        return 0;
    }

    usage(prog);
    return 2;
}
