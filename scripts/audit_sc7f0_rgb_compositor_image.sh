#!/usr/bin/env bash
# audit_sc7f0_rgb_compositor_image.sh - verify a built PS image against the
# SC7F0-RGB-COMPOSITOR-2PPC (PL base 0x26111405) contract, WITHOUT touching the
# card.
#
#   audit_sc7f0_rgb_compositor_image.sh --images <dir with system.dtb and
#                                                         rootfs.cpio.gz>
#
# Device-tree checks parse the decompiled DTB numerically instead of grepping
# for one dtc text style: dtc 1.6.1 prints cells as <0x00 0xb0080000> while the
# common.dtsi that ships in this BSP was written against a dtc that printed
# <0 89 4>, and a text grep silently misjudges one of the two.  The numbers are
# what the card will use, so the numbers are what gets compared.
set -euo pipefail
IMAGES=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --images) IMAGES=$(readlink -f "$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -f $IMAGES/system.dtb && -f $IMAGES/rootfs.cpio.gz ]] || {
    echo "--images must contain system.dtb and rootfs.cpio.gz" >&2; exit 2; }
IMAGES=$IMAGES \
SC7F0_IRQ_FRMBUF_A=${SC7F0_IRQ_FRMBUF_A:-97} \
SC7F0_IRQ_PLANE_B=${SC7F0_IRQ_PLANE_B:-98} \
SC7F0_IRQ_OVERLAY_CTRL=${SC7F0_IRQ_OVERLAY_CTRL:-99} \
SC7F0_IRQ_HDMI_TX=${SC7F0_IRQ_HDMI_TX:-100} \
SC7F0_IRQ_VPHY=${SC7F0_IRQ_VPHY:-90} \
SC7F0_EXPECT_PHY_PPC=${SC7F0_EXPECT_PHY_PPC:-2} \
SC7F0_EXPECT_PHY_WIDTH=${SC7F0_EXPECT_PHY_WIDTH:-2} \
    python3 - <<'PY'
import os, re, subprocess, sys

IMG = os.environ['IMAGES']
# The four PL->PS IRQ1_F2P SPI numbers depend on which GIC INTID block the
# fabric interrupts land in, which the PS BD export decides: 0x26111405 exported
# them as INTID 129..136 (DT SPI 97..100) and 0x26111501 exports them as
# INTID 136..143 (DT SPI 104..107).  Hard-coding one round silently misjudges
# the other, so they come from the environment; the defaults are the accepted
# 0x26111405 numbers and a new round passes its own.
IRQ_A = int(os.environ.get('SC7F0_IRQ_FRMBUF_A', '97'))
IRQ_B = int(os.environ.get('SC7F0_IRQ_PLANE_B', '98'))
IRQ_CTRL = int(os.environ.get('SC7F0_IRQ_OVERLAY_CTRL', '99'))
IRQ_TX = int(os.environ.get('SC7F0_IRQ_HDMI_TX', '100'))
# phy@b0000000 is hdmi_phy_irq on pl_ps_irq0[1] = GIC INTID 122 = DT SPI 90, so
# it does not move with the IRQ1 block above.
IRQ_VPHY = int(os.environ.get('SC7F0_IRQ_VPHY', '90'))
# GT datapath / pixels-per-clock the shipped tree must describe.  The comment at
# the phy@b0000000 check below records why these two numbers are not cosmetic.
PHY_PPC = os.environ.get('SC7F0_EXPECT_PHY_PPC', '2')
PHY_WIDTH = os.environ.get('SC7F0_EXPECT_PHY_WIDTH', '2')
DTC = next((p for p in ('/opt/Xilinx/Vitis/2023.2/bin/dtc', '/usr/bin/dtc',
                        '/bin/dtc') if os.path.exists(p)), None)
if not DTC:
    sys.exit('dtc not found; cannot audit the device tree')

dts = subprocess.run([DTC, '-I', 'dtb', '-O', 'dts', IMG + '/system.dtb'],
                     capture_output=True, text=True).stdout

def cells(text):
    return [int(x, 0) for x in re.findall(r'0[xX][0-9a-fA-F]+|\d+', text)]

def node_body(name):
    m = re.search(r'\n\s*' + re.escape(name) + r'\s*\{', dts)
    if not m:
        return None
    i = dts.index('{', m.start()) + 1
    depth, start = 1, i
    while i < len(dts) and depth:
        if dts[i] == '{':
            depth += 1
        elif dts[i] == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return dts[start:i]

def node_props(name):
    """Properties of the first node called `name`, at that node's own depth.

    Children are skipped: frame-tap/ports/endpoint carries reg = <0>, and taking
    the last reg in the subtree would report the endpoint instead of the IP.
    """
    body = node_body(name)
    if body is None:
        return None
    props, depth, buf = {}, 0, ''
    for ch in body:
        if ch == '{':
            depth += 1
            buf = ''
            continue
        if ch == '}':
            depth -= 1
            buf = ''
            continue
        if ch == '\n':
            if depth == 0:
                line = buf.strip()
                m = re.match(r'([A-Za-z0-9,_-]+)\s*=\s*(.*)$', line)
                if m:
                    props[m.group(1)] = m.group(2).rstrip(';').strip()
                elif re.fullmatch(r'[A-Za-z0-9,_-]+;', line):
                    props[line[:-1]] = '1'
            buf = ''
            continue
        buf += ch
    return props

fails, soft = [], []
def need(what, ok, fatal=True):
    print(('OK   ' if ok else 'FAIL ') + what)
    if not ok:
        (fails if fatal else soft).append(what)

def reg_cells(name):
    p = node_props(name)
    return cells(p['reg']) if p and 'reg' in p else None

def irq_cells(name):
    p = node_props(name)
    return cells(p['interrupts']) if p and 'interrupts' in p else None

def check_map(name, base, size=None, spi=None, extra=None):
    p = node_props(name)
    need(f'{name} present', p is not None)
    if p is None:
        return
    r = cells(p.get('reg', ''))
    ok = len(r) >= 4 and r[1] == base and (size is None or r[3] == size)
    need(f'{name} maps 0x{base:08x}' + (f' size 0x{size:x}' if size else ''), ok)
    if spi is not None:
        i = cells(p.get('interrupts', ''))
        need(f'{name} interrupt SPI {spi} type {4}',
             len(i) == 3 and i[1] == spi and i[2] == 4)
    for prop, want in (extra or []):
        got = p.get(prop)
        if got is None:
            need(f'{name} {prop} = {want}', False)
            continue
        # A property is numeric (<0x10>) or a string ("AB24"); compare in kind.
        if got.startswith('<'):
            c = cells(got)
            want_n = int(want, 0)
            need(f'{name} {prop} = {want_n}', any(v == want_n for v in c))
        else:
            need(f'{name} {prop} = {want}', want in got)

# --- memory map -------------------------------------------------------------
# Node names come from the petalinux-generated system.dts (it renames the
# IP-replicator instances: frame-tap, vpss-csc, hdmi-tx, hdmi-rx), so the audit
# uses those names rather than the RTL instance names.
check_map('framebuffer@b0080000', 0xb0080000, 0x10000, IRQ_A,
          [('compatible', 'xlnx,axi-frmbuf-rd'),
           ('xlnx,pixels-per-clock', '2'),
           ('xlnx,dma-align', '16')])
check_map('plane-b@b0090000', 0xb0090000, 0x10000, IRQ_B,
          [('compatible', 'yuan,sc7f0-rgb-plane-b'),
           ('reset-gpios', '0x51')])
check_map('overlay-ctrl@b00a0000', 0xb00a0000, 0x1000, IRQ_CTRL,
          [('compatible', 'yuan,sc7f0-rgb-overlay-ctrl')])
check_map('frame-tap@b0070000', 0xb0070000, 0x1000, None,
          [('compatible', 'yuan,sc7f0-frame-tap')])
check_map('vpss-csc@b0060000', 0xb0060000, 0x10000)
check_map('hdmi-tx@b0020000', 0xb0020000, 0x20000, IRQ_TX,
          [('xlnx,input-pixels-per-clock', PHY_PPC),
           ('xlnx,max-bits-per-component', '8')])
check_map('hdmi-rx@b0010000', 0xb0010000, 0x10000, None,
          [('xlnx,input-pixels-per-clock', PHY_PPC),
           ('xlnx,max-bits-per-component', '8')])

# --- the GT datapath width the driver will actually program -----------------
# phy@b0000000 has no XSA/HWH origin at all: vid_phy_controller_rgb is
# instantiated in rtl/zu4ev_pcie_card_top.v, not in the PS block design, so the
# device-tree generator emits nothing for it and every xlnx,* cell below is
# hand-written by sc7f0-hdmi-rx.dtsi (legacy 4PPC values) and re-written here.
# That is how a shipped image came to describe a datapath the fabric does not
# have, and it is not cosmetic:
#   hdmi/phy-vphy.c:408/504  xlnx,input-pixels-per-clock -> XVphy_Config.Ppc,
#                            xlnx,transceiver-width      -> XVphy_Config.TransceiverWidth
#   xvphy_hdmi.c:1838-1848   (TransceiverWidth == 2 || GTPE2) -> RxDataWidth 20 /
#                            RxIntDataWidth 2, anything else -> 40 / 4
#   xvphy_hdmi_intr.c:776    HdmiRxRefClkHz = the clock detector's RX measurement
#   xvphy_hdmi.c:1822        lineRate = HdmiRxRefClkHz * 40 in the 1/40 (HDMI2,
#                            scrambled) branch, from the clock the detector
#                            measured at the GT reference input
#   xvphy_gthe4.c:602-617    those two are written over DRP into GTHE4 RX_DATA_WIDTH
#                            (0x03[8:5]) and RX_INT_DATAWIDTH (0x66[1:0])
#   xvphy_hdmi.c:1170-1320   xlnx,input-pixels-per-clock -> MMCM Mult rounding and the
#                            Clk0Div/Clk1Div choice, i.e. the RX user/video clock
# The 0x26111503 fabric is 2 PPC: the generated channel wrapper carries
# GTHE4_CHANNEL_RX_DATA_WIDTH/TX_DATA_WIDTH = 20 and the RTL carries 24-bit link
# lanes, so a tree that says 4 programs a 40-bit GT datapath whose parallel side
# is wider than the wires that read it.  Measured with the 4/4 tree, with the
# source proven present and the GT locked (PLL_LOCK 0x7, RXSS PIO_IN 0x187,
# CLKDET_FREQ_RX 148.47 MHz), RX_TDLOCK (XVPHY_RX_TDLOCK_REG, 0xB000010C) stayed
# 0 and the RX error counter saturated at 0xFFFF: characters arrived that the
# fabric could not consume.  A wrong width is therefore a necessary condition for
# TDLOCK, not a proven sufficient one - the width-correct images have not yet been
# measurable against a locking GT because the reference clock presented to the GT
# input was 57.08 MHz where the driver's 1/40 branch needs char/4 (148.49 MHz),
# which is a board/MCU-side IT6663 clocking question this gate cannot answer.
# A DTB must still be rejected here rather than discovered on the card.
# The expected numbers are the selected-config values of this round's own IP
# (vid_phy_controller_rgb.xci: C_INPUT_PIXELS_PER_CLOCK=2, Transceiver_Width=2;
# v_hdmi_rx_ss_rgb / v_hdmi_tx_ss_rgb: C_INPUT_PIXELS_PER_CLOCK=2,
# C_MAX_BITS_PER_COMPONENT=8) and may be re-pointed at another round by
# environment for a bring-up build.
PHY_PPC_WANT = int(os.environ.get('SC7F0_EXPECT_PHY_PPC', PHY_PPC))
PHY_WIDTH_WANT = int(os.environ.get('SC7F0_EXPECT_PHY_WIDTH', PHY_WIDTH))
check_map('phy@b0000000', 0xb0000000, 0x1000, IRQ_VPHY,
          [('compatible', 'xlnx,vid-phy-controller-2.2'),
           ('xlnx,transceiver-type', '5'),      # GTHE4, the driver's enum
           ('xlnx,transceiver-width', str(PHY_WIDTH_WANT)),
           ('xlnx,input-pixels-per-clock', str(PHY_PPC_WANT)),
           ('xlnx,nidru', '1'),
           ('xlnx,rx-no-of-channels', '3'),
           ('xlnx,tx-no-of-channels', '3')])
# transceiver-width is what the GT is programmed to, pixels-per-clock is what
# the fabric and the RX/TX subsystems are built to; letting them disagree is
# the same class of mistake as disagreeing with the netlist, so tie them here.
need('VPHY xlnx,transceiver-width equals xlnx,input-pixels-per-clock '
     '(GT datapath == fabric datapath)',
     PHY_WIDTH_WANT == PHY_PPC_WANT)

disp = node_props('drm-pl-disp-drv') or {}
need('CRTC display plane format is AB24 (RGBA8888) for the DRM pipeline',
     'AB24' in disp.get('xlnx,vformat', ''))

p = node_props('hdmi-tx@b0020000') or {}
need('HDMI TX node carries the dummy retimer-clk (v_hdmi_tx_ss driver requires '
     'a named clock even when C_INCLUDE_RETIMER == 0)',
     'retimer-clk' in p.get('clock-names', ''))

for name, base, size, nomap in (
        ('overlay-pool@54000000', 0x54000000, 128 << 20, True),
        ('cma,display@5c000000', 0x5c000000, 128 << 20, False),
        ('cma,video@40000000', 0x40000000, 256 << 20, False),
        ('cma,qdmabuf@50000000', 0x50000000, 64 << 20, False),
        ('dau_fpga@30000000', 0x30000000, 256 << 20, True)):
    p = node_props(name)
    need(f'reserved-memory {name} present', p is not None)
    if p is None:
        continue
    r = cells(p.get('reg', ''))
    need(f'{name} = 0x{base:08x} + 0x{size:x}',
         len(r) >= 4 and r[1] == base and r[3] == size)
    need(f'{name} no-map == {nomap}', ('no-map' in p) == nomap)

# No region may be described twice: that is exactly what the retired VCU pool
# would have done to the overlay pool.
regions = []
for m in re.finditer(r'\t\t([A-Za-z0-9,._@-]+) \{([^}]*?reg = <[^>]*>)', dts):
    c = cells(m.group(2))
    if len(c) >= 4 and c[0] == 0 and c[1] >= 0x01000000:
        regions.append((c[1], c[3], m.group(1)))
overlap = [(a[2], b[2]) for i, a in enumerate(regions) for b in regions[i+1:]
           if a[0] < b[0] + b[1] and b[0] < a[0] + a[1]]
need(f'reserved-memory regions do not overlap ({len(regions)} regions)',
     not overlap)
need('the retired VCU CMA pool is gone from the generated tree',
     'cma,vcu@' not in dts and not re.search(r'vcu[_-]?(8|64)_?(core|scr)', dts, re.I))

# The card's real command line is assembled by boot.scr / the PetaLinux config,
# not by the DTB chosen node, so the pin that matters for the memory map is the
# one the boot script and the kernel FIT carry.  The DTB's own bootargs must
# stay exactly what system-user.dtsi declares.
chosen = node_props('chosen') or {}
need('DTB chosen bootargs are the system-user.dtsi line (the longer validated '
     'line is supplied by the boot chain, and this image ships the same '
     'boot.scr the working card boots today)',
     chosen.get('bootargs', '').strip('"') ==
     'earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/ram0 rw')
# The validated command line is not carried by image.ub: U-Boot builds it from
# its own environment (see scripts/sc7f0_backup_boot.scr and the card's
# /boot/.backup_* history) and the kernel logs it.  The only thing this image
# contributes is boot.scr, so the check is that boot.scr is byte-identical to
# the one the working card boots today.  The real command line is proven on the
# card from /proc/cmdline after boot, which is what the run report records.
scr = IMG + '/boot.scr'
if os.path.exists(scr):
    import hashlib
    h = hashlib.sha256(open(scr, 'rb').read()).hexdigest()
    want = os.environ.get('SC7F0_EXPECT_BOOT_SCR_SHA256', '')
    if want:
        need(f'boot.scr is byte-identical to the booting card '
             f'({want[:16]}...)', h == want)
    else:
        print(f'INFO boot.scr sha256 {h} (set SC7F0_EXPECT_BOOT_SCR_SHA256 to '
              'pin it against the booting card)')

# --- rootfs -----------------------------------------------------------------
listing = subprocess.run(
    f"zcat '{IMG}/rootfs.cpio.gz' | cpio -t -H newc 2>/dev/null",
    shell=True, capture_output=True, text=True).stdout
entries = {re.sub(r'^\./', '', l).strip('/') for l in listing.splitlines()}
entries.discard('')
print(f'ROOTFS_ENTRIES {len(entries)}')
if len(entries) < 500:
    sys.exit(f'rootfs listing implausible ({len(entries)} entries); the audit '
             'pipeline is wrong, not the image')
# Names are the ones the recipes actually install (qpcie_debugd and
# sc7f0_ps_capture are underscored; the debugd unit is installed under
# lib/systemd/system by the recipe, and only appears in etc/ through the
# enable symlink).  qpcie_upgrade_daemon, sc7f0_ps_watchdog and
# qpcie_hdmi_daemon are NOT here by design: scripts/inject_upgrade_daemon_to_image_ub.sh
# puts them into the initramfs of image.ub, which the release step audits.
for f in ('usr/bin/modetest', 'usr/bin/peek', 'usr/bin/poke',
          'usr/bin/qpcie_debugd', 'usr/bin/sc7f0_ps_capture',
          'lib/systemd/system/qpcie-debugd.service',
          'lib/modules/6.1.30-xilinx-v2023.2/extra/qpcie_v4l2_bridge.ko',
          'etc/modules-load.d/qpcie_v4l2_bridge.conf'):
    need('rootfs has ' + f, f in entries)
for f in ('usr/bin/sc7f0-vcud', 'etc/systemd/system/sc7f0-vcud.service'):
    need('rootfs has NO ' + f, f not in entries, fatal=False)

if fails:
    print('IMAGE_AUDIT_FAIL ' + '; '.join(fails))
    sys.exit(1)
if soft:
    print('IMAGE_AUDIT_SOFT ' + '; '.join(soft))
print('IMAGE_AUDIT_PASS')
PY
