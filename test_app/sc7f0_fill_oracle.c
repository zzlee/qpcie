/*
 * sc7f0_fill_oracle - independent hash source for the overlay H2C content check.
 *
 * "tx PASS" and issued == staged == drained only prove the writer counted the
 * bytes it was asked to move.  They do not prove the bytes that landed in the
 * PS overlay pool are the bytes the Host placed in the ring, which is the
 * question this exists to answer.
 *
 * It re-derives, from fill_rgba() in test_app/host_rgb_compositor.c, exactly
 * what a given geometry and frame index must look like on the wire, and hashes
 * the whole frame plus every fixed-size block of it.  The card hashes the same
 * region out of /dev/mem with dd | sha256sum.  Comparing the two sets answers
 * the question without sampling a few words and without dragging 4 MiB back
 * over a 2 KB mailbox, and it distinguishes
 *   byte-exact,
 *   byte-exact but block- or word-permuted (AXI-Stream tkeep / tail-byte /
 *   packing class of bug), from
 *   genuinely damaged data.
 *
 * It is an oracle, not a transcript: nothing here is tuned to what the
 * hardware currently returns, so a disagreement stays a disagreement.
 *
 * Build: make -C test_app sc7f0_fill_oracle
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fill_word(uint32_t *p, unsigned long x, unsigned long y,
		      unsigned long w, unsigned frame)
{
	uint32_t a = (uint32_t)((x + frame) & 0xffu);
	uint32_t r = (uint32_t)((x >> 3) & 0xffu);
	uint32_t g = (uint32_t)((y >> 2) & 0xffu);
	uint32_t b = (uint32_t)(((x ^ y) >> 1) & 0xffu);

	*p = (a << 24) | (b << 16) | (g << 8) | r;
	/* fill_rgba() overwrites the first 8 pixels of row 0 with the frame
	 * number so "which frame is on the monitor" is readable without a
	 * capture; the oracle has to reproduce that or it would report a
	 * mismatch that the Host itself created. */
	if (y == 0 && x < 8 && x < w)
		*p = (0xffu << 24) | (frame & 0xffu);
}

/* sha256sum does the hashing, so this carries no crypto dependency while still
 * hashing every byte. Returns 0 and fills hex (>=65 bytes) on success. */
static int sha256_of(const uint8_t *buf, size_t len, char *hex)
{
	static const char path[] = "/tmp/sc7f0_fill_oracle.bin";
	char cmd[160], line[96] = "";
	FILE *f;
	int rc = -1;

	unlink(path);
	f = fopen(path, "wb");
	if (!f)
		return -1;
	if (fwrite(buf, 1, len, f) != len) {
		fclose(f);
		unlink(path);
		return -1;
	}
	if (fclose(f) != 0) {
		unlink(path);
		return -1;
	}
	snprintf(cmd, sizeof cmd, "sha256sum %s | cut -d' ' -f1", path);
	f = popen(cmd, "r");
	if (!f) {
		unlink(path);
		return -1;
	}
	if (fgets(line, sizeof line, f) && strlen(line) == 65) {
		line[64] = 0;
		memcpy(hex, line, 65);
		rc = 0;
	}
	if (pclose(f) != 0)
		rc = -1;
	unlink(path);
	return rc;
}

int main(int argc, char **argv)
{
	unsigned long w = 1024, h = 1024, blk = 65536, frame = 0;
	unsigned long total, nbytes, i;
	uint32_t *buf;
	char hex[80];

	for (i = 1; i + 1 < (unsigned)argc; i += 2) {
		if (!strcmp(argv[i], "--width"))
			w = strtoul(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--height"))
			h = strtoul(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--frame"))
			frame = strtoul(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--block"))
			blk = strtoul(argv[i + 1], NULL, 0);
	}
	if (!w || !h || !blk || (unsigned long long)w * h > (1ULL << 26) ||
	    (blk & 3UL) || w * h * 4UL % blk) {
		fprintf(stderr,
			"--width/--height/--block must be non-zero, --block a multiple of 4 evenly dividing width*height*4\n");
		return 2;
	}
	total = w * h;
	nbytes = total * 4;
	buf = malloc(nbytes);
	if (!buf) {
		perror("malloc");
		return 1;
	}
	for (unsigned long y = 0; y < h; y++)
		for (unsigned long x = 0; x < w; x++)
			fill_word(&buf[y * w + x], x, y, w, (unsigned)frame);

	printf("# expected_fill w=%lu h=%lu frame=%lu bytes=%lu\n", w, h, frame,
	       nbytes);
	if (sha256_of((const uint8_t *)buf, nbytes, hex)) {
		fprintf(stderr, "hash failed\n");
		return 1;
	}
	printf("total sha256=%s bytes=%lu\n", hex, nbytes);
	for (i = 0; i * blk < nbytes; i++) {
		if (sha256_of((const uint8_t *)buf + i * blk, blk, hex)) {
			fprintf(stderr, "hash failed at block %lu\n", i);
			return 1;
		}
		printf("block %lu off=0x%lx sha256=%s\n", i, i * blk, hex);
	}
	free(buf);
	return 0;
}
