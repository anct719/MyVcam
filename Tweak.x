#import "MyVCAMWebSocket.h"
#import "CameraInjector.h"
#import "SpringBoardUI.h"
#import <os/log.h>
#import <notify.h>
#import <unistd.h>

static os_log_t gLog;

#define PREFS_SUITE @"com.myvcam.tweak"
#define NOTIFY_CONNECTED     "com.myvcam.connected"
#define NOTIFY_DISCONNECTED  "com.myvcam.disconnected"
#define NOTIFY_RECONNECT     "com.myvcam.reconnect"
#define NOTIFY_DISCONNECT    "com.myvcam.disconnect"

#pragma mark - Mediaserverd

@interface MediaserverdController : NSObject <MyVCAMWebSocketDelegate>
@property (nonatomic, strong) MyVCAMWebSocket *ws;
@property (nonatomic, strong) CameraInjector *injector;
- (void)start;
- (void)stop;
- (void)reconnect;
@end

@implementation MediaserverdController

+ (instancetype)sharedController {
    static MediaserverdController *ctrl;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctrl = [[MediaserverdController alloc] init];
    });
    return ctrl;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _injector = [CameraInjector sharedInstance];
        [_injector installHooks];
    }
    return self;
}

- (void)start {
    os_log(gLog, "mediaserverd controller started");
    int t1, t2;
    notify_register_dispatch(NOTIFY_RECONNECT, &t1, dispatch_get_main_queue(), ^(int t) {
        [[MediaserverdController sharedController] reconnect];
    });
    notify_register_dispatch(NOTIFY_DISCONNECT, &t2, dispatch_get_main_queue(), ^(int t) {
        [[MediaserverdController sharedController] stop];
    });
    [self reconnect];
}

- (void)reconnect {
    [self stop];
    NSUserDefaults *def = [[NSUserDefaults alloc] initWithSuiteName:PREFS_SUITE];
    NSString *host = [def stringForKey:@"serverHost"];
    NSInteger port = [def integerForKey:@"serverPort"];
    NSInteger transport = [def integerForKey:@"transport"];
    if (port <= 0) port = 8765;

    if (!host || host.length == 0) {
        os_log(gLog, "no server configured");
        notify_post(NOTIFY_DISCONNECTED);
        return;
    }

    os_log(gLog, "connecting to %@:%ld (%@)", host, (long)port,
           transport == 1 ? @"WebSocket" : @"TCP");
    _ws = [[MyVCAMWebSocket alloc] initWithHost:host port:(uint16_t)port];
    _ws.transport = (MyVCAMTransportType)transport;
    _ws.delegate = self;
    [_ws connect];
}

- (void)stop {
    if (_ws) { [_ws disconnect]; _ws = nil; }
    [_injector setConnected:NO];
    notify_post(NOTIFY_DISCONNECTED);
}

- (void)webSocketDidConnect:(MyVCAMWebSocket *)ws {
    os_log(gLog, "connected");
    [_injector setConnected:YES];
    notify_post(NOTIFY_CONNECTED);
}

- (void)webSocketDidDisconnect:(MyVCAMWebSocket *)ws {
    os_log(gLog, "disconnected");
    [_injector setConnected:NO];
    notify_post(NOTIFY_DISCONNECTED);
}

- (void)webSocket:(MyVCAMWebSocket *)ws didDecodePixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts {
    [_injector setLatestPixelBuffer:pb pts:pts];
}

@end

#pragma mark - SpringBoard

@interface SpringBoardController : NSObject
@property (nonatomic, strong) SpringBoardUI *ui;
@property (nonatomic) BOOL observing;
- (void)start;
@end

@implementation SpringBoardController

+ (instancetype)sharedController {
    static SpringBoardController *ctrl;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctrl = [[SpringBoardController alloc] init]; });
    return ctrl;
}

- (void)start {
    os_log(gLog, "SpringBoard controller started");
    _ui = [SpringBoardUI sharedInstance];
    [_ui show];
    [_ui showDisconnected];
    if (_observing) return;
    _observing = YES;
    int t1, t2;
    notify_register_dispatch(NOTIFY_CONNECTED, &t1, dispatch_get_main_queue(), ^(int t) {
        [[SpringBoardUI sharedInstance] showConnected];
    });
    notify_register_dispatch(NOTIFY_DISCONNECTED, &t2, dispatch_get_main_queue(), ^(int t) {
        [[SpringBoardUI sharedInstance] showDisconnected];
    });
}

@end

#pragma mark - Entry

%ctor {
    gLog = os_log_create("com.myvcam.tweak", "main");
    NSString *proc = [[NSProcessInfo processInfo] processName];
    os_log(gLog, "loaded into: %{public}@ (pid=%d)", proc, getpid());
    if ([proc isEqualToString:@"mediaserverd"]) {
        [[MediaserverdController sharedController] start];
    } else if ([proc isEqualToString:@"SpringBoard"]) {
        [[SpringBoardController sharedController] start];
    }
}
