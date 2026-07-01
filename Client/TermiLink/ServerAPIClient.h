#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ServerAPIClient : NSObject

+ (instancetype)sharedClient;

/**
 * 调用 /api/start_server 启动服务端 VPN 服务
 * @param serverIP 服务器 IP
 * @param completion 成功 error 为 nil，失败带 error
 */
- (void)startServerWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion;

/**
 * 调用 /api/stop_server 停止服务端 VPN 服务
 */
- (void)stopServerWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion;

@end

NS_ASSUME_NONNULL_END
