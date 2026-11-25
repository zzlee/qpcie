// SPDX-License-Identifier: GPL-2.0
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "../qpcie_kms_policy.h"

/* Inputs are procfs records, not a shell invocation. Test production code. */
struct example { const char *record; size_t size; bool strict, expected; };
#define CASE(s, c, e) { s, sizeof(s) - 1, c, e }
static const struct example cases[] = {
	CASE("BOOT_IMAGE=/boot/vmlinuz-7.0.0-43-generic root=UUID=b0935097-d1a8-4afc-93b7-852c5f9c75db ro cma=256M quiet splash vt.handoff=7\n", true, true),
	CASE("quiet\n", false, false), CASE("iomem=strict\n", false, false),
	CASE("  quiet\tiomem=strict ro\n", true, true),
	CASE("quiet iomem=relaxed\n", true, false),
	CASE("iomem=strict iomem=relaxed\n", true, false),
	CASE("iomem=relaxed iomem=strict\n", true, false),
	CASE("iomem=strict iomem=strict\n", true, false),
	CASE("iomem=relaxed,strict\n", true, false), CASE("iomem=other\n", true, false),
	CASE("iomem=\n", true, false), CASE("iomem\n", true, false),
	CASE("iomem=\"strict\"\n", true, false), CASE("iomem=str\\ict\n", true, false),
	CASE("x=\" -- iomem=relaxed\n", true, false), CASE("\"--\" iomem=relaxed\n", true, false),
	CASE("quiet -- iomem=relaxed\n", true, true),
	CASE("iomem=relaxed -- iomem=strict\n", true, false),
	CASE("quiet\nextra\n", true, false), CASE("quiet", true, false),
	CASE("quiet\0 iomem=relaxed\n", true, false), CASE("", true, false),
};
int main(void)
{
	char line[512];
	for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); ++i) {
		const struct example *c = cases + i;
		memcpy(line, c->record, c->size);
		if (qpcie_cmdline_excludes_raw(line, c->size, c->strict) != c->expected) {
			fprintf(stderr, "FAIL policy case %zu\n", i);
			return 1;
		}
	}
	printf("PASS %zu iomem policy cases\n", sizeof(cases)/sizeof(cases[0]));
	return 0;
}
