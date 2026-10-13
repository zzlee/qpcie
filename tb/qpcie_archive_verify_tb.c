#define _GNU_SOURCE
#include <stdint.h>
#include "qpcie_archive_verify.h"
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    return qav_gzip(argv[1], argv[2]) ? 1 : 0;
}
