/* Host testbench for the COMMIT backup-retention policy.
 *
 *   cc -O2 -Wall -Wextra -Itest_app test_app/qpcie_backup_retention_tb.c -o /tmp/qbr_tb && /tmp/qbr_tb
 *
 * It runs against a real directory tree (mock eMMC mount + mock staging), never
 * against mount()/devmem, so the same bytes-per-manifest behaviour the card relies
 * on is exercised on the build host. The scenario that used to be silently
 * destructive - a retry of the same package, or a second COMMIT - is asserted to
 * keep the earlier generation.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "qpcie_backup_retention.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1);} } while (0)

static int write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t len = strlen(content);
    if (fwrite(content, 1, len, f) != len) { fclose(f); return -1; }
    return fclose(f);
}

static char *path_in(const char *dir, const char *name) {
    static char buf[8][1024];
    static int i = 0;
    char *out = buf[i++ & 7];
    snprintf(out, 1024, "%s/%s", dir, name);
    return out;
}

static int read_equals(const char *path, const char *want) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char got[256] = {0};
    size_t n = fread(got, 1, sizeof got - 1, f);
    fclose(f);
    return n == strlen(want) && !memcmp(got, want, n);
}

/* Count gen-* / txn-* directories in the retention root. */
static unsigned count_prefixed(const char *root, const char *prefix) {
    char names[QBR_MAX_ENTRIES][300];
    return qbr_list(root, prefix, names);
}

/* Is `body` recoverable from some gen-* directory?
 *
 * This - not "how many directories exist" - is the question a rollback actually
 * asks, so the assertions below are written in terms of it. */
static int recoverable_has(const char *root, const char *body) {
    char names[QBR_MAX_ENTRIES][300];
    unsigned n = qbr_list(root, QBR_GEN_PREFIX, names);
    for (unsigned i = 0; i < n; i++) {
        char p[1024];
        snprintf(p, sizeof p, "%s/%s/BOOT.BIN", root, names[i]);
        if (read_equals(p, body)) return 1;
    }
    return 0;
}

static int fail_after(unsigned step, void *ctx) {
    unsigned *at = (unsigned *)ctx;
    return step >= *at ? 1 : 0;
}

static void fill_triple(const char *dir, const char *tag) {
    char b[1024], i2[1024], s[1024];
    snprintf(b, sizeof b, "BOOT-%s", tag);
    snprintf(i2, sizeof i2, "IMAGE-%s", tag);
    snprintf(s, sizeof s, "SCR-%s", tag);
    CHECK(write_file(path_in(dir, "BOOT.BIN"), b) == 0);
    CHECK(write_file(path_in(dir, "image.ub"), i2) == 0);
    CHECK(write_file(path_in(dir, "boot.scr"), s) == 0);
}

/* One COMMIT, exactly the way do_commit() drives it. */
static int one_commit(const char *mnt, const char *staging, int inject_fail_at) {
    char root[1024], txn[1024], why[512] = {0};
    CHECK(qtx_path(root, sizeof root, mnt, QBR_ROOT_NAME) == 0);
    if (qbr_recover_all(mnt, root, why, sizeof why) != 0) return -100 - (int)strlen(why);
    if (qbr_begin(mnt, root, txn, sizeof txn, why, sizeof why) != 0) return -1;
    int rc;
    if (inject_fail_at >= 0) {
        unsigned at = (unsigned)inject_fail_at;
        rc = qtx_apply(mnt, staging, txn, fail_after, &at);
    } else {
        rc = qtx_apply(mnt, staging, txn, NULL, NULL);
    }
    if (rc != 0) {
        /* do_commit leaves the journal in place for the next boot; so do we. */
        qtx_recover(mnt, txn);
        return rc;
    }
    if (qbr_promote(root, txn, why, sizeof why) != 0) return -2;
    /* Exactly what do_commit() does now: retention runs against the generation that
     * was just promoted, so a retry can only evict a byte-identical duplicate of it.
     * Passing NULL here (the old behaviour) meant "keep the newest two" with no idea
     * of content - one same-version retry could push the last distinct image out. */
    char reference[1024];
    qbr_prune(root, qbr_newest_generation(root, reference, sizeof reference) == 0
                  ? reference : NULL);
    return 0;
}

int main(void) {
    char rootdir[] = "/tmp/opencode/qbr_tb_XXXXXX";
    CHECK(mkdtemp(rootdir));
    char mnt[1024], stg[1024], bakroot[1024];
    snprintf(mnt, sizeof mnt, "%s/emmc_p1", rootdir);
    snprintf(stg, sizeof stg, "%s/staging", rootdir);
    CHECK(mkdir(mnt, 0700) == 0);
    CHECK(mkdir(stg, 0700) == 0);
    CHECK(qtx_path(bakroot, sizeof bakroot, mnt, QBR_ROOT_NAME) == 0);

    /* --- 1. legacy layout is adopted, not deleted ------------------------- */
    fill_triple(mnt, "A");
    CHECK(mkdir(bakroot, 0700) == 0);
    CHECK(write_file(path_in(bakroot, "BOOT.BIN"), "BOOT-A") == 0);
    CHECK(write_file(path_in(bakroot, "image.ub"), "IMAGE-A") == 0);
    CHECK(write_file(path_in(bakroot, "boot.scr"), "SCR-A") == 0);
    CHECK(qtx_mark(bakroot, "COMMITTED\n") == 0);
    char why[512] = {0};
    CHECK(qbr_recover_all(mnt, bakroot, why, sizeof why) == 0);
    CHECK(count_prefixed(bakroot, "gen-") == 1);
    CHECK(qbr_is_dir(path_in(bakroot, "gen-0000000000-legacy")));
    CHECK(read_equals(path_in(bakroot, "gen-0000000000-legacy/BOOT.BIN"), "BOOT-A"));

    /* --- 2. first COMMIT backs up the generation it replaces -------------- */
    fill_triple(stg, "B");
    CHECK(one_commit(mnt, stg, -1) == 0);
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-B"));
    CHECK(count_prefixed(bakroot, "txn-") == 0);
    CHECK(count_prefixed(bakroot, "gen-") == 2);
    int found_a = 0;
    for (unsigned i = 0; i < count_prefixed(bakroot, "gen-"); i++) {
        char names[QBR_MAX_ENTRIES][300];
        qbr_list(bakroot, "gen-", names);
        char p[1024];
        snprintf(p, sizeof p, "%s/%s/BOOT.BIN", bakroot, names[i]);
        if (read_equals(p, "BOOT-A")) found_a = 1;
    }
    CHECK(found_a);

    /* --- 3. THE REGRESSION: retrying the same package must not turn the
     *        only prior generation into the current image ------------------ */
    CHECK(one_commit(mnt, stg, -1) == 0);           /* staging == live image */
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-B"));
    int still_have_a = 0, gens = (int)count_prefixed(bakroot, "gen-");
    CHECK(gens >= 1);
    for (int i = 0; i < gens; i++) {
        char names[QBR_MAX_ENTRIES][300];
        qbr_list(bakroot, "gen-", names);
        char p[1024];
        snprintf(p, sizeof p, "%s/%s/BOOT.BIN", bakroot, names[i]);
        if (read_equals(p, "BOOT-A")) still_have_a = 1;
    }
    CHECK(still_have_a);   /* old policy: rm -rf would have left only BOOT-B here */

    /* --- 4. two more real upgrades: a generation differing from the live
     *        image always survives retention ------------------------------- */
    fill_triple(stg, "C");
    CHECK(one_commit(mnt, stg, -1) == 0);
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-C"));
    fill_triple(stg, "D");
    CHECK(one_commit(mnt, stg, -1) == 0);
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-D"));
    gens = (int)count_prefixed(bakroot, "gen-");
    /* Retention is bounded by content, not by a blind count: a generation that is a
     * byte-identical duplicate of the newest one is removed, while a generation
     * holding a distinct BOOT.BIN is kept even past QBR_MAX_GENERATIONS, because
     * deleting it is how a rollback image is lost (that is the whole point of the
     * reference). The set is still bounded: exactly one generation is created per
     * COMMIT and nothing else creates them, so 4 COMMITs + the adopted legacy
     * directory is the most that can exist at this point. */
    CHECK(gens >= 1 && gens <= 5);
    /* the invariant that matters: every image this card ever booted, other than the
     * one it is running now, is still recoverable */
    CHECK(recoverable_has(bakroot, "BOOT-A"));   /* what the card had at factory */
    CHECK(recoverable_has(bakroot, "BOOT-C"));   /* the image D replaced */
    int differs = 0;
    for (int i = 0; i < gens; i++) {
        char names[QBR_MAX_ENTRIES][300];
        qbr_list(bakroot, "gen-", names);
        char p[1024];
        snprintf(p, sizeof p, "%s/%s/BOOT.BIN", bakroot, names[i]);
        if (!read_equals(p, "BOOT-D")) differs = 1;
    }
    CHECK(differs);   /* rollback to a genuinely older image is still possible */

    /* --- 5. an interrupted COMMIT keeps its recovery set and is resolved at
     *        the next startup instead of being deleted --------------------- */
    CHECK(one_commit(mnt, stg, -1) == 0);           /* no-op retry, keeps tree alive */
    char txnpath[1024];
    CHECK(qtx_path(txnpath, sizeof txnpath, bakroot, "txn-9999999999-9") == 0);
    CHECK(mkdir(txnpath, 0700) == 0);
    CHECK(write_file(path_in(txnpath, "BOOT.BIN"), "BOOT-D") == 0);
    CHECK(write_file(path_in(txnpath, "image.ub"), "IMAGE-D") == 0);
    CHECK(write_file(path_in(txnpath, "boot.scr"), "SCR-D") == 0);
    CHECK(qtx_mark(txnpath, "APPLYING\n") == 0);
    /* simulate the half-written state the crash would have left behind */
    CHECK(write_file(path_in(mnt, "BOOT.BIN"), "BOOT-E-partial") == 0);
    CHECK(qbr_recover_all(mnt, bakroot, why, sizeof why) == 0);
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-D"));
    CHECK(qbr_is_dir(path_in(bakroot, "gen-9999999999-9")));

    /* --- 6. a journal that cannot be understood fails closed, and the
     *        directory is left for the operator ---------------------------- */
    char bad[1024];
    CHECK(qtx_path(bad, sizeof bad, bakroot, "txn-8888888888-0") == 0);
    CHECK(mkdir(bad, 0700) == 0);
    CHECK(write_file(path_in(bad, "BOOT.BIN"), "BOOT-X") == 0);
    CHECK(write_file(path_in(bad, "state"), "TOTAL-GARBAGE\n") == 0);
    CHECK(qbr_recover_all(mnt, bakroot, why, sizeof why) == -1);
    CHECK(strstr(why, "must not be reflashed") != NULL);
    CHECK(qbr_is_dir(bad));                          /* never deleted */
    CHECK(read_equals(path_in(bad, "BOOT.BIN"), "BOOT-X"));
    /* and the COMMIT path refuses while that is the state of the world */
    fill_triple(stg, "F");
    CHECK(one_commit(mnt, stg, -1) < 0);             /* refused, nothing flashed */
    CHECK(read_equals(path_in(mnt, "BOOT.BIN"), "BOOT-D"));

    /* --- 7. space policy: refuse before copying; prune only finished work ------ */
    fill_triple(stg, "SPACE");
    CHECK(qbr_payload_bytes(stg) == strlen("BOOT-SPACE") + strlen("IMAGE-SPACE") +
                                   strlen("SCR-SPACE"));
    /* An impossible request is refused with a reason, and refused without creating
     * anything: the retention root is untouched, so a later attempt still can run. */
    unsigned txn_before = count_prefixed(bakroot, "txn-");
    CHECK(qbr_room(mnt, 1ull << 62, why, sizeof why) != 0);
    CHECK(why[0] != '\0');
    CHECK(count_prefixed(bakroot, "txn-") == txn_before);
    CHECK(qbr_room(mnt, 0, why, sizeof why) == 0);       /* a real fs has room */
    CHECK(qbr_prune_for_space(bakroot, mnt) == 0);       /* roomy: nothing to prune */

    /* qbr_prune_oldest keeps the newest generation, removes older finished ones,
     * and refuses outright while any transaction is still unfinished. */
    {
        char sp[1024], txn[1024], newest[1300];
        CHECK(qtx_path(sp, sizeof sp, mnt, ".space_retention") == 0);
        CHECK(mkdir(sp, 0700) == 0);
        for (unsigned g = 0; g < 4; g++) {
            char name[64], st[1300], *d;
            snprintf(name, sizeof name, "gen-000000000%u-old", g);
            d = path_in(sp, name);
            CHECK(mkdir(d, 0700) == 0);
            fill_triple(d, "OLD");
            snprintf(st, sizeof st, "%s/state", d);
            CHECK(write_file(st, "COMMITTED\n") == 0);
        }
        CHECK(count_prefixed(sp, "gen-") == 4);
        CHECK(qbr_prune_oldest(sp, 1) == 3);
        CHECK(count_prefixed(sp, "gen-") == 1);
        snprintf(newest, sizeof newest, "%s/gen-0000000003-old", sp);
        CHECK(qbr_is_dir(newest));                       /* the newest survives */

        /* A directory with bytes but no verdict is not a recovery set: it must be
         * left alone AND it must not consume a retention slot, or a half-written
         * COMMIT would displace the last good generation. */
        CHECK(qbr_begin(mnt, sp, txn, sizeof txn, why, sizeof why) == 0);
        CHECK(mkdir(path_in(sp, "gen-0000000009-stale"), 0700) == 0);
        fill_triple(path_in(sp, "gen-0000000009-stale"), "STALE");   /* no journal */
        CHECK(qbr_prune_oldest(sp, 1) == 0);
        CHECK(qbr_is_dir(newest));                      /* good generation survives */
        CHECK(qbr_is_dir(path_in(sp, "gen-0000000009-stale")));

        /* A transaction holding bytes with no verdict blocks every removal. */
        CHECK(write_file(path_in(txn, "BOOT.BIN"), "BOOT-PARTIAL") == 0);
        CHECK(mkdir(path_in(sp, "gen-0000000010-done"), 0700) == 0);
        fill_triple(path_in(sp, "gen-0000000010-done"), "DONE");
        CHECK(write_file(path_in(sp, "gen-0000000010-done/state"), "COMMITTED\n") == 0);
        CHECK(qbr_prune_oldest(sp, 1) == 0);
        CHECK(qbr_is_dir(path_in(sp, "gen-0000000010-done")));
        CHECK(qbr_is_dir(newest));
        CHECK(read_equals(path_in(txn, "BOOT.BIN"), "BOOT-PARTIAL"));

        /* Resolved journals plus a newer generation: retention now drops exactly
         * the older finished generations and keeps the newest. */
        CHECK(write_file(path_in(txn, "state"), "COMMITTED\n") == 0);
        CHECK(mkdir(path_in(sp, "gen-0000000011-done"), 0700) == 0);
        fill_triple(path_in(sp, "gen-0000000011-done"), "NEW");
        CHECK(write_file(path_in(sp, "gen-0000000011-done/state"), "COMMITTED\n") == 0);
        CHECK(qbr_prune_oldest(sp, 1) == 2);
        CHECK(!qbr_is_dir(newest));
        CHECK(!qbr_is_dir(path_in(sp, "gen-0000000010-done")));
        CHECK(qbr_is_dir(path_in(sp, "gen-0000000011-done")));
        CHECK(qbr_is_dir(path_in(sp, "gen-0000000009-stale")));  /* still untouchable */
    }

    /* --- 8. the space check asks about the bytes it really copies ------------- */
    /* qtx_apply backs up what is ON THE CARD, so a COMMIT that estimates its space
     * need from the incoming package under-estimates whenever the live image is
     * bigger - which is exactly the case that ends with a half-written BOOT.BIN. */
    {
        char big[1024], small[1024];
        CHECK(qtx_path(big, sizeof big, mnt, ".big_live") == 0);
        CHECK(qtx_path(small, sizeof small, mnt, ".small_pkg") == 0);
        CHECK(mkdir(big, 0700) == 0);
        CHECK(mkdir(small, 0700) == 0);
        CHECK(write_file(path_in(big, "BOOT.BIN"), "BOOT-AAAAAAAAAAAAAAAAAAAAAAAAAAAA") == 0);
        CHECK(write_file(path_in(big, "image.ub"), "IMAGE-BBBBBBBBBBBBBBBBBBBBBBBBBB") == 0);
        CHECK(write_file(path_in(big, "boot.scr"), "SCR-CCCCCCCCCCCCCCCCCCCCCCCCCC") == 0);
        CHECK(write_file(path_in(small, "BOOT.BIN"), "BOOT-x") == 0);
        CHECK(write_file(path_in(small, "image.ub"), "IMAGE-x") == 0);
        CHECK(write_file(path_in(small, "boot.scr"), "SCR-x") == 0);
        unsigned long long live = qbr_payload_bytes(big);
        unsigned long long incoming = qbr_payload_bytes(small);
        CHECK(live > incoming);
        CHECK(qbr_commit_need_bytes(small, big) == live);
        CHECK(qbr_commit_need_bytes(big, small) == live);
        /* and the refusal is the one that saves the partition: the request sized
         * from the live image is refused, with the reason the operator needs. */
        unsigned txn_before = count_prefixed(bakroot, "txn-");
        unsigned gen_before = count_prefixed(bakroot, "gen-");
        CHECK(qbr_room(mnt, qbr_commit_need_bytes(small, big) + (1ull << 62),
                       why, sizeof why) != 0);
        CHECK(strstr(why, "Nothing was staged") != NULL);
        /* a refusal that is worth anything creates and destroys nothing */
        CHECK(count_prefixed(bakroot, "txn-") == txn_before);
        CHECK(count_prefixed(bakroot, "gen-") == gen_before);
    }

    /* --- 9. a retry must never evict the generation that actually differs ------ */
    {
        char sp[1024], newest[1300];
        CHECK(qtx_path(sp, sizeof sp, mnt, ".distinct_retention") == 0);
        CHECK(mkdir(sp, 0700) == 0);
        /* four finished generations: the three newest carry the same BOOT.BIN (a
         * same-version retry repeats it), the oldest carries a distinct one. Only
         * the two oldest are past the retention window, and of those exactly one is
         * a duplicate. */
        const char *bodies[4] = { "BOOT-DISTINCT", "BOOT-OLD", "BOOT-OLD", "BOOT-OLD" };
        for (unsigned g = 0; g < 4; g++) {
            char name[64], dir[1300];
            snprintf(name, sizeof name, "gen-00000000%02u-r9", g);
            snprintf(dir, sizeof dir, "%s/%s", sp, name);
            CHECK(mkdir(dir, 0700) == 0);
            CHECK(write_file(path_in(dir, "BOOT.BIN"), bodies[g]) == 0);
            CHECK(write_file(path_in(dir, "image.ub"), "IMAGE-r9") == 0);
            CHECK(write_file(path_in(dir, "boot.scr"), "SCR-r9") == 0);
            char st[1400];
            snprintf(st, sizeof st, "%s/state", dir);
            CHECK(write_file(st, "COMMITTED\n") == 0);
        }
        snprintf(newest, sizeof newest, "%s/gen-0000000003-r9", sp);
        char ref[1300];
        CHECK(qbr_newest_generation(sp, ref, sizeof ref) == 0);
        CHECK(!strcmp(ref, newest));
        int removed = qbr_prune(sp, ref);
        CHECK(removed == 1);          /* only the duplicate is dropped */
        CHECK(qbr_is_dir(path_in(sp, "gen-0000000000-r9")));
        CHECK(read_equals(path_in(sp, "gen-0000000000-r9/BOOT.BIN"), "BOOT-DISTINCT"));
        CHECK(qbr_is_dir(newest));
        /* A directory that is still in flight can never become the reference: its
         * bytes are not a verdict, and promoting them would let a half-written
         * COMMIT define what retention protects. */
        char inflight[1300];
        CHECK(qtx_path(inflight, sizeof inflight, sp, "gen-0000000099-r9") == 0);
        CHECK(mkdir(inflight, 0700) == 0);
        fill_triple(inflight, "PARTIAL");
        CHECK(qbr_newest_generation(sp, ref, sizeof ref) == 0);
        CHECK(strstr(ref, "gen-0000000099-r9") == NULL);
    }

    /* --- 10. a name collision on promote loses nothing ------------------------ */
    {
        char sp[1024], txn[1024], dir[1300];
        CHECK(qtx_path(sp, sizeof sp, mnt, ".collide") == 0);
        CHECK(mkdir(sp, 0700) == 0);
        CHECK(qbr_begin(mnt, sp, txn, sizeof txn, why, sizeof why) == 0);
        fill_triple(txn, "UNIQUE");
        CHECK(qtx_mark(txn, "COMMITTED\n") == 0);
        char *base = strrchr(txn, '/');
        CHECK(base != NULL);
        /* the promoted name is the transaction name with the prefix swapped, which
         * is exactly the name qbr_promote() will try to create */
        snprintf(dir, sizeof dir, "%s/gen-%s", sp, base + 1 + strlen(QBR_TXN_PREFIX));
        CHECK(mkdir(dir, 0700) == 0);
        fill_triple(dir, "HISTORY");
        CHECK(qbr_promote(sp, txn, why, sizeof why) != 0);
        CHECK(strstr(why, "refusing to overwrite") != NULL);
        CHECK(qbr_is_dir(txn));                                  /* both survive */
        CHECK(read_equals(path_in(txn, "BOOT.BIN"), "BOOT-UNIQUE"));
        CHECK(read_equals(path_in(dir, "BOOT.BIN"), "BOOT-HISTORY"));
    }

    /* --- 11. the first COMMIT has nothing to roll back to, and says so -------- */
    {
        char mnt2[1024], stg2[1024], bak2[1024];
        snprintf(mnt2, sizeof mnt2, "%s/fresh_card", rootdir);
        snprintf(stg2, sizeof stg2, "%s/fresh_pkg", rootdir);
        CHECK(mkdir(mnt2, 0700) == 0);
        CHECK(mkdir(stg2, 0700) == 0);
        fill_triple(mnt2, "FACTORY");
        fill_triple(stg2, "RELEASE");
        CHECK(qtx_path(bak2, sizeof bak2, mnt2, QBR_ROOT_NAME) == 0);
        CHECK(qbr_generation_count(bak2) == 0);      /* no recovery set exists yet */
        CHECK(one_commit(mnt2, stg2, -1) == 0);
        CHECK(qbr_generation_count(bak2) == 1);      /* ... and this one created it */
        int factory_kept = 0;
        char names[QBR_MAX_ENTRIES][300];
        for (unsigned i = 0; i < qbr_list(bak2, "gen-", names); i++) {
            char p[1024];
            snprintf(p, sizeof p, "%s/%s/BOOT.BIN", bak2, names[i]);
            if (read_equals(p, "BOOT-FACTORY")) factory_kept = 1;
        }
        CHECK(factory_kept);   /* the pre-upgrade image is what a rollback needs */
    }

    printf("TB_PASS: backup retention (%d generations kept) survives same-version "
           "retries, repeated COMMITs, an interrupted apply, an unreadable journal, a "
           "BOOT partition with no room, a promote name collision and a retention "
           "window full of duplicates\n",
           (int)count_prefixed(bakroot, "gen-"));
    return 0;
}
