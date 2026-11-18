#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <time.h>
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
  // Determine whether the test name actually resolves in the packaged
  // Android 11 service-label map, without modifying the production map.
  {
    FILE *contexts=fopen("/system/etc/selinux/plat_service_contexts","r");
    if(contexts) {
      char line[1024]; int matched=0;
      while(fgets(line,sizeof(line),contexts)) {
        char name[256],label[512];
        if(sscanf(line," %255s %511s",name,label)==2 &&
           strcmp(name,"watch3.test.echo")==0) {
          printf("DIAG service_contexts watch3.test.echo label=%s\\n",label);
          matched=1;
        }
      }
      fclose(contexts);
      if(!matched) logmsg("DIAG service_contexts has NO watch3.test.echo entry\\n");
    }
  }
  {
    char buf[128]; int f=open("/sys/fs/selinux/enforce",O_RDONLY);
    if(f>=0) { ssize_t n=read(f,buf,sizeof(buf)-1); close(f);
      if(n>0) { buf[n]=0; printf("DIAG SELinux enforcing=%s",buf); if(buf[n-1]!='\\n')puts(""); }
    } else perror("DIAG open selinux enforce");
  }
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
  int timerfd=timerfd_create(CLOCK_MONOTONIC,TFD_CLOEXEC);
  if(timerfd<0) {
    perror("timerfd_create");
    logmsg("FAIL timerfd_create unavailable in QEMU guest\n");
  } else {
    logmsg("PASS timerfd_create available in QEMU guest\n");
    close(timerfd);
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
  // Register a local Binder node using a separate process, then discover it
  // with the genuine Android 11 service CLI.
  pid_t registrar=-1;
  int registrarpipe[2]={-1,-1};
  if(result==0) {
    if(pipe2(registrarpipe,O_CLOEXEC|O_NONBLOCK)<0) {
      perror("pipe2 registrar");
      logmsg("FAIL registrar diagnostics pipe\n");
      return 1;
    }
    registrar=fork();
    if(registrar==0) {
      close(registrarpipe[0]);
      if(dup2(registrarpipe[1],1)<0 || dup2(registrarpipe[1],2)<0) _exit(126);
      close(registrarpipe[1]);
      setenv("LD_LIBRARY_PATH","/system/lib64",1);
      execl("/register-test-service","register-test-service",NULL);
      perror("exec /register-test-service");
      _exit(127);
    }
    close(registrarpipe[1]);
    if(registrar<0) {
      perror("fork register-test-service");
      logmsg("FAIL Android 11 test service registrar fork\\n");
    } else {
      for(int i=0;i<20;i++) {
        char buf[2048];
        ssize_t n;
        while((n=read(registrarpipe[0],buf,sizeof(buf)-1))>0) {
          buf[n]=0;
          logmsg("REGISTRAR: ");
          logmsg(buf);
          if(buf[n-1]!='\n') logmsg("\n");
        }
        if(logfd>=0) {
          char logbuf[4096];
          ssize_t ln;
          while((ln=recv(logfd,logbuf,sizeof(logbuf),MSG_DONTWAIT))>0) {
            logmsg("ANDROID REGISTRATION LOG: ");
            for(ssize_t k=0;k<ln;k++) {
              unsigned char c=(unsigned char)logbuf[k];
              char out=(c>=32 && c<127)?(char)c:' ';
              if(write(1,&out,1)<0) break;
            }
            logmsg("\n");
          }
        }
        usleep(100000);
      }
      int regstatus=0;
      if(waitpid(registrar,&regstatus,WNOHANG)==registrar)
        logmsg("FAIL Android 11 test service registrar exited\\n");
      else logmsg("PASS Android 11 test service registrar running\\n");
    }
  }
  // A separate genuine Android 11 process queries the service registry via Binder.
  // The service CLI's "list" command uses libbinder and talks to servicemanager.
  if(result==0) {
    int querypipe[2]={-1,-1};
    if(pipe2(querypipe,O_CLOEXEC|O_NONBLOCK)<0) {
      perror("pipe2 Android service client");
      logmsg("FAIL Android 11 service client pipe unavailable\n");
    } else {
      pid_t query=fork();
      if(query==0) {
        close(querypipe[0]);
        if(dup2(querypipe[1],1)<0 || dup2(querypipe[1],2)<0) _exit(126);
        close(querypipe[1]);
        setenv("LD_LIBRARY_PATH","/system/lib64",1);
        execl("/system/bin/service","service","list",NULL);
        perror("exec Android service client");
        _exit(127);
      }
      close(querypipe[1]);
      if(query<0) {
        perror("fork Android service client");
        logmsg("FAIL Android 11 service client fork\n");
      } else {
        int qstatus=0;
        pid_t qresult=0;
        int saw_registry=0;
        int saw_test_service=0;
        for(int i=0;i<50;i++) {
          char buf[4096];
          ssize_t n;
          while((n=read(querypipe[0],buf,sizeof(buf)-1))>0) {
            buf[n]=0;
            logmsg("ANDROID SERVICE LIST: ");
            logmsg(buf);
            if(strstr(buf,"Found ") && strstr(buf," services:")) saw_registry=1;
            if(strstr(buf,"watch3.test.echo")) saw_test_service=1;
          }
          qresult=waitpid(query,&qstatus,WNOHANG);
          if(qresult!=0) break;
          usleep(100000);
        }
        if(qresult==0) {
          kill(query,SIGKILL);
          waitpid(query,&qstatus,0);
          logmsg("FAIL Android 11 service list timed out\n");
        } else if(qresult==query && WIFEXITED(qstatus) && WEXITSTATUS(qstatus)==0 && saw_registry) {
          logmsg("PASS genuine Android 11 service list Binder registry query\n");
          if(saw_test_service) logmsg("PASS Android 11 test service discovered in registry\n");
          else logmsg("FAIL Android 11 test service missing from registry\n");
        } else {
          printf("FAIL Android 11 service list result=%ld status=%d registry=%d\\n",
                 (long)qresult,qstatus,saw_registry);
        }
      }
      close(querypipe[0]);
    }
  }
  if(registrarpipe[0]>=0) close(registrarpipe[0]);
  fflush(stdout);
  for(;;)pause();
}
