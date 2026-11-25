/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QPCIE_KMS_POLICY_H
#define QPCIE_KMS_POLICY_H
/* Conservative subset of kernel/resource.c's iomem= syntax. Do not accept
 * ambiguous overrides, even if some kernel versions would process them. */
static inline bool qpcie_iomem_strict(char *cmd, bool strict_devmem)
{
	char *arg;
	bool seen = false;

	if (!strict_devmem)
		return false;
	while ((arg = strsep(&cmd, " \t\v\f\r"))) {
		if (!*arg)
			continue;
		/* Do not infer token boundaries or -- inside quotes/escapes. */
		if (strpbrk(arg, "\"'\\"))
			return false;
		if (!strcmp(arg, "--"))
			break;
		if (!strcmp(arg, "iomem") || !strncmp(arg, "iomem=", 6)) {
			if (seen || strcmp(arg, "iomem=strict"))
				return false;
			seen = true;
		}
	}
	return true;
}

/* /proc/cmdline supplies a complete newline-terminated record. */
static inline bool qpcie_cmdline_excludes_raw(char *line, size_t n,
					     bool strict_devmem)
{
	if (!n || line[n - 1] != '\n' || memchr(line, '\0', n) ||
	    memchr(line, '\n', n - 1))
		return false;
	line[n - 1] = '\0';
	return qpcie_iomem_strict(line, strict_devmem);
}
#endif
