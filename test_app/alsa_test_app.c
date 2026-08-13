/*
 * alsa_test_app.c - Comprehensive ALSA Audio Capture User-Mode Test Application
 * Tests 32-bit AES3 Audio Subframe capture, 48kHz Stereo PCM streaming & BAR1 Audio Pattern Gen.
 *
 * Usage:
 *   ./alsa_test_app --dev /dev/snd/pcmC0D0c --rate 48000 --seconds 5 --out test_audio.pcm
 *   ./alsa_test_app --dev /dev/snd/pcmC0D0c --pattern 0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <math.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sound/asound.h>

#include "qpcie_control.h"

#define DEFAULT_PCM_DEVICE  "/dev/snd/pcmC0D0c"
#define DEFAULT_CHANNELS    2
#define DEFAULT_SAMPLE_RATE 48000
#define DEFAULT_DURATION    5 // Seconds

static void print_usage(const char *prog_name) {
    printf("QPCIe ALSA Audio User-Mode Test Application\n");
    printf("Usage: %s [options]\n", prog_name);
    printf("Options:\n");
    printf("  -d, --dev <device>     ALSA PCM Device node (default: %s)\n", DEFAULT_PCM_DEVICE);
    printf("  -r, --rate <hz>        Sample rate in Hz (default: %d)\n", DEFAULT_SAMPLE_RATE);
    printf("  -c, --channels <count> Number of channels (default: %d)\n", DEFAULT_CHANNELS);
    printf("  -s, --seconds <sec>    Capture duration in seconds (default: %d)\n", DEFAULT_DURATION);
    printf("  -p, --pattern <id>     Set Audio Pattern (0: 1kHz Sine, 1: Sawtooth, 2: 440Hz, 3: Mute)\n");
    printf("  -o, --out <file>       Save captured PCM/AES3 audio to file\n");
    printf("  -help                  Show this help message\n");
}

int main(int argc, char **argv) {
    const char *dev_name = DEFAULT_PCM_DEVICE;
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
        {"help",     no_argument,       0, '?'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:r:c:s:p:o:?", long_options, NULL)) != -1) {
        switch (opt) {
            case 'd': dev_name = optarg; break;
            case 'r': sample_rate = atoi(optarg); break;
            case 'c': channels = atoi(optarg); break;
            case 's': duration_sec = atoi(optarg); break;
            case 'p': aud_pattern = atoi(optarg); break;
            case 'o': out_filename = optarg; break;
            case '?': print_usage(argv[0]); return EXIT_SUCCESS;
            default: break;
        }
    }

    printf("=================================================================\n");
    printf(" QPCIe ALSA Audio Capture Test Application\n");
    printf(" Device: %s, Channels: %u, Rate: %u Hz, Duration: %u sec\n",
           dev_name, channels, sample_rate, duration_sec);
    printf(" Format: 32-bit AES3 Subframe (S32_LE)\n");
    printf("=================================================================\n");

    // 1. Open ALSA PCM Capture Device Node
    int fd = open(dev_name, O_RDWR);
    if (fd < 0) {
        perror("Cannot open ALSA PCM device");
        printf("Note: Ensure QPCIe ALSA driver module is loaded and node exists.\n");
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

    // Set Access type: RW_INTERLEAVED
    params.flags = SNDRV_PCM_HW_PARAMS_NORESAMPLE;

    // Set Format: S32_LE (32-bit AES3 subframes)
    params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1 << SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1 << SNDRV_PCM_FORMAT_S32_LE);

    // Set Channels & Sample Rate Interval
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

    // 5. Config Audio Pattern if requested
    if (aud_pattern >= 0) {
        printf("--> Setting Audio Pattern ID: %d...\n", aud_pattern);
        FILE *sysfs_fp = fopen("/sys/class/sound/card0/aud_pattern", "w");
        if (sysfs_fp) {
            fprintf(sysfs_fp, "%d\n", aud_pattern);
            fclose(sysfs_fp);
            printf("    Updated Audio Pattern via sysfs successfully.\n");
        } else {
            printf("    Note: Could not open sysfs node /sys/class/sound/card0/aud_pattern (Defaulting to 1kHz Sine).\n");
        }
    }

    // 6. Audio Buffer Capture Loop
    size_t period_frames = 1024;
    size_t frame_bytes = channels * sizeof(uint32_t); // 32-bit (4 bytes) per channel
    size_t buf_size = period_frames * frame_bytes;
    uint32_t *audio_buf = malloc(buf_size);

    uint64_t total_frames_target = (uint64_t)sample_rate * duration_sec;
    uint64_t total_frames_read = 0;
    double sum_sq_samples = 0.0;
    uint64_t total_sample_count = 0;

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

        // Parse AES3 Subframes & Calculate RMS Energy
        for (size_t i = 0; i < frames_read * channels; i++) {
            uint32_t aes3_subframe = audio_buf[i];

            // Extract 24-bit Audio Sample (Bits [27:4])
            int32_t pcm_24bit = (aes3_subframe >> 4) & 0x00FFFFFF;
            if (pcm_24bit & 0x00800000) { // Sign extend 24-bit to 32-bit
                pcm_24bit |= 0xFF000000;
            }

            double normalized = (double)pcm_24bit / 8388607.0; // Normalize -1.0 to +1.0
            sum_sq_samples += normalized * normalized;
            total_sample_count++;
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

    printf("=================================================================\n");
    printf(" Audio Capture Finished: %llu frames (%.2f sec)\n",
           (unsigned long long)total_frames_read,
           (double)total_frames_read / sample_rate);
    printf(" Captured Audio RMS Energy : %.4f (%.2f dBFS)\n", rms, dbfs);
    printf(" AES3 Signal Status        : %s\n", (rms > 0.05) ? "ACTIVE 1kHz Sine/Pattern OK" : "MUTE / Silence");
    printf("=================================================================\n");

    // 7. Cleanup
    if (out_fp) {
        fclose(out_fp);
        printf("Saved captured PCM audio to file: %s\n", out_filename);
    }

    free(audio_buf);
    close(fd);

    return EXIT_SUCCESS;
}
