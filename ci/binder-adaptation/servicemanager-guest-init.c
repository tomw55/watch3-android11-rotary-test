#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
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
/* selinuxfs load is a single whole-policy write, never chunked writes. */
static int load_test_policy(void) {
  int fd=-1, load=-1, exported=-1, enforcing=-1, result=-1;
  unsigned char *data=NULL;
  struct stat st;
  fd=open("/test.policy",O_RDONLY|O_CLOEXEC);
  if(fd<0 || fstat(fd,&st)<0 || st.st_size<=0 || st.st_size>16*1024*1024) {
    perror("FAIL open/stat fixture policy");goto out;
  }
  size_t length=(size_t)st.st_size, used=0;
  data=malloc(length);
  if(!data) { perror("FAIL allocate fixture policy");goto out; }
  while(used<length) {
    ssize_t n=read(fd,data+used,length-used);
    if(n<0 && errno==EINTR)continue;
    if(n<=0) { perror("FAIL read complete fixture policy");goto out; }
    used+=(size_t)n;
  }
  close(fd);fd=-1;
  load=open("/sys/fs/selinux/load",O_WRONLY|O_CLOEXEC);
  if(load<0) { perror("FAIL open selinuxfs load");goto out; }
  ssize_t written;
  do { written=write(load,data,length); } while(written<0 && errno==EINTR);
  if(written!=(ssize_t)length) { perror("FAIL whole SELinux policy load");goto out; }
  close(load);load=-1;
  exported=open("/sys/fs/selinux/policy",O_RDONLY|O_CLOEXEC);
  unsigned char byte;
  if(exported<0 || read(exported,&byte,1)!=1) {
    perror("FAIL read back loaded SELinux policy");goto out;
  }
  enforcing=open("/sys/fs/selinux/enforce",O_RDONLY|O_CLOEXEC);
  char value=0;
  if(enforcing<0 || read(enforcing,&value,1)!=1 || value!='1') {
    logmsg("FAIL loaded policy is not enforcing\n");goto out;
  }
  printf("PASS fixture SELinux policy loaded and readable bytes=%zu enforcing=1\n",length);
  result=0;
out:
  if(fd>=0)close(fd);
  if(load>=0)close(load);
  if(exported>=0)close(exported);
  if(enforcing>=0)close(enforcing);
  free(data);
  return result;
}
static int denied_service_test(int logfd) {
  int pipes[2], status=0;pid_t waited=0;
  char output[8192];size_t used=0;
  if(pipe2(pipes,O_CLOEXEC|O_NONBLOCK)<0)return -1;
  pid_t child=fork();
  if(child==0) {
    close(pipes[0]);
    if(dup2(pipes[1],1)<0 || dup2(pipes[1],2)<0)_exit(126);
    close(pipes[1]);
    setenv("LD_LIBRARY_PATH","/system/lib64",1);
    setenv("WATCH3_TEST_SERVICE_NAME","watch3.test.denied",1);
    setenv("WATCH3_EXPECT_DENIED","1",1);
    execl("/system/bin/register-test-service-ndk","register-test-service-ndk",NULL);
    _exit(127);
  }
  close(pipes[1]);
  if(child<0){close(pipes[0]);return -1;}
  for(int i=0;i<50;i++) {
    ssize_t n;
    while(used<sizeof(output)-1 && (n=read(pipes[0],output+used,sizeof(output)-1-used))>0)used+=(size_t)n;
    waited=waitpid(child,&status,WNOHANG);
    if(waited!=0)break;
    usleep(100000);
  }
  if(waited==0){kill(child,SIGKILL);waitpid(child,&status,0);}
  ssize_t n;
  while(used<sizeof(output)-1 && (n=read(pipes[0],output+used,sizeof(output)-1-used))>0)used+=(size_t)n;
  close(pipes[0]);output[used]=0;
  logmsg("DENIAL CONTROL: ");logmsg(output);
  if(logfd>=0) {
    char logbuf[4096];
    while((n=recv(logfd,logbuf,sizeof(logbuf),MSG_DONTWAIT))>0) {
      logmsg("ANDROID DENIAL LOG: ");
      for(ssize_t j=0;j<n;j++){unsigned char c=(unsigned char)logbuf[j];char text=(c>=32&&c<127)?(char)c:' ';if(write(1,&text,1)<0)break;}
      logmsg("\n");
    }
  }
  return waited==child && WIFEXITED(status) && WEXITSTATUS(status)==0 &&
    strstr(output,"PASS Android 11 expected service-manager permission denial")?0:-1;
}
static int rpc_client_test(pid_t server) {
  int pipes[2], status=0;pid_t waited=0;
  char output[16384];size_t used=0;
  if(pipe2(pipes,O_CLOEXEC|O_NONBLOCK)<0)return -1;
  pid_t child=fork();
  if(child==0) {
    close(pipes[0]);
    if(dup2(pipes[1],1)<0 || dup2(pipes[1],2)<0)_exit(126);
    close(pipes[1]);
    char number[32];snprintf(number,sizeof number,"%ld",(long)server);
    setenv("WATCH3_EXPECT_SERVER_PID",number,1);
    setenv("LD_LIBRARY_PATH","/system/lib64",1);
    execl("/system/bin/register-test-service-ndk","register-test-service-ndk","--client",NULL);
    _exit(127);
  }
  close(pipes[1]);
  if(child<0){close(pipes[0]);return -1;}
  for(int i=0;i<100;i++) {
    ssize_t n;
    while(used<sizeof(output)-1 && (n=read(pipes[0],output+used,sizeof(output)-1-used))>0)used+=(size_t)n;
    waited=waitpid(child,&status,WNOHANG);
    if(waited<0 && errno==EINTR){waited=0;continue;}
    if(waited!=0)break;
    usleep(100000);
  }
  if(waited==0){kill(child,SIGKILL);waitpid(child,&status,0);}
  ssize_t n;
  while(used<sizeof(output)-1 && (n=read(pipes[0],output+used,sizeof(output)-1-used))>0)used+=(size_t)n;
  close(pipes[0]);output[used]=0;
  logmsg("RPC CLIENT OUTPUT: ");logmsg(output);
  return waited==child && WIFEXITED(status) && WEXITSTATUS(status)==0 &&
    strstr(output,"PASS Android 11 NDK RPC 32 round trips and malformed controls") && !strstr(output,"FAIL ")?0:-1;
}
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
  /* Replace only this disposable guest's label map. The extracted platform
   * policy/map is not a compatible pair with our deliberately small policy. */
  {
    FILE *contexts=fopen("/system/etc/selinux/plat_service_contexts","w");
    if(!contexts) { perror("FAIL create fixture service contexts");return 1; }
    int rc=fputs("manager u:object_r:watch3_manager_service_t:s0\n"
                 "watch3.test.echo u:object_r:watch3_test_service_t:s0\n"
                 "watch3.test.denied u:object_r:watch3_denied_service_t:s0\n",contexts);
    int closed=fclose(contexts);
    if(rc<0 || closed!=0) { logmsg("FAIL write fixture service contexts\n");return 1; }
    logmsg("PASS guest-only service contexts match fixture policy\n");
  }
  if(load_test_policy()!=0)return 1;
  // Confirm that the synthetic service resolves in the guest-local map.
  {
    FILE *contexts=fopen("/system/etc/selinux/plat_service_contexts","r");
    if(contexts) {
      char line[1024]; int matched=0;
      while(fgets(line,sizeof(line),contexts)) {
        char name[256],label[512];
        if(sscanf(line," %255s %511s",name,label)==2 &&
           strcmp(name,"watch3.test.echo")==0) {
          printf("DIAG service_contexts watch3.test.echo label=%s\n",label);
          matched=1;
        }
      }
      fclose(contexts);
      if(!matched) logmsg("DIAG service_contexts has NO watch3.test.echo entry\n");
    }
  }
  {
    char buf[128]; int f=open("/sys/fs/selinux/enforce",O_RDONLY);
    if(f>=0) { ssize_t n=read(f,buf,sizeof(buf)-1); close(f);
      if(n>0) { buf[n]=0; printf("DIAG SELinux enforcing=%s",buf); if(buf[n-1]!='\n')puts(""); }
    } else perror("DIAG open selinux enforce");
  }
  // SELinux's enforcing flag alone does not mean a policy is loaded.
  // Android servicemanager uses userspace SELinux access checks, which fail
  // without an initialized policy. Diagnose this explicitly in the guest.
  {
    int policy=open("/sys/fs/selinux/policy",O_RDONLY);
    if(policy>=0) {
      char byte;
      ssize_t n=read(policy,&byte,1);
      close(policy);
      if(n==1) logmsg("DIAG SELinux binary policy is loaded\n");
      else logmsg("DIAG SELinux binary policy is NOT loaded\n");
    } else perror("DIAG open SELinux binary policy");
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
      execl("/system/bin/register-test-service-ndk","register-test-service-ndk",NULL);
      perror("exec Android 11 NDK registrar");
      _exit(127);
    }
    close(registrarpipe[1]);
    if(registrar<0) {
      perror("fork register-test-service");
      logmsg("FAIL Android 11 test service registrar fork\n");
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
        logmsg("FAIL Android 11 test service registrar exited\n");
      else logmsg("PASS Android 11 test service registrar running\n");
    }
  }
  if(result==0) {
    if(denied_service_test(logfd)==0)logmsg("PASS SELinux service-manager negative control\n");
    else logmsg("FAIL SELinux service-manager negative control\n");
  }
  if(result==0 && registrar>0) {
    if(rpc_client_test(registrar)==0)logmsg("PASS registered Android service request reply gate\n");
    else logmsg("FAIL registered Android service request reply gate\n");
    char buffer[4096];ssize_t count;
    while((count=read(registrarpipe[0],buffer,sizeof(buffer)-1))>0){buffer[count]=0;logmsg("RPC SERVER OUTPUT: ");logmsg(buffer);}
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
          printf("FAIL Android 11 service list result=%ld status=%d registry=%d\n",
                 (long)qresult,qstatus,saw_registry);
        }
      }
      close(querypipe[0]);
    }
  }
  close(childpipe[0]);
  if(registrarpipe[0]>=0) close(registrarpipe[0]);
  fflush(stdout);
  for(;;)pause();
}
