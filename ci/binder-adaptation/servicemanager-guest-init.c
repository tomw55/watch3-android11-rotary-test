#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/sysmacros.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
static void logmsg(const char *s) { size_t n=strlen(s); while(n) { ssize_t w=write(1,s,n); if(w<0) { if(errno==EINTR) continue; break; } if(w==0) break; s+=w; n-=(size_t)w; } }
int main(void) {
  mkdir("/proc",0755); mkdir("/sys",0755); mkdir("/dev",0755);
  mount("proc","/proc","proc",0,NULL);
  mount("sysfs","/sys","sysfs",0,NULL);
  mount("devtmpfs","/dev","devtmpfs",0,NULL);
  int console=open("/dev/console",O_RDWR);
  if(console>=0){dup2(console,0);dup2(console,1);dup2(console,2);}
  logmsg("PASS guest servicemanager init started\n");
  // Android's liblog sends diagnostic records to /dev/socket/logdw.
  // Capture those messages even without a full Android logd userspace.
  mkdir("/dev/socket",0755);
  int logfd=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK,0);
  if(logfd>=0) {
    struct sockaddr_un addr={0};
    addr.sun_family=AF_UNIX;
    strncpy(addr.sun_path,"/dev/socket/logdw",sizeof(addr.sun_path)-1);
    unlink(addr.sun_path);
    if(bind(logfd,(struct sockaddr *)&addr,sizeof(addr))<0) {
      perror("bind logdw");close(logfd);logfd=-1;
    } else logmsg("PASS Android logdw diagnostic socket ready\n");
  }
  if(access("/dev/kmsg",F_OK)!=0)
    mknod("/dev/kmsg",S_IFCHR|0600,makedev(1,11));
  mkdir("/dev/binderfs",0755);
  int fd=open("/dev/binder",O_RDWR);
  if(fd<0){perror("open /dev/binder");logmsg("FAIL Binder device unavailable\n");}
  else {logmsg("PASS Binder device opened for real servicemanager test\n");close(fd);}
  pid_t child=fork();
  if(child==0){
    setenv("LD_LIBRARY_PATH","/system/lib64",1);
    setenv("ANDROID_LOG_TAGS","*:v",1);
    execl("/system/bin/servicemanager","servicemanager",NULL);
    perror("exec servicemanager");
    _exit(127);
  }
  if(child<0){perror("fork");return 1;}
  int status=0;
  for(int i=0;i<50;i++) {
    if(logfd>=0) {
      char buf[4096];
      ssize_t n;
      while((n=recv(logfd,buf,sizeof(buf),MSG_DONTWAIT))>0) {
        logmsg("ANDROID LOG: ");
        // logd datagrams contain a binary header and NUL-delimited tag/message.
        // Render printable bytes so fatal reasons are visible in serial logs.
        for(ssize_t k=0;k<n;k++) {
          unsigned char c=(unsigned char)buf[k];
          char out=(c>=32 && c<127)?(char)c:' ';
          if(write(1,&out,1)<0) break;
        }
        logmsg("\n");
      }
    }
    usleep(100000);
  }
  pid_t result=waitpid(child,&status,WNOHANG);
  if(result==0) {
    logmsg("PASS real Android 11 servicemanager process alive after 5 seconds\n");
  } else if(result==child) {
    if(WIFEXITED(status))printf("RESULT real Android 11 servicemanager exited status=%d\n",WEXITSTATUS(status));
    else if(WIFSIGNALED(status))printf("RESULT real Android 11 servicemanager signal=%d\n",WTERMSIG(status));
  } else {
    perror("waitpid servicemanager");
    logmsg("FAIL servicemanager waitpid\n");
  }
  fflush(stdout);
  for(;;)pause();
}
