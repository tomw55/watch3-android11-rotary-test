#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/reboot.h>
int main(void) {
 setvbuf(stdout,NULL,_IOLBF,0);
 if(getpid()!=1)return 2;
 if(mount("proc","/proc","proc",0,NULL)||mount("sysfs","/sys","sysfs",0,NULL)||mount("devtmpfs","/dev","devtmpfs",0,NULL))return 3;
 setenv("LD_LIBRARY_PATH","/system/lib64",1);setenv("ANDROID_ROOT","/system",1);setenv("ANDROID_DATA","/data",1);
 int status=1;pid_t child=fork();
 if(child==0){execl("/system/bin/gralloc-gate","gralloc-gate",NULL);perror("FAIL Android exec");_exit(127);}
 if(child<0||waitpid(child,&status,0)!=child||!WIFEXITED(status)||WEXITSTATUS(status))puts("FAIL GRALLOC_GUEST");
 else puts("PASS GRALLOC_GUEST");
 fflush(NULL);reboot(RB_POWER_OFF);return 1;
}
