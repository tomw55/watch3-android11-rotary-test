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
int main(void) {
  setvbuf(stdout,NULL,_IONBF,0);
  mkdir("/proc",0755);mkdir("/sys",0755);mkdir("/dev",0755);
  if(mount("proc","/proc","proc",0,NULL)||mount("sysfs","/sys","sysfs",0,NULL)||mount("devtmpfs","/dev","devtmpfs",0,NULL))return 1;
  mkdir("/sys/fs/selinux",0755);
  if(mount("selinuxfs","/sys/fs/selinux","selinuxfs",0,NULL))return 2;
  mkdir("/dev/socket",0755);
  int logs=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK,0);
  struct sockaddr_un a={.sun_family=AF_UNIX};strcpy(a.sun_path,"/dev/socket/logdw");
  if(logs<0||bind(logs,(struct sockaddr*)&a,sizeof a)){perror("FAIL log socket");return 3;}
  mknod("/dev/kmsg",S_IFCHR|0600,makedev(1,11));
  FILE*f=fopen("/system/etc/selinux/plat_hwservice_contexts","w");
  if(!f)return 4;
  int written=fputs("android.hidl.manager::IServiceManager u:object_r:fixture_hwservice_t:s0\n"
    "android.hidl.token::ITokenManager u:object_r:fixture_hwservice_t:s0\n"
    "android.hidl.base::IBase u:object_r:fixture_hwservice_t:s0\n",f);
  int closed=fclose(f);if(written<0||closed)return 5;
  if(load_test_policy())return 6;
  setenv("LD_LIBRARY_PATH","/system/lib64",1);
  int output[2];if(pipe2(output,O_NONBLOCK|O_CLOEXEC))return 7;
  pid_t manager=fork();
  if(!manager){close(output[0]);dup2(output[1],1);dup2(output[1],2);close(output[1]);execl("/system/bin/hwservicemanager","hwservicemanager",NULL);perror("FAIL exec hwservicemanager");_exit(127);}
  close(output[1]);if(manager<0)return 8;
  pid_t baseline=-1, server=-1, client=-1;
  int status=0, complete=0, base_done=0, ready[2]={-1,-1};
  for(int tick=0;tick<400;tick++){
    char b[4096];ssize_t n;
    while((n=read(output[0],b,sizeof(b)-1))>0){b[n]=0;logmsg("HIDL STDOUT: ");logmsg(b);}
    while((n=recv(logs,b,sizeof b,MSG_DONTWAIT))>0){logmsg("HIDL LOG: ");for(ssize_t j=0;j<n;j++){unsigned char c=b[j];char t=(c>=32&&c<127)?(char)c:' ';if(write(1,&t,1)<0)break;}logmsg("\n");}
    if(waitpid(manager,&status,WNOHANG)==manager){printf("FAIL hwservicemanager exit status=%d\n",status);break;}
    if(server>0 && waitpid(server,&status,WNOHANG)==server){printf("FAIL HIDL server exit status=%d\n",status);break;}
    if(tick==50){
      puts("PASS hwservicemanager alive");baseline=fork();
      if(!baseline){execl("/system/bin/hidl-client","hidl-client",NULL);perror("FAIL exec baseline client");_exit(127);}
      if(baseline<0){puts("FAIL baseline fork");break;}
    }
    if(baseline>0 && !base_done && waitpid(baseline,&status,WNOHANG)==baseline){
      if(!WIFEXITED(status)||WEXITSTATUS(status)!=0){printf("FAIL HIDL baseline status=%d\n",status);break;}
      base_done=1;puts("PASS HIDL transport baseline");
      if(pipe2(ready,O_NONBLOCK|O_CLOEXEC)){perror("FAIL readiness pipe");break;}
      server=fork();
      if(!server){
        close(ready[0]);
        if(dup2(ready[1],3)<0){perror("FAIL readiness dup");_exit(126);}
        if(ready[1]!=3)close(ready[1]);
        if(fcntl(3,F_SETFD,0)<0){perror("FAIL readiness flags");_exit(126);}
        execl("/system/bin/hidl-fixture","hidl-fixture","--server",NULL);
        perror("FAIL exec HIDL server");_exit(127);
      }
      close(ready[1]);ready[1]=-1;
      if(server<0){puts("FAIL HIDL server fork");break;}
    }
    if(server>0 && client<0){
      char ready_byte=0;n=read(ready[0],&ready_byte,1);
      if(n==0){puts("FAIL HIDL server readiness EOF");break;}
      if(n<0 && errno!=EAGAIN && errno!=EINTR){perror("FAIL readiness read");break;}
      if(n==1){
        if(ready_byte!='R'){puts("FAIL readiness byte");break;}
        close(ready[0]);ready[0]=-1;
        char server_text[32],manager_text[32];
        snprintf(server_text,sizeof server_text,"%d",server);
        snprintf(manager_text,sizeof manager_text,"%d",manager);
        printf("HIDL INIT manager=%d server=%d\n",manager,server);
        client=fork();
        if(!client){execl("/system/bin/hidl-fixture","hidl-fixture","--client",server_text,manager_text,NULL);perror("FAIL exec fixture client");_exit(127);}
        if(client<0){puts("FAIL fixture client fork");break;}
      }
    }
    if(client>0 && waitpid(client,&status,WNOHANG)==client){
      complete=1;
      if(WIFEXITED(status)&&WEXITSTATUS(status)==0)puts("PASS registered HIDL service gate");
      else printf("FAIL HIDL fixture client status=%d\n",status);
      break;
    }
    usleep(100000);
  }
  if(!complete)puts("FAIL HIDL service timeout or startup failure");
  for(;;)pause();
}
