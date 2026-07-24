#import "SpringBoardUI.h"
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <notify.h>

#define PREFS_SUITE @"com.myvcam.tweak"
#define NOTIFY_RECONNECT "com.myvcam.reconnect"
#define NOTIFY_DISCONNECT "com.myvcam.disconnect"

static os_log_t gLog;

@interface SpringBoardUI () <UITextFieldDelegate> {
    UIWindow *_badgeWindow;
    UIWindow *_panelWindow;
    UILabel *_badgeLabel;
    UIView *_panel;
    UITextField *_ipField;
    UITextField *_portField;
    UISegmentedControl *_protoSwitch;
    UIButton *_connectBtn;
    UILabel *_statusLabel;
    BOOL _connected;
    BOOL _panelVisible;
    BOOL _visible;
}
- (void)saveConfig;
- (void)dismissPanel;
- (void)togglePanel;
- (NSString *)savedHost;
- (uint16_t)savedPort;
- (NSInteger)savedTransport;
@end

@implementation SpringBoardUI

+ (void)initialize {
    if (self == [SpringBoardUI class]) {
        gLog = os_log_create("com.myvcam.tweak", "sbui");
    }
}

+ (SpringBoardUI *)sharedInstance {
    static dispatch_once_t once;
    static SpringBoardUI *instance;
    dispatch_once(&once, ^{ instance = [[SpringBoardUI alloc] init]; });
    return instance;
}

- (instancetype)init {
    return self;
}

#pragma mark - Show/Hide

- (void)show {
    if (_visible) return;
    _visible = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self buildBadge]; });
}

- (void)hide {
    _visible = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        _badgeWindow.hidden = YES; _badgeWindow = nil;
        _panelWindow.hidden = YES; _panelWindow = nil;
    });
}

- (NSString *)savedHost {
    return [[[NSUserDefaults alloc] initWithSuiteName:PREFS_SUITE] stringForKey:@"serverHost"] ?: @"";
}

- (uint16_t)savedPort {
    return (uint16_t)[[[NSUserDefaults alloc] initWithSuiteName:PREFS_SUITE] integerForKey:@"serverPort"];
}

- (NSInteger)savedTransport {
    return [[[NSUserDefaults alloc] initWithSuiteName:PREFS_SUITE] integerForKey:@"transport"];
}

- (void)saveConfig {
    NSUserDefaults *def = [[NSUserDefaults alloc] initWithSuiteName:PREFS_SUITE];
    [def setObject:_ipField.text ?: @"" forKey:@"serverHost"];
    [def setInteger:[_portField.text integerValue] ?: 8765 forKey:@"serverPort"];
    [def setInteger:_protoSwitch.selectedSegmentIndex forKey:@"transport"];
    [def synchronize];
}

#pragma mark - Badge

- (void)buildBadge {
    CGRect screen = [UIScreen mainScreen].bounds;
    _badgeWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screen.size.width - 120, 8, 112, 28)];
    _badgeWindow.windowLevel = UIWindowLevelAlert + 200;
    _badgeWindow.backgroundColor = [UIColor clearColor];
    _badgeWindow.userInteractionEnabled = YES;
    _badgeWindow.hidden = NO;

    _badgeLabel = [[UILabel alloc] initWithFrame:_badgeWindow.bounds];
    _badgeLabel.text = @"MyVCAM ▾";
    _badgeLabel.textColor = [UIColor whiteColor];
    _badgeLabel.font = [UIFont boldSystemFontOfSize:11];
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _badgeLabel.layer.cornerRadius = 8;
    _badgeLabel.layer.masksToBounds = YES;
    _badgeLabel.userInteractionEnabled = YES;
    [_badgeWindow addSubview:_badgeLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    [_badgeLabel addGestureRecognizer:tap];
}

#pragma mark - Panel

- (void)togglePanel {
    if (_panelVisible) [self dismissPanel];
    else [self showPanel];
}

- (void)showPanel {
    if (_panelVisible) return;
    _panelVisible = YES;

    CGRect screen = [UIScreen mainScreen].bounds;
    _panelWindow = [[UIWindow alloc] initWithFrame:screen];
    _panelWindow.windowLevel = UIWindowLevelAlert + 100;
    _panelWindow.backgroundColor = [UIColor clearColor];
    _panelWindow.hidden = NO;

    UIView *backdrop = [[UIView alloc] initWithFrame:screen];
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    backdrop.userInteractionEnabled = YES;
    [_panelWindow addSubview:backdrop];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPanel)];
    [backdrop addGestureRecognizer:dismissTap];

    CGFloat pw = MIN(screen.size.width * 0.85, 340);
    CGFloat ph = 290;
    CGFloat px = (screen.size.width - pw) / 2;
    CGFloat py = screen.size.height / 2 - ph / 2 - 30;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    _panel.layer.cornerRadius = 14;
    _panel.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    _panel.layer.borderWidth = 0.5;
    [_panelWindow addSubview:_panel];

    CGFloat y = 14;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, y, pw, 22)];
    title.text = @"MyVCAM";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:title];

    // Protocol toggle
    y += 32;
    _protoSwitch = [[UISegmentedControl alloc] initWithItems:@[@"TCP", @"WebSocket"]];
    _protoSwitch.frame = CGRectMake(pw * 0.15, y, pw * 0.7, 30);
    _protoSwitch.selectedSegmentIndex = [self savedTransport];
    _protoSwitch.tintColor = [UIColor systemBlueColor];
    [_panel addSubview:_protoSwitch];

    // IP field
    y += 44;
    _ipField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, pw - 32, 36)];
    _ipField.placeholder = @"Server IP (e.g. 10.0.0.5)";
    _ipField.text = [self savedHost];
    _ipField.textColor = [UIColor whiteColor];
    _ipField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    _ipField.layer.cornerRadius = 8;
    _ipField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)];
    _ipField.leftViewMode = UITextFieldViewModeAlways;
    _ipField.keyboardType = UIKeyboardTypeDecimalPad;
    _ipField.delegate = self;
    [_panel addSubview:_ipField];

    // Port field
    y += 44;
    _portField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, pw - 32, 36)];
    _portField.placeholder = @"Port (default 8765)";
    _portField.text = [NSString stringWithFormat:@"%d", [self savedPort] ?: 8765];
    _portField.textColor = [UIColor whiteColor];
    _portField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    _portField.layer.cornerRadius = 8;
    _portField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)];
    _portField.leftViewMode = UITextFieldViewModeAlways;
    _portField.keyboardType = UIKeyboardTypeNumberPad;
    _portField.delegate = self;
    [_panel addSubview:_portField];

    // Status
    y += 44;
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, pw - 32, 18)];
    _statusLabel.text = @"disconnected";
    _statusLabel.textColor = [UIColor lightGrayColor];
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_statusLabel];

    // Connect button
    y += 26;
    _connectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _connectBtn.frame = CGRectMake(16, y, pw - 32, 40);
    _connectBtn.backgroundColor = [UIColor systemBlueColor];
    _connectBtn.layer.cornerRadius = 10;
    [_connectBtn setTitle:@"Connect" forState:UIControlStateNormal];
    [_connectBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _connectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_connectBtn addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_connectBtn];
}

- (void)dismissPanel {
    if (!_panelVisible) return;
    _panelVisible = NO;
    [_ipField resignFirstResponder];
    [_portField resignFirstResponder];
    [UIView animateWithDuration:0.2 animations:^{ _panelWindow.alpha = 0; }
    completion:^(BOOL f) { _panelWindow.hidden = YES; _panelWindow = nil; }];
}

- (void)connectTapped {
    NSString *host = _ipField.text;
    if (host.length == 0) { [self flashButton:@"Enter IP"]; return; }
    [self saveConfig];

    if (_connected) {
        notify_post(NOTIFY_DISCONNECT);
        [self showDisconnected];
    } else {
        notify_post(NOTIFY_RECONNECT);
        [self showReconnecting];
    }
}

- (void)flashButton:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIColor *orig = _connectBtn.backgroundColor;
        NSString *origTitle = _connected ? @"Disconnect" : @"Connect";
        _connectBtn.backgroundColor = [UIColor systemOrangeColor];
        [_connectBtn setTitle:msg forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            _connectBtn.backgroundColor = orig;
            [_connectBtn setTitle:origTitle forState:UIControlStateNormal];
        });
    });
}

#pragma mark - Status

- (void)showConnected {
    _connected = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        _badgeLabel.text = @"MyVCAM ●";
        _badgeLabel.backgroundColor = [UIColor colorWithRed:0 green:0.4 blue:0 alpha:0.7];
        _statusLabel.text = @"streaming";
        _statusLabel.textColor = [UIColor greenColor];
        _connectBtn.backgroundColor = [UIColor systemRedColor];
        [_connectBtn setTitle:@"Disconnect" forState:UIControlStateNormal];
    });
}

- (void)showDisconnected {
    _connected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        _badgeLabel.text = @"MyVCAM ▾";
        _badgeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _statusLabel.text = @"disconnected";
        _statusLabel.textColor = [UIColor lightGrayColor];
        _connectBtn.backgroundColor = [UIColor systemBlueColor];
        [_connectBtn setTitle:@"Connect" forState:UIControlStateNormal];
    });
}

- (void)showReconnecting {
    dispatch_async(dispatch_get_main_queue(), ^{
        _badgeLabel.text = @"MyVCAM ⟳";
        _badgeLabel.backgroundColor = [UIColor colorWithRed:0.6 green:0.3 blue:0 alpha:0.7];
        _statusLabel.text = @"connecting...";
        _statusLabel.textColor = [UIColor orangeColor];
    });
}

- (void)showStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ _statusLabel.text = text; });
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

@end
