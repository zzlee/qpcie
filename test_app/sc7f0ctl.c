// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include "qpcie_debug_io.h"
#include <signal.h>

static volatile sig_atomic_t interrupted;
static void on_signal(int sig) { interrupted=sig; }
struct peer {
    struct db_io *io;
    uint32_t card, host, beat;
    uint64_t seen;
};
static int peer_ok(struct peer *p)
{
    struct db_io *io=p->io;
    uint64_t now=db_now();
    db_wr(io,DB_HOST_BEAT,(uint32_t)now);
    if (!db_valid(io) || db_rd(io,DB_READY)!=1 ||
        db_rd(io,DB_CARD_EPOCH)!=p->card || db_rd(io,DB_HOST_EPOCH)!=p->host)
        return 0;
    uint32_t beat=db_rd(io,DB_CARD_BEAT);
    if (beat!=p->beat) { p->beat=beat; p->seen=now; }
    return now-p->seen<=DB_PEER_DEAD_MS && !io->failed;
}
static int attach(struct peer *p)
{
    struct db_io *io=p->io;
    if (!db_valid(io) || db_rd(io,DB_READY)!=1) return -1;
    p->card=db_rd(io,DB_CARD_EPOCH); p->host=db_random();
    if (!p->card || p->card==UINT32_MAX) return -1;
    p->beat=db_rd(io,DB_CARD_BEAT); p->seen=db_now();
    // Both nonce and observed heartbeat change are needed: reject stale READY.
    uint32_t oldbeat=p->beat;
    db_wr(io,DB_HOST_BEAT,(uint32_t)db_now());
    db_wr(io,DB_HOST_EPOCH,p->host);
    uint64_t end=db_now()+DB_PEER_DEAD_MS;
    while (!interrupted && db_now()<end && peer_ok(p)) {
        if (db_rd(io,DB_ACK_EPOCH)==p->host && p->beat!=oldbeat) return 0;
        db_pause();
    }
    return -1;
}
static int transact(struct peer *p, unsigned type, uint32_t id, void *data,
                    unsigned len, unsigned timeout)
{
    struct db_io *io=p->io;
    if (interrupted) return 128+interrupted;
    if (db_rd(io,DB_H2C_SEQ)!=db_rd(io,DB_H2C_ACK)) return 125;
    db_wr(io,DB_TIMEOUT_MS,timeout);
    db_send(io,false,type,id,data,len,0);
    uint64_t end=db_now()+timeout+DB_PEER_DEAD_MS;
    bool cancel_sent=false;
    while (db_now()<end && peer_ok(p) && db_rd(io,DB_ACK_EPOCH)==p->host) {
        if (interrupted && !cancel_sent && type==DB_EXEC &&
            db_rd(io,DB_H2C_SEQ)==db_rd(io,DB_H2C_ACK)) {
            db_send(io,false,DB_CANCEL,id,NULL,0,0); cancel_sent=true;
            end=db_now()+DB_PEER_DEAD_MS;
        }
        uint32_t seq=db_rd(io,DB_C2H_SEQ);
        if (seq!=db_rd(io,DB_C2H_ACK)) {
            unsigned kind=db_rd(io,DB_C2H_TYPE), rid=db_rd(io,DB_C2H_ID);
            unsigned n=db_rd(io,DB_C2H_LEN), code=db_rd(io,DB_C2H_CODE);
            char buf[DB_PAYLOAD];
            if (rid!=id || n>DB_PAYLOAD) break;
            db_payload(io,DB_C2H_DATA,buf,n,false);
            if (!peer_ok(p) || db_rd(io,DB_ACK_EPOCH)!=p->host) break;
            if (type==DB_ECHO) {
                if (kind!=DB_ECHO_REPLY || n!=len || memcmp(buf,data,len)) break;
                db_wr(io,DB_C2H_ACK,seq); return 0;
            }
            if (kind==DB_EXIT) {
                if (n || code>255) break;
                db_wr(io,DB_C2H_ACK,seq);
                return interrupted ? 128+interrupted : (int)code;
            }
            if (kind!=DB_STDOUT && kind!=DB_STDERR) break;
            FILE *stream=kind==DB_STDOUT?stdout:stderr;
            if (fwrite(buf,1,n,stream)!=n || fflush(stream)) break;
            db_wr(io,DB_C2H_ACK,seq); // only after successful consumption
        }
        db_pause();
    }
    fprintf(stderr,"Debug transport lost/timed out; command outcome may be unknown. NOT retried.\n");
    return interrupted ? 128+interrupted : 125;
}
static int usage(const char *name)
{
    fprintf(stderr,"Usage: %s [--device NODE | --sim FILE] [--timeout SECONDS]\n"
                   "       status | exec 'COMMAND' | echo 'TEXT' | loopback BYTES\n",name);
    return 2;
}
int main(int argc, char **argv)
{
    const char *path="/dev/qpcie-debug-0000:03:00.0";
    bool sim=false;
    unsigned timeout=10000;
    int arg=1;
    while (arg<argc && !strncmp(argv[arg],"--",2)) {
        if ((!strcmp(argv[arg],"--device") || !strcmp(argv[arg],"--sim")) && arg+1<argc) {
            sim=!strcmp(argv[arg],"--sim"); path=argv[arg+1]; arg+=2;
        } else if (!strcmp(argv[arg],"--timeout") && arg+1<argc) {
            char *end; errno=0; double n=strtod(argv[arg+1],&end);
            if (errno || !*argv[arg+1] || *end || !(n>=0.001 && n<=300)) return usage(argv[0]);
            timeout=(unsigned)(n*1000); arg+=2;
        } else return usage(argv[0]);
    }
    if (arg>=argc) return usage(argv[0]);
    const char *op=argv[arg++], *value=arg<argc?argv[arg++]:NULL;
    if (arg!=argc || (strcmp(op,"status") && strcmp(op,"exec") &&
        strcmp(op,"echo") && strcmp(op,"loopback")) ||
        (!strcmp(op,"status") ? value!=NULL : value==NULL)) return usage(argv[0]);
    unsigned length=value?strlen(value):0;
    uint64_t total=0;
    if (!strcmp(op,"loopback")) {
        if (!value) return usage(argv[0]);
        char *end; errno=0; total=strtoull(value,&end,0);
        if (errno || !*value || *end || !total || total>64*1024*1024) return usage(argv[0]);
    } else if (length>DB_PAYLOAD || (!strcmp(op,"exec") && (!length || length>=DB_PAYLOAD)))
        return usage(argv[0]);
    signal(SIGINT,on_signal); signal(SIGTERM,on_signal); signal(SIGPIPE,SIG_IGN);
    struct db_io io;
    if (db_open(&io,path,false,sim)) { db_close(&io); return 125; }
    int rc=125;
    if (!db_valid(&io)) { fprintf(stderr,"Unsupported debug ABI/magic\n"); goto done; }
    if (!strcmp(op,"status")) {
        printf("ABI=%u ready=%u card_epoch=%08x card_beat=%u\n",QDBG_ABI,
               db_rd(&io,DB_READY),db_rd(&io,DB_CARD_EPOCH),db_rd(&io,DB_CARD_BEAT));
        rc=io.failed?125:0; goto done;
    }
    struct peer p={.io=&io};
    if (attach(&p)) {
        fprintf(stderr,"PS debug daemon unavailable; no command submitted\n");
        if (interrupted) rc=128+interrupted;
        goto done;
    }
    if (!strcmp(op,"loopback")) {
        unsigned char buf[DB_PAYLOAD]; uint64_t checked=0; uint32_t id=1;
        while (checked<total && !interrupted) {
            unsigned n=total-checked>DB_PAYLOAD?DB_PAYLOAD:(unsigned)(total-checked);
            unsigned filled=0;
            while (filled<n) {
                ssize_t got=getrandom(buf+filled,n-filled,0);
                if (got>0) filled+=(unsigned)got;
                else if (got<0 && errno==EINTR) continue;
                else { perror("getrandom"); rc=125; goto done; }
            }
            rc=transact(&p,DB_ECHO,id++,buf,n,timeout);
            if (rc) goto done;
            checked+=n;
        }
        rc=interrupted?128+interrupted:0;
        if (!rc) printf("LOOPBACK_PASS: %llu bytes\n",(unsigned long long)checked);
    } else {
        rc=transact(&p,!strcmp(op,"exec")?DB_EXEC:DB_ECHO,1,(void *)value,length,timeout);
        if (!rc && !strcmp(op,"echo")) puts(value);
    }
done:
    db_close(&io); return rc;
}
