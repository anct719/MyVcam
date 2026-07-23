#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MyVCAMTransportType) {
    MyVCAMTransportTCP = 0,
    MyVCAMTransportWebSocket,
};

@class MyVCAMWebSocket;

@protocol MyVCAMWebSocketDelegate <NSObject>
- (void)webSocketDidConnect:(MyVCAMWebSocket *)ws;
- (void)webSocketDidDisconnect:(MyVCAMWebSocket *)ws;
- (void)webSocket:(MyVCAMWebSocket *)ws didDecodePixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts;
@end

@interface MyVCAMWebSocket : NSObject

@property (nonatomic, weak) id<MyVCAMWebSocketDelegate> delegate;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic) MyVCAMTransportType transport;

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port;
- (void)connect;
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
