#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

@interface IntelligentRouteManager : NSObject

@property (nonatomic, strong, readonly) NSMutableSet<NSString *> *reachableIPs;    // 可直接访问，走本地
@property (nonatomic, strong, readonly) NSMutableSet<NSString *> *unreachableIPs;  // 不可直接访问，走 VPN

+ (instancetype)sharedManager;

/**
 * 处理一个出站 IP 包，智能判断是否需要走 VPN
 * @return YES = 需要走 VPN, NO = 可直接访问，可以让系统路由处理
 */
- (BOOL)shouldRouteThroughVPNForDestinationIP:(NSString *)ip;

/**
 * 异步检测 IP 可达性并更新路由
 */
- (void)checkAndUpdateRouteForIP:(NSString *)ip
       tunnelProvider:(NEPacketTunnelProvider *)provider
       completion:(void (^)(BOOL needsUpdate, NEPacketTunnelNetworkSettings *newSettings))completion;

/**
 * 根据当前检测结果生成新的网络设置
 */
- (NEPacketTunnelNetworkSettings *)generateUpdatedSettingsWithTunnelAddress:(NSString *)tunnelAddress;

/**
 * 清理过期缓存（定期调用）
 */
- (void)cleanupExpiredCache;

@end

NS_ASSUME_NONNULL_END
