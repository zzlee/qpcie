#define _GNU_SOURCE
#include <sys/wait.h>
#include "qpcie_file_transaction.h"
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d\n", __LINE__); return 1; } } while (0)
static int kill_step(unsigned step, void *context) {
    if (step == *(unsigned *)context) _exit(77);
    return 0;
}
static int write_fixture(const char *dir, unsigned seed) {
    for (unsigned i = 0; i < 3; ++i) {
        char path[512];
        if (qtx_path(path, sizeof path, dir, qtx_names[i])) return -1;
        FILE *f = fopen(path, "wb");
        if (!f) return -1;
        for (unsigned j = 0; j < 1024 + 37 * i; ++j)
            if (fputc((j + seed + i) & 255, f) == EOF) { fclose(f); return -1; }
        if (fclose(f)) return -1;
    }
    return 0;
}
int main(void) {
    for (unsigned step = 0; step <= 4; ++step) {
        char root[] = "/tmp/opencode/qtx_XXXXXX";
        CHECK(mkdtemp(root));
        char mount_dir[512], staging[512], old[512], backup[512];
        CHECK(!qtx_path(mount_dir, sizeof mount_dir, root, "mount"));
        CHECK(!qtx_path(staging, sizeof staging, root, "staging"));
        CHECK(!qtx_path(old, sizeof old, root, "original"));
        CHECK(!qtx_path(backup, sizeof backup, mount_dir, "rollback"));
        CHECK(!mkdir(mount_dir, 0700) && !mkdir(staging, 0700) && !mkdir(old, 0700));
        CHECK(!write_fixture(mount_dir, 17) && !write_fixture(old, 17) && !write_fixture(staging, 91));
        pid_t pid = fork();
        CHECK(pid >= 0);
        if (!pid) {
            int rc = qtx_apply(mount_dir, staging, backup, kill_step, &step);
            _exit(rc ? 1 : 0);
        }
        int status;
        CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status));
        CHECK(WEXITSTATUS(status) == (step < 4 ? 77 : 0));
        CHECK(!qtx_recover(mount_dir, backup));
        CHECK(!qtx_recover(mount_dir, backup)); // idempotent
        for (unsigned i = 0; i < 3; ++i) {
            char a[512], b[512];
            CHECK(!qtx_path(a, sizeof a, mount_dir, qtx_names[i]));
            CHECK(!qtx_path(b, sizeof b, step < 4 ? old : staging, qtx_names[i]));
            CHECK(qch_files_equal(a, b) == 1);
        }
        CHECK(qtx_apply(mount_dir, staging, backup, NULL, NULL) == -1); // no overwrite backup
        if (!step) {
            char path[512];
            CHECK(!qtx_path(path, sizeof path, backup, qtx_names[1]));
            CHECK(!unlink(path));
            CHECK(!qtx_mark(backup, "APPLYING\n"));
            CHECK(qtx_recover(mount_dir, backup) == -1); // incomplete backup fails closed
            CHECK(!qtx_mark(backup, "APPL"));
            CHECK(qtx_recover(mount_dir, backup) == -1); // torn journal fails closed
        }
    }
    puts("TB_PASS: durable file backups, process-death checkpoints, recovery, corrupt journal refusal");
    return 0;
}
