#import "ServerAPIClient.h"

static NSString * const kControlServerIP = @"129.226.94.203";
static NSInteger const kAPIPort = 8000;
static NSString * const kAdminToken = @"zhaowei1111";

@implementation ServerAPIClient

+ (instancetype)sharedClient {
    static ServerAPIClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ServerAPIClient alloc] init];
    });
    return shared;
}

- (void)getServerListWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable servers, NSError * _Nullable error))completion {
    [self requestPath:@"/api/get_serv_list" method:@"GET" completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *servers = [json[@"servers"] isKindOfClass:[NSArray class]] ? json[@"servers"] : @[];
        completion(servers, nil);
    }];
}

- (void)startServerWithCompletion:(void (^)(NSError * _Nullable))completion {
    [self requestPath:@"/api/start_server" method:@"POST" completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(error);
            return;
        }
        if (![json[@"running"] boolValue]) {
            // 服务端返回的 message 已包含失败原因（如端口占用、证书缺失），原样展示给用户。
            NSString *reason = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil;
            NSString *description = reason.length > 0
                ? [NSString stringWithFormat:@"服务端 VPN 服务未能启动：%@", reason]
                : @"服务端 VPN 服务未能启动（控制接口未返回原因，请查看服务端日志）";
            NSError *notRunningError = [NSError errorWithDomain:@"ServerAPIClient" code:-100 userInfo:@{
                NSLocalizedDescriptionKey: description
            }];
            completion(notRunningError);
            return;
        }
        completion(nil);
    }];
}

- (void)stopServerWithCompletion:(void (^)(NSError * _Nullable))completion {
    [self requestPath:@"/api/stop_server" method:@"POST" completion:^(NSDictionary *json, NSError *error) {
        completion(error);
    }];
}

- (void)requestPath:(NSString *)path
             method:(NSString *)method
         completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {

    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@", kControlServerIP, (long)kAPIPort, path];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *urlError = [NSError errorWithDomain:@"ServerAPIClient" code:-101 userInfo:@{
            NSLocalizedDescriptionKey: @"无效的服务器地址"
        }];
        completion(nil, urlError);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 15;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", kAdminToken] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSError *requestError = [NSError errorWithDomain:@"ServerAPIClient" code:error.code userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法连接控制接口 %@：%@", urlString, error.localizedDescription],
                NSUnderlyingErrorKey: error
            }];
            completion(nil, requestError);
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
