#!/usr/bin/env python3
"""Strict host-only fault injection against the actual guest policy loader."""
import os,pathlib,subprocess,sys
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
src=(repo/'ci/binder-adaptation/servicemanager-guest-init.c').read_text()
a=src.index('static int load_test_policy(void)');begin=src.index('{',a);depth=1;end=begin+1
while depth:
    depth+=(src[end]=='{')-(src[end]=='}');end+=1
loader=src[a:end]
main_source=src[src.index('int main(void)'):]
assert main_source.index('if(load_test_policy()!=0)return 1;')<main_source.index('pid_t child=fork()')
preamble=r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
static int scenario, writes, success, fixture_reads, write_tries, live[20];
static void logmsg(const char*s){(void)s;}
static int fake_open(const char*path,int flags) {
 (void)flags;int fd;
 if(!strcmp(path,"/test.policy"))fd=10;
 else if(!strcmp(path,"/sys/fs/selinux/load"))fd=11;
 else if(!strcmp(path,"/sys/fs/selinux/policy")){assert(success);fd=12;}
 else {assert(!strcmp(path,"/sys/fs/selinux/enforce"));assert(success);fd=13;}
 if((scenario==1&&fd==10)||(scenario==6&&fd==12)||(scenario==13&&fd==13)){errno=EACCES;return -1;}
 assert(!live[fd]);live[fd]=1;return fd;
}
static int fake_close(int fd){assert(live[fd]);live[fd]=0;return 0;}
static int fake_fstat(int fd,struct stat*st){assert(fd==10&&live[fd]);if(scenario==11){errno=EIO;return -1;}memset(st,0,sizeof *st);st->st_size=scenario==2?0:(scenario==3?17*1024*1024:8);return 0;}
static ssize_t fake_read(int fd,void*buffer,size_t n){
 assert(live[fd]);
 if(fd==10){fixture_reads++;if(scenario==4){errno=EIO;return 0;}if(scenario==9&&fixture_reads==1){errno=EINTR;return -1;}size_t count=n>3?3:n;memset(buffer,0x5a,count);return (ssize_t)count;}
 if(fd==12){if(scenario==15){errno=EIO;return 0;}*(char*)buffer=0x5a;return 1;}
 assert(fd==13);if(scenario==14){errno=EIO;return 0;}*(char*)buffer=scenario==7?'0':'1';return 1;
}
static ssize_t fake_write(int fd,const void*data,size_t n){
 assert(fd==11&&live[fd]&&n==8);writes++;write_tries++;
 for(size_t i=0;i<n;i++)assert(((const unsigned char*)data)[i]==0x5a);
 if(scenario==5){errno=EIO;return (ssize_t)n-1;}
 if(scenario==8){errno=EACCES;return -1;}
 if(scenario==10&&write_tries==1){errno=EINTR;return -1;}
 success=1;return (ssize_t)n;
}
static void *fake_malloc(size_t n){if(scenario==12){errno=ENOMEM;return NULL;}return malloc(n);}
#define malloc fake_malloc
#define open fake_open
#define close fake_close
#define fstat fake_fstat
#define read fake_read
#define write fake_write
'''
main=r'''
int main(void) {
 for(scenario=0;scenario<=15;scenario++){
  writes=success=fixture_reads=write_tries=0;memset(live,0,sizeof live);
  int result=load_test_policy();
  assert((result==0)==(scenario==0||scenario==9||scenario==10));
  if((scenario>=1&&scenario<=4)||scenario==11||scenario==12)assert(writes==0);
  else assert(writes==(scenario==10?2:1));
  for(int i=0;i<20;i++)assert(!live[i]);
  printf("PASS policy-loader injected case=%d result=%d writes=%d\n",scenario,result,writes);
 }
}
'''
p=out/'loader-test.c';p.write_text(preamble+loader+main)
for suffix,flags in [('',[]),('-sanitized',['-fsanitize=address,undefined'])]:
    binary=out/('loader-test'+suffix)
    subprocess.run(['gcc','-std=c11','-Wall','-Wextra','-Werror',*flags,str(p),'-o',str(binary)],check=True)
    proc=subprocess.run([str(binary)],capture_output=True,text=True)
    (out/('loader-test'+suffix+'.log')).write_text(proc.stdout+proc.stderr)
    if proc.returncode:raise RuntimeError(proc.stdout+proc.stderr)
    print(proc.stdout,end='')
print('PASS load precedes Android process launch; short writes are terminal and all fds close')
