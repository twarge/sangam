#import <Foundation/Foundation.h>
@class RTCAudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface SGAudioFrame : NSObject
@property(nonatomic, readonly) NSData *samples;
@property(nonatomic, readonly) NSInteger sampleRate;
@property(nonatomic, readonly) NSInteger channels;
@property(nonatomic, readonly) NSInteger frames;
@property(nonatomic, readonly) NSTimeInterval startTime;
@property(nonatomic, readonly) BOOL discontinuity;
@end

/// A bounded, nonblocking tap of one remote WebRTC track, before playback mixing.
/// Local WebRTC tracks do not implement audio sinks.
@interface SGAudioTrackTap : NSObject
- (nullable instancetype)initWithTrack:(RTCAudioTrack *)track;
- (NSArray<SGAudioFrame *> *)drain;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
