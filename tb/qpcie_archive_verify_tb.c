#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>
#include "qpcie_archive_verify.h"

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int rc = qav_extract(argv[1], argv[2]);
    if (rc != 0) return 1;
    if (argc >= 4 && strcmp(argv[3], "--check-manifest") == 0) {
        int m_rc = qav_verify_manifest(argv[2]);
        if (m_rc != 0) return 3;
    }
    return 0;
}

