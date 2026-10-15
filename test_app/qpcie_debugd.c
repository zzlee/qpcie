// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include "qpcie_debug_io.h"
#include <signal.h>
#include <sys/wait.h>
#include <sys/prctl.h>

static volatile sig_atomic_t stopping;
static void stop_handler(int sig) { (void)sig; stopping = 1; }
struct job {
    pid_t pid;
    int out[2], status, forced;
    bool exited;
    uint32_t id, budget;
    uint64_t started;
};
static void kill_job(struct job *j)
{
    if (j->pid > 0) {
        kill(-j->pid, SIGKILL);
        while (waitpid(j->pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    for (int i=0; i<2; ++i) if (j->out[i] >= 0) close(j->out[i]);
    memset(j, 0, sizeof(*j)); j->out[0] = j->out[1] = -1;
}
static int start_job(struct job *j, const char *shell, char *command,
                      uint32_t id, uint32_t budget)
{
    int a[2], b[2];
    if (pipe2(a, O_CLOEXEC)) return -1;
    if (pipe2(b, O_CLOEXEC)) { close(a[0]); close(a[1]); return -1; }
    pid_t parent = getpid(), pid = fork();
    if (pid == 0) {
        /* Best-effort orphan protection for shell itself; see docs for limits
         * on commands that deliberately escape the process group. */
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (getppid() != parent) _exit(125);
        if (setpgid(0, 0)) _exit(125);
        int in = open("/dev/null", O_RDONLY);
        if (in < 0 || dup2(in, 0) < 0 || dup2(a[1], 1) < 0 || dup2(b[1], 2) < 0)
            _exit(125);
        // A standalone daemon can start with closed stdio, so pipe fds
        // themselves may be 0/1/2. Do not close newly duplicated stdio.
        int inherited[] = {in, a[0], a[1], b[0], b[1]};
        for (unsigned i=0; i<sizeof(inherited)/sizeof(inherited[0]); ++i)
            if (inherited[i]>2) close(inherited[i]);
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        execl(shell, shell, "-c", command, (char *)NULL);
        _exit(127);
    }
    close(a[1]); close(b[1]);
    if (pid < 0) { close(a[0]); close(b[0]); return -1; }
    setpgid(pid, pid);
    j->pid = pid; j->out[0] = a[0]; j->out[1] = b[0];
    j->id = id; j->budget = budget; j->started = db_now();
    for (int i=0; i<2; ++i) {
        int flags=fcntl(j->out[i], F_GETFL);
        if (flags<0 || fcntl(j->out[i], F_SETFL, flags | O_NONBLOCK)<0) {
            kill_job(j); return -1;
        }
    }
    return 0;
}
int main(int argc, char **argv)
{
    const char *path = "/dev/mem", *shell = "/bin/sh";
    bool sim = false, allow_exec = false;
    for (int i=1; i<argc; ++i) {
        if (!strcmp(argv[i], "--sim") && i+1<argc) { path=argv[++i]; sim=true; }
        else if (!strcmp(argv[i], "--shell") && i+1<argc) shell=argv[++i];
        else if (!strcmp(argv[i], "--allow-exec")) allow_exec=true;
        else { fprintf(stderr,"Usage: %s [--allow-exec] [--shell /bin/bash] [--sim FILE]\n",argv[0]); return 2; }
    }
    if (allow_exec && access(shell, X_OK)) { perror(shell); return 2; }
    signal(SIGTERM, stop_handler); signal(SIGINT, stop_handler);
    signal(SIGCHLD, SIG_DFL); // preserve child PID until explicit wait/reap
    signal(SIGPIPE, SIG_IGN);
    struct db_io io;
    if (db_open(&io,path,true,sim)) { db_close(&io); return 125; }
    if (!db_valid(&io)) {
        fprintf(stderr,"Debug mailbox ABI/magic mismatch; no writes performed\n");
        db_close(&io); return 125;
    }
    struct job j = {.out={-1,-1}};
    char payload[DB_PAYLOAD+1], command[DB_PAYLOAD+1];
    unsigned pending_len=0, pending_type=0, pending_id=0, pending_code=0;
    uint32_t epoch=db_random(), session=0, blocked=0, beat=0;
    uint64_t host_seen=db_now();
    unsigned fair=0;
    db_wr(&io,DB_READY,0);
    db_wr(&io,DB_ACK_EPOCH,0);
    db_wr(&io,DB_H2C_ACK,db_rd(&io,DB_H2C_SEQ));
    db_wr(&io,DB_C2H_SEQ,db_rd(&io,DB_C2H_ACK));
    db_wr(&io,DB_CARD_EPOCH,epoch);
    db_wr(&io,DB_CARD_BEAT,(uint32_t)db_now());
    db_wr(&io,DB_READY,1);
    fprintf(stderr,"Debug mailbox ready (exec %s, shell %s)\n",allow_exec?"enabled":"disabled",shell);
    while (!stopping && !io.failed) {
        uint64_t now=db_now();
        db_wr(&io,DB_CARD_BEAT,(uint32_t)now);
        if (!db_valid(&io) || db_rd(&io,DB_CARD_EPOCH)!=epoch) break;
        uint32_t host=db_rd(&io,DB_HOST_EPOCH);
        if (host && host!=UINT32_MAX && host!=session && host!=blocked) {
            kill_job(&j); pending_type=0;
            session=host; beat=db_rd(&io,DB_HOST_BEAT); host_seen=now;
            db_wr(&io,DB_H2C_ACK,db_rd(&io,DB_H2C_SEQ));
            db_wr(&io,DB_C2H_SEQ,db_rd(&io,DB_C2H_ACK));
            db_wr(&io,DB_ACK_EPOCH,session); // last: both slots drained
        }
        if (!session) { db_pause(); continue; }
        uint32_t newbeat=db_rd(&io,DB_HOST_BEAT);
        if (newbeat!=beat) { beat=newbeat; host_seen=now; }
        if (now-host_seen>DB_PEER_DEAD_MS) {
            kill_job(&j); pending_type=0; blocked=session; session=0;
            db_wr(&io,DB_ACK_EPOCH,0); continue;
        }
        uint32_t seq=db_rd(&io,DB_H2C_SEQ);
        if (seq!=db_rd(&io,DB_H2C_ACK)) {
            unsigned type=db_rd(&io,DB_H2C_TYPE), id=db_rd(&io,DB_H2C_ID);
            unsigned len=db_rd(&io,DB_H2C_LEN), budget=db_rd(&io,DB_TIMEOUT_MS);
            if (len>DB_PAYLOAD || !id || (type==DB_EXEC &&
                (!len || len>=DB_PAYLOAD || !budget || budget>DB_MAX_TIMEOUT))) {
                /* Corrupt framing: abandon session rather than interpret data. */
                kill_job(&j); pending_type=0; blocked=session; session=0;
                db_wr(&io,DB_ACK_EPOCH,0); continue;
            }
            if (j.pid && type!=DB_CANCEL) {
                // A second command cannot replace an in-flight request.
                kill_job(&j); pending_type=0; blocked=session; session=0;
                db_wr(&io,DB_ACK_EPOCH,0); continue;
            }
            if (pending_type && type!=DB_CANCEL) { db_pause(); continue; }
            db_payload(&io,DB_H2C_DATA,command,len,false); command[len]=0;
            if (db_rd(&io,DB_HOST_EPOCH)!=session) continue;
            db_wr(&io,DB_H2C_ACK,seq);
            if (type==DB_CANCEL) {
                if (j.pid && id==j.id && !j.forced) {
                    j.forced=125; kill(-j.pid,SIGKILL);
                }
            } else if (type==DB_ECHO) {
                memcpy(payload,command,len);
                pending_type=DB_ECHO_REPLY; pending_id=id; pending_len=len; pending_code=0;
            } else if (type==DB_EXEC) {
                if (!allow_exec || memchr(command,0,len) ||
                    start_job(&j,shell,command,id,budget)) {
                    pending_type=DB_EXIT; pending_id=id; pending_len=0;
                    pending_code=allow_exec?125:126;
                }
            } else {
                pending_type=DB_EXIT; pending_id=id; pending_len=0; pending_code=125;
            }
        }
        if (j.pid) {
            if (!j.forced && now>=j.started && now-j.started>=j.budget) {
                j.forced=124; kill(-j.pid,SIGKILL);
            }
            if (!j.exited) {
                // Keep the exited shell as a zombie until all output drains:
                // its PID/PGID cannot be reused before kill_job() cleans the
                // process group. Reaping early risks killing a reused PGID.
                siginfo_t info={0};
                int result=waitid(P_PID,j.pid,&info,WEXITED|WNOHANG|WNOWAIT);
                if (!result && info.si_pid==j.pid) {
                    j.exited=true;
                    j.status=info.si_code==CLD_EXITED ? info.si_status : 128+info.si_status;
                } else if (result<0 && errno!=EINTR) { j.exited=true; j.forced=125; }
            }
        }
        bool free_slot=db_rd(&io,DB_C2H_SEQ)==db_rd(&io,DB_C2H_ACK);
        if (free_slot && pending_type) {
            db_send(&io,true,pending_type,pending_id,payload,pending_len,pending_code);
            pending_type=0;
        } else if (free_slot && j.pid) {
            bool sent=false;
            for (unsigned k=0;k<2;++k) {
                unsigned i=(fair+k)%2;
                if (j.out[i]<0) continue;
                ssize_t n=read(j.out[i],payload,DB_PAYLOAD);
                if (n>0) {
                    db_send(&io,true,i?DB_STDERR:DB_STDOUT,j.id,payload,n,0);
                    fair=1-i; sent=true; break;
                }
                if (n==0 || (n<0 && errno!=EAGAIN && errno!=EINTR)) {
                    close(j.out[i]); j.out[i]=-1;
                }
            }
            if (!sent && j.exited && j.out[0]<0 && j.out[1]<0) {
                unsigned code=j.forced ? j.forced : j.status;
                db_send(&io,true,DB_EXIT,j.id,payload,0,code);
                kill_job(&j); // also terminate background descendants in group
            }
        }
        db_pause();
    }
    kill_job(&j);
    if (!io.failed && db_valid(&io)) db_wr(&io,DB_READY,0);
    db_close(&io);
    return stopping ? 0 : 125;
}
