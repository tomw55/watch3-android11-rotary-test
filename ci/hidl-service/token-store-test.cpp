#include "token-store.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <memory>
#include <thread>
int main() {
    TokenStore<std::shared_ptr<int>> store;
    auto value = std::make_shared<int>(73);
    std::weak_ptr<int> weak = value;
    auto token = store.create(value);
    assert(token.size() == 8 && TokenStore<int>::decode(token.data(), 8) == 1);
    value.reset();
    assert(!weak.expired() && *store.get(token.data(), 8) == 73);
    for (size_t n = 0; n <= 16; ++n) {
        if (n == 8) continue;
        std::array<uint8_t, 16> bad{};
        assert(!store.get(bad.data(), n) && !store.erase(bad.data(), n));
    }
    assert(!store.get(nullptr, 8) && !store.erase(nullptr, 8));
    std::array<uint8_t, 8> unknown{};
    assert(!store.get(unknown.data(), 8) && !store.erase(unknown.data(), 8));
    assert(store.erase(token.data(), 8) && weak.expired());
    assert(!store.erase(token.data(), 8) && !store.get(token.data(), 8));
    auto second = store.create(std::make_shared<int>(9));
    store.clear();
    auto third = store.create(std::make_shared<int>(10));
    assert(second != third && !store.get(second.data(), 8));
    TokenStore<int> limited(2);
    auto a = limited.create(1), b = limited.create(2);
    assert(limited.create(3).empty());
    assert(limited.erase(a.data(), 8));
    auto c = limited.create(3);
    assert(c != a && limited.get(b.data(), 8) == 2);
    TokenStore<int> boundary(2, UINT64_MAX);
    auto last = boundary.create(1);
    assert(TokenStore<int>::decode(last.data(), 8) == UINT64_MAX);
    assert(boundary.create(2).empty());
    TokenStore<int> concurrent;
    std::array<std::thread, 8> workers;
    for (size_t i = 0; i < workers.size(); ++i) workers[i] = std::thread([&, i] {
        auto t = concurrent.create(int(i + 1));
        assert(t.size() == 8 && concurrent.get(t.data(), 8) == int(i + 1));
        assert(concurrent.erase(t.data(), 8));
    });
    for (auto& t : workers) t.join();
    puts("PASS token-store lifetime, lengths, revocation, capacity, reset, overflow and threaded controls");
}
