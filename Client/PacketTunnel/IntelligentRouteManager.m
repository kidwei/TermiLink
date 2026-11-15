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
    // 全局代理模式：所有流量都走 VPN
    return YES;
}

- (void)checkAndUpdateRouteForIP:(NSString *)ip
       tunnelProvider:(NEPacketTunnelProvider *)provider
       completion:(void (^)(BOOL needsUpdate, NEPacketTunnelNetworkSettings *newSettings))completion {
    // 全局代理模式：不需要动态检测和更新路由，初始就是全局路由
    completion(NO, nil);
}

- (NEPacketTunnelNetworkSettings *)generateUpdatedSettingsWithTunnelAddress:(NSString *)tunnelAddress {
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:tunnelAddress];

    // IPv4 设置：客户端虚拟地址
    NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.168.50.2"] subnetMasks:@[@"255.255.255.0"]];

    // 全局代理模式：所有流量都走 VPN
    // includedRoutes = 0.0.0.0/0 表示全部流量进隧道
    ipv4Settings.includedRoutes = @[[NEIPv4Route defaultRoute]];

    // 排除列表：
    // 1. VPN 服务器自身 IP → 必须排除，否则与服务器的连接会回环进隧道导致死循环
    // 2. 本地回环
    NSMutableArray<NEIPv4Route *> *excludedRoutes = [[NSMutableArray alloc] init];
    if (tunnelAddress.length > 0) {
        [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:tunnelAddress subnetMask:@"255.255.255.255"]];
    }
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"127.0.0.0" subnetMask:@"255.0.0.0"]];
    ipv4Settings.excludedRoutes = excludedRoutes;

    settings.IPv4Settings = ipv4Settings;

    // 隧道内 MTU 需小于外层 TLS 路径 MTU，否则大包被丢弃，表现为小请求正常、流式/大响应卡死。
    settings.MTU = @1280;

    // DNS 设置
    settings.DNSSettings = [[NEDNSSettings alloc] initWithServers:@[@"8.8.8.8", @"1.1.1.1"]];

    return settings;
}

- (NEPacketTunnelNetworkSettings *)generateSplitTunnelSettingsWithTunnelAddress:(NSString *)tunnelAddress
                                                                destinationIPs:(NSArray<NSString *> *)destinationIPs
                                                                       domains:(NSArray<NSString *> *)domains {
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:tunnelAddress];
    NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"192.168.50.2"] subnetMasks:@[@"255.255.255.0"]];

    // 目标 IP 会随 Cloudflare 轮换，仅靠启动时解析的 /32 会漏；因此同时纳入 OpenAI 使用的 Cloudflare 网段。
    NSMutableOrderedSet<NSString *> *routedIPs = [NSMutableOrderedSet orderedSetWithArray:destinationIPs];
    [routedIPs addObject:@"8.8.8.8"];
    [routedIPs addObject:@"1.1.1.1"];
    NSMutableArray<NEIPv4Route *> *includedRoutes = [NSMutableArray array];
    NSArray<NSArray<NSString *> *> *cloudflareRanges = @[
        @[@"104.16.0.0", @"255.240.0.0"],
        @[@"172.64.0.0", @"255.248.0.0"],
        @[@"162.159.0.0", @"255.255.0.0"]
    ];
    for (NSArray<NSString *> *range in cloudflareRanges) {
        [includedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:range[0] subnetMask:range[1]]];
    }
    for (NSString *ip in routedIPs) {
        [includedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:ip subnetMask:@"255.255.255.255"]];
    }
    ipv4Settings.includedRoutes = includedRoutes;

    NSMutableArray<NEIPv4Route *> *excludedRoutes = [NSMutableArray array];
    if (tunnelAddress.length > 0) {
        [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:tunnelAddress subnetMask:@"255.255.255.255"]];
    }
    [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:@"127.0.0.0" subnetMask:@"255.0.0.0"]];
    ipv4Settings.excludedRoutes = excludedRoutes;
    settings.IPv4Settings = ipv4Settings;

    // IPv6 会绕过 IPv4 隧道导致直连被墙，这里把 Cloudflare 的 IPv6 段也接管；
    // 扩展端会丢弃这些 IPv6 包，让系统回退到 IPv4 走隧道。
    NEIPv6Settings *ipv6Settings = [[NEIPv6Settings alloc] initWithAddresses:@[@"fd00:1234:5678::2"]
                                                          networkPrefixLengths:@[@(64)]];
    ipv6Settings.includedRoutes = @[
        [[NEIPv6Route alloc] initWithDestinationAddress:@"2606:4700::" networkPrefixLength:@(32)],
        [[NEIPv6Route alloc] initWithDestinationAddress:@"2a06:98c0::" networkPrefixLength:@(29)]
    ];
    settings.IPv6Settings = ipv6Settings;

    // 隧道内 MTU 需小于外层 TLS 路径 MTU，否则大包被丢弃，表现为小请求正常、流式/大响应卡死。
    settings.MTU = @1280;

    // matchDomains 非空时不会替换系统默认 DNS，仅加速域名的解析走隧道。
    NEDNSSettings *dnsSettings = [[NEDNSSettings alloc] initWithServers:@[@"8.8.8.8", @"1.1.1.1"]];
    dnsSettings.matchDomains = domains;
    dnsSettings.matchDomainsNoSearch = YES;
    settings.DNSSettings = dnsSettings;
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
