#define _GNU_SOURCE
#include <errno.h>
#include <sys/epoll.h>
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
  mkdir("/sys/fs",0755); mkdir("/sys/fs/selinux",0755);
  if(mount("selinuxfs","/sys/fs/selinux","selinuxfs",0,NULL)<0) perror("mount selinuxfs");
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
  if(access("/system/etc/selinux/plat_service_contexts",R_OK)==0)
    logmsg("PASS Android 11 platform service contexts available\n");
  else logmsg("WARN Android 11 platform service contexts unavailable\n");
  if(access("/sys/fs/selinux/policy",R_OK)==0)
    logmsg("PASS SELinux policy interface available\n");
  else logmsg("WARN SELinux policy interface unavailable\n");
  int epfd=epoll_create1(EPOLL_CLOEXEC);
  if(epfd<0) {
    perror("epoll_create1");
    logmsg("FAIL epoll_create1 unavailable in QEMU guest\n");
  } else {
    logmsg("PASS epoll_create1 available in QEMU guest\n");
    close(epfd);
  }
  mkdir("/dev/binderfs",0755);
  int fd=open("/dev/binder",O_RDWR);
  if(fd<0){perror("open /dev/binder");logmsg("FAIL Binder device unavailable\n");}
  else {logmsg("PASS Binder device opened for real servicemanager test\n");close(fd);}
  // Preserve the genuine process stderr/stdout, including Android abort messages.
  int childpipe[2]={-1,-1};
  if(pipe2(childpipe,O_CLOEXEC|O_NONBLOCK)<0) {
    perror("pipe2 servicemanager diagnostics");
    logmsg("FAIL servicemanager diagnostic pipe unavailable\n");
    return 1;
  }
  pid_t child=fork();
  if(child==0){
    close(childpipe[0]);
    if(dup2(childpipe[1],1)<0 || dup2(childpipe[1],2)<0) _exit(126);
    close(childpipe[1]);
    setenv("LD_LIBRARY_PATH","/system/lib64",1);
    setenv("ANDROID_LOG_TAGS","*:v",1);
    execl("/system/bin/servicemanager","servicemanager",NULL);
    perror("exec servicemanager");
    _exit(127);
  }
  close(childpipe[1]);
  if(child<0){perror("fork");close(childpipe[0]);return 1;}
  int status=0;
  for(int i=0;i<50;i++) {
    {
      char buf[2048];
      ssize_t n;
      while((n=read(childpipe[0],buf,sizeof(buf)-1))>0) {
        buf[n]=0;
        logmsg("SERVICEMANAGER STDOUT/ERR: ");
        // Preserve output exactly, including fatal libc and linker diagnostics.
        logmsg(buf);
        if(buf[n-1]!='\n') logmsg("\n");
      }
    }
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
  // Drain messages emitted immediately before a fatal exit.
  {
    char buf[2048];
    ssize_t n;
    while((n=read(childpipe[0],buf,sizeof(buf)-1))>0) {
      buf[n]=0;
      logmsg("SERVICEMANAGER STDOUT/ERR: ");
      logmsg(buf);
      if(buf[n-1]!='\n') logmsg("\n");
    }
  }
  close(childpipe[0]);
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
