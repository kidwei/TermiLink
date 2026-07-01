#import "ServerAPIClient.h"

// 与服务端 FastAPI 控制接口对应的配置
static NSInteger const kAPIPort = 8000;              // FastAPI 控制接口端口
static NSString * const kAdminToken = @"zhaowei1111"; // 必须与服务器 ADMIN_TOKEN 一致

@implementation ServerAPIClient

+ (instancetype)sharedClient {
    static ServerAPIClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ServerAPIClient alloc] init];
    });
    return shared;
}

- (void)startServerWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion {
    [self requestPath:@"/api/start_server" serverIP:serverIP completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(error);
            return;
        }
        // 服务端返回 { "running": true, ... } 表示启动成功
        if (![json[@"running"] boolValue]) {
            NSError *notRunningError = [NSError errorWithDomain:@"ServerAPIClient" code:-100 userInfo:@{
                NSLocalizedDescriptionKey: @"服务端 VPN 服务未能启动"
            }];
            completion(notRunningError);
            return;
        }
        completion(nil);
    }];
}

- (void)stopServerWithServerIP:(NSString *)serverIP completion:(void (^)(NSError * _Nullable))completion {
    [self requestPath:@"/api/stop_server" serverIP:serverIP completion:^(NSDictionary *json, NSError *error) {
        completion(error);
    }];
}

#pragma mark - 内部方法

// 统一发起 POST 请求，鉴权方式：Authorization: Bearer {ADMIN_TOKEN}
- (void)requestPath:(NSString *)path
           serverIP:(NSString *)serverIP
         completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {

    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@", serverIP, (long)kAPIPort, path];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *urlError = [NSError errorWithDomain:@"ServerAPIClient" code:-101 userInfo:@{
            NSLocalizedDescriptionKey: @"无效的服务器地址"
        }];
        completion(nil, urlError);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    // 鉴权头：Bearer ADMIN_TOKEN
    [request setValue:[NSString stringWithFormat:@"Bearer %@", kAdminToken] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSError *httpError = [NSError errorWithDomain:@"ServerAPIClient" code:httpResponse.statusCode userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"接口返回 HTTP %ld: %@", (long)httpResponse.statusCode, body]
            }];
            completion(nil, httpError);
            return;
        }

        NSDictionary *json = nil;
        if (data.length > 0) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        completion(json ?: @{}, nil);
    }];

    [task resume];
}

@end
