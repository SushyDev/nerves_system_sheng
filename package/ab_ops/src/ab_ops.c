/*
 * Standalone helper for nerves_system_sheng/fwup-ops.conf's status/revert/
 * validate tasks - fwup can't do runtime branching (which slot is active)
 * or feed a subprocess's output back into info(), so that logic lives here
 * instead. Mirrors lib/nerves_sheng/ab_update.ex's already-proven Elixir
 * logic bit-for-bit (same offsets/masks, same GPT-blob revert mechanism) -
 * this is a port, not new design. Untested on ARM64 as of writing (no
 * cross toolchain on the authoring host); review against ab_update.ex
 * before trusting on real hardware.
 *
 * GPT attribute byte (offset 54 within each 128-byte entry), confirmed
 * against the real Qualcomm gpt-utils layout:
 *   bit0-1 priority, bit2 ACTIVE, bit3-5 retry count, bit6 SUCCESSFUL, bit7 UNBOOTABLE.
 */
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BOOT_A_ATTR_OFFSET 9910
#define BOOT_B_ATTR_OFFSET 13750
#define ACTIVE_BIT 0x04
#define RETRY_MASK 0x38
#define RETRY_MAX 0x38
#define SUCCESS_BIT 0x40

#define GPT_HEADER_OFFSET 4096
#define GPT_ENTRIES_OFFSET 8192
#define GPT_DISK_GUID_OFFSET (GPT_HEADER_OFFSET + 56)
#define GPT_DISK_GUID_LEN 16
#define GPT_MAX_ENTRIES_BYTES 16384 /* 96*128, this device's real table */

#define GPT_BLOB_DIR "/usr/share/nerves_sheng/gpt"
#define SYS_BLOCK "/sys/class/block"

/* Same sysfs PARTNAME walk as disk_device_for_partname/1 - no
 * /dev/disk/by-partlabel/ and no dirname/basename/readlink in this
 * device's busybox, so this can't shell out either; must do it natively. */
static int resolve_disk(const char *partname, char *out, size_t out_len)
{
    DIR *d = opendir(SYS_BLOCK);
    if (!d) {
        perror("opendir(" SYS_BLOCK ")");
        return -1;
    }

    char link_target[512] = {0};
    int found = 0;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.')
            continue;

        char uevent_path[300];
        snprintf(uevent_path, sizeof(uevent_path), "%s/%s/uevent", SYS_BLOCK, ent->d_name);

        FILE *f = fopen(uevent_path, "r");
        if (!f)
            continue;

        char line[256];
        char want[256];
        snprintf(want, sizeof(want), "PARTNAME=%s\n", partname);
        while (fgets(line, sizeof(line), f)) {
            if (strcmp(line, want) == 0) {
                found = 1;
                break;
            }
        }
        fclose(f);

        if (found) {
            char link_path[300];
            snprintf(link_path, sizeof(link_path), "%s/%s", SYS_BLOCK, ent->d_name);
            ssize_t n = readlink(link_path, link_target, sizeof(link_target) - 1);
            if (n < 0) {
                perror("readlink");
                closedir(d);
                return -1;
            }
            link_target[n] = '\0';
            break;
        }
    }
    closedir(d);

    if (!found) {
        fprintf(stderr, "No block device found with PARTNAME=%s\n", partname);
        return -1;
    }

    /* link_target looks like ../../devices/.../block/sde/sde13 - parent
     * disk is the second-to-last path component. */
    char *last_slash = strrchr(link_target, '/');
    if (!last_slash) {
        fprintf(stderr, "Unexpected symlink target: %s\n", link_target);
        return -1;
    }
    *last_slash = '\0';
    char *disk_name = strrchr(link_target, '/');
    disk_name = disk_name ? disk_name + 1 : link_target;

    snprintf(out, out_len, "/dev/%s", disk_name);
    return 0;
}

static int read_byte(const char *disk, off_t offset, unsigned char *out)
{
    int fd = open(disk, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return -1;
    }
    ssize_t n = pread(fd, out, 1, offset);
    close(fd);
    if (n != 1) {
        fprintf(stderr, "pread at offset %lld failed\n", (long long)offset);
        return -1;
    }
    return 0;
}

/* No zlib in this build (ab_ops.mk links nothing) - GPT's CRC32 is the
 * standard IEEE 802.3 one, same polynomial as zlib's crc32. */
static uint32_t crc32_compute(const unsigned char *data, size_t len)
{
    uint32_t crc = 0xffffffff;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xedb88320 & (~(crc & 1) + 1));
    }
    return ~crc;
}

static uint32_t read_u32le(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static void write_u32le(unsigned char *p, uint32_t v)
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

static int read_bytes(const char *path, off_t offset, unsigned char *out, size_t len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return -1;
    }
    ssize_t n = pread(fd, out, len, offset);
    close(fd);
    if (n != (ssize_t)len) {
        fprintf(stderr, "pread at offset %lld failed\n", (long long)offset);
        return -1;
    }
    return 0;
}

/* Recomputes entries_crc32/header_crc32 from the live entries table and
 * rewrites them if they don't match what the header currently claims.
 * A HyperOS stock restore left this LUN's GPT with a self-consistent
 * header but a stale entries_crc32 - ABL tolerated it for a while, then
 * fell to EDL (see nerves_sheng_edl_brick_2026_08_11.md). Repair only:
 * never touches entry data, just the two checksum fields. */
static int fix_gpt_crc(const char *disk)
{
    unsigned char hdr[512];
    if (read_bytes(disk, GPT_HEADER_OFFSET, hdr, sizeof(hdr)) != 0)
        return -1;

    uint32_t header_size = read_u32le(hdr + 12);
    uint32_t num_entries = read_u32le(hdr + 80);
    uint32_t entry_size = read_u32le(hdr + 84);
    uint32_t stored_entries_crc = read_u32le(hdr + 88);
    size_t entries_len = (size_t)num_entries * entry_size;

    if (header_size > sizeof(hdr) || entries_len == 0 || entries_len > GPT_MAX_ENTRIES_BYTES) {
        fprintf(stderr, "fix-boot-gpt-crc: implausible header (num_entries=%u entry_size=%u)\n", num_entries, entry_size);
        return -1;
    }

    unsigned char entries[GPT_MAX_ENTRIES_BYTES];
    if (read_bytes(disk, GPT_ENTRIES_OFFSET, entries, entries_len) != 0)
        return -1;

    uint32_t calc_entries_crc = crc32_compute(entries, entries_len);

    unsigned char hdr_zeroed[512];
    memcpy(hdr_zeroed, hdr, sizeof(hdr_zeroed));
    write_u32le(hdr_zeroed + 16, 0);
    uint32_t stored_header_crc = read_u32le(hdr + 16);
    uint32_t calc_header_crc_asis = crc32_compute(hdr_zeroed, header_size);

    if (calc_entries_crc == stored_entries_crc && calc_header_crc_asis == stored_header_crc) {
        return 0; /* already valid */
    }

    write_u32le(hdr_zeroed + 88, calc_entries_crc);
    uint32_t calc_header_crc = crc32_compute(hdr_zeroed, header_size);
    write_u32le(hdr_zeroed + 16, calc_header_crc);

    int fd = open(disk, O_WRONLY);
    if (fd < 0) {
        perror("open");
        return -1;
    }
    ssize_t n = pwrite(fd, hdr_zeroed, header_size, GPT_HEADER_OFFSET);
    if (n == (ssize_t)header_size)
        fsync(fd);
    close(fd);
    if (n != (ssize_t)header_size) {
        fprintf(stderr, "fix-boot-gpt-crc: header write incomplete\n");
        return -1;
    }

    fprintf(stderr, "fix-boot-gpt-crc: repaired (entries_crc 0x%08x -> 0x%08x)\n", stored_entries_crc, calc_entries_crc);
    return 0;
}

static int write_byte(const char *disk, off_t offset, unsigned char value)
{
    int fd = open(disk, O_WRONLY);
    if (fd < 0) {
        perror("open");
        return -1;
    }
    ssize_t n = pwrite(fd, &value, 1, offset);
    if (n == 1)
        fsync(fd);
    close(fd);
    if (n != 1) {
        fprintf(stderr, "pwrite at offset %lld failed\n", (long long)offset);
        return -1;
    }
    return 0;
}

/* Mirrors active_slot/0 exactly: raise (here, exit 1) rather than guess
 * on an ambiguous both/neither-active state. */
static int active_slot(char *out_slot)
{
    char disk[64];
    if (resolve_disk("boot_a", disk, sizeof(disk)) != 0)
        return -1;

    unsigned char a_attr, b_attr;
    if (read_byte(disk, BOOT_A_ATTR_OFFSET, &a_attr) != 0)
        return -1;
    if (read_byte(disk, BOOT_B_ATTR_OFFSET, &b_attr) != 0)
        return -1;

    int a_active = (a_attr & ACTIVE_BIT) != 0;
    int b_active = (b_attr & ACTIVE_BIT) != 0;

    if (a_active && !b_active) {
        *out_slot = 'a';
        return 0;
    }
    if (b_active && !a_active) {
        *out_slot = 'b';
        return 0;
    }

    fprintf(stderr, "Ambiguous GPT slot-active state (a=0x%02x b=0x%02x)\n", a_attr, b_attr);
    return -1;
}

/* Emits fwup's --framing WN-frame format directly to stdout so
 * Nerves.Runtime.FwupOps.status/0 can decode it - fwup's info() can't take
 * a runtime-computed string, so this bypasses it. Frame = <<len::32,
 * "WN", _code::16, message>> per fwup_ops.ex's decode/1 - verified
 * byte-for-byte against that decoder before relying on this. */
static int cmd_status(void)
{
    char slot;
    if (active_slot(&slot) != 0)
        return 1;

    unsigned char frame[9] = {0, 0, 0, 5, 'W', 'N', 0, 0, (unsigned char)slot};
    if (write(STDOUT_FILENO, frame, sizeof(frame)) != (ssize_t)sizeof(frame)) {
        perror("write");
        return 1;
    }
    return 0;
}

/* Mirrors write_success_bit/1 exactly: clear retry nibble, set it to max,
 * set the SUCCESSFUL bit. Only ever touches the active slot's own entry. */
static int cmd_validate(void)
{
    char slot;
    if (active_slot(&slot) != 0)
        return 1;

    char disk[64];
    if (resolve_disk("boot_a", disk, sizeof(disk)) != 0)
        return 1;

    off_t offset = (slot == 'a') ? BOOT_A_ATTR_OFFSET : BOOT_B_ATTR_OFFSET;

    unsigned char current;
    if (read_byte(disk, offset, &current) != 0)
        return 1;

    unsigned char new_byte = (current & ~RETRY_MASK) | SUCCESS_BIT | RETRY_MAX;
    if (write_byte(disk, offset, new_byte) != 0)
        return 1;

    unsigned char verify;
    if (read_byte(disk, offset, &verify) != 0)
        return 1;
    if (verify != new_byte) {
        fprintf(stderr, "validate: write verify failed (wrote 0x%02x, read 0x%02x)\n", new_byte, verify);
        return 1;
    }

    /* a single-byte attribute patch invalidates entries_crc32 unless
     * recomputed - don't reintroduce the same corruption we're fixing. */
    fix_gpt_crc(disk);

    printf("validated slot %c (0x%02x -> 0x%02x)\n", slot, current, new_byte);
    return 0;
}

/* Mirrors revert!/1 exactly: raw-write the OTHER slot's pre-shipped GPT
 * blob (real fastboot set_active capture, not synthesized - see
 * fwup.conf), then flip the UFS boot-LUN to match via the existing,
 * separately-reviewed ufs_boot_lun tool (not reimplemented here). */
static int cmd_revert(void)
{
    char slot;
    if (active_slot(&slot) != 0)
        return 1;
    char good_slot = (slot == 'a') ? 'b' : 'a';

    char disk[64];
    if (resolve_disk("boot_a", disk, sizeof(disk)) != 0)
        return 1;

    char blob_path[256];
    snprintf(blob_path, sizeof(blob_path), "%s/gpt-primary-slot-%c.bin", GPT_BLOB_DIR, good_slot);

    FILE *blob_file = fopen(blob_path, "rb");
    if (!blob_file) {
        perror("fopen(blob)");
        return 1;
    }
    unsigned char blob[24576];
    size_t blob_len = fread(blob, 1, sizeof(blob), blob_file);
    fclose(blob_file);
    if (blob_len == 0) {
        fprintf(stderr, "revert: empty or unreadable GPT blob at %s\n", blob_path);
        return 1;
    }

    int fd = open(disk, O_WRONLY);
    if (fd < 0) {
        perror("open(disk)");
        return 1;
    }
    ssize_t written = pwrite(fd, blob, blob_len, 0);
    if (written == (ssize_t)blob_len)
        fsync(fd);
    close(fd);
    if (written != (ssize_t)blob_len) {
        fprintf(stderr, "revert: GPT write incomplete (%zd of %zu bytes)\n", written, blob_len);
        return 1;
    }

    fix_gpt_crc(disk); /* cheap insurance if the blob itself wasn't fully valid */

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "ufs_boot_lun write %c", good_slot);
    int status = system(cmd);
    if (status != 0) {
        fprintf(stderr, "revert: ufs_boot_lun failed (status %d)\n", status);
        return 1;
    }

    printf("reverted to slot %c\n", good_slot);
    return 0;
}

/* disk_guid only (not the whole table - unlike PartitionMigration's
 * userdata check, raw_write/revert overwrite the whole blob anyway).
 * Catches a stale gpt-primary-slot-*.bin before it's written - see
 * nerves_sheng_edl_brick_2026_08_11.md. */
static int cmd_verify_boot_gpt(void)
{
    char disk[64];
    if (resolve_disk("boot_a", disk, sizeof(disk)) != 0)
        return 1;

    unsigned char live_guid[GPT_DISK_GUID_LEN];
    if (read_bytes(disk, GPT_DISK_GUID_OFFSET, live_guid, sizeof(live_guid)) != 0)
        return 1;

    char blob_path[256];
    snprintf(blob_path, sizeof(blob_path), "%s/gpt-primary-slot-a.bin", GPT_BLOB_DIR);
    unsigned char blob_guid[GPT_DISK_GUID_LEN];
    if (read_bytes(blob_path, GPT_DISK_GUID_OFFSET, blob_guid, sizeof(blob_guid)) != 0)
        return 1;

    if (memcmp(live_guid, blob_guid, sizeof(live_guid)) != 0) {
        fprintf(stderr, "verify-boot-gpt: disk_guid mismatch - blob is stale, recapture it\n");
        return 1;
    }

    return 0;
}

static int cmd_fix_boot_gpt_crc(void)
{
    char disk[64];
    if (resolve_disk("boot_a", disk, sizeof(disk)) != 0)
        return 1;
    return fix_gpt_crc(disk) == 0 ? 0 : 1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s status              Emit fwup --framing WN-frame with the active slot\n"
            "  %s validate            Mark the active slot successful, reset its retry count\n"
            "  %s revert              Switch GPT + boot-LUN to the other slot\n"
            "  %s verify-boot-gpt     Exit 0 if the shipped GPT blob still matches the live disk\n"
            "  %s fix-boot-gpt-crc    Repair entries_crc32/header_crc32 if stale (never touches entry data)\n",
            prog, prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "status") == 0)
        return cmd_status();
    if (argc == 2 && strcmp(argv[1], "validate") == 0)
        return cmd_validate();
    if (argc == 2 && strcmp(argv[1], "revert") == 0)
        return cmd_revert();
    if (argc == 2 && strcmp(argv[1], "verify-boot-gpt") == 0)
        return cmd_verify_boot_gpt();
    if (argc == 2 && strcmp(argv[1], "fix-boot-gpt-crc") == 0)
        return cmd_fix_boot_gpt_crc();

    usage(argv[0]);
    return 2;
}
