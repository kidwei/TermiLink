#import "ViewController.h"
#import "VPNManager.h"
#import "ServerAPIClient.h"

@interface ViewController () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *serverIPTextField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"VPNTool";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupUI];
    [self updateUI];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVPNStatusChanged:)
                                                 name:@"VPNStatusChanged"
                                               object:nil];
}

- (void)setupUI {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    // 服务器配置 section header
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    UILabel *serverHeader = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 100, 20)];
    serverHeader.text = @"服务器配置";
    serverHeader.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [headerView addSubview:serverHeader];
    self.tableView.tableHeaderView = headerView;

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ServerCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"StatusCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ButtonCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"LogCell"];

    [self.tableView reloadData];
}

- (void)updateUI {
    VPNManager *manager = [VPNManager sharedManager];

    self.serverIPTextField.enabled = !manager.isConnected;

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

    NSString *serverIP = self.serverIPTextField.text;
    if (serverIP.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"请输入服务器 IP 地址" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 连接：先调用 /api/start_server 启动服务端，成功后再建立 VPN 连接
    [self connectWithServerIP:serverIP];
}

- (void)connectWithServerIP:(NSString *)serverIP {
    // 更新 UI 为“正在启动服务端...”
    self.statusLabel.text = @"正在启动服务端...";
    self.statusLabel.textColor = [UIColor systemGrayColor];
    self.connectButton.enabled = NO;

    // 第 1 步：调用服务端 /api/start_server
    [[ServerAPIClient sharedClient] startServerWithServerIP:serverIP completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.connectButton.enabled = YES;
                [self updateUI];
                [self showAlertWithTitle:@"启动服务端失败" message:error.localizedDescription];
                return;
            }

            // 第 2 步：服务端启动成功，建立 VPN 连接
            self.statusLabel.text = @"正在连接...";
            [[VPNManager sharedManager] startVPNWithServerIP:serverIP completion:^(NSError *vpnError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectButton.enabled = YES;
                    if (vpnError) {
                        [self updateUI];
                        [self showAlertWithTitle:@"连接失败" message:vpnError.localizedDescription];
                        // VPN 连接失败，尝试把服务端也停掉，避免残留
                        [[ServerAPIClient sharedClient] stopServerWithServerIP:serverIP completion:^(NSError *e) {}];
                    }
                });
            }];
        });
    }];
}

- (void)disconnect {
    NSString *serverIP = self.serverIPTextField.text;

    // 第 1 步：停止 VPN 隧道
    [[VPNManager sharedManager] stopVPN];

    // 第 2 步：调用服务端 /api/stop_server
    if (serverIP.length > 0) {
        [[ServerAPIClient sharedClient] stopServerWithServerIP:serverIP completion:^(NSError *error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 停止服务端失败只提示，不阻塞（VPN 已经断开）
                    NSLog(@"⚠️ 停止服务端失败: %@", error.localizedDescription);
                });
            }
        }];
    }
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onVPNStatusChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateUI];
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UITableViewDataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // 服务器 IP cell
        UITableViewCell *serverCell = [tableView dequeueReusableCellWithIdentifier:@"ServerCell" forIndexPath:indexPath];
        self.serverIPTextField = [[UITextField alloc] initWithFrame:CGRectMake(15, 10, serverCell.contentView.bounds.size.width - 30, 30)];
        self.serverIPTextField.placeholder = @"例如: 129.226.94.203";
        self.serverIPTextField.keyboardType = UIKeyboardTypeDecimalPad;
        self.serverIPTextField.delegate = self;
        self.serverIPTextField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.serverIPTextField.text = @"129.226.94.203"; // 默认值
        [serverCell.contentView addSubview:self.serverIPTextField];
        return serverCell;
    } else if (indexPath.section == 1) {
        // 状态 cell
        UITableViewCell *statusCell = [tableView dequeueReusableCellWithIdentifier:@"StatusCell" forIndexPath:indexPath];
        UILabel *statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 12, 60, 30)];
        statusTitleLabel.text = @"状态";
        statusTitleLabel.font = [UIFont systemFontOfSize:16];
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(statusCell.contentView.bounds.size.width - 200 - 15, 12, 200, 30)];
        self.statusLabel.textAlignment = NSTextAlignmentRight;
        self.statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        [statusCell.contentView addSubview:statusTitleLabel];
        [statusCell.contentView addSubview:self.statusLabel];
        return statusCell;
    } else if (indexPath.section == 2) {
        // 连接按钮 cell
        UITableViewCell *buttonCell = [tableView dequeueReusableCellWithIdentifier:@"ButtonCell" forIndexPath:indexPath];
        self.connectButton = [[UIButton alloc] initWithFrame:CGRectInset(buttonCell.contentView.bounds, 10, 8)];
        self.connectButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.connectButton.layer.cornerRadius = 8;
        [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.connectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        [self.connectButton addTarget:self action:@selector(connectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttonCell.contentView addSubview:self.connectButton];
        return buttonCell;
    } else {
        // 查看日志 cell
        UITableViewCell *logCell = [tableView dequeueReusableCellWithIdentifier:@"LogCell" forIndexPath:indexPath];
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 12, 200, 20)];
        titleLabel.text = @"查看连接日志";
        titleLabel.font = [UIFont systemFontOfSize:16];
        titleLabel.textColor = [UIColor systemBlueColor];
        [logCell.contentView addSubview:titleLabel];
        logCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return logCell;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return 50;
    } else if (indexPath.section == 1) {
        return 44;
    } else if (indexPath.section == 2) {
        return 60;
    } else {
        return 44;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 3) {
        // 点击查看日志
        [self showPacketTunnelLog];
    }
}

- (void)showPacketTunnelLog {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *logURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];

    NSString *log = [NSString stringWithContentsOfFile:logURL.path encoding:NSUTF8StringEncoding error:nil];
    if (!log || log.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"日志为空" message:@"还没有生成任何日志，请先尝试连接一次 VPN" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"PacketTunnel 日志" message:log preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIPasteboard.generalPasteboard.string = log;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除日志" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [@"" writeToFile:logURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
