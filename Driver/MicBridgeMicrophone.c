// MicBridge Microphone: a virtual microphone for Core Audio.
//
// An AudioServerPlugIn (HAL plug-in) with one device and two streams. The
// MicBridge app writes the other Mac's microphone into the output stream;
// every app here records it from the input stream. Nothing else: no
// controls, no settings, no files, no network.
//
//   plug-in (1) ── device "MicBridge Microphone" (2)
//                    ├── input stream  (3)  apps record from it
//                    └── output stream (4)  MicBridge writes into it
//
// Format: 48 kHz, 2 channels, 32-bit float, interleaved. Audio written for
// sample time T is read back by input for the same T (a loopback). Input
// clears what it has read, so when MicBridge stops writing, apps hear
// silence rather than the last second over again.
//
// Written from the interface in <CoreAudio/AudioServerPlugIn.h>.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define MB_NAME          "MicBridge Microphone"
#define MB_MANUFACTURER  "MicBridge"
#define MB_DEVICE_UID    "MicBridgeMicrophone_UID"
#define MB_MODEL_UID     "MicBridgeMicrophone_ModelUID"

enum {
    kPlugIn       = kAudioObjectPlugInObject,
    kDevice       = 2,
    kInputStream  = 3,
    kOutputStream = 4,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 2;
static const UInt32 kBytesPerFrame = sizeof(Float32) * 2;
// The ring also sets the clock period (kAudioDevicePropertyZeroTimeStampPeriod).
#define RING_FRAMES 16384u

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
// Clients with IO running; the clock runs while it is above zero.
static UInt64 gIOCount = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gPeriods = 0;
static Float64 gHostTicksPerFrame = 0;
static atomic_bool gInputActive = true;
static atomic_bool gOutputActive = true;
static Float32 gRing[RING_FRAMES * 2];

// MARK: - Helpers

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static int SameFormat(const AudioStreamBasicDescription *a) {
    AudioStreamBasicDescription f = Format();
    return a->mSampleRate == f.mSampleRate && a->mFormatID == f.mFormatID && a->mFormatFlags == f.mFormatFlags &&
           a->mBytesPerFrame == f.mBytesPerFrame && a->mChannelsPerFrame == f.mChannelsPerFrame && a->mBitsPerChannel == f.mBitsPerChannel;
}

static int IsStream(AudioObjectID object) { return object == kInputStream || object == kOutputStream; }

// One answer for size queries (out == NULL) and reads.
typedef struct {
    UInt32 inSize;
    UInt32 *outSize;
    void *out;
} Reply;

static OSStatus Bytes(Reply r, const void *value, UInt32 size) {
    if (r.out == NULL) { *r.outSize = size; return kAudioHardwareNoError; }
    if (r.inSize < size) return kAudioHardwareBadPropertySizeError;
    memcpy(r.out, value, size);
    *r.outSize = size;
    return kAudioHardwareNoError;
}
// Arrays return as many whole items as fit.
static OSStatus Items(Reply r, const void *items, UInt32 count, UInt32 itemSize) {
    if (r.out == NULL) { *r.outSize = count * itemSize; return kAudioHardwareNoError; }
    UInt32 fit = r.inSize / itemSize;
    if (fit > count) fit = count;
    if (fit > 0) memcpy(r.out, items, fit * itemSize);
    *r.outSize = fit * itemSize;
    return kAudioHardwareNoError;
}
static OSStatus U32(Reply r, UInt32 value) { return Bytes(r, &value, sizeof(value)); }
static OSStatus F64(Reply r, Float64 value) { return Bytes(r, &value, sizeof(value)); }
static OSStatus Str(Reply r, CFStringRef value) { return Bytes(r, &value, sizeof(value)); }

// MARK: - Properties

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, Reply r) {
    static const AudioObjectID devices[] = { kDevice };
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return U32(r, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return U32(r, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: return U32(r, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: return Str(r, CFSTR(MB_MANUFACTURER));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: return Items(r, devices, 1, sizeof(AudioObjectID));
    case kAudioPlugInPropertyBoxList: return Items(r, NULL, 0, sizeof(AudioObjectID));
    case kAudioPlugInPropertyResourceBundle: return Str(r, CFSTR(""));
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (r.out == NULL) { *r.outSize = sizeof(AudioObjectID); return kAudioHardwareNoError; }
        if (qSize != sizeof(CFStringRef) || q == NULL) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef *)q;
        AudioObjectID found = uid != NULL && CFStringCompare(uid, CFSTR(MB_DEVICE_UID), 0) == kCFCompareEqualTo ? kDevice : kAudioObjectUnknown;
        return U32(r, found);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress *a, Reply r) {
    static const AudioObjectID both[] = { kInputStream, kOutputStream };
    static const AudioObjectID input[] = { kInputStream };
    static const AudioObjectID output[] = { kOutputStream };
    static const AudioObjectID related[] = { kDevice };
    static const UInt32 stereo[] = { 1, 2 };
    int inScope = a->mScope == kAudioObjectPropertyScopeInput, outScope = a->mScope == kAudioObjectPropertyScopeOutput;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return U32(r, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return U32(r, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: return U32(r, kPlugIn);
    case kAudioObjectPropertyName: return Str(r, CFSTR(MB_NAME));
    case kAudioObjectPropertyManufacturer: return Str(r, CFSTR(MB_MANUFACTURER));
    case kAudioDevicePropertyDeviceUID: return Str(r, CFSTR(MB_DEVICE_UID));
    case kAudioDevicePropertyModelUID: return Str(r, CFSTR(MB_MODEL_UID));
    case kAudioDevicePropertyTransportType: return U32(r, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: return Items(r, related, 1, sizeof(AudioObjectID));
    case kAudioDevicePropertyClockDomain: return U32(r, 0);
    case kAudioDevicePropertyDeviceIsAlive: return U32(r, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gLock);
        UInt32 running = gIOCount > 0;
        pthread_mutex_unlock(&gLock);
        return U32(r, running);
    }
    // Apps may pick it as their microphone; sound is never sent to it by
    // default, and alerts never play into it.
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: return U32(r, inScope ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return U32(r, 0);
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset: return U32(r, 0);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        if (inScope) return Items(r, input, 1, sizeof(AudioObjectID));
        if (outScope) return Items(r, output, 1, sizeof(AudioObjectID));
        return Items(r, both, 2, sizeof(AudioObjectID));
    case kAudioObjectPropertyControlList: return Items(r, NULL, 0, sizeof(AudioObjectID));
    case kAudioDevicePropertyNominalSampleRate: return F64(r, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = { kSampleRate, kSampleRate };
        return Items(r, &range, 1, sizeof(range));
    }
    case kAudioDevicePropertyIsHidden: return U32(r, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: return U32(r, RING_FRAMES);
    case kAudioDevicePropertyClockIsStable: return U32(r, 1);
    case kAudioDevicePropertyPreferredChannelsForStereo: return Bytes(r, stereo, sizeof(stereo));
    case kAudioDevicePropertyPreferredChannelLayout: {
        struct {
            AudioChannelLayout layout;
            AudioChannelDescription second;
        } value;
        memset(&value, 0, sizeof(value));
        value.layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        value.layout.mNumberChannelDescriptions = 2;
        value.layout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        value.second.mChannelLabel = kAudioChannelLabel_Right;
        return Bytes(r, &value, (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + 2 * sizeof(AudioChannelDescription)));
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID stream, const AudioObjectPropertyAddress *a, Reply r) {
    int isInput = stream == kInputStream;
    AudioStreamBasicDescription format = Format();
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return U32(r, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return U32(r, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: return U32(r, kDevice);
    case kAudioObjectPropertyOwnedObjects: return Items(r, NULL, 0, sizeof(AudioObjectID));
    case kAudioStreamPropertyIsActive: return U32(r, atomic_load(isInput ? &gInputActive : &gOutputActive) ? 1 : 0);
    case kAudioStreamPropertyDirection: return U32(r, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType: return U32(r, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: return U32(r, 1);
    case kAudioStreamPropertyLatency: return U32(r, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: return Bytes(r, &format, sizeof(format));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged;
        ranged.mFormat = format;
        ranged.mSampleRateRange.mMinimum = kSampleRate;
        ranged.mSampleRateRange.mMaximum = kSampleRate;
        return Items(r, &ranged, 1, sizeof(ranged));
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Property(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, Reply r) {
    if (a == NULL || r.outSize == NULL) return kAudioHardwareIllegalOperationError;
    if (object == kPlugIn) return PlugInProperty(a, qSize, q, r);
    if (object == kDevice) return DeviceProperty(a, r);
    if (IsStream(object)) return StreamProperty(object, a, r);
    return kAudioHardwareBadObjectError;
}

// MARK: - Driver interface

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef description, const AudioServerPlugInClientInfo *c, AudioObjectID *out) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus PerformConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus AbortConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a) {
    UInt32 size = 0;
    Reply r = { 0, &size, NULL };
    return Property(object, a, 0, NULL, r) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (out == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, object, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = IsStream(object) && (a->mSelector == kAudioStreamPropertyIsActive ||
                                a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qSize, const void *q, UInt32 *outSize) {
    Reply r = { 0, outSize, NULL };
    return Property(object, a, qSize, q, r);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qSize, const void *q, UInt32 inSize, UInt32 *outSize, void *out) {
    if (out == NULL) return kAudioHardwareIllegalOperationError;
    Reply r = { inSize, outSize, out };
    return Property(object, a, qSize, q, r);
}

// Only what keeps the device as it is: a stream switched on or off, or
// its one format chosen again. The sample rate is fixed at 48 kHz.
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qSize, const void *q, UInt32 inSize, const void *in) {
    if (a == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, object, pid, a)) return kAudioHardwareUnknownPropertyError;
    if (IsStream(object) && a->mSelector == kAudioStreamPropertyIsActive) {
        if (inSize != sizeof(UInt32) || in == NULL) return kAudioHardwareBadPropertySizeError;
        atomic_store(object == kInputStream ? &gInputActive : &gOutputActive, *(const UInt32 *)in != 0);
        if (gHost != NULL) gHost->PropertiesChanged(gHost, object, 1, a);
        return kAudioHardwareNoError;
    }
    if (IsStream(object) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize != sizeof(AudioStreamBasicDescription) || in == NULL) return kAudioHardwareBadPropertySizeError;
        return SameFormat((const AudioStreamBasicDescription *)in) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (device != kDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    if (gIOCount == UINT64_MAX) { pthread_mutex_unlock(&gLock); return kAudioHardwareIllegalOperationError; }
    if (gIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        gPeriods = 0;
        memset(gRing, 0, sizeof(gRing));
    }
    gIOCount++;
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (device != kDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    OSStatus result = kAudioHardwareNoError;
    if (gIOCount == 0) result = kAudioHardwareIllegalOperationError; else gIOCount--;
    pthread_mutex_unlock(&gLock);
    return result;
}

// The clock: one time stamp per ring period, from the host clock.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    if (device != kDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gLock);
    Float64 ticksPerPeriod = gHostTicksPerFrame * RING_FRAMES;
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gPeriods + 1) * ticksPerPeriod);
    if (next <= now) gPeriods++;
    *sampleTime = (Float64)(gPeriods * RING_FRAMES);
    *hostTime = gAnchorHostTime + (UInt64)((Float64)gPeriods * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, Boolean *willDo, Boolean *inPlace) {
    if (device != kDevice) return kAudioHardwareBadObjectError;
    Boolean will = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    if (willDo != NULL) *willDo = will;
    if (inPlace != NULL) *inPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return device == kDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// Copies between the interleaved buffer and the ring at `sampleTime`,
// wrapping around. Reading clears what it read.
static void RingRead(Float64 sampleTime, UInt32 frames, Float32 *buffer) {
    UInt64 start = (UInt64)sampleTime % RING_FRAMES;
    UInt32 first = (UInt32)(RING_FRAMES - start) < frames ? (UInt32)(RING_FRAMES - start) : frames;
    memcpy(buffer, gRing + start * kChannels, first * kBytesPerFrame);
    memset(gRing + start * kChannels, 0, first * kBytesPerFrame);
    if (frames > first) {
        memcpy(buffer + first * kChannels, gRing, (frames - first) * kBytesPerFrame);
        memset(gRing, 0, (frames - first) * kBytesPerFrame);
    }
}
static void RingWrite(Float64 sampleTime, UInt32 frames, const Float32 *buffer) {
    UInt64 start = (UInt64)sampleTime % RING_FRAMES;
    UInt32 first = (UInt32)(RING_FRAMES - start) < frames ? (UInt32)(RING_FRAMES - start) : frames;
    memcpy(gRing + start * kChannels, buffer, first * kBytesPerFrame);
    if (frames > first) memcpy(gRing, buffer + first * kChannels, (frames - first) * kBytesPerFrame);
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 operation,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    if (device != kDevice) return kAudioHardwareBadObjectError;
    if (main == NULL || cycle == NULL || frames > RING_FRAMES) return kAudioHardwareIllegalOperationError;
    if (operation == kAudioServerPlugInIOOperationReadInput && stream == kInputStream) {
        RingRead(cycle->mInputTime.mSampleTime, frames, (Float32 *)main);
    } else if (operation == kAudioServerPlugInIOOperationWriteMix && stream == kOutputStream) {
        RingWrite(cycle->mOutputTime.mSampleTime, frames, (const Float32 *)main);
    }
    return kAudioHardwareNoError;
}

// MARK: - COM plumbing and factory

static AudioServerPlugInDriverInterface gInterface = {
    ._reserved = NULL,
    .QueryInterface = QueryInterface,
    .AddRef = AddRef,
    .Release = Release,
    .Initialize = Initialize,
    .CreateDevice = CreateDevice,
    .DestroyDevice = DestroyDevice,
    .AddDeviceClient = AddDeviceClient,
    .RemoveDeviceClient = RemoveDeviceClient,
    .PerformDeviceConfigurationChange = PerformConfigurationChange,
    .AbortDeviceConfigurationChange = AbortConfigurationChange,
    .HasProperty = HasProperty,
    .IsPropertySettable = IsPropertySettable,
    .GetPropertyDataSize = GetPropertyDataSize,
    .GetPropertyData = GetPropertyData,
    .SetPropertyData = SetPropertyData,
    .StartIO = StartIO,
    .StopIO = StopIO,
    .GetZeroTimeStamp = GetZeroTimeStamp,
    .WillDoIOOperation = WillDoIOOperation,
    .BeginIOOperation = BeginIOOperation,
    .DoIOOperation = DoIOOperation,
    .EndIOOperation = EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePtr;

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out) {
    if (driver != gDriver || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *out = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}
static ULONG AddRef(void *driver) {
    if (driver != gDriver) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}
static ULONG Release(void *driver) {
    if (driver != gDriver) return 0;
    unsigned current = atomic_load(&gRefCount);
    while (current > 0 && !atomic_compare_exchange_weak(&gRefCount, &current, current - 1)) {}
    return current > 0 ? current - 1 : 0;
}

// Named in Info.plist (CFPlugInFactories); the only exported symbol.
__attribute__((visibility("default"))) void *MicBridge_Create(CFAllocatorRef allocator, CFUUIDRef requestedType);
__attribute__((visibility("default"))) void *MicBridge_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    if (requestedType == NULL || !CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriver;
}
