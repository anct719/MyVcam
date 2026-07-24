#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface CameraInjector : NSObject

@property (class, readonly) CameraInjector *sharedInstance;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) BOOL hasFrame;
@property (nonatomic, readonly, nullable) CVPixelBufferRef latestPixelBuffer;

- (void)setLatestPixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts;
- (void)setConnected:(BOOL)connected;
- (void)installHooks;

@end

NS_ASSUME_NONNULL_END
