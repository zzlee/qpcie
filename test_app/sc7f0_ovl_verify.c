// SPDX-License-Identifier: GPL-2.0
/*
 * sc7f0_ovl_verify.c - card-side whole-plane byte verifier for
 * SC7F0-RGB-COMPOSITOR-2PPC (0x26111502), run ON THE CARD PS.
 *
 * Why this exists: a Host `tx PASS` and a matching issued/staged/drained byte
 * counter are NOT evidence that the destination is correct.  Round 26111501
 * transferred 33,177,600 bytes with every counter satisfied while 93.72% of the
 * destination bytes were not the Host bytes, because the ingress gearbox dropped
 * the DWords of each 256-byte burst that did not start on lane 0 while still
 * advancing the byte counters.  This tool compares the destination itself.
 *
 * It re-derives the exact source plane that test_app/host_rgb_compositor.c
 * fills into the coherent ring - same formula, same corner marker - and walks
 * EVERY 32-bit word of the destination plane in the PS overlay pool:
 *
 *   a = (x + frame) & 0xff;  r = (x >> 3) & 0xff;
 *   g = (y >> 2) & 0xff;     b = ((x ^ y) >> 1) & 0xff;
 *   word  = (a << 24) | (b << 16) | (g << 8) | r;
 *   corner: y == 0 && x < 8 -> (0xff << 24) | (frame & 0xff)
 *
 * The expected stream is never taken from the card and never adjusted to match
 * what was found.  Output is deliberately machine-checkable:
 *
 *   OVLV geom      WxH words=N stride=S base=0x... frame=F
 *   OVLV expect    sha256=<digest of the re-derived plane>
 *   OVLV observed  sha256=<digest of the destination as read>
 *   OVLV words     total=8294400 mismatch=0 first_bad=-1
 *   OVLV verdict   PASS_BYTES | FAIL_BYTES
 *
 * It reads the pool through mmap on /dev/mem, which is the only access that
 * works for the no-map reserved overlay pool (read()/dd on /dev/mem returns
 * nothing useful there).  It writes nothing to the card.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* ------------------------------------------------------------------ sha256 */

typedef struct {
	uint32_t h[8];
	uint64_t len;
	uint8_t  buf[64];
	size_t   fill;
} sha256;

/* SHA-256 round constants, K[t] = floor(frac(cbrt(prime(t))) * 2^32), taken
 * from the FIPS 180-2 definition rather than from memory.  The --self-test
 * vectors below are what prove this table, because a C initializer that is
 * short, stale or mis-transcribed is legal and silently gives a stable digest
 * that is simply not SHA-256. */
static const uint32_t K256[64] = {
	0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,
	0x923f82a4u,0xab1c5ed5u,0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,
	0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,0xe49b69c1u,0xefbe4786u,
	0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
	0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,
	0x06ca6351u,0x14292967u,0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,
	0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,0xa2bfe8a1u,0xa81a664bu,
	0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
	0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,
	0x5b9cca4fu,0x682e6ff3u,0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,
	0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

/* The table above is the whole SHA-256 round-constant set: 64 entries.  A short
 * C initializer is legal and silently zero-fills, which would give a stable but
 * wrong digest, so the length is asserted where the compiler can see it. */
typedef char sha256_k_len_check[(sizeof(K256) / sizeof(K256[0]) == 64) ? 1 : -1];

static uint32_t ror32(uint32_t v, unsigned n)
{
	return (v >> n) | (v << (32 - n));
}

static void sha256_init(sha256 *s)
{
	static const uint32_t iv0[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,
		0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};
	memcpy(s->h, iv0, sizeof iv0);
	s->len = 0; s->fill = 0;
}

static void sha256_block(sha256 *s, const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) |
		       ((uint32_t)p[i*4+2] << 8) | (uint32_t)p[i*4+3];
	for (; i < 64; i++) {
		uint32_t s0 = ror32(w[i-15],7) ^ ror32(w[i-15],18) ^ (w[i-15] >> 3);
		uint32_t s1 = ror32(w[i-2],17) ^ ror32(w[i-2],19) ^ (w[i-2] >> 10);
		w[i] = w[i-16] + s0 + w[i-7] + s1;
	}
	a=s->h[0]; b=s->h[1]; c=s->h[2]; d=s->h[3];
	e=s->h[4]; f=s->h[5]; g=s->h[6]; h=s->h[7];
	for (i = 0; i < 64; i++) {
		uint32_t S1 = ror32(e,6) ^ ror32(e,11) ^ ror32(e,25);
		uint32_t ch = (e & f) ^ ((~e) & g);
		t1 = h + S1 + ch + K256[i] + w[i];
		uint32_t S0 = ror32(a,2) ^ ror32(a,13) ^ ror32(a,22);
		uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
		t2 = S0 + mj;
		h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
	}
	s->h[0]+=a; s->h[1]+=b; s->h[2]+=c; s->h[3]+=d;
	s->h[4]+=e; s->h[5]+=f; s->h[6]+=g; s->h[7]+=h;
}

static void sha256_update(sha256 *s, const void *data, size_t n)
{
	const uint8_t *p = data;

	s->len += n;
	while (n) {
		size_t take = 64 - s->fill;

		if (take > n) take = n;
		memcpy(s->buf + s->fill, p, take);
		s->fill += take; p += take; n -= take;
		if (s->fill == 64) { sha256_block(s, s->buf); s->fill = 0; }
	}
}

static void sha256_final(sha256 *s, uint8_t out[32])
{
	uint64_t bits = s->len * 8ULL;
	uint8_t pad = 0x80, z = 0, lenb[8];
	int i;

	sha256_update(s, &pad, 1);
	while (s->fill != 56) sha256_update(s, &z, 1);
	for (i = 0; i < 8; i++) lenb[i] = (uint8_t)(bits >> (56 - 8*i));
	sha256_update(s, lenb, 8);
	for (i = 0; i < 8; i++) {
		out[i*4]   = (uint8_t)(s->h[i] >> 24);
		out[i*4+1] = (uint8_t)(s->h[i] >> 16);
		out[i*4+2] = (uint8_t)(s->h[i] >> 8);
		out[i*4+3] = (uint8_t)(s->h[i]);
	}
}

static void hex32(const uint8_t d[32], char out[65])
{
	static const char hx[] = "0123456789abcdef";
	int i;

	for (i = 0; i < 32; i++) {
		out[i*2]   = hx[d[i] >> 4];
		out[i*2+1] = hx[d[i] & 0xf];
	}
	out[64] = 0;
}

/* ------------------------------------------------------------- the pattern */

static inline uint32_t expect_word(uint32_t x, uint32_t y, unsigned frame)
{
	uint32_t a, r, g, b;

	if (y == 0 && x < 8)
		return (0xffu << 24) | (frame & 0xffu);
	a = (x + frame) & 0xffu;
	r = (x >> 3) & 0xffu;
	g = (y >> 2) & 0xffu;
	b = ((x ^ y) >> 1) & 0xffu;
	return (a << 24) | (b << 16) | (g << 8) | r;
}

/* ------------------------------------------------------------------- main */

static void usage(const char *argv0)
{
	fprintf(stderr,
"usage: %s --base <phys> [--width N] [--height N] [--stride N] [--frame F]\n"
"          [--words N] [--limit N] [--mem DEV] [--expect-sha HEX] [--quiet]\n"
"\n"
"  --base   physical address of the plane in the PS overlay pool\n"
"  --stride bytes per row (native RGBA 4K is 3840*4 = 15360)\n"
"  --words  stop after N words (default: whole plane = w*h)\n"
"  --file   --mem is a regular file: --base is a byte offset inside it\n"
"  --limit  stop reporting individual mismatches after N (default 8)\n"
"  --expect-sha  fail if the re-derived expected digest is not this value,\n"
"                so the same expected plane can be pinned across host and PS\n",
		argv0);
}

int main(int argc, char **argv)
{
	uint64_t base = 0; int base_set = 0;
	unsigned width = 3840, height = 2160, frame = 0, quiet = 0;
	uint64_t stride = 0, words = 0, limit = 8, i, bad = 0, shown = 0;
	uint64_t first_bad = (uint64_t)-1, total;
	const char *mem = "/dev/mem";
	int filebacked = 0;
	char expsHA[65] = "", gotsha[65], wantsha[65];
	uint8_t ed[32], od[32];
	sha256 es, os;
	int fd, rc = 0;
	volatile uint32_t *p;
	size_t span, off;
	uint8_t *m;

	for (i = 1; i < (unsigned)argc; i++) {
		const char *a = argv[i];

		if (!strcmp(a, "--self-test")) {
			/* FIPS 180-2 published vectors: they prove this digest
			 * engine is SHA-256 and not something merely stable. */
			static const char *v[3] = { "",
				"abc",
				"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" };
			static const char *e[3] = {
				"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
				"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
				"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" };
			char hx[65];
			uint8_t dg[32];
			int k, ok = 1;

			for (k = 0; k < 3; k++) {
				sha256 s;

				sha256_init(&s);
				sha256_update(&s, v[k], strlen(v[k]));
				sha256_final(&s, dg);
				hex32(dg, hx);
				printf("OVLV selftest  vec=%d got=%s want=%s\n", k, hx, e[k]);
				if (strcmp(hx, e[k])) ok = 0;
			}
			printf("OVLV selftest  %s\n", ok ? "PASS" : "FAIL");
			return ok ? 0 : 1;
		}
		if (!strcmp(a, "--base") && i + 1 < (unsigned)argc) {
			base = strtoull(argv[++i], NULL, 0);
			base_set = 1;
		}
		else if (!strcmp(a, "--width") && i + 1 < (unsigned)argc)
			width = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--height") && i + 1 < (unsigned)argc)
			height = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--stride") && i + 1 < (unsigned)argc)
			stride = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(a, "--frame") && i + 1 < (unsigned)argc)
			frame = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--words") && i + 1 < (unsigned)argc)
			words = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(a, "--limit") && i + 1 < (unsigned)argc)
			limit = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(a, "--expect-sha") && i + 1 < (unsigned)argc) {
			snprintf(expsHA, sizeof expsHA, "%s", argv[++i]);
		} else if (!strcmp(a, "--file")) filebacked = 1;
		else if (!strcmp(a, "--mem") && i + 1 < (unsigned)argc)
			mem = argv[++i];
		else if (!strcmp(a, "--quiet")) quiet = 1;
		else { usage(argv[0]); return 2; }
	}
	if (!base_set || !width || !height) { usage(argv[0]); return 2; }
	if (!stride) stride = (uint64_t)width * 4ULL;
	total = (uint64_t)width * (uint64_t)height;
	if (!words || words > total) words = total;

	span = (size_t)(((stride * height) + 4095) & ~4095ULL);
	off  = filebacked ? 0ULL : (base & 4095ULL);

	fd = open(mem, O_RDONLY | O_SYNC);
	if (fd < 0) { fprintf(stderr, "open %s: %s\n", mem, strerror(errno)); return 1; }
	/* /dev/mem wants a page-aligned offset and the physical address itself; a
	 * plain file (used to prove this verifier against a synthetic plane) is
	 * mapped from 0 with --base as the byte offset into it. */
	if (filebacked) {
		struct stat st;

		if (fstat(fd, &st) || (uint64_t)st.st_size < base + stride * height) {
			fprintf(stderr, "file %s too small for base+plane\n", mem);
			close(fd);
			return 1;
		}
		m = mmap(NULL, (size_t)(base + stride * height), PROT_READ, MAP_SHARED,
			 fd, 0);
		off = (size_t)base;
	} else {
		m = mmap(NULL, span + off, PROT_READ, MAP_SHARED, fd,
			 (off_t)(base - off));
	}
	if (m == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%llx+%zu: %s\n",
			(unsigned long long)base, span + off, strerror(errno));
		close(fd);
		return 1;
	}
	p = (volatile uint32_t *)(m + off);

	sha256_init(&es); sha256_init(&os);

	for (i = 0; i < words; i++) {
		uint32_t x = (uint32_t)(i % width);
		uint32_t y = (uint32_t)(i / width);
		uint32_t e = expect_word(x, y, frame);
		uint32_t g = p[(stride * y + (uint64_t)x * 4) / 4];
		uint8_t eb[4] = { (uint8_t)e, (uint8_t)(e >> 8),
				  (uint8_t)(e >> 16), (uint8_t)(e >> 24) };
		uint8_t gb[4] = { (uint8_t)g, (uint8_t)(g >> 8),
				  (uint8_t)(g >> 16), (uint8_t)(g >> 24) };

		sha256_update(&es, eb, 4);
		sha256_update(&os, gb, 4);
		if (g != e) {
			bad++;
			if (first_bad == (uint64_t)-1) first_bad = i;
			if (shown < limit) {
				printf("OVLV bad     word=%llu byte=%llu x=%u y=%u got=%08x exp=%08x\n",
				       (unsigned long long)i,
				       (unsigned long long)(i * 4), x, y, g, e);
				shown++;
			}
		}
	}

	sha256_final(&es, ed); sha256_final(&os, od);
	hex32(ed, wantsha); hex32(od, gotsha);

	printf("OVLV geom      W=%u H=%u stride=%llu words=%llu base=0x%llx frame=%u\n",
	       width, height, (unsigned long long)stride,
	       (unsigned long long)words, (unsigned long long)base, frame);
	printf("OVLV expect    sha256=%s\n", wantsha);
	printf("OVLV observed  sha256=%s\n", gotsha);
	printf("OVLV words     total=%llu mismatch=%llu first_bad=%lld\n",
	       (unsigned long long)words, (unsigned long long)bad,
	       first_bad == (uint64_t)-1 ? -1LL : (long long)first_bad);

	if (*expsHA && strcmp(expsHA, wantsha)) {
		printf("OVLV pin       FAIL expected-digest-pin=%s derived=%s\n",
		       expsHA, wantsha);
		rc = 1;
	}
	if (!bad && rc == 0) {
		printf("OVLV verdict   PASS_BYTES\n");
	} else {
		printf("OVLV verdict   FAIL_BYTES\n");
		rc = 1;
	}
	(void)quiet;
	munmap(m, span + off);
	close(fd);
	return rc;
}
