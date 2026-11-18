#ifndef WATCH3_HIDL_FIXTURE_TOKEN_STORE_H
#define WATCH3_HIDL_FIXTURE_TOKEN_STORE_H
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <vector>

// Test-only opaque tokens; this is not Android's production token algorithm.
// Removing entries releases their strong references. IDs are never reused.
template<class Value> class TokenStore {
    std::mutex mutex_;
    std::map<uint64_t, Value> values_;
    const size_t capacity_;
    uint64_t next_;
public:
    explicit TokenStore(size_t capacity = 32, uint64_t first = 1)
        : capacity_(capacity), next_(first) {}
    static uint64_t decode(const uint8_t* data, size_t size) {
        if (!data || size != 8) return 0;
        uint64_t id = 0;
        for (size_t i = 0; i < 8; ++i) id |= uint64_t(data[i]) << (8 * i);
        return id;
    }
    std::vector<uint8_t> create(const Value& value) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!next_ || values_.size() >= capacity_) return {};
        const uint64_t id = next_++;
        values_.emplace(id, value);
        std::vector<uint8_t> token(8);
        for (size_t i = 0; i < 8; ++i) token[i] = uint8_t(id >> (8 * i));
        return token;
    }
    Value get(const uint8_t* data, size_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = values_.find(decode(data, size));
        return it == values_.end() ? Value{} : it->second;
    }
    bool erase(const uint8_t* data, size_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        return values_.erase(decode(data, size)) != 0;
    }
    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        values_.clear();
    }
};
#endif
