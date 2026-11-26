# Host KMS graphics-plane test

Build on the x86 host with `make -C test_app sc7f0_kms` (requires
`pkg-config` and `libdrm-dev`). Use the primary DRM node for the **dedicated
SC7F0 host frontend** with modesetting access. Select it explicitly, e.g. via
its PCI by-path link; the client never scans `/dev/dri` for an alternative.

```sh
NODE=/dev/dri/by-path/pci-0000:03:00.0-card   # verify host BDF
test_app/sc7f0_kms "$NODE" --manual 3000
test_app/sc7f0_kms "$NODE" --script 3000
test_app/sc7f0_kms "$NODE"                   # live until q or stdin EOF
```

In manual validation, wait for the log prompt after the initial A hold, then
type `B` and Return within 30 s. Script mode supplies that input itself. In
both modes `IDLE_MS` (1–600000) is the hold time for each of A, B and E.
Capture the HDMI output independently and retain stdout/stderr with it.
Expected log and output:

1. A flips once and remains visible with no submissions during the hold.
2. B flips for the single input and remains visible for the second hold.
3. C is submitted; D then E arrive before the client consumes C's completion.
   Only E is submitted after C. C may be brief; D should never be visible.
4. E holds, then `id=- fb=0` disables graphics and the final event is consumed.
   Check that the underlying HDMI picture remains, with no stale letter/panel.

Each letter is opaque white on a half-transparent **straight** red panel;
the rest of the framebuffer is transparent. `mono_ms` is local monotonic
time; `seq` and `drm_time` are the event sequence and timestamp supplied by
the driver. Event delivery alone does not establish hardware latch timing,
correct blending or correct scanout. For open-ended operation type A–E and
Return to change the ID; repeated identical input causes no redraw. No FPS
timer is used. EOF or `q` requests disable after any outstanding flip.

The dedicated node must expose one connected logical output, a routable
CRTC, a non-cursor ABGR8888 plane accepting a linear dumb FB, and standard
atomic properties. Overlay is preferred to primary. If exposed, pixel blend
mode must support `Coverage`; without that property the frontend must
implement fixed straight-alpha blending. An active routed mode is reused;
otherwise the preferred (or first) mode is enabled with A. Disable detaches
the plane and turns off the logical pipeline if the client activated it or
used its primary plane. This client does not restore another application's
display state. The logical output is expected to be separate from physical
HDMI timing. A rejected ioctl, lost fd or missing completion (5 s deadline)
terminates the run; the process never recycles a possibly in-flight buffer.

**Offline check** (development machine):

```sh
cc -O2 -Wall -Wextra -std=c11 $(pkg-config --cflags libdrm) \
  test_app/tests/sc7f0_kms_state.c -Wl,--wrap=drmModeAtomicCommit \
  $(pkg-config --libs libdrm) -o /tmp/opencode/sc7f0-kms-state
/tmp/opencode/sc7f0-kms-state
```

This injects flip records through a pipe and checks idle, buffer ownership,
coalescing, alpha bytes, pitch padding, disable and the lost-event path. It
does not exercise DRM discovery, real ioctls or HDMI hardware.
