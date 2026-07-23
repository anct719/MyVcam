#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SpringBoardUI : NSObject

@property (class, readonly) SpringBoardUI *sharedInstance;

- (void)show;
- (void)hide;

- (void)showConnected;
- (void)showDisconnected;
- (void)showReconnecting;
- (void)showStatus:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
