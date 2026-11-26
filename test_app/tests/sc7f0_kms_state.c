/* No KMS device: inject only the commit ioctl and its kernel flip record.
 * Real atomic request construction, poll and libdrm event decoding are used. */
#define main client_main
#include "../sc7f0_kms.c"
#undef main
#include <assert.h>
#include <sys/wait.h>

static int writer, count;
static const char ids[]="ABCE-";
int __wrap_drmModeAtomicCommit(int fd, const drmModeAtomicReq *req,
			       uint32_t flags, void *data)
{
	struct client *c=data;
	assert(req && fd==c->fd && c->pending==-1);
	assert(count<5 && c->wanted==ids[count]);
	assert(flags & DRM_MODE_PAGE_FLIP_EVENT);
	assert(flags & DRM_MODE_ATOMIC_NONBLOCK);
	assert(!!(flags & DRM_MODE_ATOMIC_ALLOW_MODESET)==(count==0 || count==4));
	struct drm_event_vblank e={
		.base={.type=DRM_EVENT_FLIP_COMPLETE,.length=sizeof(e)},
		.user_data=(uintptr_t)c,.sequence=++count
	};
	assert(write(writer,&e,sizeof(e))==(ssize_t)sizeof(e));
	return 0;
}

int main(void)
{
	int fds[2];
	assert(!pipe(fds)); writer=fds[1];
	struct client c={.fd=fds[0],.front=-1,.pending=-1,.modeset=true,
		.conn=1,.crtc=2,.plane=3,.conn_route=1,.active=2,.mode_id=3,.blob=4,
		.mode={.hdisplay=120,.vdisplay=120}};
	for (int i=0; i<NPROP; i++) c.p[i]=i+10;
	uint8_t pixels[2][120][484], frozen[sizeof(pixels)];
	memset(pixels,0xdd,sizeof(pixels));
	for (int i=0; i<2; i++) c.buf[i]=(struct buffer){i+1,484,&pixels[i][0][0]};
	input(&c,'A'); drain(&c);
	assert(c.front==0 && c.pending==-1);
	assert(!memcmp(pixels[0][0],"\0\0\0\0",4));
	assert(!memcmp(&pixels[0][10][40],"\xff\0\0\x80",4)); /* straight alpha */
	assert(!memcmp(&pixels[0][20][120],"\xff\xff\xff\xff",4)); /* glyph A */
	for (int y=0;y<120;y++) assert(pixels[0][y][480]==0xdd);
	hold(&c,10); input(&c,'A'); submit(&c); assert(count==1);
	input(&c,'B'); drain(&c); assert(c.front==1);
	memcpy(frozen,pixels,sizeof(pixels));
	input(&c,'C'); submit(&c);
	assert(!memcmp(frozen+sizeof(pixels[0]),pixels[1],sizeof(pixels[1])));
	assert(c.front==1 && c.pending==0);
	memcpy(frozen,pixels,sizeof(pixels));
	input(&c,'D'); submit(&c); input(&c,'E'); submit(&c);
	assert(count==3 && !memcmp(frozen,pixels,sizeof(pixels)));
	drain(&c); assert(count==4 && c.front==1 && c.shown=='E');
	input(&c,'-'); drain(&c); assert(count==5 && c.front==-1);
	/* Missing completion with both slots owned must be fatal. */
	fflush(NULL);
	pid_t pid=fork(); assert(pid>=0);
	if (!pid) { c.front=0; c.pending=1; c.submitted='B'; c.deadline=now(); events(&c,false,-1); _exit(0); }
	int status;
	assert(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==1);
	puts("PASS: idle, ownership, coalescing, alpha, disable and lost-event exit");
	return 0;
}
