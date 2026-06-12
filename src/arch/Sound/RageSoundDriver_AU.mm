#include "RageSoundDriver_AU.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageSoundConstants.h"
#include "archutils/Darwin/DarwinThreadHelpers.h"
#include "global.h"

#include <cstdint>

#if defined(TVOS)
#include <AudioToolbox/AudioToolbox.h>
#include <AVFAudio/AVFAudio.h>
#include <mach/mach_time.h>
#else
#include <AudioToolbox/AudioServices.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreServices/CoreServices.h>
#endif

REGISTER_SOUND_DRIVER_CLASS2("AudioUnit", AU);

static const UInt32 kFramesPerPacket = 1;
static const UInt32 kChannelsPerFrame = 2;
static const UInt32 kBitsPerChannel = 32;
static const UInt32 kBytesPerPacket = kChannelsPerFrame * kBitsPerChannel / 8;
static const UInt32 kBytesPerFrame = kBytesPerPacket;
static const UInt32 kFormatFlags =
    Enum::to_integral(kAudioFormatFlagsNativeEndian) | Enum::to_integral(kAudioFormatFlagIsFloat);

static const char* FormatOSError(OSStatus status) {
  NSError* error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  return [error.localizedDescription UTF8String];
}

RageSoundDriver_AU::RageSoundDriver_AU()
    :
#if defined(TVOS)
      m_HardwareSampleRate(0.0),
#endif
      m_OutputUnit(nullptr),
      m_iSampleRate(0),
      m_bDone(false),
      m_bStarted(false),
      m_pIOThread(nullptr),
      m_pNotificationThread(nullptr),
      m_Semaphore("Sound") {}

#if !defined(TVOS)
static void SetSampleRate(AudioUnit au, Float64 desiredRate) {
  AudioDeviceID OutputDevice;
  OSStatus error;
  UInt32 size = sizeof(AudioDeviceID);

  if ((error = AudioUnitGetProperty(
           au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &OutputDevice,
           &size))) {
    LOG->Warn("No output device: %s", FormatOSError(error));
    return;
  }

  AudioObjectPropertyAddress RateAddr = {
      kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  Float64 rate = 0.0;
  size = sizeof(Float64);
  if ((error = AudioObjectGetPropertyData(OutputDevice, &RateAddr, 0, NULL, &size, &rate))) {
    LOG->Warn("Couldn't get the device's sample rate: %s", FormatOSError(error));
    return;
  }
  if (rate == desiredRate) {
    return;
  }

  AudioObjectPropertyAddress AvailableRatesAddr = {
      kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  if ((error =
           AudioObjectGetPropertyDataSize(OutputDevice, &AvailableRatesAddr, 0, nullptr, &size))) {
    LOG->Warn("Couldn't get available nominal sample rates info: %s", FormatOSError(error));
    return;
  }

  const int num = size / sizeof(AudioValueRange);
  AudioValueRange* ranges = new AudioValueRange[num];

  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &AvailableRatesAddr, 0, NULL, &size, ranges))) {
    LOG->Warn("Couldn't get available nominal sample rates: %s", FormatOSError(error));
    delete[] ranges;
    return;
  }

  Float64 bestRate = 0.0;
  for (int i = 0; i < num; ++i) {
    if (desiredRate >= ranges[i].mMinimum && desiredRate <= ranges[i].mMaximum) {
      bestRate = desiredRate;
      break;
    }
    /* XXX: If the desired rate is supported by the device, then change it, if not
     * then we should select the "best" rate. I don't really know what such a best
     * rate would be. The rate closest to the desired value? A multiple of 2?
     * For now give up if the desired sample rate isn't available. */
  }
  delete[] ranges;
  if (bestRate == 0.0) {
    return;
  }

  if ((error = AudioObjectSetPropertyData(
           OutputDevice, &RateAddr, 0, nullptr, sizeof(Float64), &bestRate))) {
    LOG->Warn("Couldn't set the device's sample rate: %s", FormatOSError(error));
  }
}
#endif

#if defined(TVOS)
static double GetHostTimeScale(Float64 sampleRate) {
  mach_timebase_info_data_t info;
  mach_timebase_info(&info);
  double hostTicksPerSecond = 1e9 * (double)info.denom / (double)info.numer;
  return sampleRate / hostTicksPerSecond;
}

/* Configure the shared AVAudioSession for low-latency playback before the
 * RemoteIO AudioUnit is created and started. Without this, the OS picks a
 * default session whose hardware sample rate (48 kHz on Apple TV) differs from
 * the driver's stream format, forcing realtime sample-rate conversion in the
 * IO render callback.
 *
 * desiredRate is the rate we would like the hardware to run at. Passing the
 * hardware's own rate (or 0, meaning "no preference") avoids requesting a rate
 * the device cannot honor. Returns the session's actual sample rate after
 * activation (0.0 on hard failure), so the caller can match the AU stream
 * format to the hardware and skip realtime SRC.
 *
 * This file is compiled WITHOUT -fobjc-arc (MRC); +sharedInstance returns a
 * non-owned singleton and the NSError outparams are autoreleased, so no manual
 * retain/release is required here. */
static Float64 ConfigureAudioSession(Float64 desiredRate, NSTimeInterval ioBufferDuration) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSError* error = nil;

  if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
    LOG->Warn(
        "AVAudioSession: couldn't set playback category: %s",
        [[error localizedDescription] UTF8String]);
    error = nil;
  }

  if (desiredRate > 0.0 &&
      ![session setPreferredSampleRate:desiredRate error:&error]) {
    LOG->Warn(
        "AVAudioSession: couldn't set preferred sample rate %g: %s", desiredRate,
        [[error localizedDescription] UTF8String]);
    error = nil;
  }

  if (![session setPreferredIOBufferDuration:ioBufferDuration error:&error]) {
    LOG->Warn(
        "AVAudioSession: couldn't set preferred IO buffer duration %g: %s",
        ioBufferDuration, [[error localizedDescription] UTF8String]);
    error = nil;
  }

  if (![session setActive:YES error:&error]) {
    LOG->Warn(
        "AVAudioSession: couldn't activate session: %s",
        [[error localizedDescription] UTF8String]);
    error = nil;
    /* Even if activation reports failure, fall through and report whatever rate
     * the session exposes; the AU may still come up. */
  }

  Float64 actualRate = [session sampleRate];
  LOG->Info(
      "AVAudioSession active: sampleRate=%g, IOBufferDuration=%g, outputLatency=%g",
      actualRate, [session IOBufferDuration], [session outputLatency]);
  return actualRate;
}
#endif

std::string RageSoundDriver_AU::Init() {
  AudioComponentDescription desc;

#if defined(TVOS)
  /* Configure AVAudioSession before touching the AudioUnit. We request the
   * user's preferred rate if one is pinned (SoundPreferredSampleRate != 0),
   * otherwise we let the hardware keep its native rate (request 0). The
   * returned actualRate is the hardware rate we will run the driver at, so the
   * AU input format matches the hardware and no realtime SRC is needed. */
  Float64 requestedRate = double(int(PREFSMAN->m_iSoundPreferredSampleRate));
  /* ~10 ms IO buffer: low latency without starving a fanless box. The OS will
   * clamp this to a supported value. */
  m_HardwareSampleRate = ConfigureAudioSession(requestedRate, 0.010);
#endif

  desc.componentType = kAudioUnitType_Output;
#if defined(TVOS)
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
  desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  desc.componentFlags = 0;
  desc.componentFlagsMask = 0;

  AudioComponent comp = AudioComponentFindNext(NULL, &desc);
  // Component comp = FindNextComponent( NULL, &desc );

  if (comp == nullptr) {
    return "Failed to find the default output unit.";
  }

  OSStatus error = AudioComponentInstanceNew(comp, &m_OutputUnit);

  if (error != noErr || m_OutputUnit == nullptr) {
    return ssprintf("Could not open the default output unit: %s", FormatOSError(error));
  }

  // Set up a callback function to generate output to the output unit
  AURenderCallbackStruct input;
  input.inputProc = Render;
  input.inputProcRefCon = this;

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input,
      sizeof(input));
  if (error != noErr) {
    return ssprintf("Failed to set render callback: %s", FormatOSError(error));
  }

  AudioStreamBasicDescription streamFormat;

  streamFormat.mSampleRate = PREFSMAN->m_iSoundPreferredSampleRate;
#if defined(TVOS)
  /* Prefer the hardware's actual rate reported by AVAudioSession (48 kHz on
   * Apple TV). Running the AU input at the hardware rate means RemoteIO does no
   * realtime sample-rate conversion. Only override when the user hasn't pinned
   * a specific rate via SoundPreferredSampleRate (i.e. it's 0/unset). */
  if (PREFSMAN->m_iSoundPreferredSampleRate <= 0 && m_HardwareSampleRate > 0.0) {
    streamFormat.mSampleRate = m_HardwareSampleRate;
  }
#endif
  streamFormat.mFormatID = kAudioFormatLinearPCM;
  streamFormat.mFormatFlags = kFormatFlags;
  streamFormat.mBytesPerPacket = kBytesPerPacket;
  streamFormat.mFramesPerPacket = kFramesPerPacket;
  streamFormat.mBytesPerFrame = kBytesPerFrame;
  streamFormat.mChannelsPerFrame = kChannelsPerFrame;
  streamFormat.mBitsPerChannel = kBitsPerChannel;

  if (streamFormat.mSampleRate <= 0.0) {
    streamFormat.mSampleRate = FALLBACK_SAMPLE_RATE;
  }
  m_iSampleRate = int(streamFormat.mSampleRate);
#if defined(TVOS)
  m_TimeScale = GetHostTimeScale(streamFormat.mSampleRate);
#else
  m_TimeScale = streamFormat.mSampleRate / AudioGetHostClockFrequency();

  // Try to set the hardware sample rate.
  SetSampleRate(m_OutputUnit, streamFormat.mSampleRate);
#endif

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat,
      sizeof(AudioStreamBasicDescription));
  if (error != noErr) {
    return ssprintf("Failed to set AU stream format: %s", FormatOSError(error));
  }
  UInt32 renderQuality = kRenderQuality_Max;

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &renderQuality,
      sizeof(renderQuality));
  if (error != noErr) {
    LOG->Warn("Failed to set the maximum render quality: %s", FormatOSError(error));
  }

  // Initialize the AU.
  if ((error = AudioUnitInitialize(m_OutputUnit))) {
    return ssprintf("Could not initialize the AudioUnit: %s", FormatOSError(error));
  }

  StartDecodeThread();

  if ((error = AudioOutputUnitStart(m_OutputUnit))) {
    return ssprintf("Could not start the AudioUnit: %s", FormatOSError(error));
  }
  m_bStarted = true;
  return std::string();
}

RageSoundDriver_AU::~RageSoundDriver_AU() {
  if (!m_OutputUnit) {
    return;
  }
  if (m_bStarted) {
    m_bDone = true;
    m_Semaphore.Wait();
  }
  AudioUnitUninitialize(m_OutputUnit);
  AudioComponentInstanceDispose(m_OutputUnit);
  delete m_pIOThread;
  delete m_pNotificationThread;
}

int64_t RageSoundDriver_AU::GetPosition() const {
#if defined(TVOS)
  return int64_t(m_TimeScale * mach_absolute_time());
#else
  return int64_t(m_TimeScale * AudioGetCurrentHostTime());
#endif
}

void RageSoundDriver_AU::SetupDecodingThread() {
  /* Increase the scheduling precedence of the decoder thread. */
  const std::string sError = SetThreadPrecedence(0.75f);
  if (!sError.empty()) {
    LOG->Warn("Could not set precedence of the decoding thread: %s", sError.c_str());
  }
}

float RageSoundDriver_AU::GetPlayLatency() const {
#if defined(TVOS)
  Float64 outputLatency = 0;
  UInt32 size = sizeof(outputLatency);
  OSStatus error = AudioUnitGetProperty(
      m_OutputUnit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
      &outputLatency, &size);
  if (error != noErr) {
    LOG->Warn("Couldn't get AU latency: %s", FormatOSError(error));
    return 0.0f;
  }
  return float(outputLatency);
#else
  OSStatus error;
  UInt32 bufferSize;
  AudioDeviceID OutputDevice;
  UInt32 size = sizeof(AudioDeviceID);
  Float64 sampleRate;

  if ((error = AudioUnitGetProperty(
           m_OutputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
           &OutputDevice, &size))) {
    LOG->Warn("No output device: %s", FormatOSError(error));
    return 0.0f;
  }

  AudioObjectPropertyAddress RateAddr = {
      kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(Float64);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &RateAddr, 0, nullptr, &size, &sampleRate))) {
    LOG->Warn("Couldn't get the device sample rate: %s", FormatOSError(error));
    return 0.0f;
  }

  AudioObjectPropertyAddress BufferAddr = {
      kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(UInt32);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &BufferAddr, 0, nullptr, &size, &bufferSize))) {
    LOG->Warn("Couldn't determine buffer size: %s", FormatOSError(error));
    bufferSize = 0;
  }

  UInt32 frames;

  AudioObjectPropertyAddress LatencyAddr = {
      kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(UInt32);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &LatencyAddr, 0, nullptr, &size, &frames))) {
    LOG->Warn("Couldn't get device latency: %s", FormatOSError(error));
    frames = 0;
  }

  AudioObjectPropertyAddress SafetyAddr = {
      kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  bufferSize += frames;
  size = sizeof(UInt32);
  if ((error = AudioObjectGetPropertyData(OutputDevice, &SafetyAddr, 0, nullptr, &size, &frames))) {
    LOG->Warn("Couldn't get device safety offset: %s", FormatOSError(error));
    frames = 0;
  }
  bufferSize += frames;
  size = sizeof(UInt32);

  do {
    AudioObjectPropertyAddress StreamsAddr = {
        kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementWildcard};

    if ((error = AudioObjectGetPropertyDataSize(OutputDevice, &StreamsAddr, 0, nullptr, &size))) {
      LOG->Warn("Device has no streams: %s", FormatOSError(error));
      break;
    }
    int num = size / sizeof(AudioStreamID);
    if (num == 0) {
      LOG->Warn("Device has no streams.");
      break;
    }
    AudioStreamID* streams = new AudioStreamID[num];

    if ((error =
             AudioObjectGetPropertyData(OutputDevice, &StreamsAddr, 0, nullptr, &size, streams))) {
      LOG->Warn("Cannot get device's streams: %s", FormatOSError(error));
      delete[] streams;
      break;
    }

    AudioObjectPropertyAddress LatencyAddr = {
        kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementWildcard};

    if ((error =
             AudioObjectGetPropertyData(streams[0], &LatencyAddr, 0, nullptr, &size, &frames))) {
      LOG->Warn("Stream does not report latency: %s", FormatOSError(error));
      frames = 0;
    }
    delete[] streams;
    bufferSize += frames;
  } while (false);

  return float(bufferSize / sampleRate);
#endif
}

OSStatus RageSoundDriver_AU::Render(
    void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData) {
  RageSoundDriver_AU* This = (RageSoundDriver_AU*)inRefCon;

  if (unlikely(This->m_pIOThread == nullptr)) {
    This->m_pIOThread = new RageThreadRegister("HAL I/O thread");
  }

  AudioBuffer& buf = ioData->mBuffers[0];
#if defined(TVOS)
  int64_t now = int64_t(This->m_TimeScale * mach_absolute_time());
#else
  int64_t now = int64_t(This->m_TimeScale * AudioGetCurrentHostTime());
#endif
  int64_t next = int64_t(This->m_TimeScale * inTimeStamp->mHostTime);

  This->Mix((float*)buf.mData, inNumberFrames, next, now);
  if (unlikely(This->m_bDone)) {
    AudioOutputUnitStop(This->m_OutputUnit);
    This->m_Semaphore.Post();
  }
  return noErr;
}

/*
 * (c) 2004-2007 Steve Checkoway
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
