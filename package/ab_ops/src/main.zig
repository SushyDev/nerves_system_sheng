const std = @import("std");
const core = @import("core.zig");

fn usage(prog: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  {s} status              Emit fwup --framing WN-frame with the active slot
        \\  {s} validate            Mark the active slot successful, reset its retry count
        \\  {s} revert              Switch GPT + boot-LUN to the other slot
        \\  {s} verify-boot-gpt     Exit 0 if the shipped GPT blob still matches the live disk
        \\  {s} fix-boot-gpt-crc    Repair entries_crc32/header_crc32 if stale (never touches entry data)
        \\
    , .{ prog, prog, prog, prog, prog });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = init.args.iterate();
    const prog = it.next() orelse "ab_ops";
    const cmd = it.next() orelse {
        usage(prog);
        return 2;
    };

    if (std.mem.eql(u8, cmd, "status")) return core.cmdStatus();
    if (std.mem.eql(u8, cmd, "validate")) return core.cmdValidate();
    if (std.mem.eql(u8, cmd, "revert")) return core.cmdRevert();
    if (std.mem.eql(u8, cmd, "verify-boot-gpt")) return core.cmdVerifyBootGpt();
    if (std.mem.eql(u8, cmd, "fix-boot-gpt-crc")) return core.cmdFixBootGptCrc();

    usage(prog);
    return 2;
}
