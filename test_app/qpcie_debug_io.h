/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QPCIE_DEBUG_IO_H
#define QPCIE_DEBUG_IO_H
#include "qpcie_debug.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <endian.h>
#include <sys/mman.h>
#include <sys/file.h>
#include <sys/random.h>
#include <time.h>

struct db_io { int fd, lockfd, failed; volatile uint32_t *map; };
static inline uint64_t db_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static inline void db_pause(void)
{
    struct timespec t = {0, 2000000};
    nanosleep(&t, NULL);
}
static inline void db_barrier(void)
{
#if defined(__aarch64__)
    __asm__ volatile("dmb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}
static inline uint32_t db_random(void)
{
    uint32_t x;
    do {
        if (getrandom(&x, sizeof(x), 0) != sizeof(x)) {
            perror("getrandom"); exit(125);
        }
    } while (!x || x == UINT32_MAX);
    return x;
}
/* Host uses the bounded misc node. --sim maps a regular file explicitly.
 * Card maps Device memory using /dev/mem O_SYNC (same convention as existing
 * upgrade daemon); no cached DDR buffer and no byte/64-bit MMIO accesses. */
static inline int db_open(struct db_io *io, const char *path, bool card, bool sim)
{
    char lockpath[512];
    memset(io, 0, sizeof(*io)); io->fd = io->lockfd = -1;
    if (card || sim) {
        if (sim) {
            if (snprintf(lockpath, sizeof(lockpath), "%s.%s.lock", path,
                         card ? "card" : "host") >= (int)sizeof(lockpath)) return -1;
        } else strcpy(lockpath, "/run/qpcie-debugd.lock");
        io->lockfd = open(lockpath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (io->lockfd < 0 || flock(io->lockfd, LOCK_EX | LOCK_NB)) {
            perror("exclusive mailbox lock"); return -1;
        }
    }
    io->fd = open(path, O_RDWR | O_CLOEXEC | (card && !sim ? O_SYNC : 0));
    if (io->fd < 0) { perror(path); return -1; }
    if (card && !sim) {
        /* Never probe the new aperture on an old bitstream. Read only the
         * established CSR page first (older RTL aliases bit 13 to CSR). */
        void *csr = mmap(NULL, 4096, PROT_READ, MAP_SHARED, io->fd,
                         QDBG_PS_ADDRESS - QDBG_BAR_OFFSET);
        if (csr == MAP_FAILED) { perror("CSR mmap"); return -1; }
        volatile uint32_t *regs = csr;
        uint32_t magic = le32toh(regs[0]), version = le32toh(regs[1]);
        db_barrier();
        munmap(csr, 4096);
        if (magic != 0x12abe380U || version < QDBG_HW_VERSION_INITIAL) {
            fprintf(stderr,"Unsupported PL version %08x; debug aperture not accessed\n",version);
            return -1;
        }
    }
    if (card || sim) {
        void *p = mmap(NULL, QDBG_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                       io->fd, sim ? 0 : QDBG_PS_ADDRESS);
        if (p == MAP_FAILED) { perror("mmap"); return -1; }
        io->map = p;
    }
    return 0;
}
static inline void db_close(struct db_io *io)
{
    if (io->map) munmap((void *)io->map, QDBG_SIZE);
    if (io->fd >= 0) close(io->fd);
    if (io->lockfd >= 0) close(io->lockfd);
}
static inline uint32_t db_rd(struct db_io *io, unsigned off)
{
    uint32_t x = UINT32_MAX;
    if (io->map) { x = io->map[off/4]; db_barrier(); }
    else if (pread(io->fd, &x, 4, off) != 4) io->failed = 1;
    return le32toh(x);
}
static inline void db_wr(struct db_io *io, unsigned off, uint32_t x)
{
    x = htole32(x);
    db_barrier();
    if (io->map) { io->map[off/4] = x; db_barrier(); }
    else if (pwrite(io->fd, &x, 4, off) != 4) io->failed = 1;
}
static inline int db_valid(struct db_io *io)
{
    return db_rd(io, DB_MAGIC) == QDBG_MAGIC && db_rd(io, DB_ABI) == QDBG_ABI && !io->failed;
}
static inline void db_payload(struct db_io *io, unsigned off, void *data,
                               unsigned len, bool write_data)
{
    uint32_t words[DB_PAYLOAD/4];
    unsigned n = (len + 3) & ~3U;
    if (len > DB_PAYLOAD) { io->failed = 1; return; }
    if (write_data) { memset(words, 0, n); if (len) memcpy(words, data, len); }
    if (io->map) {
        for (unsigned i=0; i<n/4; ++i) {
            if (write_data) io->map[(off/4)+i] = words[i];
            else words[i] = io->map[(off/4)+i];
        }
        db_barrier();
    } else if (n && (write_data ? pwrite(io->fd, words, n, off) :
                                      pread(io->fd, words, n, off)) != n) io->failed = 1;
    if (!write_data && len) memcpy(data, words, len);
}
static inline void db_send(struct db_io *io, bool card, uint32_t type,
                            uint32_t id, void *data, unsigned len, uint32_t code)
{
    db_payload(io, card ? DB_C2H_DATA : DB_H2C_DATA, data, len, true);
    db_wr(io, card ? DB_C2H_TYPE : DB_H2C_TYPE, type);
    db_wr(io, card ? DB_C2H_ID : DB_H2C_ID, id);
    db_wr(io, card ? DB_C2H_LEN : DB_H2C_LEN, len);
    if (card) db_wr(io, DB_C2H_CODE, code);
    /* Publish last. Hardware host writes are flushed by the driver. */
    unsigned seq = card ? DB_C2H_SEQ : DB_H2C_SEQ;
    if (!io->failed) db_wr(io, seq, db_rd(io, seq) + 1);
}
#endif
