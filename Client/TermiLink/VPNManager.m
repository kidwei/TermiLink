#import "VPNManager.h"

@interface VPNManager ()

@property (nonatomic, strong) NETunnelProviderManager *manager;
@property (nonatomic, assign, readwrite) BOOL isConnected;
@property (nonatomic, copy, readwrite) NSString *statusText;

@end

@implementation VPNManager

+ (instancetype)sharedManager {
    static VPNManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VPNManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isConnected = NO;
        _statusText = @"未连接";
        _manager = [[NETunnelProviderManager alloc] init];

        [self loadConfiguration];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(vpnStatusDidChange:)
                                                     name:NEVPNStatusDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)loadConfiguration {
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable error) {
        if (error) {
            NSLog(@"⚠️ 加载配置出错: %@", error);
            return;
        }

        if (managers && managers.count > 0) {
            self.manager = managers.firstObject;
            [self.manager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                if (!error) {
                    [self updateStatus:self.manager.connection.status];
                }
            }];
        }
    }];
}

- (void)startVPNWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion {
    self.manager.localizedDescription = @"TermiLink VPN";

    NETunnelProviderProtocol *proto = [[NETunnelProviderProtocol alloc] init];
    proto.providerBundleIdentifier = @"com.kidwei.vpntool.PacketTunnel";
    proto.serverAddress = serverIP;

    self.manager.protocolConfiguration = proto;
    self.manager.enabled = YES;

    [self.manager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            completion(error);
            return;
        }

        [self.manager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                completion(error);
                return;
            }

            NSError *startError = nil;
            [self.manager.connection startVPNTunnelAndReturnError:&startError];
            completion(startError);
        }];
    }];
}

- (void)stopVPN {
    [self.manager.connection stopVPNTunnel];
}

- (void)vpnStatusDidChange:(NSNotification *)notification {
    NEVPNConnection *connection = notification.object;
    [self updateStatus:connection.status];
}

- (void)updateStatus:(NEVPNStatus)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case NEVPNStatusConnected:
                self.isConnected = YES;
                self.statusText = @"已连接";
                break;

            case NEVPNStatusConnecting:
                self.isConnected = NO;
                self.statusText = @"正在连接...";
                break;

            case NEVPNStatusDisconnected:
                self.isConnected = NO;
                self.statusText = @"已断开";
                break;

            case NEVPNStatusDisconnecting:
                self.isConnected = NO;
                self.statusText = @"正在断开...";
                break;

            default:
                self.isConnected = NO;
                self.statusText = @"未知状态";
                break;
        }

        // 发送通知让 UI 更新
        [[NSNotificationCenter defaultCenter] postNotificationName:@"VPNStatusChanged" object:nil];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
