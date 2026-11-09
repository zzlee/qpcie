#!/usr/bin/env python3
"""Offline matching-capture FIT/kernel/DT audit, in addition to watchdog R2 audit."""
import argparse
import gzip
import hashlib
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

from check_sc7f0_ps_watchdog_image import audit as watchdog_audit, cpio, resolve, DTC, DUMP

# Revision that the injected rootfs must declare in etc/sc7f0-recovery-release.
# Candidates after R6 (for example R7 0x26102901) pass --base-version instead of
# editing this audit; the historical default keeps R6 replay byte-identical.
DEFAULT_BASE_VERSION = '0x26102804'


def node(dts, name):
    hits = list(re.finditer(r'(?m)^\s*'+re.escape(name)+r'\s*\{', dts))
    assert len(hits)==1, (name,len(hits))
    start=hits[0].end();depth=1
    for end in range(start,len(dts)):
        depth += (dts[end]=='{')-(dts[end]=='}')
        if depth==0:return dts[start:end]
    raise AssertionError('unclosed node '+name)


def audit(build, project, ps_build, base_version=DEFAULT_BASE_VERSION):
    base_version = str(base_version)
    assert re.fullmatch(r'0x[0-9a-fA-F]{8}', base_version), 'malformed PL base version'
    base_version = base_version.lower()
    watchdog_audit(build)
    assert (ps_build/'build.exit').read_text().strip()=='0'
    assert (ps_build/'build.complete').is_file()
    # configs/config is rewritten by petalinux-build on every run (it puts the
    # generated bootargs back), so a blanket sha256sum -c over the PS input
    # manifest fails even on a perfectly good build.  The dedicated checker splits
    # the auto-generated line from real source drift and checks the rest.
    subprocess.run([sys.executable, str(Path(__file__).resolve().parent
                                         / 'check_sc7f0_ps_build_integrity.py'),
                    '--ps-build', str(ps_build)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['sha256sum','-c',str(ps_build/'imported-xsa.sha256')],check=True,stdout=subprocess.DEVNULL)
    cfg=(build/'images/kernel.config').read_text()
    for option in ('VIDEO_XILINX','VIDEO_SC7F0_FRAME_TAP','VIDEO_XILINX_VPSS_CSC',
                   'XILINX_FRMBUF','MEDIA_CONTROLLER','VIDEO_V4L2_SUBDEV_API',
                   'DMA_SHARED_BUFFER','DMA_CMA','VIDEOBUF2_DMA_CONTIG'):
        assert re.search(r'^CONFIG_'+option+r'=y$',cfg,re.M),option
    symbols=(build/'images/kernel.System.map').read_text()
    for symbol in ('sc7f0_tap_prepare','sc7f0_tap_finish','sc7f0_tap_quiesce'):
        assert re.search(r' T '+symbol+r'$',symbols,re.M),symbol
    source=project/'build/tmp/work-shared/zynqmp-generic-xczu4ev/kernel-source/drivers/media/platform/xilinx'
    expected=Path(__file__).resolve().parents[1]/'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/sc7f0-frame-tap.c'
    assert (source/'sc7f0-frame-tap.c').read_bytes()==expected.read_bytes(),'stale built tap source'
    dma_source=(source/'xilinx-dma.c').read_text()
    start=dma_source.split('static int xvip_dma_start_streaming(',1)[1].split('static void xvip_dma_stop_streaming(',1)[0]
    stop=dma_source.split('static void xvip_dma_stop_streaming(',1)[1].split('static ',1)[0]
    assert start.index('error:\n') < start.rindex('sc7f0_tap_quiesce(dma->frame_tap);') < start.index('dmaengine_terminate_all(dma->dma);'),'missing startup-unwind fence'
    assert stop.index('sc7f0_tap_quiesce(dma->frame_tap);') < stop.index('xvip_pipeline_set_stream(pipe, false);') < stop.index('dmaengine_terminate_all(dma->dma);'),'unsafe stop order'
    assert start.index('xvip_pipeline_set_stream(pipe, true);') < start.index('sc7f0_tap_credit(dma->frame_tap, queued);'),'admission before downstream graph readiness'
    dts=subprocess.run([DTC,'-I','dtb','-O','dts',str(build/'images/system.dtb')],check=True,capture_output=True,text=True).stdout
    for name in ('video-capture','frame-tap@b0070000','vpss-csc@b0060000','framebuffer@b0050000'):
        assert 'status = "okay";' in node(dts,name),name
    assert 'status = "disabled";' in node(dts,'qpcie_v4l2_bridge')
    assert 'yuan,frame-tap' in node(dts,'video-capture')
    writer=node(dts,'framebuffer@b0050000')
    tap=node(dts,'frame-tap@b0070000');csc=node(dts,'vpss-csc@b0060000')
    tap_phandle=int(re.search(r'phandle = <(0x[0-9a-f]+)>;',tap)[1],16)
    for text,bit in ((writer,0),(csc,1)):
        values=re.search(r'reset-gpios = <([^>]+)>;',text)[1].split()
        assert [int(v,0) for v in values]==[tap_phandle,bit,1],'wrong reset owner/polarity'
    clock=node(dts,'capture-clock')
    assert int(re.search(r'clock-frequency = <(0x[0-9a-f]+)>;',clock)[1],16)==300000000
    for pattern in ('interrupts = <0x00 0x5d 0x04>;', 'xlnx,dma-addr-width = <0x40>;',
                    'xlnx,pixels-per-clock = <0x04>;', 'xlnx,vid-formats = "nv12";'):
        assert pattern in writer,pattern
    base=cpio(gzip.decompress((project/'images/linux/rootfs.cpio.gz').read_bytes()))
    with tempfile.TemporaryDirectory(prefix='sc7f0-capture-fit-') as t:
        t=Path(t)
        for index,name in ((0,'kernel.gz'),(1,'dtb'),(2,'rootfs.gz')):
            subprocess.run([DUMP,'-T','flat_dt','-p',str(index),'-o',str(t/name),str(build/'images/image.ub')],check=True,capture_output=True)
        assert (t/'kernel.gz').read_bytes()==(build/'images/Image.gz').read_bytes()
        assert (t/'dtb').read_bytes()==(build/'images/system.dtb').read_bytes()
        entries=cpio(gzip.decompress((t/'rootfs.gz').read_bytes()))
        for name in ('usr/bin/sc7f0_ps_capture','usr/bin/media-ctl','usr/bin/v4l2-ctl'):
            mode,uid,data=resolve(entries,name)
            assert stat.S_ISREG(mode) and mode&0o111 and uid==0,name
            assert data[:4]==b'\x7fELF' and int.from_bytes(data[18:20],'little')==183,name
            assert data==resolve(base,name)[2],'injected image changed '+name
        for suffix in ('xilinx-hdmi-rx.ko','xilinx-vphy.ko'):
            matches=[n for n in entries if n.endswith('/extra/hdmi/'+suffix)]
            assert len(matches)==1,suffix
            assert entries[matches[0]][2]==base[matches[0]][2],'stale/replaced HDMI module'
        release=resolve(entries,'etc/sc7f0-recovery-release')[2]
        assert b'PL_BASE_VERSION=' + base_version.encode() + b'\n' in release, base_version
        assert 'etc/systemd/system/multi-user.target.wants/sc7f0-vcud.service' not in entries
    print('SC7F0_CAPTURE_IMAGE_AUDIT_PASS: actual kernel symbols/source, single media owner, IRQ/format/GPIO graph, matching FIT components/capture tools/modules, watchdog R2, PL base ' + base_version + '; not runtime/VCU acceptance')
    print('FIT SHA256:',hashlib.sha256((build/'images/image.ub').read_bytes()).hexdigest())


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('build',type=Path)
    p.add_argument('--project',type=Path,required=True);p.add_argument('--ps-build',type=Path,required=True)
    p.add_argument('--base-version',default=DEFAULT_BASE_VERSION,
                   help='PL base version declared in the injected release marker '
                        '(default: %(default)s; R7 candidates use 0x26102901)')
    a=p.parse_args()
    if not re.fullmatch(r'0x[0-9a-fA-F]{8}',a.base_version):
        p.error('--base-version must look like 0x26102901')
    audit(a.build.resolve(),a.project.resolve(),a.ps_build.resolve(),a.base_version)
