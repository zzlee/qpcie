/*
 * v4l2_test_app.c - Comprehensive V4L2 User-Mode Test Application
 * Supports: MMAP, USERPTR, DMABUF, EXPORTBUFFER memory modes & BAR1 Video TPG Pattern Control.
 *
 * Usage:
 *   ./v4l2_test_app --dev /dev/video0 --mode mmap --frames 30 --pattern 9 --out frame.yuv
 *   ./v4l2_test_app --dev /dev/video0 --mode userptr --frames 30
 *   ./v4l2_test_app --dev /dev/video0 --mode dmabuf --frames 30
 *   ./v4l2_test_app --dev /dev/video0 --mode expbuf --frames 30
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <linux/videodev2.h>

#include "qpcie_control.h"

#define DEFAULT_DEVICE  "/dev/video0"
#define DEFAULT_WIDTH   1920
#define DEFAULT_HEIGHT  1080
#define DEFAULT_BUFFERS 4
#define DEFAULT_FRAMES  30

typedef enum {
    MODE_MMAP,
    MODE_USERPTR,
    MODE_DMABUF,
    MODE_EXPBUF
} buffer_mode_t;

struct buffer {
    void   *start;
    size_t  length;
    int     export_fd;
};

static void print_usage(const char *prog_name) {
    printf("QPCIe V4L2 User-Mode Test Application\n");
    printf("Usage: %s [options]\n", prog_name);
    printf("Options:\n");
    printf("  -d, --dev <device>     V4L2 Device node (default: %s)\n", DEFAULT_DEVICE);
    printf("  -m, --mode <mode>      Buffer mode: mmap | userptr | dmabuf | expbuf (default: mmap)\n");
    printf("  -f, --frames <count>   Number of frames to capture (default: %d)\n", DEFAULT_FRAMES);
    printf("  -p, --pattern <id>     Set Video TPG Pattern (0: Pass-thru, 1: H-Ramp, 9: Colorbar, 10: ZonePlate)\n");
    printf("  -r, --fps <rate>       Set Target Frame Rate in FPS (default: 60)\n");
    printf("  -w, --width <pixels>   Frame width (default: %d)\n", DEFAULT_WIDTH);
    printf("  -h, --height <pixels>  Frame height (default: %d)\n", DEFAULT_HEIGHT);
    printf("  -o, --out <file>       Save captured frames to file\n");
    printf("  -help                  Show this help message\n");
}

static double get_timestamp_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (tv.tv_sec * 1000.0) + (tv.tv_usec / 1000.0);
}

int main(int argc, char **argv) {
    const char *dev_name = DEFAULT_DEVICE;
    const char *out_filename = NULL;
    buffer_mode_t mode = MODE_MMAP;
    uint32_t width = DEFAULT_WIDTH;
    uint32_t height = DEFAULT_HEIGHT;
    uint32_t num_frames = DEFAULT_FRAMES;
    int tpg_pattern = -1;
    int target_fps = -1;
    int pacer_mode = -1;
    int slice_height = -1;

    static struct option long_options[] = {
        {"dev",     required_argument, 0, 'd'},
        {"mode",    required_argument, 0, 'm'},
        {"frames",  required_argument, 0, 'f'},
        {"pattern", required_argument, 0, 'p'},
        {"fps",     required_argument, 0, 'r'},
        {"pacer",   required_argument, 0, 'c'},
        {"slice",   required_argument, 0, 's'},
        {"width",   required_argument, 0, 'w'},
        {"height",  required_argument, 0, 'h'},
        {"out",     required_argument, 0, 'o'},
        {"help",    no_argument,       0, '?'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:m:f:p:r:c:s:w:h:o:?", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': dev_name = optarg; break;
            case 'm':
                if (strcmp(optarg, "mmap") == 0) mode = MODE_MMAP;
                else if (strcmp(optarg, "userptr") == 0) mode = MODE_USERPTR;
                else if (strcmp(optarg, "dmabuf") == 0) mode = MODE_DMABUF;
                else if (strcmp(optarg, "expbuf") == 0) mode = MODE_EXPBUF;
                else {
                    fprintf(stderr, "Unknown mode: %s\n", optarg);
                    return EXIT_FAILURE;
                }
                break;
            case 'f': num_frames = atoi(optarg); break;
            case 'p': tpg_pattern = atoi(optarg); break;
            case 'r': target_fps = atoi(optarg); break;
            case 'c': pacer_mode = atoi(optarg); break;
            case 's': slice_height = atoi(optarg); break;
            case 'w': width = atoi(optarg); break;
            case 'h': height = atoi(optarg); break;
            case 'o': out_filename = optarg; break;
            case '?': print_usage(argv[0]); return EXIT_SUCCESS;
            default: break;
        }
    }

    if (pacer_mode >= 0) {
        FILE *sysfs_fp = fopen("/sys/bus/pci/devices/0000:01:00.0/pacer_enable", "w");
        if (sysfs_fp) {
            fprintf(sysfs_fp, "%d", pacer_mode ? 1 : 0);
            fclose(sysfs_fp);
            printf("[CONFIG] Set Video Pacer Mode: %s\n", pacer_mode ? "1 (Internal Pacer)" : "0 (External Live Signal)");
        }
    }

    if (slice_height >= 0) {
        FILE *sysfs_fp = fopen("/sys/bus/pci/devices/0000:01:00.0/slice_height", "w");
        if (sysfs_fp) {
            fprintf(sysfs_fp, "%d", slice_height);
            fclose(sysfs_fp);
            printf("[CONFIG] Set Sub-Frame Low-Latency Slice DMA Height: %d lines\n", slice_height);
        }
    }

    printf("=================================================================\n");
    printf(" QPCIe V4L2 Capture Test Application\n");
    printf(" Device: %s, Format: %ux%u, Frames: %u\n", dev_name, width, height, num_frames);
    printf(" Memory Mode: %s\n", (mode == MODE_MMAP) ? "MMAP" :
                                 (mode == MODE_USERPTR) ? "USERPTR" :
                                 (mode == MODE_DMABUF) ? "DMABUF" : "EXPORTBUFFER");
    printf("=================================================================\n");

    // 1. Open Device
    int fd = open(dev_name, O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) {
        perror("Cannot open video device");
        return EXIT_FAILURE;
    }

    // 2. Query Capabilities
    struct v4l2_capability cap;
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("[V4L2 Cap] Driver: %s, Card: %s, Bus: %s\n", cap.driver, cap.card, cap.bus_info);

    // 3. Set Video Format
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV; // YUV 4:2:2 Packed
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("[V4L2 Format] Set Width: %u, Height: %u, SizeImage: %u\n",
           fmt.fmt.pix.width, fmt.fmt.pix.height, fmt.fmt.pix.sizeimage);

    // 4. Request Buffers
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = DEFAULT_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

    switch (mode) {
        case MODE_MMAP:
        case MODE_EXPBUF:
            req.memory = V4L2_MEMORY_MMAP;
            break;
        case MODE_USERPTR:
            req.memory = V4L2_MEMORY_USERPTR;
            break;
        case MODE_DMABUF:
            req.memory = V4L2_MEMORY_DMABUF;
            break;
    }

    if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("[V4L2 ReqBufs] Allocated %u buffers\n", req.count);

    // 5. Allocate / Map Buffers
    struct buffer *buffers = calloc(req.count, sizeof(*buffers));
    for (uint32_t i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = req.memory;
        buf.index = i;

        if (mode == MODE_MMAP || mode == MODE_EXPBUF) {
            if (ioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
                perror("VIDIOC_QUERYBUF failed");
                close(fd);
                return EXIT_FAILURE;
            }

            buffers[i].length = buf.length;
            buffers[i].start = mmap(NULL, buf.length,
                                    PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, buf.m.offset);

            if (buffers[i].start == MAP_FAILED) {
                perror("mmap failed");
                close(fd);
                return EXIT_FAILURE;
            }

            if (mode == MODE_EXPBUF) {
                struct v4l2_exportbuffer expbuf;
                memset(&expbuf, 0, sizeof(expbuf));
                expbuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
                expbuf.index = i;
                if (ioctl(fd, VIDIOC_EXPBUF, &expbuf) < 0) {
                    perror("VIDIOC_EXPBUF failed");
                } else {
                    buffers[i].export_fd = expbuf.fd;
                    printf("  Buffer %u Exported DMABUF FD: %d\n", i, expbuf.fd);
                }
            }

            if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
                perror("VIDIOC_QBUF failed");
                close(fd);
                return EXIT_FAILURE;
            }
        } else if (mode == MODE_USERPTR) {
            buffers[i].length = fmt.fmt.pix.sizeimage;
            if (posix_memalign(&buffers[i].start, 4096, buffers[i].length) != 0) {
                perror("posix_memalign failed");
                close(fd);
                return EXIT_FAILURE;
            }

            buf.m.userptr = (unsigned long)buffers[i].start;
            buf.length = buffers[i].length;

            if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
                perror("VIDIOC_QBUF (USERPTR) failed");
                close(fd);
                return EXIT_FAILURE;
            }
        }
    }

    // 6. Config Video TPG Pattern if requested via standard V4L2 VIDIOC_S_CTRL ioctl (fallback to sysfs)
    if (tpg_pattern >= 0) {
        printf("--> Setting Video TPG Pattern ID: %d...\n", tpg_pattern);

        struct v4l2_control ctrl;
        memset(&ctrl, 0, sizeof(ctrl));
        ctrl.id = V4L2_CID_TEST_PATTERN;
        // Map 9 -> 3 (Color Bars), 10 -> 4 (Zone Plate) for standard V4L2 menu
        if (tpg_pattern == 9) ctrl.value = 3;
        else if (tpg_pattern == 10) ctrl.value = 4;
        else ctrl.value = tpg_pattern;

        if (ioctl(fd, VIDIOC_S_CTRL, &ctrl) == 0) {
            printf("    Updated Video TPG Pattern via standard V4L2 VIDIOC_S_CTRL ioctl successfully.\n");
        } else {
            FILE *sysfs_fp = fopen("/sys/class/video4linux/video0/tpg_pattern", "w");
            if (!sysfs_fp) sysfs_fp = fopen("/sys/bus/pci/devices/0000:01:00.0/tpg_pattern", "w");

            if (sysfs_fp) {
                fprintf(sysfs_fp, "%d\n", tpg_pattern);
                fclose(sysfs_fp);
                printf("    Updated Video TPG Pattern via sysfs fallback successfully.\n");
            } else {
                printf("    Note: Could not set pattern via ioctl or sysfs (Defaulting to Color Bars).\n");
            }
        }
    }

    // 6.1 Config Hardware Frame Rate Pacer if requested
    if (target_fps > 0) {
        printf("--> Setting Hardware Frame Rate Pacer to %d FPS...\n", target_fps);

        struct v4l2_streamparm parm;
        memset(&parm, 0, sizeof(parm));
        parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        parm.parm.capture.timeperframe.numerator = 1;
        parm.parm.capture.timeperframe.denominator = target_fps;

        if (ioctl(fd, VIDIOC_S_PARM, &parm) == 0) {
            printf("    Updated Hardware Frame Rate Pacer via standard V4L2 VIDIOC_S_PARM ioctl to %d FPS successfully.\n", target_fps);
        } else {
            FILE *sysfs_fp = fopen("/sys/class/video4linux/video0/tpg_fps", "w");
            if (!sysfs_fp) sysfs_fp = fopen("/sys/bus/pci/devices/0000:01:00.0/tpg_fps", "w");

            if (sysfs_fp) {
                fprintf(sysfs_fp, "%d\n", target_fps);
                fclose(sysfs_fp);
                printf("    Updated Hardware Frame Rate Pacer via sysfs fallback to %d FPS successfully.\n", target_fps);
            } else {
                printf("    Note: Could not set frame rate via ioctl or sysfs.\n");
            }
        }
    }

    // Start Streaming
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("--> Stream Started Successfully. Capturing %u frames...\n", num_frames);

    FILE *out_fp = NULL;
    if (out_filename) {
        out_fp = fopen(out_filename, "wb");
        if (!out_fp) perror("Cannot open output file");
    }

    // 7. Capture Loop
    double start_time = get_timestamp_ms();
    uint32_t captured_count = 0;

    while (captured_count < num_frames) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
        int r = select(fd + 1, &fds, NULL, NULL, &timeout);

        if (r < 0) {
            if (errno == EINTR) continue;
            perror("select failed");
            break;
        }

        if (r == 0) {
            fprintf(stderr, "select timeout (no frame received)\n");
            break;
        }

        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = req.memory;

        if (ioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) continue;
            perror("VIDIOC_DQBUF failed");
            break;
        }

        captured_count++;

        // Print Frame Info
        uint8_t *p = (uint8_t *)buffers[buf.index].start;
        uint32_t checksum = 0;
        for (uint32_t i = 0; i < 1024 && i < buf.bytesused; i++) {
            checksum += p[i];
        }

        printf("  [Frame %03u] Index: %u, Bytes: %u, Checksum (first 1K): 0x%08X\n",
               captured_count, buf.index, buf.bytesused, checksum);

        if (out_fp && captured_count == 1) {
            fwrite(buffers[buf.index].start, 1, buf.bytesused, out_fp);
            printf("    Saved Frame 1 to file %s\n", out_filename);
        }

        // Re-queue buffer
        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF re-queue failed");
            break;
        }
    }

    double elapsed_ms = get_timestamp_ms() - start_time;
    double fps = (captured_count * 1000.0) / elapsed_ms;

    printf("=================================================================\n");
    printf(" Capture Finished: %u frames in %.2f ms (%.2f FPS)\n",
           captured_count, elapsed_ms, fps);
    printf("=================================================================\n");

    // 8. Stop Streaming & Cleanup
    ioctl(fd, VIDIOC_STREAMOFF, &type);

    if (out_fp) fclose(out_fp);

    for (uint32_t i = 0; i < req.count; i++) {
        if (mode == MODE_MMAP || mode == MODE_EXPBUF) {
            if (buffers[i].export_fd > 0) close(buffers[i].export_fd);
            munmap(buffers[i].start, buffers[i].length);
        } else if (mode == MODE_USERPTR) {
            free(buffers[i].start);
        }
    }

    free(buffers);
    close(fd);

    return EXIT_SUCCESS;
}
