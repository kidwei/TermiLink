#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPNManager : NSObject

@property (nonatomic, assign, readonly) BOOL isConnected;
@property (nonatomic, copy, readonly) NSString *statusText;

/// 需要通过 VPN 加速的域名列表；为空数组或 nil 时表示全局模式。
@property (nonatomic, copy, nullable) NSArray<NSString *> *acceleratedDomains;

+ (instancetype)sharedManager;

- (void)startVPNWithServerIP:(NSString *)serverIP port:(NSInteger)port completion:(void (^)(NSError * _Nullable))completion;
- (void)stopVPN;

@end

NS_ASSUME_NONNULL_END
