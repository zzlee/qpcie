#pragma once
#include <linux/types.h>
#include <linux/ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
// UAPI layouts from linux/dma-heap.h and linux/dma-buf.h, named privately for the old cross sysroot.
struct heap_request { uint64_t len; uint32_t fd,fd_flags; uint64_t heap_flags; };
struct sync_request { uint64_t flags; };
struct owned_slot {int fd=-1; unsigned char* map=nullptr;size_t cap=0;};
static bool alloc_slot(int heap,owned_slot &s,size_t cap){heap_request r={cap,0,O_RDWR|O_CLOEXEC,0};if(ioctl(heap,_IOWR('H',0,heap_request),&r)<0)return false;s.fd=r.fd;s.cap=cap;void*p=mmap(nullptr,cap,PROT_READ|PROT_WRITE,MAP_SHARED,s.fd,0);if(p==MAP_FAILED){close(s.fd);s.fd=-1;return false;}s.map=(unsigned char*)p;return true;}
static bool cache_sync(int fd,unsigned flags){sync_request r={flags};int rc;do{rc=ioctl(fd,_IOW('b',0,sync_request),&r);}while(rc<0&&errno==EINTR);return rc==0;}
// No bus address is inferred from an fd. A real device attachment must supply its own DMA mapping.
static int stage(owned_slot& s,const void* payload,size_t n,size_t host_cap,size_t& wire){wire=0;if(n==0||n>SIZE_MAX-15)return -EINVAL;size_t a=(n+15)&~size_t(15);if(a>s.cap||a>host_cap||a>8*1024*1024)return -EMSGSIZE;if(!cache_sync(s.fd,2))return -EIO;memcpy(s.map,payload,n);memset(s.map+n,0,a-n);if(!cache_sync(s.fd,2|4))return -EIO;wire=a;return 0;}
static void free_slot(owned_slot& s){if(s.map)munmap(s.map,s.cap);if(s.fd>=0)close(s.fd);}
