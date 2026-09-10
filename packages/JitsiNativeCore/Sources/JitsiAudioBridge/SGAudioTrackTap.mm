#import "SGAudioTrackTap.h"
#import <WebRTC/RTCAudioTrack.h>
#include "api/media_stream_interface.h"
#include <array>
#include <atomic>
#include <cstring>
#include <mach/mach_time.h>
#include <memory>

// This is WebRTC's own Objective-C++ accessor, absent from the distributed
// public headers. Its declaration and C++ headers are pinned to M124; never
// update the binary independently of this bridge and its loopback test.
@interface RTCAudioTrack (SangamNativeAudio)
@property(nonatomic, readonly) rtc::scoped_refptr<webrtc::AudioTrackInterface> nativeAudioTrack;
@end

namespace {
constexpr size_t kCapacity = 64;
constexpr size_t kMaxSamples = 4096;
struct Frame {
  std::array<int16_t, kMaxSamples> samples;
  int rate;
  size_t channels, frames;
  double time;
  uint64_t sequence;
};

class AudioSink final : public webrtc::AudioTrackSinkInterface {
 public:
  AudioSink() {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    secondsPerTick_ = double(info.numer) / info.denom / 1e9;
  }
  void OnData(const void *data, int bits, int rate, size_t channels,
              size_t frames) override {
    const auto sequence = ++sequence_;
    if (bits != 16 || rate <= 0 || channels == 0 || frames == 0 ||
        channels > 2 || frames > kMaxSamples / channels) return;
    const auto write = write_.load(std::memory_order_relaxed);
    if (write - read_.load(std::memory_order_acquire) >= kCapacity) return;
    auto &frame = ring_[write % kCapacity];
    std::memcpy(frame.samples.data(), data, channels * frames * sizeof(int16_t));
    frame.rate = rate; frame.channels = channels; frame.frames = frames;
    frame.time = mach_absolute_time() * secondsPerTick_ - double(frames) / rate;
    frame.sequence = sequence;
    write_.store(write + 1, std::memory_order_release);
  }
  bool pop(Frame &frame) {
    const auto read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire)) return false;
    frame = ring_[read % kCapacity];
    read_.store(read + 1, std::memory_order_release);
    return true;
  }
 private:
  std::array<Frame, kCapacity> ring_;
  std::atomic<uint64_t> read_{0}, write_{0};
  uint64_t sequence_ = 0;
  double secondsPerTick_;
};
}

@implementation SGAudioFrame
- (instancetype)initWithFrame:(const Frame &)frame discontinuity:(BOOL)gap {
  if ((self = [super init])) {
    _samples = [NSData dataWithBytes:frame.samples.data()
                            length:frame.channels * frame.frames * sizeof(int16_t)];
    _sampleRate = frame.rate; _channels = frame.channels; _frames = frame.frames;
    _startTime = frame.time; _discontinuity = gap;
  }
  return self;
}
@end

@implementation SGAudioTrackTap {
  RTCAudioTrack *_track;
  rtc::scoped_refptr<webrtc::AudioTrackInterface> _nativeTrack;
  std::unique_ptr<AudioSink> _sink;
  uint64_t _lastSequence;
}
- (instancetype)initWithTrack:(RTCAudioTrack *)track {
  if (![track respondsToSelector:@selector(nativeAudioTrack)]) return nil;
  if ((self = [super init])) {
    _track = track;
    _nativeTrack = track.nativeAudioTrack;
    if (!_nativeTrack || !_nativeTrack->GetSource()->remote()) return nil;
    _sink = std::make_unique<AudioSink>();
    // The returned native track is WebRTC's signaling-thread proxy.
    _nativeTrack->AddSink(_sink.get());
  }
  return self;
}
- (NSArray<SGAudioFrame *> *)drain {
  NSMutableArray<SGAudioFrame *> *result = [NSMutableArray array];
  if (!_sink) return result;
  Frame frame;
  while (_sink->pop(frame)) {
    [result addObject:[[SGAudioFrame alloc] initWithFrame:frame
                                        discontinuity:frame.sequence != _lastSequence + 1]];
    _lastSequence = frame.sequence;
  }
  return result;
}
- (void)stop {
  if (_sink) {
    _nativeTrack->RemoveSink(_sink.get());
    _sink.reset();
  }
  _nativeTrack = nullptr;
  _track = nil;
}
- (void)dealloc { [self stop]; }
@end
