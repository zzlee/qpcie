#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
#include <string.h>
#define check(x) do{if(!(x)){fprintf(stderr,"%s errno=%d %s\n",#x,errno,strerror(errno));exit(2);}}while(0)
int main(int argc,char**argv){check(argc==4);int fd=open("/dev/video1",O_RDWR|O_NONBLOCK);check(fd>=0);int t=V4L2_BUF_TYPE_VIDEO_CAPTURE;struct v4l2_format f={.type=t};f.fmt.pix.width=3840;f.fmt.pix.height=2160;f.fmt.pix.pixelformat=getenv("HEVC")?V4L2_PIX_FMT_HEVC:V4L2_PIX_FMT_H264;check(ioctl(fd,VIDIOC_S_FMT,&f)==0);struct v4l2_requestbuffers r={.type=t,.memory=V4L2_MEMORY_MMAP,.count=9};check(ioctl(fd,VIDIOC_REQBUFS,&r)==0&&r.count==9);void*m[9];unsigned cap[9];for(unsigned i=0;i<9;i++){struct v4l2_buffer b={.type=t,.memory=r.memory,.index=i};check(!ioctl(fd,VIDIOC_QUERYBUF,&b));cap[i]=b.length;m[i]=mmap(NULL,b.length,PROT_READ|PROT_WRITE,MAP_SHARED,fd,b.m.offset);check(m[i]!=MAP_FAILED);check(!ioctl(fd,VIDIOC_QBUF,&b));}check(!ioctl(fd,VIDIOC_STREAMON,&t));if(getenv("STOPMS"))usleep(atoi(getenv("STOPMS"))*1000);unsigned n=atoi(argv[1]);FILE*out=fopen(argv[2],"wbx"),*meta=fopen(argv[3],"wx");check(out&&meta);double start=now();for(unsigned i=0;now()-start<n;i++){struct pollfd p={fd,POLLIN,0};check(poll(&p,1,7000)>0);struct v4l2_buffer b={.type=t,.memory=r.memory};check(!ioctl(fd,VIDIOC_DQBUF,&b));check(b.index<9&&b.bytesused<=cap[b.index]&&b.bytesused&&!(b.flags&V4L2_BUF_FLAG_ERROR));double dq=now();check(fwrite(m[b.index],1,b.bytesused,out)==b.bytesused);fprintf(meta,"%u %u %u %ld %ld %.9f\n",b.sequence,b.index,b.bytesused,b.timestamp.tv_sec,b.timestamp.tv_usec,dq);check(!ioctl(fd,VIDIOC_QBUF,&b));}check(!ioctl(fd,VIDIOC_STREAMOFF,&t));/* Late host writes must never touch returned MMAP planes. */for(unsigned i=0;i<9;i++)memset(m[i],0x31+i,cap[i]);usleep(250000);for(unsigned i=0;i<9;i++){unsigned char*b=m[i];for(unsigned j=0;j<cap[i];j++)check(b[j]==0x31+i);munmap(m[i],cap[i]);}close(fd);check(!fclose(out)&&!fclose(meta));}
