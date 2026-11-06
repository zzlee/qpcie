#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

// Simple script to analyze raw AES3 subframe data
//
// This reads binary data as 32-bit values and parses them for:
// - Preamble type (0x0B: left block start, 0x09: left channel, 0x0C: right channel)
// - Sample values (Bits 27:4, 24-bit signed)
// - Check channel alignment
// 

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <raw_audio_file>\n", argv[0]);
        return 1;
    }

    FILE *fp = fopen(argv[1], "rb");
    if (!fp) {
        perror("Failed to open input file");
        return 1;
    }

    uint32_t buf[128]; // Buffer for 128 samples
    size_t count = fread(buf, sizeof(uint32_t), 128, fp);
    fclose(fp);

    if (count == 0) {
        fprintf(stderr, "No data read.\n");
        return 1;
    }

    printf("=== AES3 Subframe Analysis (First %zu samples) ===\n", count);
    printf("Index | Raw Value    | Preamble | Sample (24-bit)     | Channel\n");
    printf("------|--------------|----------|---------------------|---------\n");

    for (size_t i = 0; i < count; ++i) {
        uint32_t raw = buf[i];
        uint8_t preamble = raw & 0x0F;
        int32_t sample = (raw >> 4) & 0x00FFFFFF;
        
        if (sample & 0x00800000) sample |= 0xFF000000; // Sign extend
        
        const char *channel = "Unknown";
        switch (preamble) {
            case 0xB: channel = "L BlockStart"; break;
            case 0x9: channel = "L Channel"; break;
            case 0xC: channel = "R Channel"; break;
            default:  channel = "Other"; break;
        }
        
        printf("%5zu | 0x%08X |     0x%X | %8d (0x%06X) | %s\n",
               i, raw, preamble, sample, sample & 0x00FFFFFF, channel);
    }

    return 0;
}