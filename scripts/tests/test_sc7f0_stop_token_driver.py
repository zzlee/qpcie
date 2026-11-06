"""Actual kernel stop_command/tap_stream code under an MMIO ordering model."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'petalinux/qpcie-zu4ev/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/sc7f0-frame-tap.c'
PREFIX = r'''
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
typedef uint32_t u32; typedef uint64_t u64;
#define BIT(n) (1u << (n))
#define TAP_STATUS 0x08
#define TAP_CONTROL 0x0c
#define TAP_BUSY BIT(0)
#define TAP_READY BIT(1)
#define TAP_ENABLED BIT(3)
#define TAP_STOP_REQUEST 0x68
#define TAP_STOP_ACK 0x6c
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,y) ((x)=(y))
#define spin_lock_irqsave(lock,f) do { (void)(lock); (f)=0; } while(0)
#define spin_unlock_irqrestore(lock,f) do { (void)(lock); (void)(f); } while(0)
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
struct sc7f0_frame_tap;
struct v4l2_subdev { struct sc7f0_frame_tap *owner; };
struct sc7f0_frame_tap {
  unsigned char *regs; int reg_lock,lock;
  struct v4l2_subdev sd; struct {u32 width,height;} format;
  u64 origin_ticks,origin_ns; bool streaming,start_unconfirmed,stop_waiting;
  u32 stop_token;
};
static unsigned char registers[256];
static u32 request=27,ack=27; static int mode,ack_reads,writes,waits;
static struct sc7f0_frame_tap *to_tap(struct v4l2_subdev *s) { return s->owner; }
static u64 ktime_get_ns(void) { return 100000; }
static u32 readl(const unsigned char *p) {
  ptrdiff_t offset=p-registers;
  if(offset==TAP_STATUS) return mode==4 ? 0 : TAP_READY | (mode==2 ? TAP_BUSY|TAP_ENABLED : 0);
  if(offset==TAP_STOP_REQUEST) return request;
  if(offset==TAP_STOP_ACK) {
    ++ack_reads;
    if(mode!=1 && ack_reads>=4) ack=request;
    return ack;
  }
  return 0;
}
static void writel(u32 value,unsigned char *p) {
  if(p-registers==TAP_CONTROL) {
    if(value) abort();
    ++writes; if(mode!=3)++request;
  }
}
static void usleep_range(unsigned a,unsigned b) {
  if(a!=1000 || b!=1500)abort();
  ++waits;
}
'''
SUFFIX = r'''
int main(int argc,char **argv) {
  struct sc7f0_frame_tap t={0};
  if(argc!=2)return 2;
  mode=atoi(argv[1]);
  if(mode==5)request=ack=UINT32_MAX;
  t.regs=registers;t.sd.owner=&t;t.streaming=true;t.start_unconfirmed=true;
  int requested=mode;
  if(requested==6 || requested==7)mode=1;
  int ret=tap_stream(&t.sd,0);
  if(requested==6 || requested==7) {
    if(ret!=-ETIMEDOUT || !t.stop_waiting)return 3;
    mode=0;ack_reads=0;
    if(requested==7) { t.start_unconfirmed=false; t.streaming=false; }
    ret=tap_stream(&t.sd,requested==7);
  }
  printf("ret=%d writes=%d ack_reads=%d waits=%d request=%u streaming=%d unconfirmed=%d\n",
    ret,writes,ack_reads,waits,request,t.streaming,t.start_unconfirmed);
  return 0;
}
'''


class StopTokenDriverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='sc7f0-stop-token-')
        text=SOURCE.read_text()
        functions=[]
        for name in ('command','stop_command','tap_stream'):
            match=re.search(r'^static int '+name+r'\(.*?^}\n',text,re.M|re.S)
            if not match: raise AssertionError(name)
            functions.append(match[0])
        file=Path(cls.temp.name)/'model.c';file.write_text(PREFIX+'\n'.join(functions)+SUFFIX)
        cls.binary=Path(cls.temp.name)/'model'
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(file),'-o',str(cls.binary)],check=True)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def run_mode(self,mode):
        return subprocess.run([str(self.binary),str(mode)],capture_output=True,text=True,check=True,timeout=2).stdout

    def test_idle_status_cannot_acknowledge_a_posted_stop(self):
        self.assertIn('ret=-110 writes=1 ack_reads=100',self.run_mode(1))
        self.assertIn('streaming=1 unconfirmed=1',self.run_mode(1))

    def test_fresh_token_resolves_previous_unconfirmed_enable(self):
        self.assertIn('ret=0 writes=1 ack_reads=4 waits=3',self.run_mode(0))
        self.assertIn('streaming=0 unconfirmed=0',self.run_mode(0))

    def test_approximate_busy_does_not_replace_barrier(self):
        self.assertIn('ret=0 writes=1 ack_reads=4',self.run_mode(2))

    def test_posted_write_readback_failure_fails_closed(self):
        self.assertIn('ret=-5 writes=1 ack_reads=0',self.run_mode(3))

    def test_command_full_never_writes_or_waits_for_old_ack(self):
        self.assertIn('ret=-16 writes=0 ack_reads=0',self.run_mode(4))

    def test_u32_stop_token_wrap_is_not_stale_ack(self):
        result=self.run_mode(5)
        self.assertIn('ret=0 writes=1 ack_reads=4',result)
        self.assertIn('request=0 streaming=0 unconfirmed=0',result)

    def test_retry_reuses_one_pending_fence_instead_of_wrapping_forever(self):
        self.assertIn('ret=0 writes=1 ack_reads=4',self.run_mode(6))

    def test_pending_stop_forbids_new_enable_even_with_idle_status(self):
        self.assertIn('ret=-16 writes=1 ack_reads=0',self.run_mode(7))

    def test_driver_rejects_pre_barrier_abi(self):
        text=SOURCE.read_text()
        self.assertIn('#define TAP_ABI 0x00010001U',text)
        self.assertIn('readl(t->regs + 0x04) != TAP_ABI',text)


if __name__=='__main__':unittest.main()
