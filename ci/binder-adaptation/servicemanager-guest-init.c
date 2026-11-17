#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
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
  mkdir("/dev/binderfs",0755);
  int fd=open("/dev/binder",O_RDWR);
  if(fd<0){perror("open /dev/binder");logmsg("FAIL Binder device unavailable\n");}
  else {logmsg("PASS Binder device opened for real servicemanager test\n");close(fd);}
  pid_t child=fork();
  if(child==0){
    setenv("LD_LIBRARY_PATH","/system/lib64",1);
    execl("/system/bin/servicemanager","servicemanager",NULL);
    perror("exec servicemanager");
    _exit(127);
  }
  if(child<0){perror("fork");return 1;}
  int status=0;
  waitpid(child,&status,0);
  if(WIFEXITED(status))printf("RESULT real Android 11 servicemanager exited status=%d\n",WEXITSTATUS(status));
  else if(WIFSIGNALED(status))printf("RESULT real Android 11 servicemanager signal=%d\n",WTERMSIG(status));
  fflush(stdout);
  for(;;)pause();
}
