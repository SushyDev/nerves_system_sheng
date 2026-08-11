// DUPLICATED at deps/nerves_system_br/package/ufs_boot_lun/src and
// nerves_system_sheng/deps/nerves_system_br/package/ufs_boot_lun/src
// (Buildroot only scans the latter) - copy to both after every edit.
const std = @import("std");

// scsi/scsi_bsg_ufs.h has anonymous unions containing bitfields that Zig's
// translate-c demotes to opaque types, so the UPIU structs are hand-defined
// below (byte-for-byte match, verified against the kernel UAPI header) and
// only linux/bsg.h (bitfield-free) goes through @cImport.
pub const c = @cImport({
    @cInclude("linux/bsg.h");
});

pub const ufs_bsg_dev = "/dev/bsg/ufs-bsg0";
const sg_io_ioctl = 0x2285;

const utp_upiu_query_req: u32 = 0x16;
const query_req_func_std_read: u8 = 0x01;
const query_req_func_std_write: u8 = 0x81;
const query_req_op_read_attr: u8 = 0x3;
const query_req_op_write_attr: u8 = 0x4;
const query_attr_idn_boot_lu_en: u8 = 0x00;

pub const boot_lun_a: u32 = 1;
pub const boot_lun_b: u32 = 2;

pub const UfsError = error{ IoctlFailed, VerificationFailed, InvalidTarget };

// Only the dword_0/dword_1 view of the header union is ever used (matches
// upstream), so the byte-field/bitfield arm is omitted entirely.
const UtpUpiuHeader = extern struct {
    dword_0: u32 = 0,
    dword_1: u32 = 0,
    dword_2: u32 = 0,
};

// Layout-identical to the kernel's utp_upiu_query (the qr arm of
// utp_upiu_req's union); the sc/uc arms are never touched.
const UtpUpiuQuery = extern struct {
    opcode: u8 = 0,
    idn: u8 = 0,
    index: u8 = 0,
    selector: u8 = 0,
    reserved_osf: u16 = 0,
    length: u16 = 0,
    value: u32 = 0,
    reserved: [2]u32 = .{ 0, 0 },
};

const UtpUpiuReq = extern struct {
    header: UtpUpiuHeader = .{},
    qr: UtpUpiuQuery = .{},
};

const UfsBsgRequest = extern struct {
    msgcode: u32 = 0,
    upiu_req: UtpUpiuReq = .{},
};

const UfsBsgReply = extern struct {
    result: i32 = 0,
    reply_payload_rcv_len: u32 = 0,
    upiu_rsp: UtpUpiuReq = .{},
};

fn executeQuery(fd: std.posix.fd_t, func: u8, opcode: u8, in_value: u32) !u32 {
    var req = UfsBsgRequest{};
    var rsp = UfsBsgReply{};
    var sg_io = std.mem.zeroes(c.sg_io_v4);

    req.msgcode = utp_upiu_query_req;
    req.upiu_req.header.dword_0 = std.mem.nativeToBig(u32, utp_upiu_query_req << 24);
    req.upiu_req.header.dword_1 = std.mem.nativeToBig(u32, @as(u32, func) << 16);
    req.upiu_req.qr.opcode = opcode;
    req.upiu_req.qr.idn = query_attr_idn_boot_lu_en;
    req.upiu_req.qr.value = std.mem.nativeToBig(u32, in_value);

    sg_io.guard = 'Q';
    sg_io.protocol = c.BSG_PROTOCOL_SCSI;
    sg_io.subprotocol = c.BSG_SUB_PROTOCOL_SCSI_TRANSPORT;
    sg_io.request_len = @sizeOf(UfsBsgRequest);
    sg_io.request = @intFromPtr(&req);
    sg_io.response = @intFromPtr(&rsp);
    sg_io.max_response_len = @sizeOf(UfsBsgReply);

    const ret = std.os.linux.ioctl(fd, sg_io_ioctl, @intFromPtr(&sg_io));
    if (ret != 0 or sg_io.info != 0 or rsp.result != 0) {
        return UfsError.IoctlFailed;
    }
    return std.mem.bigToNative(u32, rsp.upiu_rsp.qr.value);
}

pub fn openDevice() !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, ufs_bsg_dev, .{ .ACCMODE = .RDWR }, 0);
}

pub fn readBootLun(fd: std.posix.fd_t) !u32 {
    return executeQuery(fd, query_req_func_std_read, query_req_op_read_attr, 0);
}

pub fn writeBootLun(fd: std.posix.fd_t, target_lun: u32) !void {
    if (target_lun != boot_lun_a and target_lun != boot_lun_b) return UfsError.InvalidTarget;
    _ = try executeQuery(fd, query_req_func_std_write, query_req_op_write_attr, target_lun);
    const confirm = try readBootLun(fd);
    if (confirm != target_lun) return UfsError.VerificationFailed;
}
