#include <android/hidl/manager/1.0/BpHwServiceManager.h>
#include <hwbinder/ProcessState.h>
#include <cstdio>
#include <cstring>
extern "C" int is_selinux_enabled(void);
extern "C" int security_getenforce(void);
using android::sp;
using android::hidl::manager::V1_0::IServiceManager;
using android::hidl::manager::V1_0::BpHwServiceManager;
int main() {
 setvbuf(stdout,nullptr,_IONBF,0);
 if(is_selinux_enabled()!=1||security_getenforce()!=1){puts("FAIL HIDL client SELinux");return 1;}
 auto context=android::hardware::ProcessState::self()->getContextObject(nullptr);
 if(context==nullptr){puts("FAIL hwbinder context object");return 2;}
 sp<IServiceManager> manager=new BpHwServiceManager(context);
 if(!manager->isRemote()){puts("FAIL manager is not remote");return 3;}
 bool found=false;
 auto listed=manager->list([&](const auto& names){for(const auto& name:names){printf("HIDL REGISTRY %s\n",name.c_str());if(strstr(name.c_str(),"android.hidl.manager@")&&strstr(name.c_str(),"::IServiceManager/default"))found=true;}});
 if(!listed.isOk()||!found){puts("FAIL HIDL manager list");return 4;}
 puts("PASS HIDL manager list");
 auto result=manager->get("android.hidl.manager@1.0::IServiceManager","default");
 if(!result.isOk()){puts("FAIL HIDL self lookup transport");return 5;}
 sp<android::hidl::base::V1_0::IBase> target=result;
 if(target==nullptr||!target->isRemote()){puts("FAIL HIDL self object");return 6;}
 auto ping=target->ping();if(!ping.isOk()){puts("FAIL HIDL ping");return 7;}
 bool chain=false;
 auto checked=target->interfaceChain([&](const auto& names){for(const auto& name:names){printf("HIDL CHAIN %s\n",name.c_str());if(!strcmp(name.c_str(),"android.hidl.manager@1.0::IServiceManager"))chain=true;}});
 if(!checked.isOk()||!chain){puts("FAIL HIDL interfaceChain");return 8;}
 puts("PASS HIDL self lookup ping interfaceChain");
 puts("SCOPE direct context-object test; normal property-ready discovery NOT RUN");
 return 0;
}
