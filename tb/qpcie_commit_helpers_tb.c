/* Unit test for qpcie_commit_helpers.h: backup/restore/compare logic used by
 * the COMMIT path. Runs on the build host with temp dirs and small files;
 * a regular file stands in for the eMMC boot0 block device.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "qpcie_commit_helpers.h"

#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); return 1; } \
} while (0)

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror("write_file"); exit(1); }
    if (len && fwrite(data, 1, len, f) != len) { perror("write_file"); exit(1); }
    fclose(f);
}

static void join(char *dst, size_t cap, const char *dir, const char *name) {
    size_t dl = strlen(dir), nl = strlen(name);
    if (dl + 1 + nl + 1 > cap) { fprintf(stderr, "path too long\n"); exit(1); }
    memcpy(dst, dir, dl);
    dst[dl] = '/';
    memcpy(dst + dl + 1, name, nl + 1);
}

int main(void) {
    char tmp[] = "/tmp/opencode/qch_tb_XXXXXX";
    CHECK(mkdtemp(tmp) != NULL, "mkdtemp");
    char mnt[256], bak[256], stg[256];
    snprintf(mnt, sizeof mnt, "%s/mnt", tmp);
    snprintf(bak, sizeof bak, "%s/bak", tmp);
    snprintf(stg, sizeof stg, "%s/stg", tmp);
    CHECK(mkdir(mnt, 0755) == 0 && mkdir(bak, 0755) == 0 && mkdir(stg, 0755) == 0, "mkdir");

    char p_old_boot[256], p_old_ub[256], p_new_boot[256], p_new_ub[256];
    char p_bak_boot[256], p_bak_ub[256], p_boot0[256];
    join(p_old_boot, sizeof p_old_boot, mnt, "BOOT.BIN");
    join(p_old_ub, sizeof p_old_ub, mnt, "image.ub");
    join(p_new_boot, sizeof p_new_boot, stg, "BOOT.BIN");
    join(p_new_ub, sizeof p_new_ub, stg, "image.ub");
    join(p_bak_boot, sizeof p_bak_boot, bak, "BOOT.BIN");
    join(p_bak_ub, sizeof p_bak_ub, bak, "image.ub");
    join(p_boot0, sizeof p_boot0, tmp, "boot0");

    /* 70KB pseudo-random payloads (multi-buffer copies) */
    static unsigned char old_data[71680], new_data[71680];
    for (size_t i = 0; i < sizeof old_data; i++) old_data[i] = (unsigned char)(i * 31 + 7);
    for (size_t i = 0; i < sizeof new_data; i++) new_data[i] = (unsigned char)(i * 131 + 17);
    write_file(p_old_boot, (char *)old_data, sizeof old_data);
    write_file(p_old_ub, (char *)old_data, 1024);
    write_file(p_new_boot, (char *)new_data, sizeof new_data);
    write_file(p_new_ub, (char *)new_data, 2048);
    write_file(p_boot0, (char *)old_data, sizeof old_data);

    /* copy + equal + size */
    CHECK(qch_copy_file(p_old_boot, p_bak_boot) == 0, "backup copy");
    CHECK(qch_copy_file(p_old_ub, p_bak_ub) == 0, "backup copy 2");
    CHECK(qch_files_equal(p_old_boot, p_bak_boot) == 1, "backup equal");
    CHECK(qch_files_equal(p_old_boot, p_new_boot) == 0, "old vs new differ");
    CHECK(qch_file_size(p_new_boot) == sizeof new_data, "size");
    CHECK(qch_file_size("/nonexistent-xyz") == (size_t)-1, "missing size");
    CHECK(qch_copy_file("/nonexistent-xyz", p_bak_boot) == -1, "copy missing src");
    CHECK(qch_files_equal(p_old_boot, "/nonexistent-xyz") == -1, "equal missing");

    /* overwrite then verify-then-restore (commit failure path) */
    CHECK(qch_copy_file(p_new_boot, p_old_boot) == 0, "overwrite");
    CHECK(qch_files_equal(p_old_boot, p_new_boot) == 1, "overwrite applied");
    CHECK(qch_files_equal(p_old_boot, p_bak_boot) == 0, "overwrite differs from backup");
    /* simulate failed verification -> restore */
    CHECK(qch_copy_file(p_bak_boot, p_old_boot) == 0, "restore");
    CHECK(qch_files_equal(p_old_boot, p_bak_boot) == 1, "restore verified");

    /* block device path (regular file as fake boot0) */
    size_t boot_len = sizeof new_data;
    CHECK(qch_block_write(p_new_boot, p_boot0, boot_len) == 0, "boot0 write");
    CHECK(qch_block_prefix_equal(p_boot0, p_new_boot, boot_len) == 1, "boot0 verify");
    /* corrupt one byte, verify must fail, restore must fix */
    FILE *f = fopen(p_boot0, "r+b");
    CHECK(f != NULL, "open boot0");
    CHECK(fseek(f, 12345, SEEK_SET) == 0, "seek");
    CHECK(fputc(0xFF ^ new_data[12345], f) != EOF, "corrupt");
    fclose(f);
    CHECK(qch_block_prefix_equal(p_boot0, p_new_boot, boot_len) == 0, "corrupt detected");
    CHECK(qch_block_write(p_bak_boot, p_boot0, boot_len) == 0, "boot0 restore");
    CHECK(qch_block_prefix_equal(p_boot0, p_bak_boot, boot_len) == 1, "boot0 restored");
    /* file longer than len must not compare equal */
    CHECK(qch_block_prefix_equal(p_boot0, p_new_ub, 100) == 0, "length mismatch");
    CHECK(qch_block_write("/nonexistent-xyz", p_boot0, 100) == -1, "block write missing src");

    /* empty files are equal */
    char p_e1[256], p_e2[256];
    snprintf(p_e1, sizeof p_e1, "%s/e1", tmp);
    snprintf(p_e2, sizeof p_e2, "%s/e2", tmp);
    write_file(p_e1, "", 0);
    write_file(p_e2, "", 0);
    CHECK(qch_files_equal(p_e1, p_e2) == 1, "empty equal");

    printf("TB_PASS: copy/compare/block/backup/restore helpers\n");
    return 0;
}
