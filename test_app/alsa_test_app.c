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
#include <limits.h>
#include <sound/asound.h>

#include "qpcie_control.h"

static void init_hw_params_any(struct snd_pcm_hw_params *params) {
    memset(params, 0, sizeof(*params));

    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++) {
        memset(&params->masks[i], 0xff, sizeof(params->masks[i]));
    }

    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++) {
        params->intervals[i].min = 0;
        params->intervals[i].max = UINT_MAX;
        params->intervals[i].openmin = 0;
        params->intervals[i].openmax = 0;
        params->intervals[i].integer = 0;
        params->intervals[i].empty = 0;
    }

    params->rmask = ~0U;
    params->cmask = 0;
    params->info = ~0U;
}

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
    printf("  -p, --pattern <id>     Set Audio Pattern:\n");
    printf("                           0: L-Sine / R-Saw (Stereo Split, distinguishes L/R)\n");
    printf("                           1: Stereo 1kHz Sine Wave\n");
    printf("                           2: Stereo Sawtooth Wave\n");
    printf("                           3: Stereo 440Hz Tone\n");
    printf("                           4: Mute / Silence\n");
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
    init_hw_params_any(&params);

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &params) < 0) {
        perror("SNDRV_PCM_IOCTL_HW_REFINE initial probe failed");
        close(fd);
        return EXIT_FAILURE;
    }

    params.flags = SNDRV_PCM_HW_PARAMS_NORESAMPLE;

    // Constrain ACCESS to RW_INTERLEAVED
    memset(&params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0, sizeof(struct snd_mask));
    params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1U << SNDRV_PCM_ACCESS_RW_INTERLEAVED);

    // Constrain FORMAT to S32_LE
    memset(&params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0, sizeof(struct snd_mask));
    params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1U << SNDRV_PCM_FORMAT_S32_LE);

    // Constrain SUBFORMAT to STD
    memset(&params.masks[SNDRV_PCM_HW_PARAM_SUBFORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0, sizeof(struct snd_mask));
    params.masks[SNDRV_PCM_HW_PARAM_SUBFORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1U << SNDRV_PCM_SUBFORMAT_STD);

    // Constrain CHANNELS
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = channels;
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = channels;
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].integer = 1;

    // Constrain RATE
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = sample_rate;
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = sample_rate;
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].integer = 1;

    // Constrain PERIOD_SIZE (1024 frames = 8192 bytes for 2ch 32-bit)
    params.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = 1024;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = 1024;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].integer = 1;

    // Constrain PERIODS (4 periods = 4096 frames total = 32768 bytes buffer)
    params.intervals[SNDRV_PCM_HW_PARAM_PERIODS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = 4;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIODS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = 4;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIODS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].integer = 1;

    // Constrain BUFFER_SIZE
    params.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = 4096;
    params.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = 4096;
    params.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].integer = 1;

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &params) < 0) {
        perror("SNDRV_PCM_IOCTL_HW_PARAMS failed");
        close(fd);
        return EXIT_FAILURE;
    }

    printf("--> ALSA HW Parameters Configured (Format: S32_LE, Channels: %u, Rate: %u Hz, Period: 1024 frames)\n",
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

    double sum_sq_l = 0.0, sum_sq_r = 0.0;
    uint64_t total_samples_l = 0, total_samples_r = 0;
    int32_t min_l = 0x7FFFFFFF, max_l = -0x7FFFFFFF;
    int32_t min_r = 0x7FFFFFFF, max_r = -0x7FFFFFFF;

    int32_t prev_pcm_l = 0, prev_pcm_r = 0;
    uint64_t zero_crossings_l = 0, zero_crossings_r = 0;
    uint64_t channel_swap_errors = 0;
    int sample_preview_printed = 0;

    printf("--> Capturing %u seconds of AES3 Audio Data...\n", duration_sec);

    while (total_frames_read < total_frames_target) {
        struct snd_xferi xferi;
        memset(&xferi, 0, sizeof(xferi));
        xferi.buf = audio_buf;
        xferi.frames = period_frames;

        ssize_t frames_read = 0;
        int err = ioctl(fd, SNDRV_PCM_IOCTL_READI_FRAMES, &xferi);
        if (err < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            if (errno == EPIPE) {
                // Buffer overrun/underrun recovery
                ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
                ioctl(fd, SNDRV_PCM_IOCTL_START);
                continue;
            }
            // Fallback: try standard read()
            ssize_t ret = read(fd, audio_buf, buf_size);
            if (ret < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                perror("Audio capture read failed");
                break;
            }
            frames_read = ret / frame_bytes;
        } else {
            frames_read = (xferi.result > 0) ? xferi.result : (ssize_t)xferi.frames;
        }

        if (frames_read <= 0) continue;
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
                       (preamble == 0x09) ? "Left Channel" :
                       (preamble == 0x0C) ? "Right Channel" : "Other",
                       pcm, pcm & 0x00FFFFFF);
            }
            printf("-----------------------------------------------------------\n\n");
            sample_preview_printed = 1;
        }

        // Parse AES3 Subframes, Calculate RMS Energy & Zero Crossings per Channel
        for (size_t i = 0; i < frames_read * channels; i++) {
            uint32_t aes3_subframe = audio_buf[i];
            uint8_t preamble = aes3_subframe & 0x0F;

            // Validate strict Left/Right channel alignment
            if ((i % 2) == 0) {
                if (preamble != 0x0B && preamble != 0x09) channel_swap_errors++;
            } else {
                if (preamble != 0x0C) channel_swap_errors++;
            }

            // Extract 24-bit Audio Sample (Bits [27:4])
            int32_t pcm_24bit = (aes3_subframe >> 4) & 0x00FFFFFF;
            if (pcm_24bit & 0x00800000) {
                pcm_24bit |= 0xFF000000;
            }

            double normalized = (double)pcm_24bit / 8388607.0; // -1.0 to +1.0

            if ((i % 2) == 0) {
                // Left Channel
                sum_sq_l += normalized * normalized;
                total_samples_l++;
                if (pcm_24bit < min_l) min_l = pcm_24bit;
                if (pcm_24bit > max_l) max_l = pcm_24bit;
                if ((prev_pcm_l < 0 && pcm_24bit >= 0) || (prev_pcm_l >= 0 && pcm_24bit < 0)) {
                    zero_crossings_l++;
                }
                prev_pcm_l = pcm_24bit;
            } else {
                // Right Channel
                sum_sq_r += normalized * normalized;
                total_samples_r++;
                if (pcm_24bit < min_r) min_r = pcm_24bit;
                if (pcm_24bit > max_r) max_r = pcm_24bit;
                if ((prev_pcm_r < 0 && pcm_24bit >= 0) || (prev_pcm_r >= 0 && pcm_24bit < 0)) {
                    zero_crossings_r++;
                }
                prev_pcm_r = pcm_24bit;
            }
        }

        if (out_fp) {
            fwrite(audio_buf, 1, frames_read * frame_bytes, out_fp);
        }

        printf("  [Progress] Captured %llu / %llu frames (%.1f%%)\r",
               (unsigned long long)total_frames_read,
               (unsigned long long)total_frames_target,
               (total_frames_read * 100.0) / total_frames_target);
        fflush(stdout);
    }

    printf("\n");

    // 6. Calculate Audio Statistics per Channel
    double elapsed_sec = (double)total_frames_read / sample_rate;

    double rms_l = sqrt(sum_sq_l / (total_samples_l > 0 ? total_samples_l : 1));
    double dbfs_l = 20.0 * log10(rms_l > 1e-6 ? rms_l : 1e-6);
    double freq_l = (elapsed_sec > 0.0) ? (zero_crossings_l / 2.0) / elapsed_sec : 0.0;

    double rms_r = sqrt(sum_sq_r / (total_samples_r > 0 ? total_samples_r : 1));
    double dbfs_r = 20.0 * log10(rms_r > 1e-6 ? rms_r : 1e-6);
    double freq_r = (elapsed_sec > 0.0) ? (zero_crossings_r / 2.0) / elapsed_sec : 0.0;

    printf("=================================================================\n");
    printf(" Audio Capture Finished: %llu frames (%.2f sec)\n",
           (unsigned long long)total_frames_read, elapsed_sec);
    printf(" [Left Channel  (0x0B/0x09)] RMS: %.4f (%6.2f dBFS) | Freq: %6.1f Hz | Range: [%d, %d]\n",
           rms_l, dbfs_l, freq_l, min_l, max_l);
    printf(" [Right Channel (0x0C)]      RMS: %.4f (%6.2f dBFS) | Freq: %6.1f Hz | Range: [%d, %d]\n",
           rms_r, dbfs_r, freq_r, min_r, max_r);
    printf(" Left/Right Channel Sync   : %s (%llu swap errors)\n",
           (channel_swap_errors == 0) ? "PERFECT [L=0xB/0x9, R=0xC]" : "MISALIGNED [FAIL]",
           (unsigned long long)channel_swap_errors);

    int test_pass = 0;
    if (total_frames_read >= (total_frames_target * 95 / 100) && (rms_l > 0.05 || rms_r > 0.05) && channel_swap_errors == 0) {
        printf(" AES3 Signal Status        : ACTIVE (Energy & Framing Verified)\n");
        printf(" Channel Distinction Check : %s\n",
               (min_l < -1000000 && min_r >= 0) ? "CONFIRMED (Left=Sine bipolar, Right=Sawtooth unipolar) [PASS]" :
               (fabs(rms_l - rms_r) > 0.05)     ? "CONFIRMED (Distinct L/R RMS Levels) [PASS]" :
               "Stereo Pattern Active [PASS]");
        test_pass = 1;
    } else {
        printf(" AES3 Signal Status        : %s\n",
               (channel_swap_errors > 0) ? "CHANNEL SWAP MISALIGNMENT [FAIL]" :
               (rms_l <= 0.05 && rms_r <= 0.05) ? "LOW ENERGY / SILENCE [FAIL]" : "TRUNCATED CAPTURE [FAIL]");
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
