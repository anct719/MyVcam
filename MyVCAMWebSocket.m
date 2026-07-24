#import "MyVCAMWebSocket.h"
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <os/log.h>
#import <os/lock.h>
#import <sys/socket.h>
#import <unistd.h>

#define MVCM_MAGIC "MVCM"
#define MSG_CONFIG 1
#define MSG_FRAME  2
#define FLAG_KEYFRAME (1 << 0)

static os_log_t gLog;

#pragma pack(push, 1)
typedef struct {
    char     magic[4];
    uint32_t payload_len;
    uint8_t  type;
    uint8_t  flags;
    uint16_t reserved;
    uint32_t seq;
    uint32_t timestamp;
} MVCMHeader;
#pragma pack(pop)

@interface MyVCAMWebSocket () <NSURLSessionDelegate, NSURLSessionWebSocketDelegate> {
    NSString         *_host;
    uint16_t         _port;
    dispatch_queue_t  _socketQueue;
    BOOL              _running;
    BOOL              _connected;

    // TCP mode
    int               _sockfd;
    int               _reconnectDelay;

    // WebSocket mode
    NSURLSessionWebSocketTask *_wsTask;
    NSURLSession             *_wsSession;

    // Decoder
    VTDecompressionSessionRef _decompressionSession;
    CMVideoFormatDescriptionRef _formatDesc;
    NSData            *_pendingConfig;
    os_unfair_lock     _sessionLock;
}
- (void)closeSocket;
- (void)deallocSession;
- (BOOL)setupDecompressionSessionWithExtradata:(NSData *)extradata;
- (void)handleConfig:(NSData *)payload;
- (void)handleFrame:(NSData *)payload keyframe:(BOOL)keyframe;
- (void)scheduleReconnect;
- (void)connectTCP;
- (void)connectWebSocket;
- (void)readAvailableData;
- (void)receiveNextWebSocketMessage;

// WebSocket data parsing - auto-detect config vs frame
- (BOOL)tryParseAsConfig:(NSData *)data;
- (BOOL)containsSPS:(NSData *)data;
@end

static void decodeCallback(void *outputRefCon, void *sourceRefCon, OSStatus status,
                           VTDecodeInfoFlags infoFlags,
                           CVImageBufferRef pixelBuffer, CMTime pts, CMTime duration)
{
    MyVCAMWebSocket *self = (__bridge MyVCAMWebSocket *)outputRefCon;
    if (status != noErr || !pixelBuffer) return;
    CVPixelBufferRef pb = CVPixelBufferRetain(pixelBuffer);
    id<MyVCAMWebSocketDelegate> cb = self.delegate;
    if (cb) {
        [cb webSocket:self didDecodePixelBuffer:pb pts:pts];
    }
    CVPixelBufferRelease(pb);
}

@implementation MyVCAMWebSocket

+ (void)initialize {
    if (self == [MyVCAMWebSocket class]) {
        gLog = os_log_create("com.myvcam.tweak", "ws");
    }
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _sockfd = -1;
        _reconnectDelay = 2;
        _transport = MyVCAMTransportTCP;
        _sessionLock = OS_UNFAIR_LOCK_INIT;
        _socketQueue = dispatch_queue_create("com.myvcam.net", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isConnected { return _connected; }

- (void)connect {
    if (_running) return;
    _running = YES;
    _reconnectDelay = 2;
    dispatch_async(_socketQueue, ^{
        if (self->_transport == MyVCAMTransportWebSocket) {
            [self connectWebSocket];
        } else {
            [self connectTCP];
        }
    });
}

- (void)disconnect {
    _running = NO;
    dispatch_async(_socketQueue, ^{
        [self closeSocket];
        [self deallocSession];
    });
}

- (void)dealloc {
    [self disconnect];
}

#pragma mark - TCP Mode

- (void)connectTCP {
    if (_connected) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(gLog, "socket() failed: %d", errno);
        [self scheduleReconnect];
        return;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = inet_addr([_host UTF8String]);
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int ret = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (ret < 0) {
        os_log_error(gLog, "connect(%s:%d) failed: %d", _host.UTF8String, _port, errno);
        close(fd);
        [self scheduleReconnect];
        return;
    }
    _sockfd = fd;
    _connected = YES;
    _reconnectDelay = 2;
    os_log(gLog, "TCP connected to %s:%d", _host.UTF8String, _port);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webSocketDidConnect:self];
    });
    while (_running && _connected) {
        [self readAvailableData];
    }
}

- (void)closeSocket {
    if (_wsTask) {
        [_wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        _wsTask = nil;
    }
    if (_wsSession) {
        [_wsSession invalidateAndCancel];
        _wsSession = nil;
    }
    if (_sockfd >= 0) {
        close(_sockfd);
        _sockfd = -1;
    }
    _connected = NO;
}

- (void)readAvailableData {
    if (!_connected || _sockfd < 0) return;
    MVCMHeader hdr;
    ssize_t n = read(_sockfd, &hdr, sizeof(hdr));
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        os_log_error(gLog, "read header failed: %d", (int)n);
        [self onDisconnected];
        return;
    }
    if (memcmp(hdr.magic, MVCM_MAGIC, 4) != 0) {
        os_log_error(gLog, "bad MVCM magic, switching to WebSocket mode");
        _transport = MyVCAMTransportWebSocket;
        [self closeSocket];
        [self scheduleReconnect];
        return;
    }
    uint32_t payloadLen = ntohl(hdr.payload_len);
    if (payloadLen > 4 * 1024 * 1024) {
        os_log_error(gLog, "payload too large: %u", payloadLen);
        [self onDisconnected];
        return;
    }
    NSMutableData *payload = [NSMutableData dataWithLength:payloadLen];
    if (payloadLen > 0) {
        uint8_t *buf = (uint8_t *)[payload mutableBytes];
        size_t remaining = payloadLen;
        while (remaining > 0) {
            n = read(_sockfd, buf + (payloadLen - remaining), remaining);
            if (n <= 0) {
                os_log_error(gLog, "read payload failed: %d", (int)n);
                [self onDisconnected];
                return;
            }
            remaining -= n;
        }
    }
    if (hdr.type == MSG_CONFIG) {
        [self handleConfig:payload];
    } else if (hdr.type == MSG_FRAME) {
        [self handleFrame:payload keyframe:(hdr.flags & FLAG_KEYFRAME)];
    }
}

#pragma mark - WebSocket Mode

- (void)connectWebSocket {
    if (_connected) return;
    NSString *urlStr = [NSString stringWithFormat:@"ws://%@:%d", _host, _port];
    NSURL *url = [NSURL URLWithString:urlStr];
    os_log(gLog, "connecting WebSocket to %@", urlStr);
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.waitsForConnectivity = YES;
    cfg.timeoutIntervalForResource = 15;
    _wsSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _wsTask = [_wsSession webSocketTaskWithURL:url];
    [_wsTask resume];
    // Connection result comes via delegate callbacks
}

- (void)receiveNextWebSocketMessage {
    if (!_wsTask) return;
    __weak typeof(self) weak = self;
    [_wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        MyVCAMWebSocket *strong = weak;
        if (!strong) return;
        if (err) {
            os_log_error(gLog, "WebSocket recv error: %@", err);
            [strong onDisconnected];
            return;
        }
        if (msg.type == NSURLSessionWebSocketMessageTypeBinary) {
            NSData *data = msg.data;
            if (data.length > 0) {
                // Auto-detect: if it contains SPS, treat as config
                if ([strong tryParseAsConfig:data]) {
                    [strong handleConfig:data];
                } else {
                    [strong handleFrame:data keyframe:NO];
                }
            }
        }
        [strong receiveNextWebSocketMessage];
    }];
}

- (BOOL)tryParseAsConfig:(NSData *)data {
    if (data.length < 8) return NO;
    // Check for avcC extradata format (starts with version byte 0x01)
    const uint8_t *bytes = data.bytes;
    if (bytes[0] == 1 && data.length > 7) {
        return YES;
    }
    // Check for SPS NAL (Annex-B start code + NAL type 7)
    if ([self containsSPS:data]) {
        return YES;
    }
    return NO;
}

- (BOOL)containsSPS:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    for (NSUInteger i = 2; i + 1 < len; i++) {
        if (bytes[i] == 0 && bytes[i+1] == 0) {
            if (i + 2 < len && bytes[i+2] == 1) {
                // 0x000001 start code
                if (i + 3 < len && (bytes[i+3] & 0x1F) == 7) return YES;
            }
            if (i + 3 < len && bytes[i+2] == 0 && bytes[i+3] == 1) {
                // 0x00000001 start code
                if (i + 4 < len && (bytes[i+4] & 0x1F) == 7) return YES;
            }
        }
    }
    // Also check AVCC format: first 4 bytes are NAL length, then NAL type
    if (len > 8) {
        // Try to parse first NAL unit
        uint32_t nalLen = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
        if (nalLen > 0 && nalLen + 4 <= len) {
            uint8_t nalType = bytes[4] & 0x1F;
            if (nalType == 7) return YES;
        }
    }
    return NO;
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    os_log(gLog, "WebSocket opened (protocol=%@)", protocol ?: @"none");
    _connected = YES;
    _reconnectDelay = 2;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webSocketDidConnect:self];
    });
    [self receiveNextWebSocketMessage];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    os_log(gLog, "WebSocket closed: code=%ld reason=%@", (long)closeCode,
           reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"none");
    [self onDisconnected];

}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        os_log_error(gLog, "WebSocket task completed with error: %@", error);
    }
}

#pragma mark - Common

- (void)onDisconnected {
    [self closeSocket];
    [self deallocSession];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate webSocketDidDisconnect:self];
    });
    [self scheduleReconnect];
}

#pragma mark - Decoder

- (void)deallocSession {
    os_unfair_lock_lock(&_sessionLock);
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    _pendingConfig = nil;
    os_unfair_lock_unlock(&_sessionLock);
}

- (BOOL)setupDecompressionSessionWithExtradata:(NSData *)extradata {
    if (extradata.length < 7) return NO;
    const uint8_t *bytes = extradata.bytes;
    size_t pos = 5;
    uint8_t numSPS = bytes[pos] & 0x1F;
    pos += 1;
    if (numSPS == 0) return NO;
    uint16_t spsLen = CFSwapInt16BigToHost(*(const uint16_t *)(bytes + pos));
    pos += 2;
    if (pos + spsLen > extradata.length) return NO;
    const uint8_t *sps = bytes + pos;
    pos += spsLen;
    if (pos >= extradata.length) return NO;
    uint8_t numPPS = bytes[pos];
    pos += 1;
    if (numPPS == 0) return NO;
    uint16_t ppsLen = CFSwapInt16BigToHost(*(const uint16_t *)(bytes + pos));
    pos += 2;
    if (pos + ppsLen > extradata.length) return NO;
    const uint8_t *pps = bytes + pos;

    const uint8_t *spsArray[1] = { sps };
    const uint8_t *ppsArray[1] = { pps };
    size_t spsSizes[1] = { spsLen };
    size_t ppsSizes[1] = { ppsLen };

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 1, spsArray, spsSizes, 1, ppsArray, ppsSizes, 4, &fmtDesc);
    if (status != noErr) {
        os_log_error(gLog, "CMVideoFormatDescriptionCreate failed: %d", (int)status);
        return NO;
    }

    NSDictionary *destAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = decodeCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };

    VTDecompressionSessionRef session = NULL;
    status = VTDecompressionSessionCreate(kCFAllocatorDefault, fmtDesc, NULL,
                                          (__bridge CFDictionaryRef)destAttrs, &cb, &session);
    if (status != noErr || !session) {
        os_log_error(gLog, "VTDecompressionSessionCreate failed: %d", (int)status);
        CFRelease(fmtDesc);
        return NO;
    }

    os_unfair_lock_lock(&_sessionLock);
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
    }
    if (_formatDesc) CFRelease(_formatDesc);
    _decompressionSession = session;
    _formatDesc = fmtDesc;
    os_unfair_lock_unlock(&_sessionLock);

    os_log(gLog, "VTDecompressionSession ready: %zux%zu",
           CMVideoFormatDescriptionGetDimensions(fmtDesc).width,
           CMVideoFormatDescriptionGetDimensions(fmtDesc).height);
    return YES;
}

#pragma mark - Handlers

- (void)handleConfig:(NSData *)payload {
    if (payload.length < 7) return;
    os_log(gLog, "config received: %zu bytes", payload.length);
    [self setupDecompressionSessionWithExtradata:payload];
}

- (void)handleFrame:(NSData *)payload keyframe:(BOOL)keyframe {
    if (payload.length < 4) return;

    // If payload is Annex-B, convert to AVCC
    BOOL isAnnexB = NO;
    if (payload.length >= 4) {
        const uint8_t *b = payload.bytes;
        if ((b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1) ||
            (b[0] == 0 && b[1] == 0 && b[2] == 1)) {
            isAnnexB = YES;
        }
    }

    NSData *avccData = payload;
    if (isAnnexB) {
        avccData = [self annexbToAvcc:payload];
    }

    os_unfair_lock_lock(&_sessionLock);
    VTDecompressionSessionRef session = _decompressionSession;
    CMVideoFormatDescriptionRef fmtDesc = _formatDesc;
    if (session) CFRetain(session);
    if (fmtDesc) CFRetain(fmtDesc);
    os_unfair_lock_unlock(&_sessionLock);
    if (!session || !fmtDesc) return;

    CMBlockBufferRef blockBuf = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, (void *)avccData.bytes, avccData.length,
        kCFAllocatorNull, NULL, 0, avccData.length, 0, &blockBuf);
    if (status != noErr) {
        CFRelease(session);
        if (fmtDesc) CFRelease(fmtDesc);
        return;
    }

    size_t sampleSizes[1] = { avccData.length };
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(0, 1000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuf = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuf, fmtDesc,
                                       1, 1, &timing, 1, sampleSizes, &sampleBuf);
    CFRelease(blockBuf);
    if (status != noErr || !sampleBuf) {
        CFRelease(session);
        if (fmtDesc) CFRelease(fmtDesc);
        return;
    }

    if (keyframe) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuf, YES);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        }
    }

    VTDecodeInfoFlags outFlags = 0;
    status = VTDecompressionSessionDecodeFrame(session, sampleBuf, 0, NULL, &outFlags);
    if (status != noErr) {
        os_log_error(gLog, "VTDecodeFrame failed: %d", (int)status);
    }
    CFRelease(sampleBuf);
    CFRelease(session);
    if (fmtDesc) CFRelease(fmtDesc);
}

- (NSData *)annexbToAvcc:(NSData *)annexB {
    NSMutableData *avcc = [NSMutableData data];
    const uint8_t *bytes = annexB.bytes;
    NSUInteger len = annexB.length;
    NSUInteger i = 0;
    while (i < len) {
        // Find start code
        if (i + 3 > len) break;
        NSUInteger startCodeLen = 0;
        if (bytes[i] == 0 && bytes[i+1] == 0) {
            if (i + 3 < len && bytes[i+2] == 0 && bytes[i+3] == 1) {
                startCodeLen = 4;
            } else if (bytes[i+2] == 1) {
                startCodeLen = 3;
            }
        }
        if (startCodeLen == 0) { i++; continue; }
        NSUInteger nalStart = i + startCodeLen;
        // Find next start code
        NSUInteger nextStart = nalStart;
        while (nextStart + 2 < len) {
            if (nextStart + 3 < len && bytes[nextStart] == 0 && bytes[nextStart+1] == 0 && bytes[nextStart+2] == 0 && bytes[nextStart+3] == 1) break;
            if (bytes[nextStart] == 0 && bytes[nextStart+1] == 0 && bytes[nextStart+2] == 1) break;
            nextStart++;
        }
        NSUInteger nalLen = nextStart - nalStart;
        if (nalLen > 0) {
            uint32_t lenBE = (uint32_t)nalLen;
            [avcc appendBytes:&lenBE length:4];
            [avcc appendBytes:bytes + nalStart length:nalLen];
        }
        i = nextStart;
    }
    return avcc;
}

#pragma mark - Reconnect

- (void)scheduleReconnect {
    if (!_running) return;
    if (_reconnectDelay > 30) _reconnectDelay = 30;
    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, _reconnectDelay * NSEC_PER_SEC);
    dispatch_after(when, _socketQueue, ^{
        if (!self->_running) return;
        os_log(gLog, "reconnecting in %ds...", self->_reconnectDelay);
        self->_reconnectDelay = MIN(self->_reconnectDelay * 2, 30);
        if (self->_transport == MyVCAMTransportWebSocket) {
            [self connectWebSocket];
        } else {
            [self connectTCP];
        }
    });
}

@end
