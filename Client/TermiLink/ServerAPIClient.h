#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ServerAPIClient : NSObject

+ (instancetype)sharedClient;

/**
 * 调用 /api/get_serv_list 获取可连接的服务器列表（来自服务端 config.json）。
 * 控制接口固定连接写死的管理 IP。
 * @param completion servers 每项含 name / ip / port；失败时 error 带错误信息。
 */
- (void)getServerListWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable servers, NSError * _Nullable error))completion;

/**
 * 调用 /api/start_server 启动服务端 VPN 服务。
 * 控制接口固定连接写死的管理 IP，与用户选择的 VPN 服务器无关。
 * @param completion 成功时 error 为 nil，失败时带 error。
 */
- (void)startServerWithCompletion:(void (^)(NSError * _Nullable))completion;

/**
 * 调用 /api/stop_server 停止服务端 VPN 服务
 */
- (void)stopServerWithCompletion:(void (^)(NSError * _Nullable))completion;

@end

NS_ASSUME_NONNULL_END
