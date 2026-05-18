//
//  PureQDriver.c
//  PureQDriver
//

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <math.h>
#include <os/log.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define kPureQDriverBundleID "Sean-s-Apps.PureQ.driver"
#define kPureQBoxUID "Sean-s-Apps.PureQ.driver.box"
#define kPureQDeviceUID "Sean-s-Apps.PureQ.driver.device"
#define kPureQModelUID "Sean-s-Apps.PureQ.driver.model"
#define PUREQ_DRIVER_DEBUG 0
#define kPureQSharedRingPath "/tmp/PureQAudioRing.v1"
#define kPureQSharedRingMagic 0x50555251u
#define kPureQSharedRingVersion 1u

enum {
    kPureQObjectPlugin = kAudioObjectPlugInObject,
    kPureQObjectBox = 2,
    kPureQObjectDevice = 3,
    kPureQObjectOutputStream = 4,
    kPureQObjectInputStream = 5
};

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gReferenceCount = 1;
static atomic_uint gIOClientCount = 0;
static AudioObjectID gPlugInObjectID = kPureQObjectPlugin;
static Float64 gSampleRate = 48000.0;
static UInt32 gBufferFrameSize = 512;
static const UInt32 kPureQZeroTimeStampPeriod = 16384;
static UInt64 gStartHostTime = 0;
static Float64 gStartSampleTime = 0.0;
static const Float64 kPureQMinimumSampleRate = 44100.0;
static const Float64 kPureQMaximumSampleRate = 384000.0;
static const UInt32 kPureQMinimumBufferFrameSize = 64;
static const UInt32 kPureQMaximumBufferFrameSize = 4096;

#define kPureQLoopbackCapacityFrames (384000 * 2)

static Float32 gLoopbackRing[kPureQLoopbackCapacityFrames * 2];
static atomic_uint gLoopbackReadFrame = 0;
static atomic_uint gLoopbackWriteFrame = 0;
static atomic_uint gLoopbackAvailableFrames = 0;

typedef struct PureQSharedAudioRing {
    atomic_uint magic;
    atomic_uint version;
    atomic_uint capacityFrames;
    atomic_uint channels;
    atomic_ullong writeCounter;
    Float32 samples[kPureQLoopbackCapacityFrames * 2];
} PureQSharedAudioRing;

static PureQSharedAudioRing* gSharedRing = NULL;

static AudioStreamBasicDescription PureQStreamDescription(void)
{
    AudioStreamBasicDescription description;
    memset(&description, 0, sizeof(description));
    description.mSampleRate = gSampleRate;
    description.mFormatID = kAudioFormatLinearPCM;
    description.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    description.mBytesPerPacket = 8;
    description.mFramesPerPacket = 1;
    description.mBytesPerFrame = 8;
    description.mChannelsPerFrame = 2;
    description.mBitsPerChannel = 32;
    return description;
}

static AudioValueRange PureQSampleRateRange(void)
{
    AudioValueRange range;
    range.mMinimum = kPureQMinimumSampleRate;
    range.mMaximum = kPureQMaximumSampleRate;
    return range;
}

static AudioValueRange PureQBufferFrameSizeRange(void)
{
    AudioValueRange range;
    range.mMinimum = (Float64)kPureQMinimumBufferFrameSize;
    range.mMaximum = (Float64)kPureQMaximumBufferFrameSize;
    return range;
}

static Float64 PureQClampSampleRate(Float64 sampleRate)
{
    if (!isfinite(sampleRate)) {
        return 48000.0;
    }
    if (sampleRate < kPureQMinimumSampleRate) {
        return kPureQMinimumSampleRate;
    }
    if (sampleRate > kPureQMaximumSampleRate) {
        return kPureQMaximumSampleRate;
    }
    return sampleRate;
}

static UInt32 PureQClampBufferFrameSize(UInt32 frameSize)
{
    if (frameSize < kPureQMinimumBufferFrameSize) {
        return kPureQMinimumBufferFrameSize;
    }
    if (frameSize > kPureQMaximumBufferFrameSize) {
        return kPureQMaximumBufferFrameSize;
    }
    return frameSize;
}

static AudioStreamRangedDescription PureQStreamRangedDescription(void)
{
    AudioStreamRangedDescription description;
    memset(&description, 0, sizeof(description));
    description.mFormat = PureQStreamDescription();
    description.mSampleRateRange = PureQSampleRateRange();
    return description;
}

static Boolean PureQIsPluginObject(AudioObjectID objectID)
{
    if (objectID == kPureQObjectPlugin || objectID == gPlugInObjectID) {
        return true;
    }
    return objectID > kPureQObjectInputStream;
}

static void PureQRememberPluginObject(AudioObjectID objectID)
{
    if (objectID > kPureQObjectInputStream) {
        gPlugInObjectID = objectID;
    }
}

static Boolean PureQObjectExists(AudioObjectID objectID)
{
    return PureQIsPluginObject(objectID) ||
        objectID == kPureQObjectBox ||
        objectID == kPureQObjectDevice ||
        objectID == kPureQObjectOutputStream ||
        objectID == kPureQObjectInputStream;
}

static AudioClassID PureQObjectClass(AudioObjectID objectID)
{
    switch (objectID) {
    case kPureQObjectPlugin:
        return kAudioPlugInClassID;
    case kPureQObjectBox:
        return kAudioBoxClassID;
    case kPureQObjectDevice:
        return kAudioDeviceClassID;
    case kPureQObjectOutputStream:
    case kPureQObjectInputStream:
        return kAudioStreamClassID;
    default:
        return PureQIsPluginObject(objectID) ? kAudioPlugInClassID : kAudioObjectClassID;
    }
}

static AudioObjectID PureQObjectOwner(AudioObjectID objectID)
{
    switch (objectID) {
    case kPureQObjectBox:
        return gPlugInObjectID;
    case kPureQObjectDevice:
        return gPlugInObjectID;
    case kPureQObjectOutputStream:
    case kPureQObjectInputStream:
        return kPureQObjectDevice;
    default:
        return kAudioObjectUnknown;
    }
}

static CFStringRef PureQObjectName(AudioObjectID objectID)
{
    switch (objectID) {
    case kPureQObjectPlugin:
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Driver"));
    case kPureQObjectBox:
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Audio Box"));
    case kPureQObjectDevice:
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Virtual Output"));
    case kPureQObjectOutputStream:
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Output Stream"));
    case kPureQObjectInputStream:
        return CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Input Stream"));
    default:
        return PureQIsPluginObject(objectID) ? CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ Driver")) : CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ"));
    }
}

static UInt32 PureQStreamConfigurationSize(UInt32 bufferCount)
{
    return (UInt32)(offsetof(AudioBufferList, mBuffers) + (sizeof(AudioBuffer) * bufferCount));
}

static UInt32 PureQStreamCountForScope(AudioObjectPropertyScope scope)
{
    if (scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput) {
        return 1;
    }
    return 2;
}

static void PureQFillStreamConfiguration(AudioObjectPropertyScope scope, AudioBufferList* outBufferList)
{
    UInt32 bufferCount = PureQStreamCountForScope(scope);
    outBufferList->mNumberBuffers = bufferCount;

    for (UInt32 index = 0; index < bufferCount; index++) {
        outBufferList->mBuffers[index].mNumberChannels = 2;
        outBufferList->mBuffers[index].mDataByteSize = gBufferFrameSize * 8;
        outBufferList->mBuffers[index].mData = NULL;
    }
}

static Boolean PureQWriteData(UInt32 inDataSize, UInt32* outDataSize, void* outData, const void* source, UInt32 sourceSize)
{
    if (inDataSize < sourceSize) {
        *outDataSize = 0;
        return false;
    }
    memcpy(outData, source, sourceSize);
    *outDataSize = sourceSize;
    return true;
}

static Boolean PureQWriteUInt32(UInt32 inDataSize, UInt32* outDataSize, void* outData, UInt32 value)
{
    return PureQWriteData(inDataSize, outDataSize, outData, &value, sizeof(value));
}

static Boolean PureQWriteAudioObjectID(UInt32 inDataSize, UInt32* outDataSize, void* outData, AudioObjectID value)
{
    return PureQWriteData(inDataSize, outDataSize, outData, &value, sizeof(value));
}

static Boolean PureQWriteBoolean(UInt32 inDataSize, UInt32* outDataSize, void* outData, UInt32 value)
{
    return PureQWriteUInt32(inDataSize, outDataSize, outData, value);
}

static Boolean PureQWriteFloat64(UInt32 inDataSize, UInt32* outDataSize, void* outData, Float64 value)
{
    return PureQWriteData(inDataSize, outDataSize, outData, &value, sizeof(value));
}

static Boolean PureQWriteCFString(UInt32 inDataSize, UInt32* outDataSize, void* outData, CFStringRef value)
{
    if (inDataSize < sizeof(CFStringRef)) {
        if (value != NULL) {
            CFRelease(value);
        }
        *outDataSize = 0;
        return false;
    }
    *((CFStringRef*)outData) = value;
    *outDataSize = sizeof(CFStringRef);
    return true;
}

static void PureQLoopbackReset(void)
{
    memset(gLoopbackRing, 0, sizeof(gLoopbackRing));
    atomic_store_explicit(&gLoopbackReadFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&gLoopbackWriteFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&gLoopbackAvailableFrames, 0, memory_order_relaxed);
    if (gSharedRing != NULL) {
        memset(gSharedRing->samples, 0, sizeof(gSharedRing->samples));
        atomic_store_explicit(&gSharedRing->writeCounter, 0, memory_order_release);
    }
}

static void PureQEnsureSharedRing(void)
{
    if (gSharedRing != NULL) {
        return;
    }

    int descriptor = open(kPureQSharedRingPath, O_CREAT | O_RDWR, 0666);
    if (descriptor < 0) {
        return;
    }

    size_t ringSize = sizeof(PureQSharedAudioRing);
    if (ftruncate(descriptor, (off_t)ringSize) != 0) {
        close(descriptor);
        return;
    }
    fchmod(descriptor, 0666);

    void* mapping = mmap(NULL, ringSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) {
        return;
    }

    gSharedRing = (PureQSharedAudioRing*)mapping;
    atomic_store_explicit(&gSharedRing->magic, kPureQSharedRingMagic, memory_order_release);
    atomic_store_explicit(&gSharedRing->version, kPureQSharedRingVersion, memory_order_release);
    atomic_store_explicit(&gSharedRing->capacityFrames, kPureQLoopbackCapacityFrames, memory_order_release);
    atomic_store_explicit(&gSharedRing->channels, 2, memory_order_release);
    memset(gSharedRing->samples, 0, sizeof(gSharedRing->samples));
    atomic_store_explicit(&gSharedRing->writeCounter, 0, memory_order_release);
}

static void PureQSharedRingWrite(const Float32* samples, UInt32 frames)
{
    if (samples == NULL || frames == 0) {
        return;
    }

    PureQEnsureSharedRing();
    if (gSharedRing == NULL) {
        return;
    }

    uint64_t writeCounter = atomic_load_explicit(&gSharedRing->writeCounter, memory_order_acquire);
    for (UInt32 frame = 0; frame < frames; frame++) {
        uint64_t targetFrame = (writeCounter + frame) % kPureQLoopbackCapacityFrames;
        UInt32 ringOffset = (UInt32)targetFrame * 2;
        UInt32 sampleOffset = frame * 2;

        gSharedRing->samples[ringOffset] = samples[sampleOffset];
        gSharedRing->samples[ringOffset + 1] = samples[sampleOffset + 1];
    }
    atomic_store_explicit(&gSharedRing->writeCounter, writeCounter + frames, memory_order_release);
}

static void PureQLoopbackWrite(const Float32* samples, UInt32 frames)
{
    if (samples == NULL || frames == 0) {
        return;
    }

    PureQSharedRingWrite(samples, frames);

    for (UInt32 frame = 0; frame < frames; frame++) {
        UInt32 writeFrame = atomic_load_explicit(&gLoopbackWriteFrame, memory_order_relaxed);
        UInt32 ringOffset = writeFrame * 2;
        UInt32 sampleOffset = frame * 2;

        gLoopbackRing[ringOffset] = samples[sampleOffset];
        gLoopbackRing[ringOffset + 1] = samples[sampleOffset + 1];

        UInt32 nextWriteFrame = (writeFrame + 1) % kPureQLoopbackCapacityFrames;
        atomic_store_explicit(&gLoopbackWriteFrame, nextWriteFrame, memory_order_release);

        UInt32 availableFrames = atomic_load_explicit(&gLoopbackAvailableFrames, memory_order_acquire);
        if (availableFrames >= kPureQLoopbackCapacityFrames) {
            UInt32 readFrame = atomic_load_explicit(&gLoopbackReadFrame, memory_order_relaxed);
            atomic_store_explicit(&gLoopbackReadFrame, (readFrame + 1) % kPureQLoopbackCapacityFrames, memory_order_release);
        } else {
            atomic_fetch_add_explicit(&gLoopbackAvailableFrames, 1, memory_order_release);
        }
    }
}

static UInt32 PureQLoopbackRead(Float32* samples, UInt32 frames)
{
    if (samples == NULL || frames == 0) {
        return 0;
    }

    UInt32 copiedFrames = 0;
    for (; copiedFrames < frames; copiedFrames++) {
        UInt32 availableFrames = atomic_load_explicit(&gLoopbackAvailableFrames, memory_order_acquire);
        if (availableFrames == 0) {
            break;
        }

        UInt32 readFrame = atomic_load_explicit(&gLoopbackReadFrame, memory_order_relaxed);
        UInt32 ringOffset = readFrame * 2;
        UInt32 sampleOffset = copiedFrames * 2;

        samples[sampleOffset] = gLoopbackRing[ringOffset];
        samples[sampleOffset + 1] = gLoopbackRing[ringOffset + 1];

        atomic_store_explicit(&gLoopbackReadFrame, (readFrame + 1) % kPureQLoopbackCapacityFrames, memory_order_release);
        atomic_fetch_sub_explicit(&gLoopbackAvailableFrames, 1, memory_order_release);
    }

    return copiedFrames;
}

static void PureQNotifyProperty(AudioObjectID objectID, const AudioObjectPropertyAddress* address)
{
    if (gHost != NULL && gHost->PropertiesChanged != NULL) {
        AudioObjectPropertyAddress changedAddress = *address;
        gHost->PropertiesChanged(gHost, objectID, 1, &changedAddress);
    }
}

static void PureQNotifySelector(AudioObjectID objectID, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address;
    address.mSelector = selector;
    address.mScope = scope;
    address.mElement = kAudioObjectPropertyElementMain;
    PureQNotifyProperty(objectID, &address);
}

static void PureQResetTiming(void)
{
    gStartHostTime = AudioGetCurrentHostTime();
    gStartSampleTime = 0.0;
}

static void PureQDebugProperty(const char* phase, AudioObjectID objectID, const AudioObjectPropertyAddress* address, OSStatus status, UInt32 dataSize)
{
#if PUREQ_DRIVER_DEBUG
    if (address != NULL && (objectID <= kPureQObjectInputStream || address->mSelector == kAudioPlugInPropertyDeviceList || address->mSelector == kAudioObjectPropertyOwnedObjects)) {
        os_log_error(OS_LOG_DEFAULT, "PureQDriver %{public}s object=%u selector=%u scope=%u status=%d size=%u plugin=%{public}d",
            phase,
            objectID,
            address->mSelector,
            address->mScope,
            status,
            dataSize,
            PureQIsPluginObject(objectID));
    }
#else
    (void)phase;
    (void)objectID;
    (void)address;
    (void)status;
    (void)dataSize;
#endif
}

static HRESULT STDMETHODCALLTYPE PureQQueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG STDMETHODCALLTYPE PureQAddRef(void* inDriver);
static ULONG STDMETHODCALLTYPE PureQRelease(void* inDriver);
static OSStatus STDMETHODCALLTYPE PureQInitialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus STDMETHODCALLTYPE PureQCreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus STDMETHODCALLTYPE PureQDestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus STDMETHODCALLTYPE PureQAddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus STDMETHODCALLTYPE PureQRemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus STDMETHODCALLTYPE PureQPerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus STDMETHODCALLTYPE PureQAbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean STDMETHODCALLTYPE PureQHasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus STDMETHODCALLTYPE PureQIsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus STDMETHODCALLTYPE PureQGetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus STDMETHODCALLTYPE PureQGetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus STDMETHODCALLTYPE PureQSetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus STDMETHODCALLTYPE PureQStartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE PureQStopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE PureQGetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus STDMETHODCALLTYPE PureQWillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus STDMETHODCALLTYPE PureQBeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus STDMETHODCALLTYPE PureQDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus STDMETHODCALLTYPE PureQEndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gPureQDriverInterface = {
    NULL,
    PureQQueryInterface,
    PureQAddRef,
    PureQRelease,
    PureQInitialize,
    PureQCreateDevice,
    PureQDestroyDevice,
    PureQAddDeviceClient,
    PureQRemoveDeviceClient,
    PureQPerformDeviceConfigurationChange,
    PureQAbortDeviceConfigurationChange,
    PureQHasProperty,
    PureQIsPropertySettable,
    PureQGetPropertyDataSize,
    PureQGetPropertyData,
    PureQSetPropertyData,
    PureQStartIO,
    PureQStopIO,
    PureQGetZeroTimeStamp,
    PureQWillDoIOOperation,
    PureQBeginIOOperation,
    PureQDoIOOperation,
    PureQEndIOOperation
};

static AudioServerPlugInDriverInterface* gPureQDriverInterfacePtr = &gPureQDriverInterface;
static AudioServerPlugInDriverRef gPureQDriverRef = &gPureQDriverInterfacePtr;

__attribute__((visibility("default")))
void* PureQDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        PureQAddRef(gPureQDriverRef);
        return gPureQDriverRef;
    }
    return NULL;
}

static HRESULT STDMETHODCALLTYPE PureQQueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    (void)inDriver;
    if (outInterface == NULL) {
        return E_POINTER;
    }

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(requestedUUID, IUnknownUUID)) {
        PureQAddRef(gPureQDriverRef);
        *outInterface = gPureQDriverRef;
        CFRelease(requestedUUID);
        return S_OK;
    }

    *outInterface = NULL;
    CFRelease(requestedUUID);
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE PureQAddRef(void* inDriver)
{
    (void)inDriver;
    return atomic_fetch_add_explicit(&gReferenceCount, 1, memory_order_relaxed) + 1;
}

static ULONG STDMETHODCALLTYPE PureQRelease(void* inDriver)
{
    (void)inDriver;
    UInt32 current = atomic_load_explicit(&gReferenceCount, memory_order_relaxed);
    if (current == 0) {
        return 0;
    }
    return atomic_fetch_sub_explicit(&gReferenceCount, 1, memory_order_relaxed) - 1;
}

static OSStatus STDMETHODCALLTYPE PureQInitialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;
    PureQResetTiming();
    PureQEnsureSharedRing();
    PureQLoopbackReset();
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQCreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    if (outDeviceObjectID == NULL) {
        return kAudioHardwareBadObjectError;
    }
    *outDeviceObjectID = kPureQObjectDevice;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQDestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PureQAddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PureQRemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PureQPerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PureQAbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static Boolean STDMETHODCALLTYPE PureQHasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;
    PureQRememberPluginObject(inObjectID);
    PureQDebugProperty("has-entry", inObjectID, inAddress, 0, 0);
    if (!PureQObjectExists(inObjectID) || inAddress == NULL) {
        return false;
    }

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
        return true;
    default:
        break;
    }

    if (PureQIsPluginObject(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyClockDeviceList:
        case kAudioObjectPropertyCustomPropertyInfoList:
            return true;
        default:
            return false;
        }
    }

    if (inObjectID == kPureQObjectBox) {
        switch (inAddress->mSelector) {
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
        case kAudioBoxPropertyClockDeviceList:
            return true;
        default:
            return false;
        }
    }

    if (inObjectID == kPureQObjectDevice) {
        switch (inAddress->mSelector) {
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        case kAudioDevicePropertyActualSampleRate:
            return true;
        default:
            return false;
        }
    }

    if (inObjectID == kPureQObjectInputStream || inObjectID == kPureQObjectOutputStream) {
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
        }
    }

    return false;
}

static OSStatus STDMETHODCALLTYPE PureQIsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver;
    (void)inClientProcessID;
    PureQRememberPluginObject(inObjectID);
    if (outIsSettable == NULL || inAddress == NULL || !PureQObjectExists(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    *outIsSettable = false;
    if (inObjectID == kPureQObjectBox && inAddress->mSelector == kAudioBoxPropertyAcquired) {
        *outIsSettable = true;
    }
    if (inObjectID == kPureQObjectDevice &&
        (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
         inAddress->mSelector == kAudioDevicePropertyBufferFrameSize)) {
        *outIsSettable = true;
    }
    return PureQHasProperty(inDriver, inObjectID, inClientProcessID, inAddress) ? noErr : kAudioHardwareUnknownPropertyError;
}

static OSStatus STDMETHODCALLTYPE PureQGetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    PureQRememberPluginObject(inObjectID);
    PureQDebugProperty("size-entry", inObjectID, inAddress, 0, 0);
    if (outDataSize == NULL || inAddress == NULL || !PureQObjectExists(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (!PureQHasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioPlugInPropertyBundleID:
    case kAudioBoxPropertyBoxUID:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        *outDataSize = sizeof(CFStringRef);
        return noErr;
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyBufferFrameSize:
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioBoxPropertyHasAudio:
    case kAudioBoxPropertyHasVideo:
    case kAudioBoxPropertyHasMIDI:
    case kAudioBoxPropertyIsProtected:
    case kAudioBoxPropertyAcquired:
    case kAudioBoxPropertyAcquisitionFailed:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
        *outDataSize = sizeof(UInt32);
        return noErr;
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyActualSampleRate:
        *outDataSize = sizeof(Float64);
        return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyBufferFrameSizeRange:
        *outDataSize = sizeof(AudioValueRange);
        return noErr;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return noErr;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outDataSize = 2 * sizeof(UInt32);
        return noErr;
    case kAudioObjectPropertyOwnedObjects:
        if (PureQIsPluginObject(inObjectID)) {
            *outDataSize = 2 * sizeof(AudioObjectID);
        } else if (inObjectID == kPureQObjectBox) {
            *outDataSize = 0;
        } else if (inObjectID == kPureQObjectDevice) {
            *outDataSize = 2 * sizeof(AudioObjectID);
        } else {
            *outDataSize = 0;
        }
        return noErr;
    case kAudioPlugInPropertyDeviceList:
        *outDataSize = sizeof(AudioObjectID);
        PureQDebugProperty("size-device-list", inObjectID, inAddress, noErr, *outDataSize);
        return noErr;
    case kAudioPlugInPropertyBoxList:
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    case kAudioPlugInPropertyClockDeviceList:
    case kAudioObjectPropertyControlList:
    case kAudioObjectPropertyCustomPropertyInfoList:
        *outDataSize = 0;
        return noErr;
    case kAudioPlugInPropertyTranslateUIDToBox:
    case kAudioPlugInPropertyTranslateUIDToDevice:
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    case kAudioBoxPropertyDeviceList:
    case kAudioDevicePropertyRelatedDevices:
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    case kAudioBoxPropertyClockDeviceList:
        *outDataSize = 0;
        return noErr;
    case kAudioDevicePropertyStreams:
        *outDataSize = PureQStreamCountForScope(inAddress->mScope) * sizeof(AudioObjectID);
        return noErr;
    case kAudioDevicePropertyStreamConfiguration:
        *outDataSize = PureQStreamConfigurationSize(PureQStreamCountForScope(inAddress->mScope));
        return noErr;
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus STDMETHODCALLTYPE PureQGetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    PureQRememberPluginObject(inObjectID);
    PureQDebugProperty("data-entry", inObjectID, inAddress, 0, inDataSize);
    if (outDataSize == NULL || outData == NULL || inAddress == NULL || !PureQObjectExists(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (!PureQHasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    *outDataSize = 0;
    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, kAudioObjectClassID) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioObjectPropertyClass:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, PureQObjectClass(inObjectID)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioObjectPropertyOwner:
        return PureQWriteAudioObjectID(inDataSize, outDataSize, outData, PureQObjectOwner(inObjectID)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioObjectPropertyName:
        return PureQWriteCFString(inDataSize, outDataSize, outData, PureQObjectName(inObjectID)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioObjectPropertyManufacturer:
        return PureQWriteCFString(inDataSize, outDataSize, outData, CFStringCreateCopy(kCFAllocatorDefault, CFSTR("PureQ"))) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioObjectPropertyOwnedObjects: {
        if (PureQIsPluginObject(inObjectID)) {
            AudioObjectID objects[] = { kPureQObjectBox, kPureQObjectDevice };
            return PureQWriteData(inDataSize, outDataSize, outData, objects, sizeof(objects)) ? noErr : kAudioHardwareBadPropertySizeError;
        }
        if (inObjectID == kPureQObjectBox) {
            *outDataSize = 0;
            return noErr;
        }
        if (inObjectID == kPureQObjectDevice) {
            AudioObjectID objects[] = { kPureQObjectOutputStream, kPureQObjectInputStream };
            return PureQWriteData(inDataSize, outDataSize, outData, objects, sizeof(objects)) ? noErr : kAudioHardwareBadPropertySizeError;
        }
        *outDataSize = 0;
        return noErr;
    }
    case kAudioPlugInPropertyBundleID:
        return PureQWriteCFString(inDataSize, outDataSize, outData, CFStringCreateWithCString(kCFAllocatorDefault, kPureQDriverBundleID, kCFStringEncodingUTF8)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID devices[] = { kPureQObjectDevice };
        PureQDebugProperty("data-device-list", inObjectID, inAddress, noErr, sizeof(devices));
        return PureQWriteData(inDataSize, outDataSize, outData, devices, sizeof(devices)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID device = kAudioObjectUnknown;
        if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            if (uid != NULL && CFStringCompare(uid, CFSTR(kPureQDeviceUID), 0) == kCFCompareEqualTo) {
                device = kPureQObjectDevice;
            }
        }
        return PureQWriteAudioObjectID(inDataSize, outDataSize, outData, device) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioPlugInPropertyBoxList: {
        AudioObjectID boxes[] = { kPureQObjectBox };
        return PureQWriteData(inDataSize, outDataSize, outData, boxes, sizeof(boxes)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioPlugInPropertyTranslateUIDToBox: {
        AudioObjectID box = kAudioObjectUnknown;
        if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            if (uid != NULL && CFStringCompare(uid, CFSTR(kPureQBoxUID), 0) == kCFCompareEqualTo) {
                box = kPureQObjectBox;
            }
        }
        return PureQWriteAudioObjectID(inDataSize, outDataSize, outData, box) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioPlugInPropertyClockDeviceList:
    case kAudioObjectPropertyControlList:
    case kAudioObjectPropertyCustomPropertyInfoList:
        *outDataSize = 0;
        return noErr;
    case kAudioBoxPropertyBoxUID:
        return PureQWriteCFString(inDataSize, outDataSize, outData, CFStringCreateWithCString(kCFAllocatorDefault, kPureQBoxUID, kCFStringEncodingUTF8)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioBoxPropertyHasAudio:
    case kAudioBoxPropertyAcquired:
        return PureQWriteBoolean(inDataSize, outDataSize, outData, 1) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioBoxPropertyHasVideo:
    case kAudioBoxPropertyHasMIDI:
    case kAudioBoxPropertyIsProtected:
    case kAudioBoxPropertyAcquisitionFailed:
        return PureQWriteBoolean(inDataSize, outDataSize, outData, 0) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioBoxPropertyDeviceList: {
        AudioObjectID devices[] = { kPureQObjectDevice };
        return PureQWriteData(inDataSize, outDataSize, outData, devices, sizeof(devices)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioBoxPropertyClockDeviceList:
        *outDataSize = 0;
        return noErr;
    case kAudioDevicePropertyDeviceUID:
        return PureQWriteCFString(inDataSize, outDataSize, outData, CFStringCreateWithCString(kCFAllocatorDefault, kPureQDeviceUID, kCFStringEncodingUTF8)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyModelUID:
        return PureQWriteCFString(inDataSize, outDataSize, outData, CFStringCreateWithCString(kCFAllocatorDefault, kPureQModelUID, kCFStringEncodingUTF8)) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyTransportType:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, kAudioDeviceTransportTypeVirtual) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID devices[] = { kPureQObjectDevice };
        return PureQWriteData(inDataSize, outDataSize, outData, devices, sizeof(devices)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, 0) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioStreamPropertyIsActive:
        return PureQWriteBoolean(inDataSize, outDataSize, outData, 1) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyDeviceIsRunning:
        return PureQWriteBoolean(inDataSize, outDataSize, outData, atomic_load_explicit(&gIOClientCount, memory_order_relaxed) > 0 ? 1 : 0) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyActualSampleRate:
        return PureQWriteFloat64(inDataSize, outDataSize, outData, gSampleRate) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = PureQSampleRateRange();
        return PureQWriteData(inDataSize, outDataSize, outData, &range, sizeof(range)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioDevicePropertyBufferFrameSize:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, gBufferFrameSize) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyZeroTimeStampPeriod:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, kPureQZeroTimeStampPeriod) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioDevicePropertyBufferFrameSizeRange: {
        AudioValueRange range = PureQBufferFrameSizeRange();
        return PureQWriteData(inDataSize, outDataSize, outData, &range, sizeof(range)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 channels[] = { 1, 2 };
        return PureQWriteData(inDataSize, outDataSize, outData, channels, sizeof(channels)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioDevicePropertyStreams: {
        if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
            AudioObjectID streams[] = { kPureQObjectInputStream };
            return PureQWriteData(inDataSize, outDataSize, outData, streams, sizeof(streams)) ? noErr : kAudioHardwareBadPropertySizeError;
        }
        if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
            AudioObjectID streams[] = { kPureQObjectOutputStream };
            return PureQWriteData(inDataSize, outDataSize, outData, streams, sizeof(streams)) ? noErr : kAudioHardwareBadPropertySizeError;
        }
        AudioObjectID streams[] = { kPureQObjectInputStream, kPureQObjectOutputStream };
        return PureQWriteData(inDataSize, outDataSize, outData, streams, sizeof(streams)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioDevicePropertyStreamConfiguration: {
        UInt32 bufferCount = PureQStreamCountForScope(inAddress->mScope);
        UInt32 dataSize = PureQStreamConfigurationSize(bufferCount);
        if (inDataSize < dataSize) {
            return kAudioHardwareBadPropertySizeError;
        }
        PureQFillStreamConfiguration(inAddress->mScope, (AudioBufferList*)outData);
        *outDataSize = dataSize;
        return noErr;
    }
    case kAudioStreamPropertyDirection:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, inObjectID == kPureQObjectInputStream ? 1 : 0) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioStreamPropertyTerminalType:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, inObjectID == kPureQObjectInputStream ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioStreamPropertyStartingChannel:
        return PureQWriteUInt32(inDataSize, outDataSize, outData, 1) ? noErr : kAudioHardwareBadPropertySizeError;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription description = PureQStreamDescription();
        return PureQWriteData(inDataSize, outDataSize, outData, &description, sizeof(description)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription description = PureQStreamRangedDescription();
        return PureQWriteData(inDataSize, outDataSize, outData, &description, sizeof(description)) ? noErr : kAudioHardwareBadPropertySizeError;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus STDMETHODCALLTYPE PureQSetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) {
        return kAudioHardwareBadObjectError;
    }

    if (inObjectID == kPureQObjectBox && inAddress->mSelector == kAudioBoxPropertyAcquired) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        PureQNotifyProperty(inObjectID, inAddress);
        return noErr;
    }

    if (inObjectID != kPureQObjectDevice) {
        return kAudioHardwareBadObjectError;
    }

    switch (inAddress->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (inDataSize != sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gSampleRate = PureQClampSampleRate(*((const Float64*)inData));
        PureQResetTiming();
        PureQLoopbackReset();
        PureQNotifyProperty(inObjectID, inAddress);
        PureQNotifySelector(inObjectID, kAudioDevicePropertyActualSampleRate, kAudioObjectPropertyScopeGlobal);
        PureQNotifySelector(kPureQObjectInputStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
        PureQNotifySelector(kPureQObjectInputStream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal);
        PureQNotifySelector(kPureQObjectOutputStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
        PureQNotifySelector(kPureQObjectOutputStream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal);
        return noErr;
    case kAudioDevicePropertyBufferFrameSize:
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gBufferFrameSize = PureQClampBufferFrameSize(*((const UInt32*)inData));
        PureQNotifyProperty(inObjectID, inAddress);
        return noErr;
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus STDMETHODCALLTYPE PureQStartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kPureQObjectDevice) {
        return kAudioHardwareBadObjectError;
    }
    if (atomic_fetch_add_explicit(&gIOClientCount, 1, memory_order_relaxed) == 0) {
        PureQResetTiming();
        PureQLoopbackReset();
        PureQNotifySelector(kPureQObjectDevice, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal);
    }
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQStopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kPureQObjectDevice) {
        return kAudioHardwareBadObjectError;
    }
    UInt32 count = atomic_load_explicit(&gIOClientCount, memory_order_relaxed);
    if (count > 0) {
        if (atomic_fetch_sub_explicit(&gIOClientCount, 1, memory_order_relaxed) == 1) {
            PureQNotifySelector(kPureQObjectDevice, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal);
        }
    }
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQGetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kPureQObjectDevice || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareBadObjectError;
    }

    UInt64 now = AudioGetCurrentHostTime();
    UInt64 hostTicksPerSecond = AudioConvertNanosToHostTime(1000000000ULL);
    Float64 hostTicksPerFrame = ((Float64)hostTicksPerSecond) / gSampleRate;
    Float64 elapsedFrames = ((Float64)(now - gStartHostTime)) / hostTicksPerFrame;
    UInt64 zeroFrame = (((UInt64)elapsedFrames) / kPureQZeroTimeStampPeriod) * kPureQZeroTimeStampPeriod;

    *outSampleTime = gStartSampleTime + (Float64)zeroFrame;
    *outHostTime = gStartHostTime + (UInt64)(((Float64)zeroFrame) * hostTicksPerFrame);
    *outSeed = 1;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQWillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kPureQObjectDevice || outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareBadObjectError;
    }

    *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix ||
        inOperationID == kAudioServerPlugInIOOperationReadInput;
    *outWillDoInPlace = true;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQBeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus STDMETHODCALLTYPE PureQDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)inStreamObjectID;
    (void)ioSecondaryBuffer;
    if (inDeviceObjectID != kPureQObjectDevice) {
        return kAudioHardwareBadObjectError;
    }
    if (ioMainBuffer == NULL) {
        return noErr;
    }

    UInt32 frames = inIOBufferFrameSize;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        PureQLoopbackWrite((const Float32*)ioMainBuffer, frames);
        return noErr;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt32 copyFrames = PureQLoopbackRead((Float32*)ioMainBuffer, frames);
        UInt32 copyBytes = copyFrames * 2 * (UInt32)sizeof(Float32);
        if (copyFrames < inIOBufferFrameSize) {
            UInt32 remainingBytes = (inIOBufferFrameSize - copyFrames) * 2 * (UInt32)sizeof(Float32);
            memset(((UInt8*)ioMainBuffer) + copyBytes, 0, remainingBytes);
        }
        return noErr;
    }

    return noErr;
}

static OSStatus STDMETHODCALLTYPE PureQEndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kPureQObjectDevice ? noErr : kAudioHardwareBadObjectError;
}
