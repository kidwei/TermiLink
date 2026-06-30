#import "ViewController.h"
#import "VPNManager.h"

@interface ViewController () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *serverIPTextField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"TermiLink";
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
        [manager stopVPN];
        return;
    }

    NSString *serverIP = self.serverIPTextField.text;
    if (serverIP.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"请输入服务器 IP 地址" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [manager startVPNWithServerIP:serverIP completion:^(NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"连接失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        }
    }];
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
    return 3;
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
    } else {
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
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return 50;
    } else if (indexPath.section == 1) {
        return 44;
    } else {
        return 60;
    }
}

@end
