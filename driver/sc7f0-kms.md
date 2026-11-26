# SC7F0 host logical KMS output

`qpcie.ko` has a bind-time `kms=1` profile for the [direct-pull v1
ABI](../docs/sc7f0_direct_pull_v1.md). Default `kms=0` keeps the legacy
interfaces. KMS selects only the **overlay** frontend. HDMI/raw and VCU
V4L2 channels, ALSA, sysfs and the debug/upgrade interfaces use the normal
PCI probe and shared MSI. Source 9 wakes the flip worker; the common IRQ
handler acknowledges TOP after dispatch. No second vector, DMA mask or
PCI bus-master lifetime is owned by DRM. Bind-time selection excludes
legacy overlay ioctls and surviving legacy VMAs from a second plane owner;
the GEM fd maps only its buffers. Module parameter `kms` is read-only.

The gate requires the canonical ID, C2H/RGB capabilities, RGB1 ID, v1
signature, **0x26112407**, inactive engines and a positive drain. 05/06
advertised the same signature without the persistent admission/epoch-poison
contract. Other versions get no DRM node. A busy v1 engine is not reset to
force a bind. This version gate is not evidence of a routed/deployed image.

### Ownership, maintenance and capture

* Read-only control/status remains available while displaying. The first
  destructive management operation (debug mailbox write including arbitrary
  PS exec, HPD/EDID pulse, or upgrade write) competes atomically with the
  first display commit or media open. Read-only debug status needs neither.
  A V4L2 file (QBUF may arm before STREAMON) or open ALSA PCM holds a media
  lease; those leases coexist with each other and with display. Management
  gets `EBUSY` until the last media close and verified plane disable,
  including producer-fence wait. If maintenance wins, it
  owns the rest of the bind. Closing a debug fd is not proof that a PS child
  stopped. Quarantine rejects management too. Prepare the independent base
  before the display run; no independent PS writer may touch overlay CSRs.
* The ordinary build and `kms=0` bind keep the supported `resource0` flash
  workflow and have no new KMS management restrictions. Complete a normal
  disable and unload the display module before running the standard flash
  workflow. The normal `make -C driver` used by that workflow deliberately
  builds without a `drm_dma_helper` dependency for direct `insmod`.
* On a matching display bind, before probe reset, request exclusive regions,
  deactivate PCI sysfs BAR0/1 and WC aliases, and zap existing PTEs for those
  exact ranges in the common x86 iomem mapping. A writable resource fd
  opened before bind cannot remap through the removed kernfs node. Restore
  aliases on clean teardown. Raw physical access must also be excluded:
  `/dev/mem` absent, kernel lockdown blocking it, or `CONFIG_STRICT_DEVMEM`
  with **effective strict iomem policy**. `CONFIG_STRICT_DEVMEM=y` enables
  this by default for our busy, explicitly exclusive BARs, including with
  `CONFIG_IO_STRICT_DEVMEM=n`. An unambiguous `iomem=strict` is also accepted;
  relaxed, duplicate or unrecognized policy withholds DRM. The gate accepts
  only simple unquoted kernel arguments before `--`. Finish out-of-band accesses
  before bind. This is driver arbitration, not isolation from a hostile
  host kernel, independently controlled PCI config writes or a PS shell.
* HDMI raw STREAMOFF first disables channel 0, then requires both requester
  and descriptor idle. On clean drain it rebases that channel's rings but
  does not reset the shared engine. VCU retains its independent stop path.
  A raw drain timeout stops KMS admission and fences the plane **before**
  attempting capture recovery. If the overlay cannot drain, its mappings
  stay pinned and BME is cleared; no shared reset is used to reclaim them.
  If capture retirement is also ambiguous, STREAMOFF retains its queue
  until config readback + PCI pending drain + ordered endpoint readback, or
  PCI-core disconnect. There is no time-only fallback to return USERPTRs.

One connected virtual connector, one CRTC and one primary support only
3840×2160, 15,360-byte pitch, zero offset, linear `DRM_FORMAT_ABGR8888`,
fullscreen, fixed straight-alpha coverage. The advertised 60 Hz timing
describes the logical mode; it does not change HDMI clocks or pace commits.
DMA addresses come from GEM DMA on the PCI device. A 33,177,600-byte
contiguous device address range must be allocatable.

* One commit slot. A second nonblocking commit gets `EBUSY` before state
  swap; a blocking one waits. No software overwrite/coalescing in the driver.
* DRM's GEM prepare step collects producer fences. NONBLOCK waits in work
  context before publishing the descriptor. The submitted cookie is checked
  against hardware admission. Once presented, replay needs no host submit.
* MSI source 9 wakes the worker. Only the matching active cookie with no
  pending cookie proves presentation at the blender output. SOF counts, DMA
  completion and elapsed time are not presentation. The event uses the
  counter and monotonic time **observed** at confirmation; v1 does not latch
  the exact SOF timestamp alongside the cookie. The old FB must also have
  matching retirement before the event is delivered and it may be reused.
* Turning the logical CRTC off completes after blend bypass, disable and
  verified drain with unchanged admission high-water mark. This final KMS
  event means *logical disable complete*, not proof of a base-only pixel at
  the physical sink. Observe HDMI independently.
* A producer error, three-second producer/presentation timeout, fault or
  ambiguous admission fails the session. Unpresented commits get no success
  event: blocking callers receive the error; event pollers get `POLLERR` and
  an out-fence, if requested, signals error. Only off/cleanup is allowed
  after failure. No timeout releases DMA references. If detach cannot prove
  drain, BME is cleared and the device, module and uncertain FBs stay pinned.
* Cookies start above `FLIP_ADMITTED`, never wrap and reserve all-ones for
  dead BAR reads. Frozen 07 retains that high-water across PCIe reset and
  poisons an epoch that admitted any descriptor, including a drained one.
  Only full PL configuration restarts the namespace; it is not a DMA fence.
  PCI `reset_prepare` stops the binding before reset; an unproven pre-reset
  drain remains quarantined even if post-reset registers look idle.

## Local verification (no device access)

```sh
make -C driver QPCIE_KMS=1 -j8
modinfo driver/qpcie.ko
cc -std=gnu11 -Wall -Wextra -Werror -Idriver/tests/mock \
  driver/tests/kms_v1.c -o /tmp/opencode/qpcie-kms-v1
/tmp/opencode/qpcie-kms-v1
cc -std=gnu11 -Wall -Wextra -Werror -pthread driver/tests/kms_gate.c \
  -o /tmp/opencode/qpcie-kms-gate
/tmp/opencode/qpcie-kms-gate
```

`make -C driver QPCIE_KMS=0` builds without a DRM helper dependency.
The fake-MMIO test exercises the production backend, including asynchronous
presentation vs retirement, a missing base despite frame interrupts, reset,
and refused/rejected transfers. It does not load the kernel module.

The race test exercises the production ownership transitions. Neither test
executes DRM ioctls or proves hardware timing. Build on the actual host and
load `drm_dma_helper` as a dependency for the optional module.

Next integration checks are the [real client](../test_app/sc7f0_kms.md)
concurrently with raw/VCU capture, stopping each capture during a held FB,
refusal of pre-existing raw-map and maintenance writes during a flip,
an unsignaled/failed `IN_FENCE_FD`, a second NONBLOCK while pending, source
loss, and unbind with live GEM mappings. Baseline compatibility, real IRQs,
DMA isolation, blend and sink timing require the serialized board run.
