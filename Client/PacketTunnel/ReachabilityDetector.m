#import "ReachabilityDetector.h"

@implementation ReachabilityDetector

+ (instancetype)sharedDetector {
    static ReachabilityDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ReachabilityDetector alloc] init];
    });
    return shared;
}

- (void)checkReachabilityForIP:(NSString *)ip timeout:(NSTimeInterval)timeout completion:(ReachabilityCompletion)completion {
    // 使用普通的 TCP 连接检测来判断是否可达
    // 直接走本地默认路由，不走 VPN 接口

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        // 创建 socket 并设置非阻塞
        int sockfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sockfd < 0) {
            completion(NO);
            return;
        }

        // 设置非阻塞模式
        fcntl(sockfd, F_SETFL, O_NONBLOCK);

        // 解析 IP
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        inet_pton(AF_INET, [ip UTF8String], &addr.sin_addr);
        addr.sin_port = htons(80); // 探测 80 端口，一般都是开放的

        // 开始连接
        int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
        if (result == 0) {
            // 连接立即成功 - 可达
            close(sockfd);
            completion(YES);
            return;
        }

        if (errno != EINPROGRESS) {
            // 连接失败 - 不可达
            close(sockfd);
            completion(NO);
            return;
        }

        // 使用 select 等待连接完成或超时
        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(sockfd, &writeSet);

        struct timeval tv;
        tv.tv_sec = (int)timeout;
        tv.tv_usec = (timeout - tv.tv_sec) * 1000000;

        result = select(sockfd + 1, NULL, &writeSet, NULL, &tv);
        if (result > 0 && FD_ISSET(sockfd, &writeSet)) {
            // 连接成功 - 可达
            close(sockfd);
            completion(YES);
        } else {
            // 超时或错误 - 不可达
            close(sockfd);
            completion(NO);
        }
    });
}

- (void)checkReachabilityForIPs:(NSArray<NSString *> *)ips completion:(void (^)(NSDictionary<NSString *, NSNumber *> *))completion {
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *results = [[NSMutableDictionary alloc] init];

    for (NSString *ip in ips) {
        dispatch_group_enter(group);
        [self checkReachabilityForIP:ip timeout:2.0 completion:^(BOOL isReachable) {
            @synchronized(results) {
                results[ip] = @(isReachable);
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion([results copy]);
    });
}

@end
