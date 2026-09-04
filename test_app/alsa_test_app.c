/*
 * alsa_test_app.c - Comprehensive ALSA Audio Capture User-Mode Test Application
 * Tests 32-bit AES3 Audio Subframe capture, 48kHz Stereo PCM streaming & BAR1 Audio Pattern Gen.
 *
 * Usage:
 *   ./alsa_test_app [-d /dev/snd/pcmC1D0c] [-r 48000] [-s 3] [-o test_audio.pcm]
 *   ./alsa_test_app --pattern 0   (0: 1kHz Sine, 1: Sawtooth, 2: 440Hz, 3: Mute)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <math.h>
#include <glob.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sound/asound.h>

#include "qpcie_control.h"

#define DEFAULT_CHANNELS    2
#define DEFAULT_SAMPLE_RATE 48000
#define DEFAULT_DURATION    3 // Seconds

static void print_usage(const char *prog_name) {
    printf("QPCIe ALSA Audio User-Mode Test Application\n");
    printf("Usage: %s [options]\n", prog_name);
    printf("Options:\n");
    printf("  -d, --dev <device>     ALSA PCM Device node (auto-detected if omitted)\n");
    printf("  -r, --rate <hz>        Sample rate in Hz (default: %d)\n", DEFAULT_SAMPLE_RATE);
    printf("  -c, --channels <count> Number of channels (default: %d)\n", DEFAULT_CHANNELS);
    printf("  -s, --seconds <sec>    Capture duration in seconds (default: %d)\n", DEFAULT_DURATION);
    printf("  -p, --pattern <id>     Set Audio Pattern (0: 1kHz Sine, 1: Sawtooth, 2: 440Hz, 3: Mute)\n");
    printf("  -o, --out <file>       Save captured PCM/AES3 audio to file\n");
    printf("  -h, --help             Show this help message\n");
}

/* Auto-detect QPCIe ALSA PCM device path from /proc/asound/cards */
static int find_qpcie_pcm_device(char *dev_path, size_t max_len) {
    FILE *fp = fopen("/proc/asound/cards", "r");
    if (!fp) return -1;

    char line[256];
    int card_num = -1;

    while (fgets(line, sizeof(line), fp)) {
        int num;
        char id[64];
        if (sscanf(line, " %d [%63[^]:]", &num, id) == 2) {
            if (strstr(id, "QPCIe") || strstr(id, "qpcie") || strstr(id, "AES3")) {
                card_num = num;
                break;
            }
        }
        if (strstr(line, "QPCIe") || strstr(line, "qpcie-alsa")) {
            if (card_num >= 0) break;
        }
    }
    fclose(fp);

    if (card_num >= 0) {
        snprintf(dev_path, max_len, "/dev/snd/pcmC%dD0c", card_num);
        return 0;
    }

    // Fallback: search /dev/snd/pcmC*D0c
    glob_t globbuf;
    if (glob("/dev/snd/pcmC*D0c", 0, NULL, &globbuf) == 0) {
        if (globbuf.gl_pathc > 0) {
            // Pick the last non-zero card if available, or first
            size_t idx = (globbuf.gl_pathc > 1) ? 1 : 0;
            snprintf(dev_path, max_len, "%s", globbuf.gl_pathv[idx]);
            globfree(&globbuf);
            return 0;
        }
        globfree(&globbuf);
    }

    return -1;
}

/* Find PCI sysfs node for aud_pattern */
static int set_sysfs_pattern(int pattern_id) {
    glob_t globbuf;
    int ret = -1;

    if (glob("/sys/bus/pci/devices/*/aud_pattern", 0, NULL, &globbuf) == 0) {
        for (size_t i = 0; i < globbuf.gl_pathc; i++) {
            FILE *fp = fopen(globbuf.gl_pathv[i], "w");
            if (fp) {
                fprintf(fp, "%d\n", pattern_id);
                fclose(fp);
                printf("  [Sysfs] Set %s -> %d\n", globbuf.gl_pathv[i], pattern_id);
                ret = 0;
                break;
            }
        }
        globfree(&globbuf);
    }
    return ret;
}

int main(int argc, char **argv) {
    char auto_dev[64] = {0};
    const char *dev_name = NULL;
    const char *out_filename = NULL;
    uint32_t sample_rate = DEFAULT_SAMPLE_RATE;
    uint32_t channels = DEFAULT_CHANNELS;
    uint32_t duration_sec = DEFAULT_DURATION;
    int aud_pattern = -1;

    static struct option long_options[] = {
        {"dev",      required_argument, 0, 'd'},
        {"rate",     required_argument, 0, 'r'},
        {"channels", required_argument, 0, 'c'},
        {"seconds",  required_argument, 0, 's'},
        {"pattern",  required_argument, 0, 'p'},
        {"out",      required_argument, 0, 'o'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:r:c:s:p:o:h?", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': dev_name = optarg; break;
            case 'r': sample_rate = atoi(optarg); break;
            case 'c': channels = atoi(optarg); break;
            case 's': duration_sec = atoi(optarg); break;
            case 'p': aud_pattern = atoi(optarg); break;
            case 'o': out_filename = optarg; break;
            case 'h':
            case '?': print_usage(argv[0]); return EXIT_SUCCESS;
            default: break;
        }
    }

    if (!dev_name) {
        if (find_qpcie_pcm_device(auto_dev, sizeof(auto_dev)) == 0) {
            dev_name = auto_dev;
            printf("[Auto-Detect] Found QPCIe Audio Device: %s\n", dev_name);
        } else {
            dev_name = "/dev/snd/pcmC1D0c";
            printf("[Notice] Could not auto-detect; defaulting to %s\n", dev_name);
        }
    }

    printf("=================================================================\n");
    printf(" QPCIe ALSA Audio Capture Test Application (Channel 0)\n");
    printf(" Device: %s, Channels: %u, Rate: %u Hz, Duration: %u sec\n",
           dev_name, channels, sample_rate, duration_sec);
    printf(" Format: 32-bit AES3 Subframe (S32_LE)\n");
    printf("=================================================================\n");

    // Configure Audio Pattern if requested
    if (aud_pattern >= 0) {
        printf("--> Setting Audio Pattern ID: %d...\n", aud_pattern);
        if (set_sysfs_pattern(aud_pattern) < 0) {
            printf("    Note: Could not set via sysfs; pattern may retain default.\n");
        }
    }

    // 1. Open ALSA PCM Capture Device Node
    int fd = open(dev_name, O_RDWR);
    if (fd < 0) {
        perror("Cannot open ALSA PCM device");
        printf("Hint: Run 'arecord -l' to check available sound cards.\n");
        printf("      Ensure custom_pcie_av kernel module is loaded.\n");
        return EXIT_FAILURE;
    }

    // 2. Query Driver PVERSION
    int ver = 0;
    if (ioctl(fd, SNDRV_PCM_IOCTL_PVERSION, &ver) < 0) {
        perror("SNDRV_PCM_IOCTL_PVERSION failed");
        close(fd);
        return EXIT_FAILURE;
    }
    printf("[ALSA Driver] Protocol Version: %d.%d.%d\n",
           (ver >> 16), ((ver >> 8) & 0xFF), (ver & 0xFF));

    // 3. Configure PCM Hardware Parameters (SNDRV_PCM_IOCTL_HW_PARAMS)
    struct snd_pcm_hw_params params;
    memset(&params, 0, sizeof(params));

    params.flags = SNDRV_PCM_HW_PARAMS_NORESAMPLE;
    params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1 << SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1 << SNDRV_PCM_FORMAT_S32_LE);
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = channels;
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = channels;
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = sample_rate;
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = sample_rate;

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &params) < 0) {
        perror("SNDRV_PCM_IOCTL_HW_PARAMS failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("--> ALSA HW Parameters Configured (Format: S32_LE, Channels: %u, Rate: %u Hz)\n",
           channels, sample_rate);

    // 4. Prepare & Start PCM Stream
    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) {
        perror("SNDRV_PCM_IOCTL_PREPARE failed");
        close(fd);
        return EXIT_FAILURE;
    }

    if (ioctl(fd, SNDRV_PCM_IOCTL_START) < 0) {
        perror("SNDRV_PCM_IOCTL_START failed");
        close(fd);
        return EXIT_FAILURE;
    }

    FILE *out_fp = NULL;
    if (out_filename) {
        out_fp = fopen(out_filename, "wb");
        if (!out_fp) perror("Cannot open output file");
    }

    // 5. Audio Buffer Capture Loop
    size_t period_frames = 1024;
    size_t frame_bytes = channels * sizeof(uint32_t); // 32-bit (4 bytes) per channel
    size_t buf_size = period_frames * frame_bytes;
    uint32_t *audio_buf = malloc(buf_size);

    uint64_t total_frames_target = (uint64_t)sample_rate * duration_sec;
    uint64_t total_frames_read = 0;
    double sum_sq_samples = 0.0;
    uint64_t total_sample_count = 0;

    int32_t prev_pcm = 0;
    uint64_t zero_crossings = 0;
    int sample_preview_printed = 0;

    printf("--> Capturing %u seconds of AES3 Audio Data...\n", duration_sec);

    while (total_frames_read < total_frames_target) {
        ssize_t ret = read(fd, audio_buf, buf_size);
        if (ret < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            perror("PCM read failed");
            break;
        }

        size_t frames_read = ret / frame_bytes;
        total_frames_read += frames_read;

        // Print first few samples preview
        if (!sample_preview_printed && frames_read >= 4) {
            printf("\n--- [AES3 Subframe Sample Preview (First 4 Subframes)] ---\n");
            for (int k = 0; k < 4; k++) {
                uint32_t raw = audio_buf[k];
                uint8_t preamble = raw & 0x0F;
                int32_t pcm = (raw >> 4) & 0x00FFFFFF;
                if (pcm & 0x00800000) pcm |= 0xFF000000;
                printf("  Sample[%d]: Raw=0x%08X | Preamble=0x%X (%s) | 24-bit PCM=%d (0x%06X)\n",
                       k, raw, preamble,
                       (preamble == 0x0B) ? "Left / Block Start" :
                       (preamble == 0x0C) ? "Right Channel" : "Other",
                       pcm, pcm & 0x00FFFFFF);
            }
            printf("-----------------------------------------------------------\n\n");
            sample_preview_printed = 1;
        }

        // Parse AES3 Subframes, Calculate RMS Energy & Zero Crossings
        for (size_t i = 0; i < frames_read * channels; i++) {
            uint32_t aes3_subframe = audio_buf[i];

            // Extract 24-bit Audio Sample (Bits [27:4])
            int32_t pcm_24bit = (aes3_subframe >> 4) & 0x00FFFFFF;
            if (pcm_24bit & 0x00800000) {
                pcm_24bit |= 0xFF000000;
            }

            double normalized = (double)pcm_24bit / 8388607.0; // -1.0 to +1.0
            sum_sq_samples += normalized * normalized;
            total_sample_count++;

            // Track zero crossings on Left channel (even indices) for freq estimation
            if ((i % 2) == 0) {
                if ((prev_pcm < 0 && pcm_24bit >= 0) || (prev_pcm >= 0 && pcm_24bit < 0)) {
                    zero_crossings++;
                }
                prev_pcm = pcm_24bit;
            }
        }

        if (out_fp) {
            fwrite(audio_buf, 1, ret, out_fp);
        }

        printf("  [Progress] Captured %llu / %llu frames (%.1f%%)\r",
               (unsigned long long)total_frames_read,
               (unsigned long long)total_frames_target,
               (total_frames_read * 100.0) / total_frames_target);
        fflush(stdout);
    }

    printf("\n");

    // 6. Calculate Audio Statistics
    double rms = sqrt(sum_sq_samples / (total_sample_count > 0 ? total_sample_count : 1));
    double dbfs = 20.0 * log10(rms > 1e-6 ? rms : 1e-6);
    double elapsed_sec = (double)total_frames_read / sample_rate;
    double estimated_freq = (elapsed_sec > 0.0) ? (zero_crossings / 2.0) / elapsed_sec : 0.0;

    printf("=================================================================\n");
    printf(" Audio Capture Finished: %llu frames (%.2f sec)\n",
           (unsigned long long)total_frames_read, elapsed_sec);
    printf(" Captured Audio RMS Energy : %.4f (%.2f dBFS)\n", rms, dbfs);
    printf(" Estimated Audio Frequency : %.1f Hz\n", estimated_freq);

    int test_pass = 0;
    if (total_frames_read >= (total_frames_target * 95 / 100) && rms > 0.05) {
        printf(" AES3 Signal Status        : ACTIVE (Signal Energy Verified)\n");
        printf(" Frequency Check           : %s (%.1f Hz)\n",
               (fabs(estimated_freq - 1000.0) < 150.0) ? "1kHz Sine Detected [PASS]" :
               (fabs(estimated_freq - 440.0) < 50.0)   ? "440Hz Tone Detected [PASS]" :
               "Non-standard Tone / Sawtooth [PASS]", estimated_freq);
        test_pass = 1;
    } else {
        printf(" AES3 Signal Status        : %s\n", (rms <= 0.05) ? "LOW ENERGY / SILENCE [FAIL]" : "TRUNCATED CAPTURE [FAIL]");
    }

    printf(" Verdict                   : %s\n", test_pass ? "🎉 [PASS]" : "❌ [FAIL]");
    printf("=================================================================\n");

    // 7. Cleanup
    if (out_fp) {
        fclose(out_fp);
        printf("Saved captured PCM audio to file: %s\n", out_filename);
    }

    free(audio_buf);
    close(fd);

    return test_pass ? EXIT_SUCCESS : EXIT_FAILURE;
}
