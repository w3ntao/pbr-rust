#pragma once

#include <vector>

#include "pbrt/util/macro.h"

class HashMap {
  public:
    static const uint64_t EMPTY_KEY = 0xffffffff;

    struct KeyValue {
        uint64_t key;
        uint64_t value;
    };

    static HashMap *create(uint capacity, std::vector<void *> &gpu_dynamic_pointers);

    PBRT_CPU_GPU
    uint64_t lookup(uint64_t key) const;

    PBRT_CPU_GPU
    void insert(uint64_t key, uint64_t value);

  private:
    KeyValue *items;
    uint size;
    uint capacity;
};