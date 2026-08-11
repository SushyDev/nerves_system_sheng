/*
 * Reads/writes bBootLunEn - the UFS attribute selecting which physical
 * boot LUN (1=A, 2=B) ABL reads at power-on. Lives outside the GPT
 * entirely; see ../../fwup.conf for why both must agree.
 *
 * Standard SG_IO ioctl + UFS query UPIU (not a vendor hack), modeled on
 * linux-msm/qbootctl's ufs-bsg.c.
 */
#include <linux/bsg.h>
#include <scsi/scsi_bsg_ufs.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define UFS_BSG_DEV "/dev/bsg/ufs-bsg0"

/* Standard UFS/UPIU query constants, not vendor-specific. */
#define SG_IO 0x2285
#define UTP_UPIU_QUERY_REQ 0x16
#define QUERY_REQ_FUNC_STD_READ 0x01
#define QUERY_REQ_FUNC_STD_WRITE 0x81
#define QUERY_REQ_OP_READ_ATTR 0x3
#define QUERY_REQ_OP_WRITE_ATTR 0x4
#define QUERY_ATTR_IDN_BOOT_LU_EN 0x00

#define BOOT_LUN_A_ID 1
#define BOOT_LUN_B_ID 2

static void compose_query_req(struct ufs_bsg_request *req, __u8 func, __u8 opcode)
{
    struct utp_upiu_header *hdr = &req->upiu_req.header;
    struct utp_upiu_query *qr = &req->upiu_req.qr;

    req->msgcode = UTP_UPIU_QUERY_REQ;
    hdr->dword_0 = htobe32(UTP_UPIU_QUERY_REQ << 24);
    hdr->dword_1 = htobe32((__u32)func << 16);
    qr->opcode = opcode;
    qr->idn = QUERY_ATTR_IDN_BOOT_LU_EN;
}

/* Returns 0 on success with *out_value set (read) or written (write). */
static int ufs_boot_lun_query(__u8 func, __u8 opcode, __u32 in_value, __u32 *out_value)
{
    int fd = open(UFS_BSG_DEV, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open(%s): %s\n", UFS_BSG_DEV, strerror(errno));
        return -1;
    }

    struct ufs_bsg_request req = {0};
    struct ufs_bsg_reply rsp = {0};
    req.upiu_req.qr.value = htobe32(in_value);
    compose_query_req(&req, func, opcode);

    struct sg_io_v4 sg_io = {
        .guard = 'Q',
        .protocol = BSG_PROTOCOL_SCSI,
        .subprotocol = BSG_SUB_PROTOCOL_SCSI_TRANSPORT,
        .request_len = sizeof(req),
        .request = (__u64)&req,
        .response = (__u64)&rsp,
        .max_response_len = sizeof(rsp),
    };

    int ret = ioctl(fd, SG_IO, &sg_io);
    close(fd);

    if (ret != 0 || sg_io.info != 0 || rsp.result != 0) {
        fprintf(stderr,
                "UFS query failed: ioctl_ret=%d errno=%d info=%u "
                "device_status=0x%x transport_status=0x%x driver_status=0x%x rsp.result=%u\n",
                ret, errno, sg_io.info, sg_io.device_status, sg_io.transport_status,
                sg_io.driver_status, rsp.result);
        return -1;
    }

    if (out_value)
        *out_value = be32toh(rsp.upiu_rsp.qr.value);
    return 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s read              Print the current bBootLunEn value\n"
            "  %s write <a|b>       Select boot LUN A or B\n",
            prog, prog);
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "read") == 0) {
        __u32 value = 0;
        if (ufs_boot_lun_query(QUERY_REQ_FUNC_STD_READ, QUERY_REQ_OP_READ_ATTR, 0, &value) != 0)
            return 1;
        printf("%u\n", value);
        return 0;
    }

    if (argc == 3 && strcmp(argv[1], "write") == 0 &&
        (strcmp(argv[2], "a") == 0 || strcmp(argv[2], "b") == 0)) {
        __u32 target = (strcmp(argv[2], "a") == 0) ? BOOT_LUN_A_ID : BOOT_LUN_B_ID;
        if (ufs_boot_lun_query(QUERY_REQ_FUNC_STD_WRITE, QUERY_REQ_OP_WRITE_ATTR, target, NULL) != 0)
            return 1;

        /* Read back - this gates whether ABL boots the slot fwup just activated. */
        __u32 confirm = 0;
        if (ufs_boot_lun_query(QUERY_REQ_FUNC_STD_READ, QUERY_REQ_OP_READ_ATTR, 0, &confirm) != 0)
            return 1;
        if (confirm != target) {
            fprintf(stderr, "Wrote bBootLunEn=%u but read back %u\n", target, confirm);
            return 1;
        }
        printf("%u\n", confirm);
        return 0;
    }

    usage(argv[0]);
    return 2;
}
