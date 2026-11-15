#import "ViewController.h"
#import "VPNManager.h"
#import "ServerAPIClient.h"
#import <pwd.h>
#import <unistd.h>

// 沙盒下 NSHomeDirectory() 会指向应用容器，这里取真实用户目录以便与扩展共享日志。
static NSString *TermiLinkRealHomeDirectory(void) {
    struct passwd *pw = getpwuid(getuid());
    return pw ? [NSString stringWithUTF8String:pw->pw_dir] : NSHomeDirectory();
}

static NSString * const kAccelerationTargetsKey = @"AccelerationTargets";
static NSString * const kTargetChatGPT = @"chatgpt";
static NSString * const kTargetCursor = @"cursor";
static NSString * const kTargetAll = @"all";

@interface ViewController ()

@property (nonatomic, strong) NSPopUpButton *serverPopUp;
@property (nonatomic, strong) NSArray<NSDictionary *> *serverList;
@property (nonatomic, assign) BOOL serverListFailed;
@property (nonatomic, strong) NSDictionary *selectedServer;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, strong) NSTimer *logTimer;

// 加速目的地选择
@property (nonatomic, strong) NSButton *appSelectButton;
@property (nonatomic, copy) NSArray<NSString *> *selectedTargets;

// 选择弹框
@property (nonatomic, strong) NSWindow *appPanel;
@property (nonatomic, strong) NSButton *chatGPTCheckbox;
@property (nonatomic, strong) NSButton *cursorCheckbox;
@property (nonatomic, strong) NSButton *allCheckbox;

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
    self.selectedTargets = [self loadSelectedTargets];

    [self setupUI];
    [self updateUI];
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
    serverTitle.frame = NSMakeRect(20, 625, 60, 22);
    [self.view addSubview:serverTitle];

    self.serverPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(85, 620, 400, 28) pullsDown:NO];
    self.serverPopUp.target = self;
    self.serverPopUp.action = @selector(serverSelectionChanged:);
    [self.view addSubview:self.serverPopUp];

    NSTextField *appTitle = [self labelWithText:@"加速范围:" bold:NO];
    appTitle.frame = NSMakeRect(20, 580, 65, 22);
    [self.view addSubview:appTitle];

    self.appSelectButton = [[NSButton alloc] initWithFrame:NSMakeRect(90, 575, 395, 28)];
    self.appSelectButton.bezelStyle = NSBezelStyleRounded;
    self.appSelectButton.alignment = NSTextAlignmentLeft;
    self.appSelectButton.target = self;
    self.appSelectButton.action = @selector(appSelectButtonTapped:);
    [self.view addSubview:self.appSelectButton];

    NSTextField *statusTitle = [self labelWithText:@"状态:" bold:NO];
    statusTitle.frame = NSMakeRect(20, 535, 60, 22);
    [self.view addSubview:statusTitle];

    self.statusLabel = [self labelWithText:@"未连接" bold:YES];
    self.statusLabel.frame = NSMakeRect(85, 535, 400, 22);
    [self.view addSubview:self.statusLabel];

    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 475, 480, 36)];
    self.connectButton.bezelStyle = NSBezelStyleRounded;
    self.connectButton.font = [NSFont boldSystemFontOfSize:14];
    self.connectButton.target = self;
    self.connectButton.action = @selector(connectButtonTapped:);
    [self.view addSubview:self.connectButton];

    NSTextField *logTitle = [self labelWithText:@"连接日志" bold:YES];
    logTitle.textColor = [NSColor secondaryLabelColor];
    logTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    logTitle.frame = NSMakeRect(20, 435, 80, 20);
    [self.view addSubview:logTitle];

    NSButton *clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(335, 430, 80, 28)];
    clearButton.bezelStyle = NSBezelStyleRoundRect;
    clearButton.title = @"清空";
    clearButton.font = logTitle.font;
    clearButton.target = self;
    clearButton.action = @selector(clearLogTapped:);
    [self.view addSubview:clearButton];

    NSButton *copyButton = [[NSButton alloc] initWithFrame:NSMakeRect(420, 430, 80, 28)];
    copyButton.bezelStyle = NSBezelStyleRoundRect;
    copyButton.title = @"复制";
    copyButton.font = logTitle.font;
    copyButton.target = self;
    copyButton.action = @selector(copyLogTapped:);
    [self.view addSubview:copyButton];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 480, 400)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor textBackgroundColor];

    self.logTextView = [[NSTextView alloc] initWithFrame:scrollView.contentView.bounds];
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont systemFontOfSize:11];
    self.logTextView.backgroundColor = [NSColor textBackgroundColor];
    self.logTextView.textColor = [NSColor labelColor];
    self.logTextView.drawsBackground = YES;
    self.logTextView.textContainerInset = NSMakeSize(8, 8);
    self.logTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = self.logTextView;
    [self.view addSubview:scrollView];

    [self rebuildServerMenu];
    [self refreshAppSelectButtonTitle];
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
        self.connectButton.enabled = YES;
    } else {
        self.statusLabel.textColor = [NSColor secondaryLabelColor];
        self.connectButton.title = @"连接 VPN";
        self.connectButton.contentTintColor = [NSColor whiteColor];
        self.connectButton.bezelColor = [NSColor systemBlueColor];
        self.connectButton.enabled = self.selectedTargets.count > 0;
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
            VPNManager *manager = [VPNManager sharedManager];
            manager.acceleratedDomains = [self acceleratedDomainsForCurrentSelection];
            [manager startVPNWithServerIP:serverIP port:port completion:^(NSError *vpnError) {
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

- (NSURL *)logFileURL {
    NSString *logDirectory = [TermiLinkRealHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TermiLink"];
    return [NSURL fileURLWithPath:[logDirectory stringByAppendingPathComponent:@"packettunnel.log"]];
}

- (void)copyLogTapped:(NSButton *)sender {
    NSString *log = self.logTextView.string ?: @"";
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:log forType:NSPasteboardTypeString];
    [self showToast:@"复制成功"];
}

- (void)clearLogTapped:(NSButton *)sender {
    NSError *error = nil;
    if (![@"" writeToFile:self.logFileURL.path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"❌ 清空日志失败: %@", error);
        [self showToast:@"清空失败"];
        return;
    }
    [self refreshLog];
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
    NSString *log = [NSString stringWithContentsOfFile:[self logFileURL].path encoding:NSUTF8StringEncoding error:nil];
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

#pragma mark - Destination Selection

- (void)refreshAppSelectButtonTitle {
    if ([self.selectedTargets containsObject:kTargetAll]) {
        self.appSelectButton.title = @"全部流量（全局加速）";
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([self.selectedTargets containsObject:kTargetChatGPT]) [names addObject:@"ChatGPT"];
    if ([self.selectedTargets containsObject:kTargetCursor]) [names addObject:@"Cursor CLI"];
    self.appSelectButton.title = names.count > 0 ? [names componentsJoinedByString:@"、"] : @"请选择加速目标";
}

- (NSArray<NSString *> *)loadSelectedTargets {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kAccelerationTargetsKey];
    if ([stored isKindOfClass:[NSArray class]] && stored.count > 0) {
        NSMutableArray<NSString *> *valid = [NSMutableArray array];
        for (id item in stored) {
            if ([item isKindOfClass:[NSString class]] &&
                ([item isEqualToString:kTargetChatGPT] ||
                 [item isEqualToString:kTargetCursor] ||
                 [item isEqualToString:kTargetAll])) {
                [valid addObject:item];
            }
        }
        if (valid.count > 0) {
            return valid;
        }
    }
    // 默认只加速 ChatGPT，避免新用户无意中开启全局路由。
    return @[kTargetChatGPT];
}

- (void)saveSelectedTargets {
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedTargets forKey:kAccelerationTargetsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray<NSString *> *)acceleratedDomainsForCurrentSelection {
    // 选中「全部」时走全局路由，其余按目标合并域名。
    if ([self.selectedTargets containsObject:kTargetAll]) {
        return @[];
    }
    NSMutableOrderedSet<NSString *> *domains = [NSMutableOrderedSet orderedSet];
    if ([self.selectedTargets containsObject:kTargetChatGPT]) {
        [domains addObjectsFromArray:@[
            @"chatgpt.com",
            @"openai.com",
            @"oaistatic.com",
            @"cdn.oaistatic.com",
            @"files.oaiusercontent.com"
        ]];
    }
    if ([self.selectedTargets containsObject:kTargetCursor]) {
        [domains addObjectsFromArray:@[
            @"cursor.sh",
            @"cursor.com",
            @"api2.cursor.sh",
            @"api2direct.cursor.sh",
            @"api3.cursor.sh",
            @"api.cursor.com",
            @"agentn.us.api5.cursor.sh",
            @"agentn.api5geo.cursor.sh",
            @"agentn.api5lat.cursor.sh",
            @"cloud-agent-artifacts.s3.us-east-1.amazonaws.com"
        ]];
    }
    return domains.array;
}

- (void)appSelectButtonTapped:(NSButton *)sender {
    if ([VPNManager sharedManager].isConnected) {
        [self showAlertWithTitle:@"已连接" message:@"请先断开 VPN 后再修改加速范围"];
        return;
    }
    [self showDestinationSelectionPanel];
}

- (void)showDestinationSelectionPanel {
    [self closeAppPanel];

    NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 280)
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    panel.title = @"选择加速目标";
    panel.releasedWhenClosed = NO;
    self.appPanel = panel;

    NSView *content = panel.contentView;

    self.allCheckbox = [self checkboxWithTitle:@"全部（全局加速，所有应用都走 VPN）"
                                          frame:NSMakeRect(20, 210, 440, 24)
                                       selected:[self.selectedTargets containsObject:kTargetAll]];
    [content addSubview:self.allCheckbox];

    self.chatGPTCheckbox = [self checkboxWithTitle:@"ChatGPT"
                                             frame:NSMakeRect(20, 175, 200, 24)
                                          selected:[self.selectedTargets containsObject:kTargetChatGPT]];
    [content addSubview:self.chatGPTCheckbox];

    self.cursorCheckbox = [self checkboxWithTitle:@"Cursor CLI"
                                            frame:NSMakeRect(20, 140, 200, 24)
                                         selected:[self.selectedTargets containsObject:kTargetCursor]];
    [content addSubview:self.cursorCheckbox];

    NSTextField *hint = [self labelWithText:@"可多选。ChatGPT / Cursor CLI 只将相关域名解析出的 IP 和对应 DNS 送入 VPN，其他流量直连；至少选择一项才能连接。" bold:NO];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:12];
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.frame = NSMakeRect(20, 75, 440, 55);
    [content addSubview:hint];

    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(260, 20, 90, 32)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.title = @"取消";
    cancelButton.target = self;
    cancelButton.action = @selector(appPanelCancelTapped:);
    [content addSubview:cancelButton];

    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(360, 20, 100, 32)];
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.title = @"确定";
    okButton.keyEquivalent = @"\r";
    okButton.target = self;
    okButton.action = @selector(appPanelOKTapped:);
    [content addSubview:okButton];

    [panel center];
    [self.view.window addChildWindow:panel ordered:NSWindowAbove];
    [panel makeKeyAndOrderFront:nil];
}

- (NSButton *)checkboxWithTitle:(NSString *)title frame:(NSRect)frame selected:(BOOL)selected {
    NSButton *checkbox = [[NSButton alloc] initWithFrame:frame];
    [checkbox setButtonType:NSButtonTypeSwitch];
    checkbox.title = title;
    checkbox.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    return checkbox;
}

- (void)appPanelCancelTapped:(NSButton *)sender {
    [self closeAppPanel];
}

- (void)appPanelOKTapped:(NSButton *)sender {
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    if (self.allCheckbox.state == NSControlStateValueOn) [targets addObject:kTargetAll];
    if (self.chatGPTCheckbox.state == NSControlStateValueOn) [targets addObject:kTargetChatGPT];
    if (self.cursorCheckbox.state == NSControlStateValueOn) [targets addObject:kTargetCursor];

    if (targets.count == 0) {
        [self showAlertWithTitle:@"请至少选择一项" message:@"ChatGPT、Cursor CLI、全部 中至少需要选择一项才能连接 VPN。"];
        return;
    }

    self.selectedTargets = targets;
    [self saveSelectedTargets];
    [self refreshAppSelectButtonTitle];
    [self updateUI];
    [self closeAppPanel];
}

- (void)closeAppPanel {
    NSWindow *panel = self.appPanel;
    if (panel) {
        [self.view.window removeChildWindow:panel];
        [panel orderOut:nil];
    }
    self.appPanel = nil;
    self.chatGPTCheckbox = nil;
    self.cursorCheckbox = nil;
    self.allCheckbox = nil;
}

@end
