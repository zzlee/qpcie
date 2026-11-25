"""Join the overlap DQ cohort to physical SOF IDs and OMX event clocks."""
import json, math, re, statistics, struct, sys
from pathlib import Path
p=Path(sys.argv[1]); dq=[x.split() for x in (p/'dq').read_text().splitlines()]; submitted=[int(x.split()[3]) for x in (p/'trace').read_text().splitlines() if x.startswith('S ')];drm=[float(x) for x in re.findall(r'flip id=. .*?drm_time=([\d.]+)',(p/'flips.log').read_text())];raw=[float(x) for x in re.findall(r'cap dqbuf: \d+ seq:\s*\d+.*?ts: (\d+\.\d+)',(p/'raw.log').read_text())];lo=max(float(dq[0][-1]),drm[0],raw[0]);hi=min(float(dq[-1][-1]),drm[-1],raw[-1]);cohort=[submitted[i] for i,x in enumerate(dq) if lo<=float(x[-1])<=hi];ev={v:{} for v in cohort};ids={}
for t,v,o,i,n,fl,b,r in struct.iter_unpack('<QQ6I',(p/'events').read_bytes()):
    if v in ev:
        ev[v][o]=t
        if o==1:ids[v]=n
miss=ids[cohort[-1]]-ids[cohort[0]]+1-len(cohort);assert all(ids[y]>ids[x] for x,y in zip(cohort,cohort[1:]));out=dict(duration_s=hi-lo,overlap_missing=miss,first=ids[cohort[0]],last=ids[cohort[-1]],count=len(cohort))
for name,a,b in [('ETB_EBD',2,4),('ETB_FBD',2,8),('FBD_FTB_return',8,11)]:
    x=sorted((e[b]-e[a])/1e6 for e in ev.values());out[name]=[round(statistics.median(x),3),round(x[math.ceil(len(x)*.99)-1],3)]
print(json.dumps(out))
