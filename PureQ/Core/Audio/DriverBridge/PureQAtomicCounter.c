#include "PureQAtomicCounter.h"

void PureQAtomicInt64Initialize(PureQAtomicInt64* counter, int64_t value)
{
    atomic_init(&counter->value, value);
}

int64_t PureQAtomicInt64LoadRelaxed(PureQAtomicInt64* counter)
{
    return atomic_load_explicit(&counter->value, memory_order_relaxed);
}

int64_t PureQAtomicInt64LoadAcquire(PureQAtomicInt64* counter)
{
    return atomic_load_explicit(&counter->value, memory_order_acquire);
}

void PureQAtomicInt64StoreRelease(PureQAtomicInt64* counter, int64_t value)
{
    atomic_store_explicit(&counter->value, value, memory_order_release);
}

uint32_t PureQAtomicUInt32LoadAcquire(const void* value)
{
    return atomic_load_explicit((const _Atomic uint32_t*)value, memory_order_acquire);
}

uint64_t PureQAtomicUInt64LoadAcquire(const void* value)
{
    return atomic_load_explicit((const _Atomic uint64_t*)value, memory_order_acquire);
}
