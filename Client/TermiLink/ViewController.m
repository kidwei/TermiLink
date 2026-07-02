#import "ViewController.h"
#import "VPNManager.h"
#import "ServerAPIClient.h"

@interface ViewController ()

@property (nonatomic, strong) UIButton *serverButton;
@property (nonatomic, strong) NSArray<NSDictionary *> *serverList;   // 由 /api/get_serv_list 返回
@property (nonatomic, assign) BOOL serverListFailed;                 // 列表拉取是否失败
@property (nonatomic, strong) NSDictionary *selectedServer;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) NSTimer *logTimer;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"VPNTool";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.serverList = @[];
    self.selectedServer = nil;

    [self setupUI];
    [self updateUI];
    [self clearLog];
    [self refreshLog];

    // 首次进入先拉一次（切前台的通知可能在注册前已触发）
    [self fetchServerList];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVPNStatusChanged:)
                                                 name:@"VPNStatusChanged"
                                               object:nil];

    // App 每次切换到前台都重新拉取服务器列表
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(fetchServerList)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每 2 秒自动刷新日志
    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(refreshLog)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.logTimer invalidate];
    self.logTimer = nil;
}

- (void)setupUI {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // 服务器选择（下拉菜单）
    UILabel *serverTitle = [[UILabel alloc] init];
    serverTitle.translatesAutoresizingMaskIntoConstraints = NO;
    serverTitle.font = [UIFont systemFontOfSize:16];
    serverTitle.text = @"服务器:";
    [self.view addSubview:serverTitle];

    self.serverButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.serverButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.serverButton.titleLabel.font = [UIFont systemFontOfSize:16];
    self.serverButton.showsMenuAsPrimaryAction = YES;
    // 下拉标识：右侧 chevron 箭头
    UIImage *chevron = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
    [self.serverButton setImage:chevron forState:UIControlStateNormal];
    // 文字在左、箭头在右
    self.serverButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    self.serverButton.imageEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.serverButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    // 轻边框，看起来像可点的下拉框
    self.serverButton.layer.borderWidth = 1;
    self.serverButton.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.serverButton.layer.cornerRadius = 8;
    self.serverButton.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [self rebuildServerMenu];
    [self.view addSubview:self.serverButton];

    // 状态行
    UILabel *statusTitle = [[UILabel alloc] init];
    statusTitle.translatesAutoresizingMaskIntoConstraints = NO;
    statusTitle.font = [UIFont systemFontOfSize:16];
    statusTitle.text = @"状态:";
    [self.view addSubview:statusTitle];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [self.view addSubview:self.statusLabel];

    // 连接按钮
    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectButton.layer.cornerRadius = 8;
    [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.connectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [self.connectButton addTarget:self action:@selector(connectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.connectButton];

    // 日志标题
    UILabel *logTitle = [[UILabel alloc] init];
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;
    logTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    logTitle.textColor = [UIColor secondaryLabelColor];
    logTitle.text = @"连接日志";
    [self.view addSubview:logTitle];

    // 复制按钮（字体大小与"连接日志"文本一致）
    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [copyButton setTitle:@"复制" forState:UIControlStateNormal];
    copyButton.titleLabel.font = logTitle.font;
    [copyButton addTarget:self action:@selector(copyLogTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copyButton];

    // 日志展示（直接显示在下方）
    self.logTextView = [[UITextView alloc] init];
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logTextView.editable = NO;
    self.logTextView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    self.logTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logTextView.layer.cornerRadius = 8;
    self.logTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:self.logTextView];

    [NSLayoutConstraint activateConstraints:@[
        [serverTitle.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [serverTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],

        [self.serverButton.centerYAnchor constraintEqualToAnchor:serverTitle.centerYAnchor],
        [self.serverButton.leadingAnchor constraintEqualToAnchor:serverTitle.trailingAnchor constant:8],
        [self.serverButton.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],

        [statusTitle.topAnchor constraintEqualToAnchor:serverTitle.bottomAnchor constant:16],
        [statusTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],

        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusTitle.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:statusTitle.trailingAnchor constant:8],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.connectButton.topAnchor constraintEqualToAnchor:statusTitle.bottomAnchor constant:20],
        [self.connectButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.connectButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.connectButton.heightAnchor constraintEqualToConstant:50],

        [logTitle.topAnchor constraintEqualToAnchor:self.connectButton.bottomAnchor constant:24],
        [logTitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],

        [copyButton.centerYAnchor constraintEqualToAnchor:logTitle.centerYAnchor],
        [copyButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.logTextView.topAnchor constraintEqualToAnchor:logTitle.bottomAnchor constant:8],
        [self.logTextView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logTextView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logTextView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}

- (void)fetchServerList {
    // 调用 /api/get_serv_list 获取服务器列表（控制接口固定 IP）
    [[ServerAPIClient sharedClient] getServerListWithCompletion:^(NSArray<NSDictionary *> *servers, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                // 请求失败（含超时）弹 Toast 提示
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
    // 保持已选项（按 ip 匹配），否则默认选第一个
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
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSDictionary *server in self.serverList) {
        BOOL isSelected = [server[@"ip"] isEqual:self.selectedServer[@"ip"]];
        UIAction *action = [UIAction actionWithTitle:(server[@"name"] ?: server[@"ip"])
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *act) {
            weakSelf.selectedServer = server;
            [weakSelf rebuildServerMenu];
        }];
        action.state = isSelected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }

    // 列表为空时给一个“重新获取”选项，保证菜单可弹出、可重试
    if (actions.count == 0) {
        UIAction *retry = [UIAction actionWithTitle:@"重新获取列表"
                                              image:[UIImage systemImageNamed:@"arrow.clockwise"]
                                         identifier:nil
                                            handler:^(UIAction *act) {
            [weakSelf fetchServerList];
        }];
        [actions addObject:retry];
    }
    self.serverButton.menu = [UIMenu menuWithTitle:@"" children:actions];

    NSString *title = self.selectedServer[@"name"] ?: self.selectedServer[@"ip"];
    if (!title) {
        title = self.serverListFailed ? @"拉取失败" : @"加载中...";
    }
    [self.serverButton setTitle:title forState:UIControlStateNormal];
}

- (void)updateUI {
    VPNManager *manager = [VPNManager sharedManager];

    // 连接后不允许切换服务器
    self.serverButton.enabled = !manager.isConnected;

    if (manager.isConnected) {
        self.statusLabel.text = manager.statusText;
        self.statusLabel.textColor = [UIColor systemGreenColor];
        [self.connectButton setTitle:@"断开连接" forState:UIControlStateNormal];
        [self.connectButton setBackgroundColor:[UIColor systemRedColor]];
    } else {
        self.statusLabel.text = manager.statusText;
        self.statusLabel.textColor = [UIColor systemGrayColor];
        [self.connectButton setTitle:@"连接 VPN" forState:UIControlStateNormal];
        [self.connectButton setBackgroundColor:[UIColor systemBlueColor]];
    }
}

- (void)connectButtonTapped:(UIButton *)sender {
    VPNManager *manager = [VPNManager sharedManager];

    if (manager.isConnected) {
        // 断开：先停 VPN，再调用 /api/stop_server
        [self disconnect];
        return;
    }

    // 连接：调用 /api/start_server 启动服务端，成功后再建立 VPN 连接
    [self connect];
}

- (void)connect {
    NSDictionary *target = self.selectedServer;
    NSString *serverIP = target[@"ip"];
    NSInteger port = [target[@"port"] integerValue];
    if (serverIP.length == 0 || port == 0) {
        // 还没拿到服务器列表，先尝试拉取一次
        [self showAlertWithTitle:@"暂无可用服务器" message:@"正在获取服务器列表，请稍后重试"];
        [self fetchServerList];
        return;
    }

    // 更新 UI 为“正在启动服务端...”
    self.statusLabel.text = @"正在启动服务端...";
    self.statusLabel.textColor = [UIColor systemGrayColor];
    self.connectButton.enabled = NO;

    // 第 1 步：调用服务端 /api/start_server（固定控制 IP）
    [[ServerAPIClient sharedClient] startServerWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.connectButton.enabled = YES;
                [self updateUI];
                [self showAlertWithTitle:@"启动服务端失败" message:error.localizedDescription];
                return;
            }

            // 第 2 步：服务端启动成功，建立 VPN 连接（IP + 端口来自选中的服务器）
            self.statusLabel.text = @"正在连接...";
            [[VPNManager sharedManager] startVPNWithServerIP:serverIP port:port completion:^(NSError *vpnError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectButton.enabled = YES;
                    if (vpnError) {
                        [self updateUI];
                        [self showAlertWithTitle:@"连接失败" message:vpnError.localizedDescription];
                        // VPN 连接失败，尝试把服务端也停掉，避免残留
                        [[ServerAPIClient sharedClient] stopServerWithCompletion:^(NSError *e) {}];
                    }
                });
            }];
        });
    }];
}

- (void)disconnect {
    // 第 1 步：停止 VPN 隧道
    [[VPNManager sharedManager] stopVPN];

    // 第 2 步：调用服务端 /api/stop_server
    [[ServerAPIClient sharedClient] stopServerWithCompletion:^(NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 停止服务端失败只提示，不阻塞（VPN 已经断开）
                NSLog(@"⚠️ 停止服务端失败: %@", error.localizedDescription);
            });
        }
    }];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
    // 每次 App 启动清空旧日志，只保留本次会话
    [@"" writeToFile:logURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)copyLogTapped:(UIButton *)sender {
    NSString *log = self.logTextView.text ?: @"";
    UIPasteboard.generalPasteboard.string = log;
    [self showToast:@"复制成功"];
}

- (void)showToast:(NSString *)message {
    UILabel *toast = [[UILabel alloc] init];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.text = message;
    toast.textColor = [UIColor whiteColor];
    toast.font = [UIFont systemFontOfSize:14];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    toast.layer.cornerRadius = 10;
    toast.layer.masksToBounds = YES;
    [self.view addSubview:toast];

    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [toast.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [toast.heightAnchor constraintEqualToConstant:44],
    ]];

    toast.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{
        toast.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.2 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished2) {
            [toast removeFromSuperview];
        }];
    }];
}

- (void)refreshLog {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *logURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];

    NSString *log = [NSString stringWithContentsOfFile:logURL.path encoding:NSUTF8StringEncoding error:nil];
    if (!log || log.length == 0) {
        self.logTextView.text = @"暂无日志";
        return;
    }

    // 内容变化时才更新，避免打断用户滚动/选择
    if (![self.logTextView.text isEqualToString:log]) {
        self.logTextView.text = log;
        // 自动滚动到底部
        if (log.length > 0) {
            [self.logTextView scrollRangeToVisible:NSMakeRange(log.length - 1, 1)];
        }
    }
}

- (void)dealloc {
    [self.logTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
