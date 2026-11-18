/*
 * sc7f0_dmabuf_loop - card-side zero-copy loop-through: V4L2 capture buffer ->
 * DRM plane framebuffer, by fd, with no pixel copied anywhere.
 *
 *   sc7f0_dmabuf_loop [options]
 *     --video PATH       capture node            (default /dev/video0)
 *     --drm PATH         DRM card                (default /dev/dri/card0)
 *     --set-mode         set the connector's first mode before flipping
 *     --mode WxH[@Hz]    pick a specific connector mode (implies --set-mode)
 *     --crtc N           CRTC id                 (default: one the connector drives)
 *     --conn N           connector id            (default: first connected)
 *     --plane N          plane id to flip        (default: primary 32bpp plane)
 *     --fourcc ABCD      display fourcc          (default: first 32bpp the plane has)
 *     --cap-fourcc ABCD  capture fourcc to request (default XB24 = "xbgr8888")
 *     --frames N         frames to present       (default 600)
 *     --hold SECONDS     keep the last frame up before clearing the mode (0..600)
 *     --no-clear         leave the mode set on exit (operator inspection)
 *     --probe-only       enumerate and refuse to touch the display
 *
 * Why this exists and not modetest: modetest allocates its own framebuffers, so it
 * can prove a mode and a plane work, but it cannot prove that the buffer the PS
 * *capture* wrote is the buffer the display reads.  The claim this tool tests is
 * exactly A1's: RX -> PS DDR (RGBX, memory R,G,B,X) -> v_frmbuf_rd Plane A -> HDMI
 * TX, with the DMA-BUF import path as the only thing between them.
 *
 * Why the mode set lives here and not in a preceding modetest: page flipping needs
 * an active CRTC, and the card has no render node - the first opener of /dev/dri/
 * card0 holds DRM master and every later opener is refused the modesetting ioctls.
 * So "set the mode" and "flip the capture buffer" must be the same process, and a
 * background modetest would only lock this tool out.  The first presented buffer is
 * therefore handed to drmModeSetCrtc(), which means frame 1 is already a captured
 * frame rather than a test pattern.
 *
 * What "passed" means here, and what it does not: a pass means the exporter gave a
 * dmabuf fd, the DRM driver imported it, an FB was built over it with the pitch the
 * exporter reported, a mode was set, and page flips completed with vblank events.
 * It says nothing about whether the pixels are the right colours - an R/B exchange
 * (the HAS_BGRX8/HAS_RGBX8 mistake this round nearly shipped) is invisible to
 * everything in this file, and the capture fourcc ("XB24") and the plane fourcc
 * ("AB24"/"AR24") are deliberately different codes over the same three colour
 * bytes.  Colour identity is measured separately against a known source.
 *
 * Failure is reported with the name of the call that failed and never recovered
 * from by retry: a rejected import means the geometry or the format does not match,
 * and looping on it hides that.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <drm.h>
#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include <linux/videodev2.h>

#define NBUF        4
#define MAX_PLANE   1       /* the RGBX writer has exactly one memory plane */

/* 32 bpp fourccs in preference order, capture side and display side.  The two
 * lists overlap on purpose: "XB24" is what the frmbuf writer's "xbgr8888" is in
 * V4L2, and "AB24"/"AR24" is what v_frmbuf_rd_rgb's "abgr8888"/"argb8888" is in
 * DRM.  Both name the same R,G,B bytes in memory. */
static const uint32_t disp_pref[] = {
    DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888,
    DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888,
};
static const uint32_t cap_pref[] = {
    V4L2_PIX_FMT_XBGR32, V4L2_PIX_FMT_ABGR32,
    V4L2_PIX_FMT_ARGB32, V4L2_PIX_FMT_XRGB32,
};

static volatile int flip_seen;

/* libdrm's page-flip callback signature: (fd, frame, tv_sec, tv_usec, user). */
static void on_flip(int fd, unsigned int frame, unsigned int tv_sec,
                    unsigned int tv_usec, void *user)
{
    (void)fd; (void)frame; (void)tv_sec; (void)tv_usec; (void)user;
    flip_seen++;
}

static const char *fourcc_str(uint32_t f, char out[5])
{
    out[0] = (f >> 0) & 0xff;
    out[1] = (f >> 8) & 0xff;
    out[2] = (f >> 16) & 0xff;
    out[3] = (f >> 24) & 0xff;
    out[4] = 0;
    return out;
}

static uint32_t parse_fourcc(const char *s)
{
    if (strlen(s) != 4) return 0;
    return (uint32_t)(uint8_t)s[0] | ((uint32_t)(uint8_t)s[1] << 8) |
           ((uint32_t)(uint8_t)s[2] << 16) | ((uint32_t)(uint8_t)s[3] << 24);
}

static void msleep(unsigned ms)
{
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

struct buf {
    int      fd;        /* exported dmabuf, -1 until EXPBUF */
    uint32_t handle;    /* GEM handle, 0 until import */
    uint32_t fb;        /* framebuffer over that handle, 0 until AddFB2 */
    size_t   length;    /* plane-0 length the exporter reports */
};

struct cfg {
    const char *video;
    const char *drm;
    const char *mode_str;
    uint32_t crtc;
    uint32_t conn;
    uint32_t plane;
    uint32_t fourcc;
    uint32_t cap_fourcc;
    int      frames;
    int      hold;
    bool     set_mode;
    bool     no_clear;
    bool     probe_only;
};

int main(int argc, char **argv)
{
    struct cfg cfg = {
        .video = "/dev/video0", .drm = "/dev/dri/card0", .mode_str = NULL,
        .crtc = 0, .conn = 0, .plane = 0, .fourcc = 0, .cap_fourcc = 0,
        .frames = 600, .hold = 0, .set_mode = false, .no_clear = false,
        .probe_only = false,
    };
    struct buf bufs[NBUF] = {{0}};
    struct v4l2_capability cap = {0};
    struct v4l2_format fmt = {0};
    enum v4l2_buf_type btype = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int vid = -1, drm = -1, rc = 1;
    int presented = 0, flips_done = 0, nbufs = 0, streaming = 0;
    uint32_t w = 0, h = 0, pitch = 0, cap_cc = 0, disp_cc = 0;
    char fcc[5];
    drmModeRes *res = NULL;
    drmModeConnector *conn = NULL;
    drmModePlaneRes *pres = NULL;
    drmModePlane *plane = NULL;
    drmModeModeInfo *mode = NULL;
    bool mode_set = false;
    int fail = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if      (!strcmp(a, "--video"))     cfg.video = argv[++i];
        else if (!strcmp(a, "--drm"))       cfg.drm = argv[++i];
        else if (!strcmp(a, "--mode"))      { cfg.mode_str = argv[++i]; cfg.set_mode = true; }
        else if (!strcmp(a, "--set-mode"))  cfg.set_mode = true;
        else if (!strcmp(a, "--crtc"))      cfg.crtc = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--conn"))      cfg.conn = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--plane"))     cfg.plane = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "--fourcc"))    cfg.fourcc = parse_fourcc(argv[++i]);
        else if (!strcmp(a, "--cap-fourcc")) cfg.cap_fourcc = parse_fourcc(argv[++i]);
        else if (!strcmp(a, "--frames"))    cfg.frames = atoi(argv[++i]);
        else if (!strcmp(a, "--hold"))      cfg.hold = atoi(argv[++i]);
        else if (!strcmp(a, "--no-clear"))  cfg.no_clear = true;
        else if (!strcmp(a, "--probe-only")) cfg.probe_only = true;
        else {
            fprintf(stderr,
                "usage: %s [--video P] [--drm P] [--set-mode|--mode WxH[@Hz]]\n"
                "          [--crtc N] [--conn N] [--plane N] [--fourcc ABCD]\n"
                "          [--cap-fourcc ABCD] [--frames N] [--hold S] [--no-clear]\n"
                "          [--probe-only]\n", argv[0]);
            return 2;
        }
    }
    for (int i = 0; i < NBUF; i++) bufs[i].fd = -1;

    /* ---- capture node: caps only, no format change before the sink is known - */
    vid = open(cfg.video, O_RDWR | O_CLOEXEC);
    if (vid < 0) { fprintf(stderr, "FAIL open %s: %s\n", cfg.video, strerror(errno)); return 1; }
    if (ioctl(vid, VIDIOC_QUERYCAP, &cap)) {
        fprintf(stderr, "FAIL VIDIOC_QUERYCAP %s: %s\n", cfg.video, strerror(errno));
        goto out;
    }
    uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps
                                                              : cap.capabilities;
    if (!(caps & V4L2_CAP_STREAMING)) {
        fprintf(stderr, "FAIL %s does not stream (caps 0x%x)\n", cfg.video, caps);
        goto out;
    }
    if (caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE) btype = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    else if (!(caps & V4L2_CAP_VIDEO_CAPTURE)) {
        fprintf(stderr, "FAIL %s is not a capture node (caps 0x%x)\n", cfg.video, caps);
        goto out;
    }
    bool multi = btype == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    printf("CAPTURE %s driver=%s card=%s bus=%s multiplane=%d caps=0x%x\n",
           cfg.video, cap.driver, cap.card, cap.bus_info, multi, caps);

    /* ---- display side ------------------------------------------------------ */
    drm = open(cfg.drm, O_RDWR | O_CLOEXEC);
    if (drm < 0) { fprintf(stderr, "FAIL open %s: %s\n", cfg.drm, strerror(errno)); goto out; }
    if (drmSetClientCap(drm, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)) {
        fprintf(stderr, "FAIL DRM_CLIENT_CAP_UNIVERSAL_PLANES: %s\n", strerror(errno));
        goto out;
    }
    res = drmModeGetResources(drm);
    if (!res) { fprintf(stderr, "FAIL drmModeGetResources: %s\n", strerror(errno)); goto out; }

    /* A sink is a precondition, not a nice-to-have: with HPD low this persona's
     * driver reports disconnected and adds no modes, so there is nothing to set
     * and a modeset attempt is a guaranteed failure.  Saying BLOCKED_NO_SINK here
     * is the honest answer; it is not evidence about the capture path. */
    if (cfg.conn) {
        conn = drmModeGetConnector(drm, cfg.conn);
        if (conn && (conn->connection != DRM_MODE_CONNECTED || conn->count_modes == 0)) {
            printf("CONNECTOR id=%u connection=%d modes=%d (not usable)\n",
                   conn->connector_id, conn->connection, conn->count_modes);
            drmModeFreeConnector(conn);
            conn = NULL;
        }
    } else {
        for (int i = 0; i < res->count_connectors && !conn; i++) {
            drmModeConnector *c = drmModeGetConnector(drm, res->connectors[i]);
            if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) conn = c;
            else if (c) {
                printf("CONNECTOR id=%u connection=%d modes=%d (skipped)\n",
                       c->connector_id, c->connection, c->count_modes);
                drmModeFreeConnector(c);
            }
        }
    }
    if (!conn) {
        printf("SC7F0_DMABUF_LOOP_BLOCKED_NO_SINK connector=%u "
               "reason=no connected connector with a mode\n", cfg.conn);
        rc = 3;
        goto out;
    }
    printf("CONNECTOR id=%u type=%d connection=%d modes=%d encoders=%d\n",
           conn->connector_id, conn->connector_type, conn->connection,
           conn->count_modes, conn->count_encoders);

    /* Mode selection is read off the connector, never invented: this driver only
     * publishes the modes its EDID/mode list actually carries. */
    for (int i = 0; i < conn->count_modes; i++)
        printf("  MODE[%d] %s %dHz type=0x%x\n", i, conn->modes[i].name,
               conn->modes[i].vrefresh, conn->modes[i].type);
    if (cfg.mode_str) {
        for (int i = 0; i < conn->count_modes && !mode; i++) {
            char want[32];
            if (strchr(cfg.mode_str, '@'))
                snprintf(want, sizeof want, "%s", cfg.mode_str);
            else
                snprintf(want, sizeof want, "%s-60", cfg.mode_str);
            if (!strcmp(conn->modes[i].name, want)) mode = &conn->modes[i];
        }
        if (!mode) {
            printf("FAIL no connector mode matches \"%s\" (see MODE[] above)\n",
                   cfg.mode_str);
            goto out;
        }
    } else {
        mode = &conn->modes[0];
    }
    w = mode->hdisplay;
    h = mode->vdisplay;

    pres = drmModeGetPlaneResources(drm);
    if (!pres) { fprintf(stderr, "FAIL drmModeGetPlaneResources: %s\n", strerror(errno)); goto out; }

        /* Pick a CRTC the connector can drive and the plane can be attached to. */
    uint32_t use_crtc = cfg.crtc;
    if (!use_crtc) {
        for (int i = 0; i < res->count_crtcs; i++) {
            if (conn->encoder_id) {
                drmModeEncoder *enc = drmModeGetEncoder(drm, conn->encoder_id);
                if (enc) {
                    /* libdrm's encoder field is possible_crtcs; the kernel-side
                     * DRM struct calls the same thing crtc_mask. */
                    int ok = (enc->possible_crtcs >> i) & 1;
                    drmModeFreeEncoder(enc);
                    if (!ok) continue;
                }
            }
            use_crtc = res->crtcs[i];
            break;
        }
    }
    if (!use_crtc) { fprintf(stderr, "FAIL no CRTC available for connector %u\n", conn->connector_id); goto out; }

    /* Plane selection: a plane that can attach to that CRTC and advertises a 32 bpp
     * format.  Preference order follows disp_pref so Plane A (the frmbuf reader)
     * wins over anything else with the same depth. */
    if (!cfg.plane) {
        uint32_t best = 0, best_rank = 99;
        for (uint32_t i = 0; i < pres->count_planes; i++) {
            drmModePlane *p = drmModeGetPlane(drm, pres->planes[i]);
            if (!p) continue;
            uint32_t crtc_bit = 0;
            for (int c = 0; c < res->count_crtcs; c++)
                if (res->crtcs[c] == use_crtc) crtc_bit = 1u << c;
            if (crtc_bit && !(p->possible_crtcs & crtc_bit)) { drmModeFreePlane(p); continue; }
            for (uint32_t f = 0; f < p->count_formats; f++) {
                for (uint32_t r = 0; r < sizeof disp_pref / sizeof *disp_pref; r++) {
                    if (p->formats[f] == disp_pref[r] && r < best_rank) {
                        best_rank = r;
                        best = p->plane_id;
                    }
                }
            }
            drmModeFreePlane(p);
        }
        cfg.plane = best;
    }
    if (!cfg.plane) {
        printf("FAIL no plane advertising a 32bpp format on CRTC %u; "
               "--plane and --fourcc are available\n", use_crtc);
        goto out;
    }
    plane = drmModeGetPlane(drm, cfg.plane);
    if (!plane) { fprintf(stderr, "FAIL drmModeGetPlane %u: %s\n", cfg.plane, strerror(errno)); goto out; }
    if (cfg.fourcc) {
        bool supported = false;
        for (uint32_t f = 0; f < plane->count_formats; f++)
            if (plane->formats[f] == cfg.fourcc) supported = true;
        if (!supported) {
            printf("FAIL plane %u does not advertise %s (formats:",
                   cfg.plane, fourcc_str(cfg.fourcc, fcc));
            for (uint32_t f = 0; f < plane->count_formats; f++)
                printf(" %s", fourcc_str(plane->formats[f], fcc));
            printf(")\n");
            goto out;
        }
        disp_cc = cfg.fourcc;
    } else {
        for (uint32_t r = 0; r < sizeof disp_pref / sizeof *disp_pref && !disp_cc; r++)
            for (uint32_t f = 0; f < plane->count_formats; f++)
                if (plane->formats[f] == disp_pref[r]) { disp_cc = disp_pref[r]; break; }
    }
    printf("PLANE id=%u crtc_id=%u fb_id=%u possible_crtcs=0x%x fourcc=%s formats=",
           plane->plane_id, plane->crtc_id, plane->fb_id, plane->possible_crtcs,
           fourcc_str(disp_cc, fcc));
    for (uint32_t f = 0; f < plane->count_formats; f++) printf(" %s", fourcc_str(plane->formats[f], fcc));
    printf("\n");
    if (!disp_cc) { fprintf(stderr, "FAIL no usable display fourcc\n"); goto out; }

    if (cfg.probe_only) {
        printf("SC7F0_DMABUF_LOOP_PROBE video=%s plane=%u crtc=%u connector=%u "
               "mode=%s %ux%u display_fourcc=%s\n", cfg.video, cfg.plane, use_crtc,
               conn->connector_id, mode->name, w, h, fourcc_str(disp_cc, fcc));
        rc = 0;
        goto out;
    }
    if (!cfg.set_mode && !plane->crtc_id) {
        /* A page flip on an inactive CRTC is EINVAL, and the only way to activate
         * it is DRM master, which this process holds and a modetest would not
         * share.  Refusing here is the honest answer, with the fix named. */
        printf("SC7F0_DMABUF_LOOP_NO_ACTIVE_MODE plane=%u crtc=%u "
               "hint=pass --set-mode or --mode WxH@Hz\n", cfg.plane, use_crtc);
        rc = 5;
        goto out;
    }

    /* ---- configure the capture to the mode we are about to display --------- */
    fmt.type = btype;
    if (multi) {
        fmt.fmt.pix_mp.width = w; fmt.fmt.pix_mp.height = h;
        fmt.fmt.pix_mp.field = V4L2_FIELD_NONE; fmt.fmt.pix_mp.num_planes = MAX_PLANE;
        fmt.fmt.pix_mp.pixelformat = cfg.cap_fourcc ? cfg.cap_fourcc : cap_pref[0];
    } else {
        fmt.fmt.pix.width = w; fmt.fmt.pix.height = h;
        fmt.fmt.pix.field = V4L2_FIELD_NONE;
        fmt.fmt.pix.pixelformat = cfg.cap_fourcc ? cfg.cap_fourcc : cap_pref[0];
    }
    if (ioctl(vid, VIDIOC_S_FMT, &fmt)) {
        fprintf(stderr, "FAIL VIDIOC_S_FMT %ux%u %s: %s "
                        "(the media graph must be configured first)\n", w, h,
                fourcc_str(multi ? fmt.fmt.pix_mp.pixelformat : fmt.fmt.pix.pixelformat,
                           fcc), strerror(errno));
        goto out;
    }
    cap_cc = multi ? fmt.fmt.pix_mp.pixelformat : fmt.fmt.pix.pixelformat;
    pitch = multi ? fmt.fmt.pix_mp.plane_fmt[0].bytesperline : fmt.fmt.pix.bytesperline;
    uint32_t sizeimage = multi ? fmt.fmt.pix_mp.plane_fmt[0].sizeimage : fmt.fmt.pix.sizeimage;
    uint32_t got_w = multi ? fmt.fmt.pix_mp.width : fmt.fmt.pix.width;
    uint32_t got_h = multi ? fmt.fmt.pix_mp.height : fmt.fmt.pix.height;
    if (got_w != w || got_h != h || pitch == 0) {
        fprintf(stderr, "FAIL capture negotiated %ux%u pitch=%u, wanted %ux%u\n",
                got_w, got_h, pitch, w, h);
        goto out;
    }
    printf("CAPTURE_FMT %ux%u pitch=%u sizeimage=%u fourcc=%s (%s)\n", got_w, got_h,
           pitch, sizeimage, fourcc_str(cap_cc, fcc),
           cap_cc == disp_cc ? "same code as the plane" :
           "DIFFERENT code from the plane; both are 32bpp over R,G,B - colour identity is measured separately");

    /* ---- allocate, export, queue, stream ---------------------------------- */
    struct v4l2_requestbuffers req = { .count = NBUF, .type = btype,
                                       .memory = V4L2_MEMORY_MMAP };
    if (ioctl(vid, VIDIOC_REQBUFS, &req)) {
        fprintf(stderr, "FAIL VIDIOC_REQBUFS: %s\n", strerror(errno)); goto out;
    }
    nbufs = (int)req.count;
    if (nbufs < 2) { fprintf(stderr, "FAIL only %d capture buffers\n", nbufs); goto out; }

    for (int i = 0; i < nbufs; i++) {
        struct v4l2_plane planes[MAX_PLANE] = {{0}};
        struct v4l2_buffer b = { .type = btype, .memory = V4L2_MEMORY_MMAP,
                                 .index = (uint32_t)i };
        if (multi) { b.length = MAX_PLANE; b.m.planes = planes; }
        if (ioctl(vid, VIDIOC_QUERYBUF, &b)) {
            fprintf(stderr, "FAIL VIDIOC_QUERYBUF[%d]: %s\n", i, strerror(errno)); goto out;
        }
        bufs[i].length = multi ? planes[0].length : b.length;
        if (bufs[i].length < sizeimage) {
            fprintf(stderr, "FAIL buffer %d length %zu < sizeimage %u\n",
                    i, bufs[i].length, sizeimage);
            goto out;
        }
        struct v4l2_exportbuffer eb = { .type = btype, .index = (uint32_t)i,
                                        .plane = 0, .flags = O_CLOEXEC | O_RDWR };
        if (ioctl(vid, VIDIOC_EXPBUF, &eb)) {
            fprintf(stderr, "FAIL VIDIOC_EXPBUF[%d]: %s (zero copy needs EXPBUF)\n",
                    i, strerror(errno));
            goto out;
        }
        if (eb.fd < 0) { fprintf(stderr, "FAIL EXPBUF[%d] returned fd %d\n", i, eb.fd); goto out; }
        bufs[i].fd = (int)eb.fd;
        printf("EXPBUF[%d] fd=%d length=%zu\n", i, bufs[i].fd, bufs[i].length);
        /* Buffers must be queued before STREAMON; a DQBUF on a stream that never
         * had a buffer handed to it blocks forever. */
        if (ioctl(vid, VIDIOC_QBUF, &b)) {
            fprintf(stderr, "FAIL VIDIOC_QBUF[%d]: %s\n", i, strerror(errno)); goto out;
        }
    }
    if (ioctl(vid, VIDIOC_STREAMON, &btype)) {
        fprintf(stderr, "FAIL VIDIOC_STREAMON: %s\n", strerror(errno)); goto out;
    }
    streaming = 1;

    for (int n = 0; n < cfg.frames && !fail; n++) {
        struct v4l2_plane planes[MAX_PLANE] = {{0}};
        struct v4l2_buffer bq = { .type = btype, .memory = V4L2_MEMORY_MMAP };
        if (multi) { bq.length = MAX_PLANE; bq.m.planes = planes; }

        struct pollfd pfd_v = { .fd = vid, .events = POLLIN };
        int pr = poll(&pfd_v, 1, 3000);
        if (pr <= 0) {
            printf("FAIL no capture buffer within 3 s at frame %d "
                   "(no RX timing, or the writer is not started)\n", n);
            fail = 1;
            break;
        }
        if (ioctl(vid, VIDIOC_DQBUF, &bq)) {
            fprintf(stderr, "FAIL VIDIOC_DQBUF: %s\n", strerror(errno)); fail = 1; break;
        }
        uint32_t idx = bq.index;
        if ((int)idx >= nbufs || bufs[idx].fd < 0) {
            fprintf(stderr, "FAIL dequeued index %u has no exported fd\n", idx);
            fail = 1; break;
        }

        if (!bufs[idx].handle) {
            if (drmPrimeFDToHandle(drm, bufs[idx].fd, &bufs[idx].handle)) {
                fprintf(stderr, "FAIL drmPrimeFDToHandle(fd=%d): %s\n",
                        bufs[idx].fd, strerror(errno));
                fail = 1; break;
            }
        }
        if (!bufs[idx].fb) {
            uint32_t handles[4] = { bufs[idx].handle, 0, 0, 0 };
            uint32_t pitches[4] = { pitch, 0, 0, 0 };
            uint32_t offsets[4] = { 0, 0, 0, 0 };
            if (drmModeAddFB2(drm, w, h, disp_cc, handles, pitches, offsets,
                              &bufs[idx].fb, 0)) {
                fprintf(stderr, "FAIL drmModeAddFB2 %ux%u %s pitch=%u: %s\n",
                        w, h, fourcc_str(disp_cc, fcc), pitch, strerror(errno));
                fail = 1; break;
            }
        }

        int got = 0;
        if (!mode_set) {
            /* The first presented buffer IS the mode-set framebuffer, so the panel
             * never shows anything but captured pixels. */
            if (drmModeSetCrtc(drm, use_crtc, bufs[idx].fb, 0, 0,
                               &conn->connector_id, 1, mode)) {
                fprintf(stderr, "FAIL drmModeSetCrtc crtc=%u fb=%u mode=%s: %s\n",
                        use_crtc, bufs[idx].fb, mode->name, strerror(errno));
                fail = 1; break;
            }
            mode_set = true;
        } else {
            if (drmModePageFlip(drm, use_crtc, bufs[idx].fb,
                                DRM_MODE_PAGE_FLIP_EVENT, NULL)) {
                fprintf(stderr, "FAIL drmModePageFlip crtc=%u fb=%u: %s\n",
                        use_crtc, bufs[idx].fb, strerror(errno));
                fail = 1; break;
            }
            struct pollfd pfd_d = { .fd = drm, .events = POLLIN };
            for (int t = 0; t < 20 && !got; t++) {
                if (poll(&pfd_d, 1, 250) > 0) {
                    drmEventContext ev = {0};
                    ev.version = DRM_EVENT_CONTEXT_VERSION;
                    ev.page_flip_handler = on_flip;
                    if (drmHandleEvent(drm, &ev) == 0 && flip_seen) got = 1;
                }
            }
            if (got) flips_done++;
        }
        presented++;
        if (ioctl(vid, VIDIOC_QBUF, &bq)) {
            fprintf(stderr, "FAIL VIDIOC_QBUF after present: %s\n", strerror(errno));
            fail = 1; break;
        }
        if ((n % 60) == 0)
            printf("FRAME %d idx=%u fb=%u flip_event=%d\n", n, idx, bufs[idx].fb, got);
    }

    if (cfg.hold > 0 && mode_set) {
        printf("HOLD %d s (last captured frame stays on HDMI OUT)\n", cfg.hold);
        for (int s = 0; s < cfg.hold; s++) msleep(1000);
    }

    printf("SC7F0_DMABUF_LOOP frames=%d presented=%d flip_events=%d mode_set=%d "
           "plane=%u crtc=%u mode=%s cap_fourcc=%s disp_fourcc=%s %ux%u pitch=%u\n",
           cfg.frames, presented, flips_done, mode_set, cfg.plane, use_crtc,
           mode->name, fourcc_str(cap_cc, fcc), fourcc_str(disp_cc, fcc), w, h, pitch);
    if (!fail && presented > 0 && mode_set && flips_done * 2 >= presented) {
        printf("SC7F0_DMABUF_LOOP_PASS (buffer import + modeset + page flip completed; "
               "colour correctness is a separate measurement)\n");
        rc = 0;
    } else {
        printf("SC7F0_DMABUF_LOOP_INCOMPLETE presented=%d flip_events=%d mode_set=%d\n",
               presented, flips_done, mode_set);
        rc = 4;
    }

out:
    if (streaming) {
        enum v4l2_buf_type off = btype;
        if (ioctl(vid, VIDIOC_STREAMOFF, &off))
            fprintf(stderr, "note: VIDIOC_STREAMOFF: %s\n", strerror(errno));
    }
    if (drm >= 0) {
        for (int i = 0; i < NBUF; i++) {
            if (bufs[i].fb) drmModeRmFB(drm, bufs[i].fb);
            /* The handles came from imported dmabufs, not dumb buffers, so they are
             * released with the GEM close ioctl rather than a dumb-buffer destroy. */
            if (bufs[i].handle && drmCloseBufferHandle(drm, bufs[i].handle))
                fprintf(stderr, "note: drmCloseBufferHandle(%u): %s\n",
                        bufs[i].handle, strerror(errno));
        }
        if (mode_set && !cfg.no_clear) {
            if (drmModeSetCrtc(drm, use_crtc, 0, 0, 0, &conn->connector_id, 0, NULL))
                fprintf(stderr, "note: drmModeSetCrtc clear: %s\n", strerror(errno));
            else
                printf("MODE_CLEARED crtc=%u\n", use_crtc);
        }
    }
    for (int i = 0; i < NBUF; i++) if (bufs[i].fd >= 0) close(bufs[i].fd);
    if (plane) drmModeFreePlane(plane);
    if (pres) drmModeFreePlaneResources(pres);
    if (conn) drmModeFreeConnector(conn);
    if (res) drmModeFreeResources(res);
    if (vid >= 0) close(vid);
    if (drm >= 0) close(drm);
    return rc;
}
