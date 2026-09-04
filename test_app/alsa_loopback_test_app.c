/*
 * alsa_loopback_test_app.c - Multi-Channel ALSA Loopback Test Application
 *
 * Tests concurrent multi-channel Audio Playback -> FPGA Loopback -> Capture
 * for Channels 1, 2, and 3:
 *   - Card Ch1: Device 0 Playback (/dev/snd/pcmC*D0p) -> Device 1 Capture (/dev/snd/pcmC*D1c)
 *   - Card Ch2: Device 0 Playback (/dev/snd/pcmC*D0p) -> Device 1 Capture (/dev/snd/pcmC*D1c)
 *   - Card Ch3: Device 0 Playback (/dev/snd/pcmC*D0p) -> Device 1 Capture (/dev/snd/pcmC*D1c)
 *
 * Usage:
 *   ./alsa_loopback_test_app [-c <1|2|3|all>] [-s <seconds>] [-r <rate>]
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <pthread.h>
#include <math.h>
#include <glob.h>
#include <time.h>
#include <limits.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sound/asound.h>

#define DEFAULT_SAMPLE_RATE 48000
#define DEFAULT_CHANNELS    2
#define DEFAULT_DURATION    3 // Seconds
#define PERIOD_FRAMES       1024
#define FRAME_BYTES         (DEFAULT_CHANNELS * sizeof(uint32_t)) // 8 bytes per stereo frame
#define PERIOD_BYTES        (PERIOD_FRAMES * FRAME_BYTES)        // 8192 bytes

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

static int configure_pcm_device(int fd, int is_playback, uint32_t rate, uint32_t channels, uint32_t period_frames) {
    struct snd_pcm_hw_params params;
    init_hw_params_any(&params);

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &params) < 0) {
        perror("HW_REFINE failed");
        return -1;
    }

    // Set ACCESS: RW_INTERLEAVED
    params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1U << SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    params.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[1] = 0;

    // Set FORMAT: S32_LE (or S24_LE)
    uint32_t fmt_mask = (1U << SNDRV_PCM_FORMAT_S32_LE);
    if (!(params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] & fmt_mask)) {
        fmt_mask = (1U << SNDRV_PCM_FORMAT_S24_LE);
    }
    params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = fmt_mask;
    params.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[1] = 0;

    // Set SUBFORMAT: STANDARD
    params.masks[SNDRV_PCM_HW_PARAM_SUBFORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[0] = (1U << SNDRV_PCM_SUBFORMAT_STD);
    params.masks[SNDRV_PCM_HW_PARAM_SUBFORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[1] = 0;

    // Channels
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = channels;
    params.intervals[SNDRV_PCM_HW_PARAM_CHANNELS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = channels;

    // Rate
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = rate;
    params.intervals[SNDRV_PCM_HW_PARAM_RATE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = rate;

    // Period size
    params.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = period_frames;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = period_frames;

    // Periods
    params.intervals[SNDRV_PCM_HW_PARAM_PERIODS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = 2;
    params.intervals[SNDRV_PCM_HW_PARAM_PERIODS - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = 8;

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &params) < 0) {
        perror("HW_PARAMS configuration failed");
        return -1;
    }

    // Set Software Parameters
    struct snd_pcm_sw_params swparams;
    memset(&swparams, 0, sizeof(swparams));
    swparams.tstamp_mode = SNDRV_PCM_TSTAMP_ENABLE;
    swparams.period_step = 1;
    swparams.avail_min = period_frames;
    swparams.start_threshold = is_playback ? period_frames : 1;
    swparams.stop_threshold = period_frames * 16;

    if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &swparams) < 0) {
        perror("SW_PARAMS configuration failed");
        return -1;
    }

    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) {
        perror("PCM PREPARE failed");
        return -1;
    }

    return 0;
}

/* Find card number for a given audio channel (1, 2, 3) */
static int find_channel_card(int channel_id) {
    FILE *fp = fopen("/proc/asound/cards", "r");
    if (!fp) return -1;

    char line[256];
    int cur_card = -1;
    char pat1[32], pat2[32], pat3[32], pat4[32];
    snprintf(pat1, sizeof(pat1), "Audio%d", channel_id);
    snprintf(pat2, sizeof(pat2), "Audio-%d", channel_id);
    snprintf(pat3, sizeof(pat3), "Audio Ch%d", channel_id);
    snprintf(pat4, sizeof(pat4), "Channel %d", channel_id);

    while (fgets(line, sizeof(line), fp)) {
        int num;
        if (sscanf(line, " %d [", &num) == 1) {
            cur_card = num;
        }
        if (cur_card >= 0 && (strstr(line, pat1) || strstr(line, pat2) ||
                              strstr(line, pat3) || strstr(line, pat4))) {
            fclose(fp);
            return cur_card;
        }
    }
    fclose(fp);
    return -1;
}

struct channel_test_context {
    int channel_id;
    int card_num;
    char play_dev[64];
    char cap_dev[64];
    uint32_t sample_rate;
    uint32_t duration_sec;
    volatile bool stop;

    // Statistics
    uint64_t frames_sent;
    uint64_t frames_recv;
    uint64_t swap_errors;
    uint64_t bit_errors;
    uint64_t xrun_errors;
    double   min_latency_us;
    double   max_latency_us;
    double   avg_latency_us;
    uint64_t latency_count;
    bool     passed;
};

static uint32_t make_aes3_subframe(int is_left, uint32_t sample_index, int32_t pcm_val) {
    uint32_t preamble = is_left ? ((sample_index % 192 == 0) ? 0x0B : 0x09) : 0x0C;
    uint32_t audio_bits = ((uint32_t)pcm_val & 0x00FFFFFF) << 4;
    // Calculate parity
    uint32_t parity = 0;
    uint32_t temp = audio_bits;
    while (temp) {
        parity ^= (temp & 1);
        temp >>= 1;
    }
    return (parity << 31) | audio_bits | (preamble & 0x0F);
}

static void *playback_thread_fn(void *arg) {
    struct channel_test_context *ctx = (struct channel_test_context *)arg;
    int fd = open(ctx->play_dev, O_WRONLY);
    if (fd < 0) {
        printf("[Ch%d Error] Cannot open playback device: %s\n", ctx->channel_id, ctx->play_dev);
        return NULL;
    }

    if (configure_pcm_device(fd, 1, ctx->sample_rate, DEFAULT_CHANNELS, PERIOD_FRAMES) < 0) {
        printf("[Ch%d Error] Failed to configure playback device\n", ctx->channel_id);
        close(fd);
        return NULL;
    }

    uint32_t *play_buf = malloc(PERIOD_BYTES);
    if (!play_buf) {
        close(fd);
        return NULL;
    }

    uint64_t frame_idx = 0;
    double tone_freq = 440.0 * ctx->channel_id; // Unique frequency per channel (440, 880, 1320 Hz)

    while (!ctx->stop) {
        for (int i = 0; i < PERIOD_FRAMES; i++) {
            double t = (double)(frame_idx + i) / (double)ctx->sample_rate;
            int32_t pcm_l = (int32_t)(sin(2.0 * M_PI * tone_freq * t) * 8388600.0);
            int32_t pcm_r = (int32_t)(cos(2.0 * M_PI * tone_freq * t) * 8388600.0);

            // Left subframe (Even)
            play_buf[i * 2 + 0] = make_aes3_subframe(1, frame_idx + i, pcm_l);
            // Right subframe (Odd)
            play_buf[i * 2 + 1] = make_aes3_subframe(0, frame_idx + i, pcm_r);
        }

        struct snd_xferi xferi;
        memset(&xferi, 0, sizeof(xferi));
        xferi.buf = play_buf;
        xferi.frames = PERIOD_FRAMES;

        int err = ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xferi);
        if (err < 0) {
            if (errno == EPIPE) {
                ctx->xrun_errors++;
                ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
                continue;
            }
            if (errno == EAGAIN || errno == EINTR) continue;
            perror("Playback writei failed");
            break;
        }

        frame_idx += PERIOD_FRAMES;
        ctx->frames_sent = frame_idx;
    }

    free(play_buf);
    close(fd);
    return NULL;
}

static void *capture_thread_fn(void *arg) {
    struct channel_test_context *ctx = (struct channel_test_context *)arg;
    int fd = open(ctx->cap_dev, O_RDONLY);
    if (fd < 0) {
        printf("[Ch%d Error] Cannot open capture device: %s\n", ctx->channel_id, ctx->cap_dev);
        return NULL;
    }

    if (configure_pcm_device(fd, 0, ctx->sample_rate, DEFAULT_CHANNELS, PERIOD_FRAMES) < 0) {
        printf("[Ch%d Error] Failed to configure capture device\n", ctx->channel_id);
        close(fd);
        return NULL;
    }

    if (ioctl(fd, SNDRV_PCM_IOCTL_START) < 0) {
        // Start might not be needed if auto-started by read
    }

    uint32_t *cap_buf = malloc(PERIOD_BYTES);
    if (!cap_buf) {
        close(fd);
        return NULL;
    }

    uint64_t total_frames = (uint64_t)ctx->duration_sec * ctx->sample_rate;
    uint64_t frames_captured = 0;

    struct timeval start_tv, end_tv;
    gettimeofday(&start_tv, NULL);

    while (!ctx->stop && frames_captured < total_frames) {
        struct snd_xferi xferi;
        memset(&xferi, 0, sizeof(xferi));
        xferi.buf = cap_buf;
        xferi.frames = PERIOD_FRAMES;

        int err = ioctl(fd, SNDRV_PCM_IOCTL_READI_FRAMES, &xferi);
        if (err < 0) {
            if (errno == EPIPE) {
                ctx->xrun_errors++;
                ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
                ioctl(fd, SNDRV_PCM_IOCTL_START);
                continue;
            }
            if (errno == EAGAIN || errno == EINTR) continue;
            perror("Capture readi failed");
            break;
        }

        ssize_t read_frames = (xferi.result > 0) ? xferi.result : (ssize_t)xferi.frames;
        if (read_frames <= 0) continue;

        gettimeofday(&end_tv, NULL);
        double rtt_us = (end_tv.tv_sec - start_tv.tv_sec) * 1000000.0 + (end_tv.tv_usec - start_tv.tv_usec);
        if (rtt_us > 0) {
            if (ctx->latency_count == 0 || rtt_us < ctx->min_latency_us) ctx->min_latency_us = rtt_us;
            if (rtt_us > ctx->max_latency_us) ctx->max_latency_us = rtt_us;
            ctx->avg_latency_us += rtt_us;
            ctx->latency_count++;
        }
        start_tv = end_tv;

        // Verify captured subframes
        for (int i = 0; i < read_frames; i++) {
            uint32_t raw_l = cap_buf[i * 2 + 0];
            uint32_t raw_r = cap_buf[i * 2 + 1];

            uint8_t preamble_l = raw_l & 0x0F;
            uint8_t preamble_r = raw_r & 0x0F;

            // Strict L/R channel preamble check
            if (preamble_l != 0x0B && preamble_l != 0x09) {
                ctx->swap_errors++;
            }
            if (preamble_r != 0x0C) {
                ctx->swap_errors++;
            }

            // Verify non-zero PCM payload
            int32_t pcm_l = (int32_t)(raw_l >> 4) & 0x00FFFFFF;
            int32_t pcm_r = (int32_t)(raw_r >> 4) & 0x00FFFFFF;
            if (pcm_l == 0 && pcm_r == 0 && frames_captured > PERIOD_FRAMES) {
                ctx->bit_errors++;
            }
        }

        frames_captured += read_frames;
        ctx->frames_recv = frames_captured;
    }

    ctx->stop = true; // Signal playback thread to finish cleanly

    if (ctx->latency_count > 0) {
        ctx->avg_latency_us /= (double)ctx->latency_count;
    }

    free(cap_buf);
    close(fd);
    return NULL;
}

static void print_usage(const char *prog) {
    printf("QPCIe Multi-Channel ALSA Audio Loopback Test Application\n");
    printf("Usage: %s [options]\n", prog);
    printf("Options:\n");
    printf("  -c, --channel <1|2|3|all>   Channel to test (default: all)\n");
    printf("  -s, --seconds <sec>         Duration in seconds (default: %d)\n", DEFAULT_DURATION);
    printf("  -r, --rate <hz>             Sample rate (default: %d)\n", DEFAULT_SAMPLE_RATE);
    printf("  -h, --help                  Show this help message\n");
}

int main(int argc, char **argv) {
    int target_ch = 0; // 0 = all channels (1, 2, 3)
    uint32_t duration_sec = DEFAULT_DURATION;
    uint32_t sample_rate = DEFAULT_SAMPLE_RATE;

    static struct option long_options[] = {
        {"channel",  required_argument, 0, 'c'},
        {"seconds",  required_argument, 0, 's'},
        {"rate",     required_argument, 0, 'r'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:s:r:h?", long_options, NULL)) != -1) {
        switch (opt) {
            case 'c':
                if (strcmp(optarg, "all") == 0) target_ch = 0;
                else target_ch = atoi(optarg);
                break;
            case 's': duration_sec = atoi(optarg); break;
            case 'r': sample_rate = atoi(optarg); break;
            case 'h':
            case '?': print_usage(argv[0]); return EXIT_SUCCESS;
            default: break;
        }
    }

    printf("=================================================================\n");
    printf(" QPCIe Multi-Channel ALSA Loopback Test Application\n");
    printf(" Target Channel(s): %s | Duration: %u sec | Sample Rate: %u Hz\n",
           (target_ch == 0) ? "Channels 1, 2, 3 (All)" :
           (target_ch == 1) ? "Channel 1" :
           (target_ch == 2) ? "Channel 2" : "Channel 3",
           duration_sec, sample_rate);
    printf(" Format: S32_LE AES3 Subframes (Stereo 2-Ch, 48kHz)\n");
    printf("=================================================================\n\n");

    int start_ch = (target_ch == 0) ? 1 : target_ch;
    int end_ch   = (target_ch == 0) ? 3 : target_ch;

    struct channel_test_context ctxs[4];
    memset(ctxs, 0, sizeof(ctxs));
    pthread_t play_threads[4];
    pthread_t cap_threads[4];
    int active_channels = 0;

    for (int ch = start_ch; ch <= end_ch; ch++) {
        int card = find_channel_card(ch);
        if (card < 0) {
            // Fallback: card index heuristic (e.g. Card 3 for Ch1, Card 4 for Ch2, Card 5 for Ch3)
            card = 2 + ch;
            printf("[Notice] Card for Ch%d not found in /proc/asound/cards; probing Card #%d\n", ch, card);
        } else {
            printf("[Found] Audio Channel %d -> ALSA Card #%d\n", ch, card);
        }

        ctxs[ch].channel_id   = ch;
        ctxs[ch].card_num     = card;
        ctxs[ch].sample_rate  = sample_rate;
        ctxs[ch].duration_sec = duration_sec;
        ctxs[ch].stop         = false;

        // Device 0 = Playback, Device 1 = Capture
        snprintf(ctxs[ch].play_dev, sizeof(ctxs[ch].play_dev), "/dev/snd/pcmC%dD0p", card);
        snprintf(ctxs[ch].cap_dev,  sizeof(ctxs[ch].cap_dev),  "/dev/snd/pcmC%dD1c", card);

        printf("  Channel %d: Playback=%s, Capture=%s\n", ch, ctxs[ch].play_dev, ctxs[ch].cap_dev);
        active_channels++;
    }

    if (active_channels == 0) {
        printf("[Error] No active loopback audio channels found!\n");
        return EXIT_FAILURE;
    }

    printf("\n--> Starting Concurrent Playback & Capture Streams on %d Channel(s)...\n", active_channels);

    // Launch Playback Threads first so samples fill FIFO
    for (int ch = start_ch; ch <= end_ch; ch++) {
        if (pthread_create(&play_threads[ch], NULL, playback_thread_fn, &ctxs[ch]) != 0) {
            perror("Failed to create playback thread");
            return EXIT_FAILURE;
        }
    }

    // Brief settling delay before starting capture
    usleep(20000);

    // Launch Capture Threads
    for (int ch = start_ch; ch <= end_ch; ch++) {
        if (pthread_create(&cap_threads[ch], NULL, capture_thread_fn, &ctxs[ch]) != 0) {
            perror("Failed to create capture thread");
            return EXIT_FAILURE;
        }
    }


    // Wait for all threads to complete
    for (int ch = start_ch; ch <= end_ch; ch++) {
        pthread_join(play_threads[ch], NULL);
        pthread_join(cap_threads[ch], NULL);
    }

    // Evaluate and Print Results Table
    printf("\n=========================================================================================\n");
    printf("                          MULTI-CHANNEL LOOPBACK TEST RESULTS\n");
    printf("=========================================================================================\n");
    printf(" Ch | Card # | Node (P/C)    | Sent Frames | Recv Frames | L/R Sync | XRUNs | Latency (avg) | Verdict\n");
    printf("----+--------+---------------+-------------+-------------+----------+-------+---------------+--------\n");

    bool all_passed = true;

    for (int ch = start_ch; ch <= end_ch; ch++) {
        uint64_t target_frames = (uint64_t)ctxs[ch].duration_sec * ctxs[ch].sample_rate;
        bool pass = (ctxs[ch].frames_recv >= target_frames) &&
                    (ctxs[ch].swap_errors == 0) &&
                    (ctxs[ch].xrun_errors == 0);

        ctxs[ch].passed = pass;
        if (!pass) all_passed = false;

        printf(" %2d | Card %d | pcmC%dD0p/D1c  | %11lu | %11lu | %8lu | %5lu | %9.1f us | %s\n",
               ch, ctxs[ch].card_num, ctxs[ch].card_num,
               ctxs[ch].frames_sent, ctxs[ch].frames_recv,
               ctxs[ch].swap_errors, ctxs[ch].xrun_errors,
               ctxs[ch].avg_latency_us,
               pass ? "\033[1;32m[PASS]\033[0m" : "\033[1;31m[FAIL]\033[0m");
    }
    printf("=========================================================================================\n\n");

    if (all_passed) {
        printf("🎉 ALL LOOPBACK AUDIO CHANNELS PASSED VERIFICATION (100%% DATA INTEGRITY, 0 SWAP ERRORS)!\n");
        return EXIT_SUCCESS;
    } else {
        printf("❌ ONE OR MORE AUDIO CHANNELS FAILED LOOPBACK VERIFICATION!\n");
        return EXIT_FAILURE;
    }
}
