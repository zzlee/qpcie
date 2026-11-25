#include "credit2.h"
#include <linux/random.h>
struct c2slot {void *cpu;dma_addr_t dma;struct vb2_buffer *vb;};
struct c2host {struct mutex m;struct delayed_work work;struct qpcie_v4l2_channel *v;struct c2slot s[16];struct list_head wait;void *records;dma_addr_t record_dma;u32 epoch,head,ret;bool live,dead,fault,stopping,quarantined;unsigned long first;};
static void __iomem *c2base(struct c2host*c){return c->v->qdev->bar0_mmio+QPCIE_BAR0_VCU_RING_OFFSET;}
static u32 c2rd(struct c2host*c,int w){return ioread32(c2base(c)+4*w);}static void c2wr(struct c2host*c,int w,u32 v){iowrite32(v,c2base(c)+4*w);}
static void c2give(struct vb2_buffer*b,enum vb2_buffer_state st,size_t n){vb2_set_plane_payload(b,0,n);vb2_buffer_done(b,st);}
static void c2publish(struct c2host*c){while(c->live&&!c->fault&&c->head-c->ret<16&&!list_empty(&c->wait)){
 u32 t=c->head,idx=t%16,w=16+idx*8,*r=c->records+idx*128;struct c2slot*s=&c->s[idx];struct qpcie_v4l2_buffer*b=list_first_entry(&c->wait,struct qpcie_v4l2_buffer,list);int i;
 if(t>=0x7ffffffe){c->fault=true;vb2_queue_error(&c->v->queue);break;}list_del_init(&b->list);s->vb=&b->vb.vb2_buf;b->queued_jiffies=jiffies;
 memset(r,0,64);for(i=0;i<16;i++)WRITE_ONCE(r[16+i],~c2_fence_word(i,c->epoch,t));dma_wmb();
 c2wr(c,w,lower_32_bits(s->dma));c2wr(c,w+1,upper_32_bits(s->dma));c2wr(c,w+2,lower_32_bits(c->record_dma+idx*128));c2wr(c,w+3,upper_32_bits(c->record_dma+idx*128));c2wr(c,w+4,min_t(size_t,C2_BYTES,vb2_plane_size(s->vb,0)));c2wr(c,w+5,t);c2wr(c,w+6,c->epoch);c2wr(c,w+7,0);c2wr(c,C2_HEAD,++c->head);c2rd(c,C2_HEAD);
 }}
static void c2revoke(struct c2host*c){if(!c->stopping){c->stopping=true;c->live=false;if(!pci_dev_is_disconnected(c->v->qdev->pdev)){c2wr(c,C2_STATE,C2_STOP);c2rd(c,C2_STATE);}}}
/* Quarantine recovery never dereferences vb2: only the private coherent
 * bank survives a failed close. A new session is refused until the original
 * producer fences publication and the host sees every claimed final record. */
static bool c2recover(struct c2host*c){u32 lim,t;unsigned i;if(!c->quarantined)return true;
 if(pci_dev_is_disconnected(c->v->qdev->pdev)||c2rd(c,0)!=C2_MAGIC||c2rd(c,C2_ACK_STATE)!=C2_STOP||c2rd(c,C2_ACK_EPOCH)!=c->epoch)return false;
 lim=c2rd(c,C2_LIMIT);if(lim<c->ret||lim>c->head||lim-c->ret>16)return false;
 for(t=c->ret;t<lim;t++){u32*r=c->records+(t%16)*128+64;for(i=0;i<16;i++)if(READ_ONCE(r[i])!=c2_fence_word(i,c->epoch,t))return false;}
 dma_rmb();c2wr(c,12,c->epoch);c2rd(c,12);c->quarantined=false;put_device(&c->v->qdev->pdev->dev);dev_info(&c->v->qdev->pdev->dev,"C2 quarantine released epoch=%u through=%u\n",c->epoch,lim);return true;}
static void c2harvest(struct c2host*c){while(c->ret!=c->head){u32 t=c->ret,idx=t%16,*r=c->records+idx*128,len;int i;struct c2slot*s=&c->s[idx];struct vb2_buffer*b=s->vb;bool ok;u64 pts;
 if(!b)break;
 for(i=0;i<16;i++)if(READ_ONCE(r[i+16])!=c2_fence_word(i,c->epoch,t))break;if(i!=16)break;dma_rmb();len=READ_ONCE(r[10]);ok=r[0]==C2_DPC&&!r[1]&&r[8]==t&&r[9]==c->epoch&&len>0&&len<=C2_BYTES&&len<=vb2_plane_size(b,0)&&vb2_plane_vaddr(b,0);
 if(ok&&!c->stopping){memcpy(vb2_plane_vaddr(b,0),s->cpu,len);pts=(((u64)r[7]<<32)|r[6])*1000/150;if(!c->v->vcu_offset_calibrated){c->v->vcu_card_to_host_offset_ns=(s64)ktime_get_ns()-(s64)pts;c->v->vcu_offset_calibrated=true;}b->timestamp=pts+c->v->vcu_card_to_host_offset_ns;to_vb2_v4l2_buffer(b)->sequence=t;}
 s->vb=NULL;c->ret++;c2give(b,ok&&!c->stopping?VB2_BUF_STATE_DONE:VB2_BUF_STATE_ERROR,ok&&!c->stopping?len:0);
 }}
static void c2work(struct work_struct*w){struct c2host*c=container_of(to_delayed_work(w),struct c2host,work);mutex_lock(&c->m);if(c->live&&!c->dead){c2harvest(c);if(c->ret!=c->head){struct vb2_buffer*b=c->s[c->ret%16].vb;struct qpcie_v4l2_buffer*q=container_of(to_vb2_v4l2_buffer(b),struct qpcie_v4l2_buffer,vb);if(time_after(jiffies,q->queued_jiffies+3*HZ)){c->fault=true;c2revoke(c);vb2_queue_error(&c->v->queue);dev_warn(&c->v->qdev->pdev->dev,"C2 timeout frozen epoch=%u ret=%u head=%u\n",c->epoch,c->ret,c->head);}}
 c2publish(c);if(c->live)schedule_delayed_work(&c->work,msecs_to_jiffies(2));}mutex_unlock(&c->m);}
static void c2return(struct c2host*c,enum vb2_buffer_state st){int i;while(!list_empty(&c->wait)){struct qpcie_v4l2_buffer*b=list_first_entry(&c->wait,struct qpcie_v4l2_buffer,list);list_del_init(&b->list);c2give(&b->vb.vb2_buf,st,0);}for(i=0;i<16;i++)if(c->s[i].vb){struct vb2_buffer*b=c->s[i].vb;c->s[i].vb=NULL;c2give(b,st,0);}}
static void c2free(struct c2host*c){int i;struct device*d=&c->v->qdev->pdev->dev;if(c->quarantined)return;for(i=0;i<16;i++)if(c->s[i].cpu){dma_free_coherent(d,C2_BYTES,c->s[i].cpu,c->s[i].dma);c->s[i].cpu=NULL;}if(c->records){dma_free_coherent(d,2048,c->records,c->record_dma);c->records=NULL;}}
static int c2start(struct c2host*c){int i,rc=-EIO;struct device*d=&c->v->qdev->pdev->dev;mutex_lock(&c->m);if(c->dead||c->quarantined||!c->epoch||c->epoch==U32_MAX||c2rd(c,C2_PEER)!=C2_CAP)goto fail;
 if(!c->records){c->records=dma_alloc_coherent(d,2048,&c->record_dma,GFP_KERNEL);if(!c->records)goto fail;for(i=0;i<16;i++){c->s[i].cpu=dma_alloc_coherent(d,C2_BYTES,&c->s[i].dma,GFP_KERNEL);if(!c->s[i].cpu){c2free(c);goto fail;}}}
 c->epoch++;c->head=c->ret=0;c->fault=c->stopping=false;c->v->vcu_offset_calibrated=false;c2wr(c,C2_HEAD,0);c2wr(c,C2_EPOCH,c->epoch);c2wr(c,C2_STATE,C2_OPEN);c2rd(c,C2_STATE);
 for(i=0;i<200;i++){if(c2rd(c,C2_ACK_STATE)==C2_OPEN&&c2rd(c,C2_ACK_EPOCH)==c->epoch)break;usleep_range(3000,5000);}if(i==200){c2revoke(c);rc=-ETIMEDOUT;goto fail;}c->live=true;c2publish(c);schedule_delayed_work(&c->work,0);rc=0;goto out;
 fail:c2return(c,VB2_BUF_STATE_QUEUED);out:mutex_unlock(&c->m);return rc;}
static void c2stop(struct c2host*c){int i;bool safe=false;u32 lim=0;mutex_lock(&c->m);if(!c->live&&!c->stopping){c2return(c,VB2_BUF_STATE_ERROR);mutex_unlock(&c->m);return;}c2revoke(c);
 for(i=0;i<500&&!pci_dev_is_disconnected(c->v->qdev->pdev);i++){c2harvest(c);if(c2rd(c,C2_ACK_STATE)==C2_STOP&&c2rd(c,C2_ACK_EPOCH)==c->epoch){lim=c2rd(c,C2_LIMIT);if(lim<=c->head&&lim==c->ret){safe=true;break;}}usleep_range(3000,5000);}
 if(safe){c2wr(c,12,c->epoch);c2rd(c,12);}else{c->quarantined=true;get_device(&c->v->qdev->pdev->dev);/* Private DMA pages and mapping intentionally pinned, never reused. */}dev_info(&c->v->qdev->pdev->dev,"C2 close epoch=%u head=%u claimed=%u fenced=%u quarantine=%u\n",c->epoch,c->head,lim,c->ret,!safe);c->stopping=false;c2return(c,VB2_BUF_STATE_ERROR);mutex_unlock(&c->m);cancel_delayed_work_sync(&c->work);}
