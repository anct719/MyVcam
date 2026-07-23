#import "CameraInjector.h"
#import <os/log.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurface.h>
#import <substrate.h>

static os_log_t gLog;

static CameraInjector *gSharedInjector;

// Hook function pointers
static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef);
static void (*orig_FigCaptureClientSessionMonitor_handleNotification)(id, SEL, id);

#pragma mark - BWNodeOutput hook

static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    CameraInjector *inj = [CameraInjector sharedInstance];
    if (!inj.connected || !inj.hasFrame) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sb);
        return;
    }

    // Only inject if this is a video frame from the camera pipeline
    CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
    if (!fmtDesc) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sb);
        return;
    }
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmtDesc);
    if (mediaType != kCMMediaType_Video) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sb);
        return;
    }

    // Extract timing from original frame
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(sb, 0, &timing);

    // Get our decoded pixel buffer (IOSurface-backed for VT compatibility)
    CVPixelBufferRef ourPB = inj.latestPixelBuffer;
    if (!ourPB) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sb);
        return;
    }

    // Create new CMSampleBuffer from our pixel buffer with original timing
    CMSampleBufferRef newSb = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, ourPB, true, NULL, NULL,
        fmtDesc, &timing, &newSb
    );

    if (status == noErr && newSb) {
        os_log(gLog, "injected frame: pts=%.2f", CMTimeGetSeconds(timing.presentationTimeStamp));
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, newSb);
        CFRelease(newSb);
    } else {
        os_log_error(gLog, "CMSampleBufferCreateForImageBuffer failed: %d", (int)status);
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sb);
    }
}

#pragma mark - FigCaptureClientSessionMonitor hook

static void hook_FigCaptureClientSessionMonitor_handleNotification(id self, SEL _cmd, id notification) {
    CameraInjector *inj = [CameraInjector sharedInstance];
    os_log(gLog, "FigCaptureClientSessionMonitor notification: %@", notification);
    orig_FigCaptureClientSessionMonitor_handleNotification(self, _cmd, notification);
}

#pragma mark - CameraInjector implementation

@interface CameraInjector () {
    CVPixelBufferRef _latestPixelBuffer;
    CMTime _latestPTS;
    BOOL _connected;
    BOOL _hasFrame;
    BOOL _hooksInstalled;
    os_unfair_lock _lock;
}
@end

@implementation CameraInjector

+ (void)initialize {
    if (self == [CameraInjector class]) {
        gLog = os_log_create("com.myvcam.tweak", "injector");
    }
}

+ (CameraInjector *)sharedInstance {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSharedInjector = [[CameraInjector alloc] init];
    });
    return gSharedInjector;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    if (_latestPixelBuffer) {
        CVPixelBufferRelease(_latestPixelBuffer);
    }
}

- (BOOL)connected { return _connected; }
- (BOOL)hasFrame { return _hasFrame; }
- (CVPixelBufferRef)latestPixelBuffer { return _latestPixelBuffer; }

- (void)setConnected:(BOOL)connected {
    _connected = connected;
    if (!connected) {
        os_unfair_lock_lock(&_lock);
        _hasFrame = NO;
        if (_latestPixelBuffer) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
        os_unfair_lock_unlock(&_lock);
    }
}

- (void)setLatestPixelBuffer:(CVPixelBufferRef)pb pts:(CMTime)pts {
    if (!pb) return;
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _latestPixelBuffer;
    _latestPixelBuffer = CVPixelBufferRetain(pb);
    _latestPTS = pts;
    _hasFrame = YES;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

- (void)installHooks {
    if (_hooksInstalled) return;
    _hooksInstalled = YES;

    // Hook BWNodeOutput -emitSampleBuffer:
    Class bwNodeOutput = objc_getClass("BWNodeOutput");
    if (bwNodeOutput) {
        SEL emitSel = sel_registerName("emitSampleBuffer:");
        Method m = class_getInstanceMethod(bwNodeOutput, emitSel);
        if (m) {
            MSHookMessageEx(bwNodeOutput, emitSel,
                (IMP)hook_BWNodeOutput_emitSampleBuffer,
                (IMP *)&orig_BWNodeOutput_emitSampleBuffer);
            os_log(gLog, "hooked BWNodeOutput emitSampleBuffer:");
        } else {
            os_log_error(gLog, "BWNodeOutput emitSampleBuffer: not found");
        }
    } else {
        os_log_error(gLog, "BWNodeOutput class not found");
    }

    // Hook FigCaptureClientSessionMonitor
    Class figMon = objc_getClass("FigCaptureClientSessionMonitor");
    if (figMon) {
        // Try to find the notification handler method
        SEL notifSel = sel_registerName("handleNotification:");
        Method m = class_getInstanceMethod(figMon, notifSel);
        if (m) {
            MSHookMessageEx(figMon, notifSel,
                (IMP)hook_FigCaptureClientSessionMonitor_handleNotification,
                (IMP *)&orig_FigCaptureClientSessionMonitor_handleNotification);
            os_log(gLog, "hooked FigCaptureClientSessionMonitor handleNotification:");
        } else {
            os_log(gLog, "FigCaptureClientSessionMonitor handleNotification: not found (trying clientAuditTokenDidChange:)");
            // Fallback: try another selector
            notifSel = sel_registerName("clientAuditTokenDidChange:");
            m = class_getInstanceMethod(figMon, notifSel);
            if (m) {
                MSHookMessageEx(figMon, notifSel,
                    (IMP)hook_FigCaptureClientSessionMonitor_handleNotification,
                    (IMP *)&orig_FigCaptureClientSessionMonitor_handleNotification);
                os_log(gLog, "hooked FigCaptureClientSessionMonitor clientAuditTokenDidChange:");
            } else {
                os_log_error(gLog, "could not find hookable method on FigCaptureClientSessionMonitor");
            }
        }
    } else {
        os_log_error(gLog, "FigCaptureClientSessionMonitor class not found");
    }

    // Future: add photo capture hooks
    // _addAuxImagesIfNeededForEncodingScheme (FigCaptureStillImageSinkPipeline)
    // _generatePreviewForSampleBuffer (FigCaptureStillImageSinkPipeline)
}

@end
