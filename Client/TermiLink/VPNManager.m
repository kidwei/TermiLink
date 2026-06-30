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
    // 先加载已有配置
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable loadError) {
        if (loadError) {
            completion(loadError);
            return;
        }

        NETunnelProviderManager *existingManager = nil;
        if (managers && managers.count > 0) {
            // 找到已有的 TermiLink 配置，复用它
            for (NETunnelProviderManager *manager in managers) {
                if ([manager.localizedDescription isEqualToString:@"TermiLink VPN"]) {
                    existingManager = manager;
                    break;
                }
            }
        }

        if (existingManager) {
            // 使用已有配置，只更新 IP 地址
            self.manager = existingManager;
            NETunnelProviderProtocol *proto = (NETunnelProviderProtocol *)existingManager.protocolConfiguration;
            if (!proto) {
                proto = [[NETunnelProviderProtocol alloc] init];
                proto.providerBundleIdentifier = @"com.kidwei.vpntool.PacketTunnel";
            }
            proto.serverAddress = serverIP;
            existingManager.protocolConfiguration = proto;
            existingManager.enabled = YES;

            [existingManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                if (error) {
                    completion(error);
                    return;
                }
                [existingManager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                    if (error) {
                        completion(error);
                        return;
                    }
                    NSError *startError = nil;
                    [existingManager.connection startVPNTunnelAndReturnError:&startError];
                    completion(startError);
                }];
            }];
        } else {
            // 没有配置，创建新的
            [self createNewConfigurationWithServerIP:serverIP completion:completion];
        }
    }];
}

- (void)createNewConfigurationWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion {
    // 创建全新的配置
    NETunnelProviderManager *newManager = [[NETunnelProviderManager alloc] init];
    newManager.localizedDescription = @"TermiLink VPN";

    NETunnelProviderProtocol *proto = [[NETunnelProviderProtocol alloc] init];
    proto.providerBundleIdentifier = @"com.kidwei.vpntool.PacketTunnel";
    proto.serverAddress = serverIP;

    newManager.protocolConfiguration = proto;
    newManager.enabled = YES;
    self.manager = newManager;

    [newManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            completion(error);
            return;
        }

        [newManager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                completion(error);
                return;
            }

            NSError *startError = nil;
            [newManager.connection startVPNTunnelAndReturnError:&startError];
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
