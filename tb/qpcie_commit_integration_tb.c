#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static int mock_mount(const char *special_file, const char *dir,
                      const char *fstype, unsigned long rwflag,
                      const void *data) {
    (void)special_file; (void)dir; (void)fstype; (void)rwflag; (void)data;
    return 0;
}
static int mock_umount(const char *target) {
    (void)target;
    return 0;
}

static char g_test_mount[512];
#define EMMC_MOUNT_DIR g_test_mount
#define mount mock_mount
#define umount mock_umount

#define main qpcie_daemon_main
#include "../test_app/qpcie_upgrade_daemon.c"
#undef main
#undef mount
#undef umount

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

static int write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t len = strlen(content);
    if (fwrite(content, 1, len, f) != len) { fclose(f); return -1; }
    return fclose(f);
}

int main(void) {
    char root[] = "/tmp/opencode/commit_tb_XXXXXX";
    CHECK(mkdtemp(root));

    char mnt_dir[1024], stg_dir[1024];
    CHECK(qtx_path(mnt_dir, sizeof(mnt_dir), root, "emmc_p1") == 0);
    CHECK(qtx_path(stg_dir, sizeof(stg_dir), root, "staging") == 0);
    CHECK(mkdir(mnt_dir, 0700) == 0);
    CHECK(mkdir(stg_dir, 0700) == 0);
    CHECK(qtx_path(g_test_mount, sizeof(g_test_mount), root, "emmc_p1") == 0);
    CHECK(qtx_path(staging_dir, sizeof(staging_dir), root, "staging") == 0);

    // 1. Write existing firmware to mock eMMC
    char p_boot[1024], p_img[1024], p_scr[1024];
    CHECK(qtx_path(p_boot, sizeof(p_boot), mnt_dir, "BOOT.BIN") == 0);
    CHECK(qtx_path(p_img,  sizeof(p_img),  mnt_dir, "image.ub") == 0);
    CHECK(qtx_path(p_scr,  sizeof(p_scr),  mnt_dir, "boot.scr") == 0);
    CHECK(write_file(p_boot, "OLD_BOOT_BIN_DATA_12345") == 0);
    CHECK(write_file(p_img,  "OLD_IMAGE_UB_DATA_67890") == 0);
    CHECK(write_file(p_scr,  "OLD_BOOT_SCR_DATA_ABCDE") == 0);

    // 2. Write new firmware to staging
    char s_boot[1024], s_img[1024], s_scr[1024];
    CHECK(qtx_path(s_boot, sizeof(s_boot), stg_dir, "BOOT.BIN") == 0);
    CHECK(qtx_path(s_img,  sizeof(s_img),  stg_dir, "image.ub") == 0);
    CHECK(qtx_path(s_scr,  sizeof(s_scr),  stg_dir, "boot.scr") == 0);
    CHECK(write_file(s_boot, "NEW_BOOT_BIN_DATA_99999") == 0);
    CHECK(write_file(s_img,  "NEW_IMAGE_UB_DATA_88888") == 0);
    CHECK(write_file(s_scr,  "NEW_BOOT_SCR_DATA_77777") == 0);

    uint32_t regs[PL_MMAP_SIZE / 4] = {0};
    uint32_t size = 4096, crc = 0x12345678;
    bool verified = false;

    // Test A: rejected when not verified
    regs[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_IDLE;
    regs[REG_DMA_UPG_SIZE / 4] = size;
    regs[REG_DMA_UPG_CRC32 / 4] = crc;
    do_commit(regs, &size, &crc, &verified);
    CHECK(regs[REG_DMA_UPG_STATUS / 4] == STATUS_UPG_ERR_STATE);

    // Test B: rejected when size mismatched
    verified = true;
    regs[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_VERIFIED;
    regs[REG_DMA_UPG_SIZE / 4] = size + 1;
    regs[REG_DMA_UPG_CRC32 / 4] = crc;
    do_commit(regs, &size, &crc, &verified);
    CHECK(!verified);
    CHECK(regs[REG_DMA_UPG_STATUS / 4] == STATUS_UPG_ERR_STATE);

    // Test C: successful commit
    verified = true;
    regs[REG_DMA_UPG_STATUS / 4] = STATUS_UPG_VERIFIED;
    regs[REG_DMA_UPG_SIZE / 4] = size;
    regs[REG_DMA_UPG_CRC32 / 4] = crc;
    do_commit(regs, &size, &crc, &verified);
    CHECK(!verified); // consumed
    CHECK(regs[REG_DMA_UPG_STATUS / 4] == STATUS_UPG_SUCCESS);
    CHECK(regs[REG_DMA_UPG_PROGRESS / 4] == 100);

    // Verify eMMC files were updated
    CHECK(qch_files_equal(p_boot, s_boot) == 1);
    CHECK(qch_files_equal(p_img, s_img) == 1);
    CHECK(qch_files_equal(p_scr, s_scr) == 1);

    // Verify backup journal was written and marked COMMITTED
    char bak_dir[1024], state_file[1024];
    CHECK(qtx_path(bak_dir, sizeof(bak_dir), mnt_dir, ".backup_upgrade") == 0);
    CHECK(qtx_path(state_file, sizeof(state_file), bak_dir, "state") == 0);
    FILE *fs = fopen(state_file, "r");
    CHECK(fs != NULL);
    char sbuf[32] = {0};
    CHECK(fgets(sbuf, sizeof(sbuf), fs) != NULL);
    fclose(fs);
    CHECK(strcmp(sbuf, "COMMITTED\n") == 0);

    // Verify backup contains the original files
    char bak_boot[1024];
    CHECK(qtx_path(bak_boot, sizeof(bak_boot), bak_dir, "BOOT.BIN") == 0);
    FILE *fb = fopen(bak_boot, "rb");
    CHECK(fb != NULL);
    char bdata[64] = {0};
    CHECK(fread(bdata, 1, sizeof(bdata)-1, fb) > 0);
    fclose(fb);
    CHECK(strcmp(bdata, "OLD_BOOT_BIN_DATA_12345") == 0);

    puts("TB_PASS: full transactional COMMIT with persistent journal and backup verified");
    return 0;
}
