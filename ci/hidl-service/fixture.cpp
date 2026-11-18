#include <android/hidl/manager/1.0/BpHwServiceManager.h>
#include <android/hidl/token/1.0/ITokenManager.h>
#include <hidl/HidlTransportSupport.h>
#include <hwbinder/IPCThreadState.h>
#include <hwbinder/ProcessState.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include "token-store.h"
extern "C" int is_selinux_enabled(void);
extern "C" int security_getenforce(void);
using android::sp;
using android::hardware::Return;
using android::hardware::Void;
using android::hardware::hidl_vec;
using android::hidl::base::V1_0::IBase;
using android::hidl::base::V1_0::DebugInfo;
using android::hidl::manager::V1_0::IServiceManager;
using android::hidl::manager::V1_0::BpHwServiceManager;
using android::hidl::token::V1_0::ITokenManager;
static constexpr char instance[] = "watch3.fixture";
static int fail(const char* message) { printf("FAIL HIDL fixture %s\n", message); return 1; }
static sp<IServiceManager> manager() {
    auto binder = android::hardware::ProcessState::self()->getContextObject(nullptr);
    if (!binder) return nullptr;
    return new BpHwServiceManager(binder);
}
class Fixture final : public ITokenManager {
    TokenStore<sp<IBase>> tokens_;
public:
    Return<void> createToken(const sp<IBase>& object, createToken_cb cb) override {
        hidl_vec<uint8_t> result;
        if (object) {
            auto bytes = tokens_.create(object);
            result.resize(bytes.size());
            for (size_t i = 0; i < bytes.size(); ++i) result[i] = bytes[i];
            printf("HIDL SERVER create id=%llu caller=%d server=%d bytes=%zu\n",
                (unsigned long long)TokenStore<int>::decode(bytes.data(), bytes.size()),
                android::hardware::IPCThreadState::self()->getCallingPid(), getpid(), bytes.size());
        }
        cb(result);
        return Void();
    }
    Return<bool> unregister(const hidl_vec<uint8_t>& token) override {
        return tokens_.erase(token.data(), token.size());
    }
    Return<sp<IBase>> get(const hidl_vec<uint8_t>& token) override {
        return tokens_.get(token.data(), token.size());
    }
    Return<void> getDebugInfo(getDebugInfo_cb cb) override {
        DebugInfo info{}; info.pid = getpid(); cb(info); return Void();
    }
};
static int server() {
    android::hardware::configureRpcThreadpool(2, false);
    android::hardware::ProcessState::self()->startThreadPool();
    auto registry = manager();
    if (!registry || !registry->isRemote()) return fail("server manager");
    sp<Fixture> object = new Fixture;
    auto added = registry->add(instance, object);
    if (!added.isOk() || !bool(added)) return fail("registration");
    printf("PASS HIDL fixture registered server=%d instance=%s\n", getpid(), instance);
    if (write(3, "R", 1) != 1) return fail("readiness pipe");
    close(3);
    android::hardware::joinRpcThreadpool();
    return fail("server threadpool returned");
}
static bool missing(const sp<ITokenManager>& service, const hidl_vec<uint8_t>& token) {
    auto got = service->get(token);
    if (!got.isOk()) return false;
    sp<IBase> object = got;
    auto erased = service->unregister(token);
    if (!erased.isOk()) return false;
    return !object && !bool(erased);
}
static int client(pid_t expectedServer, pid_t expectedManager) {
    if (expectedServer <= 0 || expectedManager <= 0 || expectedServer == expectedManager ||
        getpid() == expectedServer || getpid() == expectedManager) return fail("process identities");
    auto registry = manager();
    if (!registry || !registry->isRemote()) return fail("client manager");
    bool listed = false;
    auto listing = registry->list([&](const auto& names) {
        for (const auto& n : names)
            if (!strcmp(n.c_str(), "android.hidl.token@1.0::ITokenManager/watch3.fixture")) listed = true;
    });
    if (!listing.isOk() || !listed) return fail("registered instance absent");
    auto result = registry->get(ITokenManager::descriptor, instance);
    if (!result.isOk()) return fail("instance lookup");
    sp<IBase> base = result;
    if (!base || !base->isRemote()) return fail("instance not remote");
    auto cast = ITokenManager::castFrom(base, true);
    if (!cast.isOk()) return fail("typed cast transport");
    sp<ITokenManager> service = cast;
    if (!service || !service->isRemote()) return fail("typed remote interface");
    int32_t serverPid = -1;
    auto debug = service->getDebugInfo([&](const DebugInfo& info) { serverPid = info.pid; });
    if (!debug.isOk() || serverPid != expectedServer) return fail("server identity reply");
    printf("HIDL CLIENT pid=%d server=%d manager=%d remote=1\n", getpid(), serverPid, expectedManager);
    for (unsigned sequence = 0; sequence < 32; ++sequence) {
        hidl_vec<uint8_t> token;
        auto created = service->createToken(registry, [&](const auto& bytes) { token = bytes; });
        if (!created.isOk() || token.size() != 8) return fail("createToken");
        uint64_t id = TokenStore<int>::decode(token.data(), token.size());
        if (id != sequence + 1) return fail("token sequence");
        auto returned = service->get(token);
        if (!returned.isOk()) return fail("token lookup transport");
        sp<IBase> restored = returned;
        if (!restored || !restored->isRemote() ||
            android::hardware::toBinder<IBase>(restored) != android::hardware::toBinder<IServiceManager>(registry))
            return fail("returned Binder identity");
        auto ping = restored->ping();
        if (!ping.isOk()) return fail("returned object ping");
        auto removed = service->unregister(token);
        if (!removed.isOk() || !bool(removed) || !missing(service, token)) return fail("revocation");
        printf("PASS HIDL lifecycle sequence=%u token=%llu server=%d\n", sequence, (unsigned long long)id, serverPid);
    }
    for (size_t length : {size_t(0), size_t(7), size_t(8), size_t(9)}) {
        hidl_vec<uint8_t> invalid; invalid.resize(length);
        for (size_t i = 0; i < length; ++i) invalid[i] = 0xee;
        if (!missing(service, invalid)) return fail("invalid token accepted");
        printf("PASS HIDL invalid-token bytes=%zu\n", length);
    }
    bool empty = false;
    auto rejected = service->createToken(nullptr, [&](const auto& token) { empty = token.size() == 0; });
    if (!rejected.isOk() || !empty) return fail("null object accepted");
    auto ping = service->ping();
    if (!ping.isOk()) return fail("service lost after controls");
    puts("PASS HIDL typed lifecycle and negative controls");
    return 0;
}
int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (is_selinux_enabled() != 1 || security_getenforce() != 1) return fail("SELinux not enforcing");
    if (argc == 2 && !strcmp(argv[1], "--server")) return server();
    if (argc == 4 && !strcmp(argv[1], "--client")) {
        char *end = nullptr;
        long service = strtol(argv[2], &end, 10);
        if (!end || *end || service <= 0 || service > INT32_MAX) return fail("server PID argument");
        long registry = strtol(argv[3], &end, 10);
        if (!end || *end || registry <= 0 || registry > INT32_MAX) return fail("manager PID argument");
        return client(pid_t(service), pid_t(registry));
    }
    return fail("arguments");
}
