#import "ViewController.h"
#import "VPNManager.h"
#import "ServerAPIClient.h"

@interface ViewController ()

@property (nonatomic, strong) NSPopUpButton *serverPopUp;
@property (nonatomic, strong) NSArray<NSDictionary *> *serverList;
@property (nonatomic, assign) BOOL serverListFailed;
@property (nonatomic, strong) NSDictionary *selectedServer;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, strong) NSTimer *logTimer;

@end

@implementation ViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 680)];
    self.view.wantsLayer = YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.serverList = @[];
    self.selectedServer = nil;

    [self setupUI];
    [self updateUI];
    [self clearLog];
    [self refreshLog];
    [self fetchServerList];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVPNStatusChanged:)
                                                 name:@"VPNStatusChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(fetchServerList)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(refreshLog)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.logTimer invalidate];
    self.logTimer = nil;
}

- (void)setupUI {
    NSTextField *serverTitle = [self labelWithText:@"服务器:" bold:NO];
    serverTitle.frame = NSMakeRect(20, 620, 60, 22);
    [self.view addSubview:serverTitle];

    self.serverPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(85, 615, 400, 28) pullsDown:NO];
    self.serverPopUp.target = self;
    self.serverPopUp.action = @selector(serverSelectionChanged:);
    [self.view addSubview:self.serverPopUp];

    NSTextField *statusTitle = [self labelWithText:@"状态:" bold:NO];
    statusTitle.frame = NSMakeRect(20, 575, 60, 22);
    [self.view addSubview:statusTitle];

    self.statusLabel = [self labelWithText:@"未连接" bold:YES];
    self.statusLabel.frame = NSMakeRect(85, 575, 400, 22);
    [self.view addSubview:self.statusLabel];

    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 515, 480, 36)];
    self.connectButton.bezelStyle = NSBezelStyleRounded;
    self.connectButton.font = [NSFont boldSystemFontOfSize:14];
    self.connectButton.target = self;
    self.connectButton.action = @selector(connectButtonTapped:);
    [self.view addSubview:self.connectButton];

    NSTextField *logTitle = [self labelWithText:@"连接日志" bold:YES];
    logTitle.textColor = [NSColor secondaryLabelColor];
    logTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    logTitle.frame = NSMakeRect(20, 475, 80, 20);
    [self.view addSubview:logTitle];

    NSButton *copyButton = [[NSButton alloc] initWithFrame:NSMakeRect(420, 470, 80, 28)];
    copyButton.bezelStyle = NSBezelStyleRoundRect;
    copyButton.title = @"复制";
    copyButton.font = logTitle.font;
    copyButton.target = self;
    copyButton.action = @selector(copyLogTapped:);
    [self.view addSubview:copyButton];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 480, 440)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.autohidesScrollers = YES;

    self.logTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont systemFontOfSize:11];
    self.logTextView.backgroundColor = [NSColor textBackgroundColor];
    self.logTextView.textContainerInset = NSMakeSize(8, 8);
    scrollView.documentView = self.logTextView;
    [self.view addSubview:scrollView];

    [self rebuildServerMenu];
}

- (NSTextField *)labelWithText:(NSString *)text bold:(BOOL)bold {
    NSTextField *label = [[NSTextField alloc] init];
    label.stringValue = text;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:14] : [NSFont systemFontOfSize:14];
    return label;
}

- (void)fetchServerList {
    [[ServerAPIClient sharedClient] getServerListWithCompletion:^(NSArray<NSDictionary *> *servers, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.serverListFailed = YES;
                [self rebuildServerMenu];
                [self showToast:@"获取服务器列表失败"];
                return;
            }
            if (servers.count == 0) {
                self.serverListFailed = YES;
                [self rebuildServerMenu];
                [self showToast:@"暂无可用服务器"];
                return;
            }
            self.serverListFailed = NO;
            [self applyServerList:servers];
        });
    }];
}

- (void)applyServerList:(NSArray<NSDictionary *> *)servers {
    self.serverList = servers;
    NSDictionary *keep = nil;
    for (NSDictionary *s in servers) {
        if ([s[@"ip"] isEqual:self.selectedServer[@"ip"]]) {
            keep = s;
            break;
        }
    }
    self.selectedServer = keep ?: servers.firstObject;
    [self rebuildServerMenu];
    [self updateUI];
}

- (void)rebuildServerMenu {
    [self.serverPopUp removeAllItems];

    if (self.serverList.count == 0) {
        NSString *placeholder = self.serverListFailed ? @"拉取失败" : @"加载中...";
        [self.serverPopUp addItemWithTitle:placeholder];
        self.serverPopUp.enabled = !self.serverListFailed;
        if (self.serverListFailed) {
            NSMenuItem *retry = [[NSMenuItem alloc] initWithTitle:@"重新获取列表" action:@selector(fetchServerList) keyEquivalent:@""];
            retry.target = self;
            [self.serverPopUp.menu addItem:retry];
        }
        return;
    }

    for (NSDictionary *server in self.serverList) {
        NSString *title = server[@"name"] ?: server[@"ip"];
        [self.serverPopUp addItemWithTitle:title];
    }

    NSInteger selectedIndex = 0;
    for (NSInteger i = 0; i < (NSInteger)self.serverList.count; i++) {
        if ([self.serverList[i][@"ip"] isEqual:self.selectedServer[@"ip"]]) {
            selectedIndex = i;
            break;
        }
    }
    [self.serverPopUp selectItemAtIndex:selectedIndex];
    self.selectedServer = self.serverList[selectedIndex];
}

- (void)serverSelectionChanged:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem;
    if (index >= 0 && index < (NSInteger)self.serverList.count) {
        self.selectedServer = self.serverList[index];
    }
}

- (void)updateUI {
    VPNManager *manager = [VPNManager sharedManager];

    self.serverPopUp.enabled = !manager.isConnected;

    self.statusLabel.stringValue = manager.statusText;
    if (manager.isConnected) {
        self.statusLabel.textColor = [NSColor systemGreenColor];
        self.connectButton.title = @"断开连接";
        self.connectButton.contentTintColor = [NSColor whiteColor];
        self.connectButton.bezelColor = [NSColor systemRedColor];
    } else {
        self.statusLabel.textColor = [NSColor secondaryLabelColor];
        self.connectButton.title = @"连接 VPN";
        self.connectButton.contentTintColor = [NSColor whiteColor];
        self.connectButton.bezelColor = [NSColor systemBlueColor];
    }
}

- (void)connectButtonTapped:(NSButton *)sender {
    VPNManager *manager = [VPNManager sharedManager];
    if (manager.isConnected) {
        [self disconnect];
        return;
    }
    [self connect];
}

- (void)connect {
    NSDictionary *target = self.selectedServer;
    NSString *serverIP = target[@"ip"];
    NSInteger port = [target[@"port"] integerValue];
    if (serverIP.length == 0 || port == 0) {
        [self showAlertWithTitle:@"暂无可用服务器" message:@"正在获取服务器列表，请稍后重试"];
        [self fetchServerList];
        return;
    }

    self.statusLabel.stringValue = @"正在启动服务端...";
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.connectButton.enabled = NO;

    [[ServerAPIClient sharedClient] startServerWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.connectButton.enabled = YES;
                [self updateUI];
                [self showAlertWithTitle:@"启动服务端失败" message:error.localizedDescription];
                return;
            }

            self.statusLabel.stringValue = @"正在连接...";
            [[VPNManager sharedManager] startVPNWithServerIP:serverIP port:port completion:^(NSError *vpnError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectButton.enabled = YES;
                    if (vpnError) {
                        [self updateUI];
                        [self showAlertWithTitle:@"连接失败" message:vpnError.localizedDescription];
                        [[ServerAPIClient sharedClient] stopServerWithCompletion:^(NSError *e) {}];
                    }
                });
            }];
        });
    }];
}

- (void)disconnect {
    [[VPNManager sharedManager] stopVPN];
    [[ServerAPIClient sharedClient] stopServerWithCompletion:^(NSError *error) {
        if (error) {
            NSLog(@"⚠️ 停止服务端失败: %@", error.localizedDescription);
        }
    }];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"确定"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (void)onVPNStatusChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateUI];
        [self refreshLog];
    });
}

- (void)clearLog {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *logURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];
    [@"" writeToFile:logURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)copyLogTapped:(NSButton *)sender {
    NSString *log = self.logTextView.string ?: @"";
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:log forType:NSPasteboardTypeString];
    [self showToast:@"复制成功"];
}

- (void)showToast:(NSString *)message {
    NSTextField *toast = [self labelWithText:message bold:NO];
    toast.textColor = [NSColor whiteColor];
    toast.font = [NSFont systemFontOfSize:13];
    toast.alignment = NSTextAlignmentCenter;
    toast.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.75];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 8;
    toast.frame = NSMakeRect(160, 340, 200, 36);
    [self.view addSubview:toast];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [toast removeFromSuperview];
    });
}

- (void)refreshLog {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *logURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];

    NSString *log = [NSString stringWithContentsOfFile:logURL.path encoding:NSUTF8StringEncoding error:nil];
    if (!log || log.length == 0) {
        self.logTextView.string = @"暂无日志";
        return;
    }

    if (![self.logTextView.string isEqualToString:log]) {
        self.logTextView.string = log;
        [self.logTextView scrollRangeToVisible:NSMakeRange(log.length, 0)];
    }
}

- (void)dealloc {
    [self.logTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
