#include <android/hidl/manager/1.0/BpHwServiceManager.h>
#include <android/hardware/graphics/allocator/2.0/IAllocator.h>
#include <android/hardware/graphics/mapper/2.0/IMapper.h>
#include <hidl/HidlTransportSupport.h>
#include <hwbinder/IPCThreadState.h>
#include <hwbinder/ProcessState.h>
#include <cutils/native_handle.h>
#include <hardware/gralloc.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
using android::sp;
using android::hardware::Return;
using android::hardware::Void;
using android::hardware::hidl_vec;
using android::hardware::hidl_handle;
using android::hidl::base::V1_0::DebugInfo;
using android::hidl::manager::V1_0::IServiceManager;
using android::hidl::manager::V1_0::BpHwServiceManager;
using android::hardware::graphics::allocator::V2_0::IAllocator;
using android::hardware::graphics::mapper::V2_0::IMapper;
using android::hardware::graphics::mapper::V2_0::Error;
using android::hardware::graphics::common::V1_0::PixelFormat;
extern "C" int is_selinux_enabled(void);
extern "C" int security_getenforce(void);
static constexpr char instance[]="watch3.graphics";
static int fail(const char* text){printf("FAIL GRAPHICS %s errno=%d\n",text,errno);return 1;}
static sp<IServiceManager> registry(){auto p=android::hardware::ProcessState::self()->getContextObject(nullptr);return p?sp<IServiceManager>(new BpHwServiceManager(p)):nullptr;}
template<class T> static sp<T> load(const char* filename,const char* symbol){
 void* library=dlopen(filename,RTLD_NOW|RTLD_LOCAL);
 if(!library){printf("FAIL GRAPHICS dlopen %s: %s\n",filename,dlerror());return nullptr;}
 auto fetch=reinterpret_cast<T*(*)(const char*)>(dlsym(library,symbol));
 if(!fetch){printf("FAIL GRAPHICS dlsym %s\n",symbol);return nullptr;}
 return fetch("default"); // Keep the DSO resident for object/vtable lifetime.
}
static sp<IMapper> mapper(){return load<IMapper>("/vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl.so","HIDL_FETCH_IMapper");}
// Only diagnostics are added; allocation and ownership remain in actual r48 adapter.
class LoggedAllocator final:public IAllocator {
 sp<IAllocator> real_;
public:
 explicit LoggedAllocator(sp<IAllocator> real):real_(real){}
 Return<void> dumpDebugInfo(dumpDebugInfo_cb cb) override{return real_->dumpDebugInfo(cb);}
 Return<void> allocate(const hidl_vec<uint32_t>& descriptor,uint32_t count,allocate_cb cb) override{
  printf("ALLOCATOR SERVER caller=%d server=%d count=%u words=%zu\n",android::hardware::IPCThreadState::self()->getCallingPid(),getpid(),count,descriptor.size());
  return real_->allocate(descriptor,count,cb);
 }
 Return<void> getDebugInfo(getDebugInfo_cb cb)override{DebugInfo d{};d.pid=getpid();cb(d);return Void();}
};
static int server(){
 android::hardware::configureRpcThreadpool(2,false);android::hardware::ProcessState::self()->startThreadPool();
 auto real=load<IAllocator>("/vendor/lib64/hw/android.hardware.graphics.allocator@2.0-impl.so","HIDL_FETCH_IAllocator");
 auto manager=registry();if(!real||!manager||real->isRemote())return fail("allocator adapter load");
 sp<LoggedAllocator> object=new LoggedAllocator(real);auto added=manager->add(instance,object);
 if(!added.isOk()||!bool(added))return fail("register allocator");
 printf("PASS graphics allocator registered server=%d\n",getpid());
 if(write(3,"R",1)!=1)return fail("ready pipe");close(3);
 android::hardware::joinRpcThreadpool();return fail("threadpool returned");
}
static bool unlock(const sp<IMapper>& m,void* buffer){
 bool okay=false;auto r=m->unlock(buffer,[&](Error e,const hidl_handle& fence){
  const native_handle_t* f=fence.getNativeHandle();okay=e==Error::NONE&&(!f||f->numFds==0);
 });return r.isOk()&&okay; // This narrow profile has no real release fences.
}
static uint32_t pixel(unsigned x,unsigned y,bool second){return (second?0xff57c42au:0xffa33671u)^((x*73u+y*19u)&0xffffu);}
static bool pixels(const sp<IMapper>& m,void* buffer,uint32_t width,uint32_t height,uint32_t stride,bool second,bool write){
 void* address=nullptr;Error error=Error::NO_RESOURCES;IMapper::Rect rect{0,0,int32_t(width),int32_t(height)};
 auto r=m->lock(buffer,GRALLOC_USAGE_SW_READ_OFTEN|GRALLOC_USAGE_SW_WRITE_OFTEN,rect,hidl_handle(),[&](Error e,void* p){error=e;address=p;});
 if(!r.isOk()||error!=Error::NONE||!address||stride<width)return false;
 bool okay=true;auto data=static_cast<uint32_t*>(address);
 for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++){
  uint32_t& value=data[size_t(y)*stride+x];if(write)value=pixel(x,y,second);else if(value!=pixel(x,y,second))okay=false;
 }
 return unlock(m,buffer)&&okay;
}
struct Transfer {uint32_t width,height,stride;int32_t fds,ints;int32_t values[64];};
static int importer(){
 Transfer p{};char control[CMSG_SPACE(4*sizeof(int))]{};struct iovec io{&p,sizeof p};struct msghdr msg{};msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control;msg.msg_controllen=sizeof control;
 ssize_t n=recvmsg(3,&msg,0);if(n!=sizeof p||(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC))||p.fds!=1||p.ints<0||p.ints>64||p.width!=65||p.height!=7||p.stride<p.width||p.stride>4096)return fail("import message bounds");
 auto cm=CMSG_FIRSTHDR(&msg);if(!cm||cm->cmsg_level!=SOL_SOCKET||cm->cmsg_type!=SCM_RIGHTS||cm->cmsg_len!=CMSG_LEN(sizeof(int))||CMSG_NXTHDR(&msg,cm))return fail("import fd control");
 native_handle_t* raw=native_handle_create(p.fds,p.ints);if(!raw)return fail("native handle");memcpy(raw->data,CMSG_DATA(cm),sizeof(int));memcpy(raw->data+1,p.values,size_t(p.ints)*sizeof(int));
 auto m=mapper();if(!m||m->isRemote())return fail("importer mapper");void* buffer=nullptr;Error error=Error::NO_RESOURCES;
 auto imported=m->importBuffer(hidl_handle(raw),[&](Error e,void* b){error=e;buffer=b;});
 native_handle_close(raw);native_handle_delete(raw);
 if(!imported.isOk()||error!=Error::NONE||!buffer)return fail("exec import");
 if(!pixels(m,buffer,p.width,p.height,p.stride,false,false)||!pixels(m,buffer,p.width,p.height,p.stride,true,true))return fail("exec pixel integrity");
 auto freed=m->freeBuffer(buffer);if(!freed.isOk()||Error(freed)!=Error::NONE)return fail("exec free");
 printf("PASS GRAPHICS exec importer pid=%d verifies and updates pixels\n",getpid());
 if(write(3,"D",1)!=1)return fail("import completion");return 0;
}
static bool crossProcess(void* buffer,uint32_t width,uint32_t height,uint32_t stride){
 auto handle=static_cast<native_handle_t*>(buffer);if(handle->numFds!=1||handle->numInts<0||handle->numInts>64)return false;
 int pair[2];if(socketpair(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0,pair))return false;
 pid_t child=fork();if(!child){
  close(pair[0]);if(dup2(pair[1],3)<0)_exit(125);fcntl(3,F_SETFD,0);
  for(int fd=4;fd<1024;fd++)close(fd);
  execl("/system/bin/graphics-fixture","graphics-fixture","--importer",nullptr);_exit(127);
 }
 close(pair[1]);if(child<0)return false;
 Transfer p{};p.width=width;p.height=height;p.stride=stride;p.fds=handle->numFds;p.ints=handle->numInts;memcpy(p.values,handle->data+p.fds,size_t(p.ints)*sizeof(int));
 char control[CMSG_SPACE(sizeof(int))]{};struct iovec io{&p,sizeof p};struct msghdr msg{};msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control;msg.msg_controllen=sizeof control;
 auto cm=CMSG_FIRSTHDR(&msg);cm->cmsg_level=SOL_SOCKET;cm->cmsg_type=SCM_RIGHTS;cm->cmsg_len=CMSG_LEN(sizeof(int));memcpy(CMSG_DATA(cm),handle->data,sizeof(int));
 if(sendmsg(pair[0],&msg,0)!=sizeof p)return false;
 struct timeval timeout{10,0};setsockopt(pair[0],SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
 char result=0;ssize_t n=read(pair[0],&result,1);close(pair[0]);int status=0;
 if(n!=1||result!='D'){kill(child,SIGKILL);waitpid(child,&status,0);return false;}
 return waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0;
}
static int client(pid_t expectedServer,pid_t expectedManager){
 auto manager=registry();auto m=mapper();if(!manager||!m||m->isRemote())return fail("client mapper");
 auto found=manager->get(IAllocator::descriptor,instance);if(!found.isOk())return fail("allocator lookup");sp<android::hidl::base::V1_0::IBase> base=found;auto cast=IAllocator::castFrom(base,true);if(!cast.isOk())return fail("allocator cast");sp<IAllocator> allocator=cast;if(!allocator||!allocator->isRemote())return fail("allocator remote");
 int32_t actual=-1;auto debug=allocator->getDebugInfo([&](const DebugInfo& d){actual=d.pid;});if(!debug.isOk()||actual!=expectedServer||getpid()==actual||actual==expectedManager)return fail("process identities");
 printf("GRAPHICS CLIENT pid=%d server=%d manager=%d remote_allocator=1 local_mapper=1\n",getpid(),actual,expectedManager);
 const unsigned widths[]={16,63,65};const unsigned heights[]={16,3,7};
 for(unsigned i=0;i<3;i++){
  IMapper::BufferDescriptorInfo info{};info.width=widths[i];info.height=heights[i];info.layerCount=1;info.format=PixelFormat::RGBA_8888;info.usage=GRALLOC_USAGE_SW_READ_OFTEN|GRALLOC_USAGE_SW_WRITE_OFTEN|GRALLOC_USAGE_HW_COMPOSER;
  hidl_vec<uint32_t> descriptor;Error e=Error::NO_RESOURCES;auto described=m->createDescriptor(info,[&](Error x,const auto& d){e=x;descriptor=d;});if(!described.isOk()||e!=Error::NONE)return fail("descriptor");
  void* buffer=nullptr;uint32_t stride=0;Error imported=Error::NO_RESOURCES;
  auto allocated=allocator->allocate(descriptor,1,[&](Error x,uint32_t s,const auto& handles){
   e=x;stride=s;if(x==Error::NONE&&handles.size()==1){auto r=m->importBuffer(handles[0],[&](Error z,void* p){imported=z;buffer=p;});if(!r.isOk())imported=Error::NO_RESOURCES;}
  });
  if(!allocated.isOk()||e!=Error::NONE||imported!=Error::NONE||!buffer)return fail("remote allocate and import");
  if(!pixels(m,buffer,info.width,info.height,stride,false,true)||!pixels(m,buffer,info.width,info.height,stride,false,false))return fail("client pixels");
  if(i==2 && (!crossProcess(buffer,info.width,info.height,stride)||!pixels(m,buffer,info.width,info.height,stride,true,false)))return fail("cross-process visibility");
  auto freed=m->freeBuffer(buffer);if(!freed.isOk()||Error(freed)!=Error::NONE)return fail("free buffer");
  auto twice=m->freeBuffer(buffer);if(!twice.isOk()||Error(twice)!=Error::BAD_BUFFER)return fail("double-free control");
  printf("PASS GRAPHICS allocation case=%u width=%u height=%u stride=%u\n",i,info.width,info.height,stride);
 }
 bool rejected=false;auto bad=allocator->allocate(hidl_vec<uint32_t>(),1,[&](Error e,uint32_t,const auto& handles){rejected=e==Error::BAD_DESCRIPTOR&&handles.size()==0;});if(!bad.isOk()||!rejected)return fail("invalid descriptor control");
 auto null=m->freeBuffer(nullptr);if(!null.isOk()||Error(null)!=Error::BAD_BUFFER)return fail("null free control");
 puts("PASS GRAPHICS allocator mapper buffer lifecycle");return 0;
}
int main(int argc,char** argv){
 setvbuf(stdout,nullptr,_IONBF,0);
 if(is_selinux_enabled()!=1||security_getenforce()!=1)return fail("SELinux enforcement");
 if(argc==2&&!strcmp(argv[1],"--server"))return server();
 if(argc==2&&!strcmp(argv[1],"--importer"))return importer();
 if(argc==4&&!strcmp(argv[1],"--client"))return client(pid_t(atoi(argv[2])),pid_t(atoi(argv[3])));
 return fail("arguments");
}
