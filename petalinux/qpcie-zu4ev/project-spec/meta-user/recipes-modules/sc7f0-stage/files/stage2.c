// SPDX-License-Identifier: GPL-2.0-only
/* OF-bound importer for the capture_clk HP1 packet master.  Process
 * death deliberately cannot drop a persistent attachment. Explicit release
 * is permitted only before arm, or after a validated host drain cookie. */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/mutex.h>
struct req {u32 slot,fd;u64 address;};
#define IMPORT _IOWR('s',1,struct req)
#define ARM _IOW('s',2,u32)
#define DROP _IO('s',3)
struct entry {struct dma_buf*b;struct dma_buf_attachment*a;struct sg_table*t;};
static struct entry p[16];static struct device *master;static void __iomem* ring;static DEFINE_MUTEX(lock);static u32 epoch;static int opened;
static void release_all(void){int i;for(i=0;i<16;i++)if(p[i].b){dma_buf_unmap_attachment(p[i].a,p[i].t,DMA_TO_DEVICE);dma_buf_detach(p[i].b,p[i].a);dma_buf_put(p[i].b);p[i].b=NULL;module_put(THIS_MODULE);}epoch=0;}
static long op(struct file*f,unsigned cmd,unsigned long arg){struct req r;struct dma_buf*b;struct dma_buf_attachment*a;struct sg_table*t;int rc=-EINVAL;u64 end;u32 e;mutex_lock(&lock);
 if(cmd==DROP){if(epoch&&(ioread32(ring)!=0x56324352||ioread32(ring+4*12)!=epoch)){rc=-EBUSY;goto out;}release_all();rc=0;goto out;}
 if(cmd==ARM){unsigned int i;
 if(copy_from_user(&e,(void __user*)arg,sizeof(e))){rc=-EFAULT;goto out;}
 if(!e)goto out;
 for(i=0;i<ARRAY_SIZE(p);i++)if(!p[i].b)goto out;
 /* Never replace a live epoch before the host explicitly drained it. */
 if(epoch && (ioread32(ring)!=0x56324352 || ioread32(ring+4*12)!=epoch)){rc=-EBUSY;goto out;}
 epoch=e;rc=0;goto out;}
 if(cmd!=IMPORT||copy_from_user(&r,(void __user*)arg,sizeof(r))||r.slot>=16||p[r.slot].b||epoch)goto out;
 b=dma_buf_get(r.fd);if(IS_ERR(b)){rc=PTR_ERR(b);goto out;}if(b->size!=4*1024*1024)goto put;a=dma_buf_attach(b,master);if(IS_ERR(a)){rc=PTR_ERR(a);goto put;}t=dma_buf_map_attachment(a,DMA_TO_DEVICE);if(IS_ERR(t)){rc=PTR_ERR(t);goto detach;}
 r.address=sg_dma_address(t->sgl);end=r.address+b->size;if(t->nents!=1||sg_dma_len(t->sgl)<b->size||!r.address||(r.address&15)||end<=r.address|| !(end<=0x80000000ULL||(r.address>=0x800000000ULL&&end<=0x1000000000ULL)))goto unmap;
 if(copy_to_user((void __user*)arg,&r,sizeof(r)))goto unmap;__module_get(THIS_MODULE);p[r.slot]=(struct entry){b,a,t};rc=0;goto out;
 unmap:dma_buf_unmap_attachment(a,t,DMA_TO_DEVICE);detach:dma_buf_detach(b,a);put:dma_buf_put(b);out:mutex_unlock(&lock);return rc;}
static int open2(struct inode*i,struct file*f){int rc=0;mutex_lock(&lock);if(opened||epoch)rc=-EBUSY;else opened=1;mutex_unlock(&lock);return rc;}
static int close2(struct inode*i,struct file*f){mutex_lock(&lock);if(!epoch)release_all();opened=0;mutex_unlock(&lock);return 0;}
static const struct file_operations ops={.owner=THIS_MODULE,.open=open2,.release=close2,.unlocked_ioctl=op};static struct miscdevice misc={.minor=MISC_DYNAMIC_MINOR,.name="sc7f0-stage2",.fops=&ops,.mode=0600};
static int probe(struct platform_device*d){int rc;master=&d->dev;rc=dma_set_mask_and_coherent(master,DMA_BIT_MASK(40));if(rc)return rc;ring=devm_ioremap(master,0xa0002200,64);if(!ring)return -ENOMEM;return misc_register(&misc);}
static int remove2(struct platform_device*d){misc_deregister(&misc);return 0;}
static const struct of_device_id match[]={{.compatible="sc7f0,packet-reader-hp1-v2"},{}};
static struct platform_driver drv={.probe=probe,.remove=remove2,.driver={.name="sc7f0-stage2",.of_match_table=match,.suppress_bind_attrs=true}};module_platform_driver(drv);MODULE_LICENSE("GPL");MODULE_IMPORT_NS(DMA_BUF);
