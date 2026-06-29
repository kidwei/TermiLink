#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ReachabilityCompletion)(BOOL isReachable);

@interface ReachabilityDetector : NSObject

+ (instancetype)sharedDetector;

/**
 * 检测指定 IP 是否可以直接访问（不走 VPN）
 * @param ip 目标 IP 地址
 * @param timeout 超时时间（秒）
 * @param completion 回调 YES=可直接访问，NO=不可访问，需要走 VPN
 */
- (void)checkReachabilityForIP:(NSString *)ip timeout:(NSTimeInterval)timeout completion:(ReachabilityCompletion)completion;

/**
 * 检测一批 IP，全部完成后回调
 */
- (void)checkReachabilityForIPs:(NSArray<NSString *> *)ips completion:(void (^)(NSDictionary<NSString *, NSNumber *> *results))completion;

@end

NS_ASSUME_NONNULL_END
