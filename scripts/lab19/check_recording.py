import json,struct,statistics as st,collections as C,re,hashlib,subprocess,sys,os,bisect,math
from pathlib import Path as P
k=P.cwd().name;c=k.split('-')[0];integrity='audit' in k;HE=c=='hevc';H=lambda b:hashlib.sha256(b).hexdigest();source={};events=C.defaultdict(dict);holds=[];rc=C.Counter();inputseq=[];nev=0
with open('events','rb') as f:
 for t,p,o,i,n,fl,b,r in struct.iter_unpack('<QQ6I',f.read()):
  nev+=1
  if o in (1,2,3,4,5,6,8,10,11):events[p][o]=(t,i,n,fl,b,r)
  if o==1:source[p]=n;inputseq.append(n)
  if o in (2,4):holds.append((t,1 if o==2 else -1))
  if o in (3,5,11) and r:rc[(o,r)]+=1
assert nev<600000
G={};S=[];hdr=[]
for l in open('trace'):
 r=l.split()
 if r[0]=='S':S.append(r)
 elif r[0]=='G' and not int(r[5]):G[int(r[1])]=r
 else:hdr.append(r)
D=[x.split() for x in open('dq')];raw=[(int(x),float(y)) for x,y in re.findall(r'cap dqbuf: \d+ seq:\s*(\d+).*?ts: (\d+\.\d+)',P('raw.log').read_text())];fr=[(x,float(y)) for x,y in re.findall(r'flip id=(.) .*?drm_time=(\d+\.\d+)',P('flips.log').read_text())];lo=max(raw[0][1],float(D[0][-1]),fr[0][1]);hi=min(raw[-1][1],float(D[-1][-1]),fr[-1][1]);pts=[];ids=[];time=[];sizes=[];keys=[];headers=0;hist=C.Counter();prefix=C.Counter();pads=C.Counter();oset=C.Counter();alloc=C.Counter();big=0;imax=0;bad=[];padhash=0;twins=0;ptsmap=[];digest=hashlib.sha256();gaps=[]
with open('host.es','rb') as f:
 for j,d in enumerate(D):
  seq,idx,n=map(int,d[:3]);s=S[j];p=int(s[3]);z=int(s[4]);b=f.read(n);g=G[p];m=int(g[2]);delta=z-m;ev=events[p];assert seq==j==int(s[2]) and len(b)==n==int(s[5]) and 0<=delta and z<=n<=4194304 and n-z<16 and not any(b[z:]);assert all(a in ev for a in (1,2,3,4,5,6,8,10,11)) and not ev[6][5] and ev[1][4]==12441600 and ev[1][3]&0x40==0;pts.append(p);ids.append(source[p]);t=float(d[-1]);time.append(t);sizes.append(n);prefix[delta]+=1;pads[n-z]+=1;oset[int(g[8])]+=1;alloc[int(g[9])]+=1;nal=[((b[x.end()]>>1)&63 if HE else b[x.end()]&31) for x in re.finditer(b'\0\0\1',b) if x.end()<z];v=[k for k in nal if (k<=31 if HE else k in (1,5))];hist[len(v)]+=1;key=any(k in ((19,20) if HE else (5,)) for k in v)
  if key:keys.append(j);headers+=set((32,33,34) if HE else (7,8))<=set(nal);big+=m>1048576;imax=max(imax,m)
  if integrity:
   assert g[6]==g[7]==H(b[delta:z]) and s[6]==H(b);twins+=1;padhash+=1
  else:assert s[6]==g[6]==g[7]=='-'
  if j and (ids[-1]!=ids[-2]+1 or p-pts[-2]>25000 or p<=pts[-2]):gaps.append([j,ids[-2],ids[-1],p-pts[-2],round(t-lo,3)])
 assert not f.read(1)
first,last=pts[0],pts[-1]; gen=[p for p in G if first<=p<=last];capture=[p for p in source if first<=p<=last];assert set(gen)==set(pts)==set(capture) and len(capture)==len(gen)==len(set(pts))==len(D);assert len(S)>=len(D);assert set(hist)=={4};drain=re.search(r'head=(\d+) claimed=(\d+) fenced=(\d+) quarantine=(\d+)',P('drain').read_text());assert drain and int(drain[2])==int(drain[3])==len(S) and int(drain[4])==0
rgaps=sum(b[0]!=a[0]+1 for a,b in zip(raw,raw[1:]));t0=events[first][1][0];t1=events[last][1][0];depth=0;maxheld=0;full=[];start=0
for t,v in sorted(holds):
 if depth==12 and v==-1 and min(t,t1)>max(start,t0):full.append((min(t,t1)-max(start,t0))/1e6)
 depth+=v
 if depth==12 and v==1:start=t
 if t0<=t<=t1:maxheld=max(maxheld,depth)
def quant(v):v.sort();return [round(x,3) for x in (st.median(v),v[math.ceil(.99*len(v))-1],max(v))]
ages={k:quant([(events[p][b][0]-events[p][a][0])/1e6 for p in pts]) for k,a,b in [('outHold',8,10),('inputHold',2,4)]};inc=[i for i,t in enumerate(time) if lo<=t<=hi];windows=[]
for a in range(0,int(hi-lo)+1,60):
 dt=min(60,hi-lo-a)
 if dt>.1:windows.append(round(sum(lo+a<=t<lo+a+dt for t in time)/dt,3))
res=dict(k=k,integrity=integrity,host=len(D),captured=len(capture),gen=len(gen),submitted=len(S),tail_not_DQ=len(S)-len(D),raw=len(raw),rgaps=rgaps,acks=''.join(x for x,t in fr),overlap=round(hi-lo,3),overlapN=len(inc),fps=round(len(inc)/(hi-lo),3),mbps=round(sum(sizes[i] for i in inc)*8e-6/(hi-lo),3),win=windows,source_gaps=len(gaps),first_gap=gaps[:1],miss=sum(x[2]-x[1]-1 for x in gaps),service_nonunit=sum(q!=p+1 for p,q in zip(inputseq,inputseq[1:])),ptsdt=quant([(q-p)/1000 for p,q in zip(pts,pts[1:])]),dqdt=quant([(q-p)*1000 for p,q in zip(time,time[1:])]),input_output_tails=ages,fullStalls=len(full),fullMaxMs=round(max(full or [0]),3),maxHeld=maxheld,fullMs=round(sum(full),3),idrs=len(keys),spacing=dict(C.Counter(y-x for x,y in zip(keys,keys[1:]))),header_idrs=headers,headerOnly=len(hdr),idrOver1=big,largestIDR=imax,slices=hist,prefix=prefix,pad=pads,offset=oset,allocation=alloc,hashes=twins,stagehashes=padhash,badrc=str(rc),maxsize=max(sizes),drain=drain[0]);P('gaps.json').write_text(json.dumps(gaps));P('result.json').write_text(json.dumps(res,indent=2));print('timing',res,flush=True)
# Full decode with passthrough timing, retain one frame-sized-down digest for each decoded picture offline only.
with open('decode.log','w') as err:subprocess.run(['ffmpeg','-nostdin','-v','warning','-xerror','-f',('hevc' if HE else 'h264'),'-probesize','64M','-analyzeduration','20000000','-fpsprobesize','128','-i','host.es','-vf','scale=32:18:flags=area,format=gray','-fps_mode','passthrough','-f','framemd5','decode.md5'],stderr=err,check=True)
dec=sum(not x.startswith('#') for x in open('decode.md5'));warnings=P('decode.log').read_text();probe=subprocess.run(['ffmpeg','-nostdin','-v','info','-f',('hevc' if HE else 'h264'),'-probesize','64M','-analyzeduration','20000000','-fpsprobesize','128','-i','host.es','-c','copy','-bsf:v','trace_headers','-frames:v','1','-f','null','-'],capture_output=True,check=True).stderr.decode(errors='replace');info=[x for x in probe.splitlines() if re.search(r'\b(entropy_coding_mode_flag|profile_idc|general_profile_idc|level_idc|general_level_idc)\b',x)];P('headers.log').write_text('\n'.join(info));assert HE or any('entropy_coding_mode_flag' in x and x.endswith('= 1') for x in info);assert dec==len(D); res.update(decoded=dec,warnings=warnings,passed=bool(not gaps and not warnings and not rc and not rgaps and (integrity or hi-lo>=600) and keys[0]==0 and all(b-a==30 for a,b in zip(keys,keys[1:])) and headers==len(keys) and (not integrity or big>0)));P('result.json').write_text(json.dumps(res,indent=2));print('decode',dec,'pass',res['passed']);
