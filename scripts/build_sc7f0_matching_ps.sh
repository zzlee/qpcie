#!/usr/bin/env bash
# PS-only build from an accepted matching XSA. No hardware build/flash/reboot.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
ACCEPT=$(realpath "${1:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
OUT=$(realpath -m "${2:?ACCEPTANCE_DIRECTORY NEW_LOG_DIRECTORY}")
[[ ! -e "$OUT" ]] || { echo 'Refusing existing PS build logs' >&2; exit 1; }
mkdir -p "$OUT"
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/build.exit"' EXIT
python3 - "$ACCEPT" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads((p/'hardware.json').read_text())
assert r['hardware_accepted'] and r['version']=='0x26102804'
assert hashlib.sha256((p/'hardware.xsa').read_bytes()).hexdigest()==r['xsa_sha256']
assert (p/'hardware.ok').is_file() and json.loads((p/'full-profile-review-after-export.json').read_text())['pass_gate']
PY
sha256sum -c "$ACCEPT/REVIEW_INPUTS_OUTPUTS.sha256" > "$OUT/hardware-review-input-check.log"
export SC7F0_REPO_ROOT="$ROOT" SC7F0_ACCEPTED_XSA="$ACCEPT/hardware.xsa" SC7F0_PS_BUILD_LOGS="$OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="${USER:-zzlee}" -e TERM=xterm \
    -e SC7F0_REPO_ROOT -e SC7F0_ACCEPTED_XSA -e SC7F0_PS_BUILD_LOGS \
    -e XILINXD_LICENSE_FILE=2101@192.168.200.112 \
    -v "$HOME:$HOME" -v /opt:/opt \
    -v /etc/timezone:/etc/timezone:ro -v /etc/localtime:/etc/localtime:ro \
    -w "$ROOT/petalinux/qpcie-zu4ev" petalinux:latest bash -s <<'CONTAINER'
set -eo pipefail
source /opt/Xilinx/petalinux/2023.2/settings.sh
set -u
petalinux-config --get-hw-description="$SC7F0_ACCEPTED_XSA" --silentconfig
python3 - <<'PY'
from pathlib import Path
import hashlib,os
p=Path.cwd();root=Path(os.environ['SC7F0_REPO_ROOT']);out=Path(os.environ['SC7F0_PS_BUILD_LOGS']);xsa=Path(os.environ['SC7F0_ACCEPTED_XSA'])
x=list((p/'project-spec/hw-description').glob('*.xsa'))
assert len(x)==1 and hashlib.sha256(x[0].read_bytes()).digest()==hashlib.sha256(xsa.read_bytes()).digest(), 'imported XSA mismatch'
assert (p/'build/tmp').resolve()==p/'build/tmp', 'TMPDIR aliases another project'
conf=(p/'build/conf/bblayers.conf').read_text()
assert '/home/zzlee/qpcie/petalinux/qpcie-zu4ev/project-spec/meta-user' not in conf, 'wrong source layer'
assert 'meta-user' in conf, 'missing custom source layer'
files=list((p/'project-spec/meta-user').rglob('*'))
files += [p/'project-spec/configs/config',p/'project-spec/configs/rootfs_config',p/'.petalinux/metadata']
files += [f for d in ('test_app','include') for f in (root/d).glob('*') if f.suffix in ('.c','.h') or f.name=='Makefile']
files=sorted(f for f in set(files) if f.is_file())
(out/'PS_BUILD_INPUTS.sha256').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+str(f)+'\n' for f in files))
(out/'imported-xsa.sha256').write_text(hashlib.sha256(x[0].read_bytes()).hexdigest()+'  '+str(x[0])+'\n')
print('SC7F0_MATCHING_XSA_AND_ISOLATED_PROJECT_PREFLIGHT_PASS',len(files),'PS source inputs')
PY
petalinux-build
sha256sum -c "$SC7F0_PS_BUILD_LOGS/PS_BUILD_INPUTS.sha256" > "$SC7F0_PS_BUILD_LOGS/ps-source-check.log"
sha256sum -c "$SC7F0_PS_BUILD_LOGS/imported-xsa.sha256" > "$SC7F0_PS_BUILD_LOGS/xsa-after-build-check.log"
printf 'Matching PS build completed; firmware/DT/rootfs/package acceptance still required.\n' > "$SC7F0_PS_BUILD_LOGS/build.complete"
CONTAINER
