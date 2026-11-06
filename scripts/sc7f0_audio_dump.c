#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

#define AUDIO_BUFFER_SIZE (128 * 1024)  // 128KB buffer as per ALSA config

int main(int argc, char *argv[]) {
    int fd;
    void *map_base;
    char *device_path = "/dev/video0";
    FILE *out_file;

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <output_file>\n", argv[0]);
        return 1;
    }

    // Open device for read-only mmap
    fd = open(device_path, O_RDONLY);
    if (fd < 0) {
        perror("Failed to open video device");
        return 1;
    }

    // Map the buffer (as captured by v4l2)
    map_base = mmap(NULL, AUDIO_BUFFER_SIZE, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map_base == MAP_FAILED) {
        perror("Failed to mmap capture buffer");
        close(fd);
        return 1;
    }

    // Write raw samples to output file
    out_file = fopen(argv[1], "wb");
    if (!out_file) {
        perror("Failed to open output file");
        munmap(map_base, AUDIO_BUFFER_SIZE);
        close(fd);
        return 1;
    }
    
    fwrite(map_base, AUDIO_BUFFER_SIZE, 1, out_file);
    fclose(out_file);
    munmap(map_base, AUDIO_BUFFER_SIZE);
    close(fd);

    printf("Raw audio data written to %s\n", argv[1]);
    return 0;
}