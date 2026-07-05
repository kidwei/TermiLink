#import "VPNManager.h"

static NSString *PacketTunnelBundleIdentifier(void) {
#if TARGET_OS_OSX
    return @"com.kidwei.vpntool.mac.PacketTunnel";
#else
    return @"com.kidwei.vpntool.PacketTunnel";
#endif
}

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

- (void)startVPNWithServerIP:(NSString *)serverIP port:(NSInteger)port completion:(void (^)(NSError * _Nullable))completion {
    NSDictionary *providerConfig = @{@"port": @(port)};

    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable loadError) {
        if (loadError) {
            completion(loadError);
            return;
        }

        NETunnelProviderManager *existingManager = nil;
        if (managers && managers.count > 0) {
            for (NETunnelProviderManager *manager in managers) {
                if ([manager.localizedDescription isEqualToString:@"TermiLink VPN"]) {
                    existingManager = manager;
                    break;
                }
            }
        }

        if (existingManager) {
            self.manager = existingManager;
            NETunnelProviderProtocol *proto = (NETunnelProviderProtocol *)existingManager.protocolConfiguration;
            if (!proto) {
                proto = [[NETunnelProviderProtocol alloc] init];
                proto.providerBundleIdentifier = PacketTunnelBundleIdentifier();
            }
            proto.serverAddress = serverIP;
            proto.providerConfiguration = providerConfig;
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
            [self createNewConfigurationWithServerIP:serverIP providerConfig:providerConfig completion:completion];
        }
    }];
}

- (void)createNewConfigurationWithServerIP:(NSString *)serverIP providerConfig:(NSDictionary *)providerConfig completion:(void (^)(NSError * _Nullable))completion {
    NETunnelProviderManager *newManager = [[NETunnelProviderManager alloc] init];
    newManager.localizedDescription = @"TermiLink VPN";

    NETunnelProviderProtocol *proto = [[NETunnelProviderProtocol alloc] init];
    proto.providerBundleIdentifier = PacketTunnelBundleIdentifier();
    proto.serverAddress = serverIP;
    proto.providerConfiguration = providerConfig;

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

        [[NSNotificationCenter defaultCenter] postNotificationName:@"VPNStatusChanged" object:nil];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
