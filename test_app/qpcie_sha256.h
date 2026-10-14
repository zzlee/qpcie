/* SPDX-License-Identifier: MIT */
/*
 * qpcie_sha256.h - Self-contained, portable FIPS 180-2 SHA-256 implementation.
 * Zero external library dependencies; works in user-mode on x86_64 and aarch64.
 */

#ifndef QPCIE_SHA256_H
#define QPCIE_SHA256_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} qpcie_sha256_ctx;

#define QPCIE_SHA256_DIGEST_SIZE 32
#define QPCIE_SHA256_HEX_SIZE    65

static inline uint32_t qpcie_rotr32(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32 - n));
}

#define QPCIE_CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define QPCIE_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define QPCIE_EP0(x)       (qpcie_rotr32(x, 2) ^ qpcie_rotr32(x, 13) ^ qpcie_rotr32(x, 22))
#define QPCIE_EP1(x)       (qpcie_rotr32(x, 6) ^ qpcie_rotr32(x, 11) ^ qpcie_rotr32(x, 25))
#define QPCIE_SIG0(x)      (qpcie_rotr32(x, 7) ^ qpcie_rotr32(x, 18) ^ ((x) >> 3))
#define QPCIE_SIG1(x)      (qpcie_rotr32(x, 17) ^ qpcie_rotr32(x, 19) ^ ((x) >> 10))

static const uint32_t qpcie_k256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static inline void qpcie_sha256_transform(uint32_t state[8], const uint8_t data[64]) {
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)data[i * 4] << 24) |
               ((uint32_t)data[i * 4 + 1] << 16) |
               ((uint32_t)data[i * 4 + 2] << 8) |
               ((uint32_t)data[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++) {
        w[i] = QPCIE_SIG1(w[i - 2]) + w[i - 7] + QPCIE_SIG0(w[i - 15]) + w[i - 16];
    }
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + QPCIE_EP1(e) + QPCIE_CH(e, f, g) + qpcie_k256[i] + w[i];
        uint32_t t2 = QPCIE_EP0(a) + QPCIE_MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static inline void qpcie_sha256_init(qpcie_sha256_ctx *ctx) {
    ctx->state[0] = 0x6a09e667;
    ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372;
    ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f;
    ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab;
    ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static inline void qpcie_sha256_update(qpcie_sha256_ctx *ctx, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    size_t idx = (size_t)(ctx->count & 63);
    ctx->count += len;
    while (len > 0) {
        size_t part = 64 - idx;
        if (len < part) part = len;
        memcpy(ctx->buffer + idx, p, part);
        p += part;
        len -= part;
        idx += part;
        if (idx == 64) {
            qpcie_sha256_transform(ctx->state, ctx->buffer);
            idx = 0;
        }
    }
}

static inline void qpcie_sha256_final(qpcie_sha256_ctx *ctx, uint8_t digest[32]) {
    uint8_t bits[8];
    uint64_t total_bits = ctx->count * 8;
    for (int i = 0; i < 8; i++) {
        bits[7 - i] = (uint8_t)(total_bits >> (i * 8));
    }
    size_t idx = (size_t)(ctx->count & 63);
    uint8_t pad = 0x80;
    qpcie_sha256_update(ctx, &pad, 1);
    while ((ctx->count & 63) != 56) {
        uint8_t zero = 0;
        qpcie_sha256_update(ctx, &zero, 1);
    }
    qpcie_sha256_update(ctx, bits, 8);
    for (int i = 0; i < 8; i++) {
        digest[i * 4]     = (uint8_t)(ctx->state[i] >> 24);
        digest[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        digest[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        digest[i * 4 + 3] = (uint8_t)(ctx->state[i]);
    }
    (void)idx;
}

static inline void qpcie_sha256_to_hex(const uint8_t digest[32], char hex[65]) {
    static const char hex_digits[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        hex[i * 2]     = hex_digits[(digest[i] >> 4) & 0x0f];
        hex[i * 2 + 1] = hex_digits[digest[i] & 0x0f];
    }
    hex[64] = '\0';
}

static inline int qpcie_sha256_buffer(const void *buf, size_t len, char hex_out[65]) {
    qpcie_sha256_ctx ctx;
    uint8_t digest[32];
    qpcie_sha256_init(&ctx);
    qpcie_sha256_update(&ctx, buf, len);
    qpcie_sha256_final(&ctx, digest);
    qpcie_sha256_to_hex(digest, hex_out);
    return 0;
}

static inline int qpcie_sha256_file(const char *path, char hex_out[65]) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return -1;
    qpcie_sha256_ctx ctx;
    uint8_t digest[32];
    uint8_t buf[65536];
    size_t n;
    qpcie_sha256_init(&ctx);
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        qpcie_sha256_update(&ctx, buf, n);
    }
    int err = ferror(fp);
    fclose(fp);
    if (err) return -1;
    qpcie_sha256_final(&ctx, digest);
    qpcie_sha256_to_hex(digest, hex_out);
    return 0;
}

#endif /* QPCIE_SHA256_H */
