#import "IntelligentRouteManager.h"
#import "ReachabilityDetector.h"

@implementation IntelligentRouteManager {
    NSMutableDictionary<NSString *, NSDate *> *_cacheTimestamps;
}

+ (instancetype)sharedManager {
    static IntelligentRouteManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[IntelligentRouteManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reachableIPs = [[NSMutableSet alloc] init];
        _unreachableIPs = [[NSMutableSet alloc] init];
        _cacheTimestamps = [[NSMutableDictionary alloc] init];

        // 默认将内网地址标记为可直接访问
        // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
        // 这些都是内网地址，本来就不需要走 VPN
        [self addPrivateNetworksToReachable];
    }
    return self;
}

- (void)addPrivateNetworksToReachable {
    // 内网 IP 段默认不走 VPN
    // 在设置路由时会排除这些网段
    // 这里不用添加单个 IP，后面路由生成的时候处理
}

- (BOOL)shouldRouteThroughVPNForDestinationIP:(NSString *)ip {
    // 如果在缓存中已经标记可达 → 不走 VPN
    if ([_reachableIPs containsObject:ip]) {
        return NO;
    }
    // 如果已经标记不可达 → 走 VPN
    if ([_unreachableIPs containsObject:ip]) {
        return YES;
    }
    // 未检测过 → 先走 VPN 同时异步检测
    return YES;
}

- (void)checkAndUpdateRouteForIP:(NSString *)ip
       tunnelProvider:(NEPacketTunnelProvider *)provider
       completion:(void (^)(BOOL needsUpdate, NEPacketTunnelNetworkSettings *newSettings))completion {

    // 如果已经检测过，且缓存没过期 → 不用重新检测
    NSDate *cachedTime = _cacheTimestamps[ip];
    if (cachedTime && -cachedTime.timeIntervalSinceNow < 300) { // 缓存 5 分钟
        // 缓存有效，不需要更新设置
        completion(NO, nil);
        return;
    }

    [[ReachabilityDetector sharedDetector] checkReachabilityForIP:ip timeout:2.0 completion:^(BOOL isReachable) {
        BOOL needsUpdate = NO;

        if (isReachable) {
            if (![_reachableIPs containsObject:ip]) {
                [_reachableIPs addObject:ip];
                [_unreachableIPs removeObject:ip];
                needsUpdate = YES;
            }
        } else {
            if (![_unreachableIPs containsObject:ip]) {
                [_unreachableIPs addObject:ip];
                [_reachableIPs removeObject:ip];
                needsUpdate = YES;
            }
        }

        // 更新缓存时间
        _cacheTimestamps[ip] = [NSDate date];

        if (needsUpdate) {
            NSString *tunnelAddress = ((NETunnelProviderProtocol *)provider.protocolConfiguration).serverAddress;
            NEPacketTunnelNetworkSettings *newSettings = [self generateUpdatedSettingsWithTunnelAddress:tunnelAddress];
            completion(YES, newSettings);
        } else {
            completion(NO, nil);
        }
    }];
}

- (NEPacketTunnelNetworkSettings *)generateUpdatedSettingsWithTunnelAddress:(NSString *)tunnelAddress {
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:tunnelAddress];

    // IPv4 设置：客户端虚拟地址
    NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.168.50.2"] subnetMasks:@[@"255.255.255.0"]];

    // 智能分割隧道策略：
    // 1. 默认不包含任何路由（所有流量走本地）
    // 2. 只把检测不可达的（需要走 VPN 的）添加到 includedRoutes
    // 3. 把所有内网和检测可达的排除

    NSMutableArray<NEIPv4Route *> *includedRoutes = [[NSMutableArray alloc] init];

    // 将所有确认不可达的 /32 路由添加到包含列表 → 只有这些走 VPN
    for (NSString *ip in _unreachableIPs) {
        NEIPv4Route *route = [[NEIPv4Route alloc] initWithDestinationAddress:ip subnetMask:@"255.255.255.255"];
        [includedRoutes addObject:route];
    }

    ipv4Settings.includedRoutes = includedRoutes;

    // 排除列表：所有内网网段 + 确认可达的 IP
    NSMutableArray<NEIPv4Route *> *excludedRoutes = [[NSMutableArray alloc] init];

    // 私有内网地址段 → 始终不走 VPN
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"10.0.0.0" subnetMask:@"255.0.0.0"]];
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"172.16.0.0" subnetMask:@"240.0.0.0"]];
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"192.168.0.0" subnetMask:@"255.255.0.0"]];
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"127.0.0.0" subnetMask:@"255.0.0.0"]];

    // 添加已检测为可达的 IP 作为排除 → 不走 VPN
    for (NSString *ip in _reachableIPs) {
        NEIPv4Route *route = [[NEIPv4Route alloc] initWithDestinationAddress:ip subnetMask:@"255.255.255.255"];
        [excludedRoutes addObject:route];
    }

    ipv4Settings.excludedRoutes = excludedRoutes;
    settings.IPv4Settings = ipv4Settings;

    // DNS 设置
    settings.DNSSettings = [[NEDNSSettings alloc] initWithServers:@[@"8.8.8.8", @"1.1.1.1"]];

    return settings;
}

- (void)cleanupExpiredCache {
    // 清理超过 1 小时未访问的缓存
    NSTimeInterval maxAge = 3600;
    NSMutableArray<NSString *> *toRemove = [[NSMutableArray alloc] init];

    [_cacheTimestamps enumerateKeysAndObjectsUsingBlock:^(NSString *ip, NSDate *timestamp, BOOL *stop) {
        if (-timestamp.timeIntervalSinceNow > maxAge) {
            [toRemove addObject:ip];
        }
    }];

    for (NSString *ip in toRemove) {
        [_cacheTimestamps removeObjectForKey:ip];
        [_reachableIPs removeObject:ip];
        [_unreachableIPs removeObject:ip];
    }
}

@end
