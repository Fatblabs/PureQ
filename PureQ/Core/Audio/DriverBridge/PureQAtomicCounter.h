#ifndef PureQAtomicCounter_h
#define PureQAtomicCounter_h

#include <stdint.h>
#include <stdatomic.h>

typedef struct PureQAtomicInt64 {
    _Atomic int64_t value;
} PureQAtomicInt64;

void PureQAtomicInt64Initialize(PureQAtomicInt64* counter, int64_t value);
int64_t PureQAtomicInt64LoadRelaxed(PureQAtomicInt64* counter);
int64_t PureQAtomicInt64LoadAcquire(PureQAtomicInt64* counter);
void PureQAtomicInt64StoreRelease(PureQAtomicInt64* counter, int64_t value);
uint32_t PureQAtomicUInt32LoadAcquire(const void* value);
uint64_t PureQAtomicUInt64LoadAcquire(const void* value);

#endif
