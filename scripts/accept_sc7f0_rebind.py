#!/usr/bin/env python3
"""Authorized card-only driver detach/reattach with an active debug client.
No module unload, firmware write, PCIe hot-remove, board/Host reboot.
"""
import os,select,subprocess as sp,sys,time
from pathlib import Path
if not __debug__:
    raise SystemExit('Assertions must be enabled; do not use python -O')
if os.geteuid()!=0 or len(sys.argv)!=4 or sys.argv[3]!='--run':
    raise SystemExit('Usage: sudo python3 accept_sc7f0_rebind.py CLIENT DIAG --run')
P=Path('/sys/bus/pci/devices/0000:03:00.0')
assert (P/'vendor').read_text().strip()=='0x12ab' and (P/'device').read_text().strip()=='0xe380'
assert (P/'driver').resolve().name=='qpcie-dma'
base=[str(Path(sys.argv[1]).resolve())]
diag=sp.check_output([str(Path(sys.argv[2]).resolve()),str(P/'resource0')],text=True)
assert 'VERSION=26101504' in diag and 'STATUS=00000000' in diag
assert 'CTRL=00000000' in diag or 'CTRL=00000002' in diag  # idle/DONE, never START
fixture='/tmp/sc7f0-driver-reconnect-'+str(os.getpid())
command='printf A > '+fixture+'; printf "%s\\n" "$$"; sleep 30; printf B >> '+fixture
p=sp.Popen(base+['exec',command],stdout=sp.PIPE,stderr=sp.PIPE)
assert select.select([p.stdout],[],[],5)[0]
pid=int(p.stdout.readline().strip())
unbound=False
try:
    Path('/sys/bus/pci/drivers/qpcie-dma/unbind').write_text('0000:03:00.0\n');unbound=True
    assert not (P/'driver').is_symlink()
    out,err=p.communicate(timeout=8)
    assert p.returncode==125,(p.returncode,out,err)
    print('PASS live client exits125 on driver removal; dead FD cannot access MMIO',flush=True)
    time.sleep(4.5)
finally:
    if unbound: Path('/sys/bus/pci/drivers_probe').write_text('0000:03:00.0\n')
assert (P/'driver').is_symlink()
check='test "$(cat '+fixture+')" = A && ! kill -0 -- -'+str(pid)+' && rm -f '+fixture+' && printf RECONNECTED_NO_REPLAY'
r=sp.run(base+['exec',check],capture_output=True,timeout=10)
assert r.returncode==0 and r.stdout==b'RECONNECTED_NO_REPLAY',(r.returncode,r.stdout,r.stderr)
print('TB_PASS actual driver disconnect/rebind: PS daemon survived, stale command group reaped, no replay',flush=True)
