import json,time,sys
from pathlib import Path as P
S=P('/sys/bus/pci/devices/0000:03:00.0');keys='perf_enable perf_stats packet_stats hdmi_status ch0_frames ch0_drops frame_drop_count current_link_speed current_link_width aer_dev_correctable aer_dev_nonfatal aer_dev_fatal'.split()
with open('bus.jsonl','x',buffering=1) as out:
 while True:
  r={'t':time.monotonic(),'cpu':open('/proc/stat').readline().strip()}
  for k in keys:
   try:r[k]=(S/k).read_text()
   except OSError as e:r[k]=str(e)
  out.write(json.dumps(r)+'\n');time.sleep(5)
