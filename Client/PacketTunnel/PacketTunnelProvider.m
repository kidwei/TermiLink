#import "PacketTunnelProvider.h"
#import "IntelligentRouteManager.h"
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <pwd.h>
#import <unistd.h>

#if TARGET_OS_OSX
// 沙盒下 NSHomeDirectory() 会指向扩展容器，这里取真实用户目录以便与主程序共享日志。
static NSString *TermiLinkRealHomeDirectory(void) {
    struct passwd *pw = getpwuid(getuid());
    return pw ? [NSString stringWithUTF8String:pw->pw_dir] : NSHomeDirectory();
}
#endif

// 文件日志帮助函数
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // 同时输出到系统日志
    NSLog(@"%@", message);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *logURL = nil;
#if TARGET_OS_OSX
    // macOS 主程序与扩展通过沙盒临时例外共用真实用户目录，避免 App Group 容器写不进去。
    NSString *logDirectory = [TermiLinkRealHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TermiLink"];
    NSError *directoryError = nil;
    if (![fm createDirectoryAtPath:logDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        NSLog(@"❌ [PacketTunnel] 创建日志目录失败: %@", directoryError);
        return;
    }
    logURL = [NSURL fileURLWithPath:[logDirectory stringByAppendingPathComponent:@"packettunnel.log"]];
#else
    logURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];
#endif
    if (!logURL) {
        return;
    }

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];

    // 追加写入
    if ([fm fileExistsAtPath:logURL.path]) {
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
        [file seekToEndOfFile];
        [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    } else {
        [line writeToFile:logURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

@implementation PacketTunnelProvider {
    nw_connection_t _connection;       // Network.framework 连接
    dispatch_queue_t _connectionQueue; // 连接专用队列
    NSMutableData *_readBuffer;        // 读缓冲区
    void (^_pendingCompletion)(NSError * _Nullable);
    BOOL _authenticated;               // 是否已完成鉴权
    NSArray<NSString *> *_routedDestinationIPs;  // 当前已写入路由的目标 IP
    dispatch_source_t _routeRefreshTimer;        // 定时刷新路由，应对 DNS 轮换
    NSString *_serverHost;             // 当前服务器，用于切换分流路由
    NSArray<NSString *> *_acceleratedDomains; // 非空表示按目的地分流
}

- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    WriteLog(@"✅ [PacketTunnel] 开始启动 VPN 隧道（智能分割隧道模式）");

    NSString *serverHost = [[self protocolConfiguration] serverAddress];
    WriteLog(@"📝 [PacketTunnel] 服务器地址: %@", serverHost);

    // 端口由 App 通过 providerConfiguration 传入，默认 10011
    NETunnelProviderProtocol *proto = (NETunnelProviderProtocol *)[self protocolConfiguration];
    NSNumber *portNumber = proto.providerConfiguration[@"port"];
    NSString *serverPort = portNumber ? [portNumber stringValue] : @"10011";
    WriteLog(@"📝 [PacketTunnel] 服务器端口: %@", serverPort);

    _serverHost = [serverHost copy];
    NSArray *configuredDomains = proto.providerConfiguration[@"acceleratedDomains"];
    _acceleratedDomains = [configuredDomains isKindOfClass:[NSArray class]] ? [configuredDomains copy] : @[];
    WriteLog(@"📝 [PacketTunnel] 路由模式: %@", _acceleratedDomains.count > 0 ? [NSString stringWithFormat:@"按目的地分流（%lu 个域名）", (unsigned long)_acceleratedDomains.count] : @"全局");

    // 分流模式也需要先用全局路由完成 bootstrap DNS 解析，鉴权后立即切换为指定 IP 路由。
    NEPacketTunnelNetworkSettings *initialSettings = [[IntelligentRouteManager sharedManager] generateUpdatedSettingsWithTunnelAddress:serverHost];

    __weak PacketTunnelProvider *weakSelf = self;
    [self setTunnelNetworkSettings:initialSettings completionHandler:^(NSError *error) {
        if (error) {
            WriteLog(@"❌ [PacketTunnel] 设置虚拟网卡失败: %@ (code: %ld)", error, (long)error.code);
            completionHandler(error);
            return;
        }

        WriteLog(@"✅ [PacketTunnel] 虚拟网卡配置完成，开始连接服务器");

        __strong PacketTunnelProvider *strongSelf = weakSelf;
        if (strongSelf){
            strongSelf->_readBuffer = [[NSMutableData alloc] init];
            strongSelf->_pendingCompletion = completionHandler;
            strongSelf->_authenticated = NO;
            strongSelf->_connectionQueue = dispatch_queue_create("com.kidwei.vpntool.connection", DISPATCH_QUEUE_SERIAL);
            
            [strongSelf connectToServer:serverHost port:serverPort];
        }
    }];
}

- (void)connectToServer:(NSString *)host port:(NSString *)port {
    // 创建 endpoint
    nw_endpoint_t endpoint = nw_endpoint_create_host([host UTF8String], [port UTF8String]);

    // 创建参数：TLS + TCP，并且在 TLS 配置中跳过证书验证
    nw_parameters_configure_protocol_block_t tlsConfig = ^(nw_protocol_options_t tlsOptions) {
        sec_protocol_options_t secOptions = nw_tls_copy_sec_protocol_options(tlsOptions);
        // 设置 verify block，直接信任所有证书（允许自签名）
        sec_protocol_options_set_verify_block(secOptions, ^(sec_protocol_metadata_t metadata,
                                                            sec_trust_t trust_ref,
                                                            sec_protocol_verify_complete_t complete) {
            WriteLog(@"📝 [PacketTunnel] TLS 证书验证回调 - 直接信任");
            complete(true); // 信任所有证书
        }, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    };

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(tlsConfig, NW_PARAMETERS_DEFAULT_CONFIGURATION);

    // 创建连接
    _connection = nw_connection_create(endpoint, parameters);
    nw_connection_set_queue(_connection, _connectionQueue);

    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        switch (state) {
            case nw_connection_state_invalid:
                WriteLog(@"📝 [PacketTunnel] 连接状态: invalid");
                break;
            case nw_connection_state_waiting:
                WriteLog(@"📝 [PacketTunnel] 连接状态: waiting, error: %@", error);
                break;
            case nw_connection_state_preparing:
                WriteLog(@"📝 [PacketTunnel] 连接状态: preparing (TCP连接+TLS握手中)");
                break;
            case nw_connection_state_ready:
                WriteLog(@"✅ [PacketTunnel] 连接状态: ready (TLS 握手完成!)");
                if (!strongSelf->_authenticated) {
                    [strongSelf doAuthentication];
                }
                break;
            case nw_connection_state_failed: {
                WriteLog(@"❌ [PacketTunnel] 连接状态: failed, error: %@", error);
                NSError *err = [NSError errorWithDomain:@"PacketTunnel" code:-2 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"连接失败: %@", error]
                }];
                [strongSelf failTunnelWithError:err];
                break;
            }
            case nw_connection_state_cancelled:
                WriteLog(@"🚫 [PacketTunnel] 连接状态: cancelled");
                break;
            default:
                break;
        }
    });

    WriteLog(@"📝 [PacketTunnel] 启动 TLS 连接 %@:%@", host, port);
    nw_connection_start(_connection);

    // 20 秒超时保护
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_pendingCompletion && !strongSelf->_authenticated) {
            WriteLog(@"⏰ [PacketTunnel] 连接超时");
            NSError *timeoutError = [NSError errorWithDomain:@"PacketTunnel" code:-1 userInfo:@{
                NSLocalizedDescriptionKey: @"连接服务器超时"
            }];
            strongSelf->_pendingCompletion(timeoutError);
            strongSelf->_pendingCompletion = nil;
            nw_connection_cancel(strongSelf->_connection);
        }
    });
}

- (void)doAuthentication {
    WriteLog(@"✅ [PacketTunnel] 开始鉴权");

    // 鉴权协议: [2字节魔数 "AH"][2字节token长度][token数据]
    NSString *token = [[NSProcessInfo processInfo] environment][@"TERMILINK_AUTH_TOKEN"];
    if (!token || token.length == 0) {
        token = @"kidwei123456";
    }
    WriteLog(@"📝 [PacketTunnel] token 长度: %lu", (unsigned long)token.length);

    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t magic = CFSwapInt16HostToBig((uint16_t)0x4148);
    uint16_t tokenLength = CFSwapInt16HostToBig((uint16_t)tokenData.length);

    NSMutableData *authPacket = [[NSMutableData alloc] init];
    [authPacket appendBytes:&magic length:2];
    [authPacket appendBytes:&tokenLength length:2];
    [authPacket appendData:tokenData];

    // 发送鉴权包
    dispatch_data_t sendData = dispatch_data_create([authPacket bytes], [authPacket length],
                                                     _connectionQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __weak typeof(self) weakSelf = self;
    nw_connection_send(_connection, sendData, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            WriteLog(@"❌ [PacketTunnel] 发送鉴权失败: %@", error);
            if (strongSelf->_pendingCompletion) {
                NSError *err = [NSError errorWithDomain:@"PacketTunnel" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"发送鉴权失败"}];
                strongSelf->_pendingCompletion(err);
                strongSelf->_pendingCompletion = nil;
            }
            return;
        }
        WriteLog(@"✅ [PacketTunnel] 鉴权包已发送，等待响应");
        [strongSelf receiveAuthResponse];
    });
}

- (void)receiveAuthResponse {
    __weak typeof(self) weakSelf = self;
    // 读取 2 字节响应
    nw_connection_receive(_connection, 2, 2, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            WriteLog(@"❌ [PacketTunnel] 接收鉴权响应失败: %@", error);
            if (strongSelf->_pendingCompletion) {
                NSError *err = [NSError errorWithDomain:@"PacketTunnel" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"接收鉴权响应失败"}];
                strongSelf->_pendingCompletion(err);
                strongSelf->_pendingCompletion = nil;
            }
            return;
        }

        if (content) {
            NSData *data = [strongSelf dataFromDispatchData:content];
            NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            WriteLog(@"📝 [PacketTunnel] 服务器鉴权响应: '%@'", response);

            if ([response isEqualToString:@"OK"]) {
                WriteLog(@"✅ [PacketTunnel] 鉴权成功，开始数据包转发");
                strongSelf->_authenticated = YES;
                [strongSelf startPacketForwarding];
                [strongSelf startReceivingFromServer];
                if (strongSelf->_acceleratedDomains.count > 0) {
                    [strongSelf switchToSplitTunnel];
                } else {
                    [strongSelf finishTunnelStartup];
                }
            } else {
                WriteLog(@"❌ [PacketTunnel] 鉴权失败: %@", response);
                if (strongSelf->_pendingCompletion) {
                    NSError *err = [NSError errorWithDomain:@"PacketTunnel" code:-3 userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"鉴权失败: %@", response]
                    }];
                    strongSelf->_pendingCompletion(err);
                    strongSelf->_pendingCompletion = nil;
                }
            }
        }
    });
}

- (void)finishTunnelStartup {
    if (_pendingCompletion) {
        _pendingCompletion(nil);
        _pendingCompletion = nil;
    }
}

- (void)failTunnelWithError:(NSError *)error {
    _authenticated = NO;
    if (_pendingCompletion) {
        _pendingCompletion(error);
        _pendingCompletion = nil;
    }
    // 必须让系统移除旧路由，否则连接已坏但 VPN 仍显示连接，会拖断其他应用网络。
    [self cancelTunnelWithError:error];
}

// 解析所有加速域名的 IPv4 地址，返回排序后的结果
- (NSArray<NSString *> *)resolveAcceleratedIPs {
    NSMutableOrderedSet<NSString *> *resolvedIPs = [NSMutableOrderedSet orderedSet];
    for (NSString *domain in _acceleratedDomains) {
        if (![domain isKindOfClass:[NSString class]] || domain.length == 0) {
            continue;
        }

        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *addresses = NULL;
        int status = getaddrinfo(domain.UTF8String, NULL, &hints, &addresses);
        if (status != 0) {
            WriteLog(@"⚠️ [PacketTunnel] 解析 %@ 失败: %s", domain, gai_strerror(status));
            continue;
        }

        for (struct addrinfo *cursor = addresses; cursor != NULL; cursor = cursor->ai_next) {
            if (cursor->ai_family != AF_INET) {
                continue;
            }
            char addressText[INET_ADDRSTRLEN];
            struct sockaddr_in *address = (struct sockaddr_in *)cursor->ai_addr;
            if (inet_ntop(AF_INET, &address->sin_addr, addressText, sizeof(addressText)) != NULL) {
                [resolvedIPs addObject:[NSString stringWithUTF8String:addressText]];
            }
        }
        freeaddrinfo(addresses);
    }
    return [resolvedIPs.array sortedArrayUsingSelector:@selector(compare:)];
}

- (void)switchToSplitTunnel {
    WriteLog(@"🔎 [PacketTunnel] 开始解析加速域名，准备切换分流路由");
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSString *> *destinationIPs = [strongSelf resolveAcceleratedIPs];
        dispatch_async(strongSelf->_connectionQueue, ^{
            if (!strongSelf->_authenticated) {
                return;
            }
            if (destinationIPs.count == 0) {
                NSError *error = [NSError errorWithDomain:@"PacketTunnel" code:-5 userInfo:@{
                    NSLocalizedDescriptionKey: @"加速域名解析失败，未启用全局代理"
                }];
                WriteLog(@"❌ [PacketTunnel] 所有加速域名均解析失败，停止隧道");
                [strongSelf failTunnelWithError:error];
                return;
            }

            NEPacketTunnelNetworkSettings *settings = [[IntelligentRouteManager sharedManager] generateSplitTunnelSettingsWithTunnelAddress:strongSelf->_serverHost
                                                                                                               destinationIPs:destinationIPs
                                                                                                                      domains:strongSelf->_acceleratedDomains];
            __weak typeof(strongSelf) weakProvider = strongSelf;
            [strongSelf setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
                __strong typeof(weakProvider) provider = weakProvider;
                if (!provider) return;
                if (error) {
                    WriteLog(@"❌ [PacketTunnel] 切换分流路由失败: %@", error);
                    [provider failTunnelWithError:error];
                    return;
                }
                provider->_routedDestinationIPs = destinationIPs;
                WriteLog(@"✅ [PacketTunnel] 分流路由已生效，仅 %lu 个目标 IP 及相关 DNS 走 VPN: %@", (unsigned long)destinationIPs.count, destinationIPs);
                [provider startRouteRefreshTimer];
                [provider finishTunnelStartup];
            }];
        });
    });
}

// 把 dispatch_data_t 转为 NSData
- (NSData *)dataFromDispatchData:(dispatch_data_t)dispatchData {
    NSMutableData *result = [NSMutableData data];
    dispatch_data_apply(dispatchData, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        [result appendBytes:buffer length:size];
        return true;
    });
    return result;
}

- (void)startReceivingFromServer {
    __weak typeof(self) weakSelf = self;
    // 持续接收服务器数据
    nw_connection_receive(_connection, 1, 65535, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            WriteLog(@"❌ [PacketTunnel] 读取服务器数据失败: %@", error);
            if (strongSelf->_authenticated) {
                NSError *tunnelError = [NSError errorWithDomain:@"PacketTunnel" code:-6 userInfo:@{
                    NSLocalizedDescriptionKey: @"服务器连接已中断"
                }];
                [strongSelf failTunnelWithError:tunnelError];
            }
            return;
        }

        if (content) {
            NSData *data = [strongSelf dataFromDispatchData:content];
            [strongSelf->_readBuffer appendData:data];

            // 解析长度前缀协议: [2字节长度][IP包]，同一批一次性写入虚拟网卡
            NSMutableArray<NSData *> *inboundPackets = [NSMutableArray array];
            while (strongSelf->_readBuffer.length >= 2) {
                uint16_t lengthBigEndian;
                [strongSelf->_readBuffer getBytes:&lengthBigEndian range:NSMakeRange(0, 2)];
                int length = CFSwapInt16BigToHost(lengthBigEndian);

                if (strongSelf->_readBuffer.length < 2 + length) {
                    break;
                }

                NSData *ipPacket = [strongSelf->_readBuffer subdataWithRange:NSMakeRange(2, length)];
                [strongSelf->_readBuffer replaceBytesInRange:NSMakeRange(0, 2 + length) withBytes:NULL length:0];

                [inboundPackets addObject:ipPacket];
            }
            if (inboundPackets.count > 0) {
                NSMutableArray<NSNumber *> *protocols = [NSMutableArray arrayWithCapacity:inboundPackets.count];
                for (NSUInteger i = 0; i < inboundPackets.count; i++) {
                    [protocols addObject:@(AF_INET)];
                }
                [strongSelf.packetFlow writePackets:inboundPackets withProtocols:protocols];
            }
        }

        if (is_complete) {
            if (strongSelf->_authenticated) {
                WriteLog(@"❌ [PacketTunnel] 服务器已关闭连接");
                NSError *tunnelError = [NSError errorWithDomain:@"PacketTunnel" code:-6 userInfo:@{
                    NSLocalizedDescriptionKey: @"服务器已关闭连接"
                }];
                [strongSelf failTunnelWithError:tunnelError];
            }
            return;
        }
        [strongSelf startReceivingFromServer];
    });
}

- (void)startPacketForwarding {
    WriteLog(@"✅ [PacketTunnel] 开始从虚拟网卡读取数据包");
    [self readPacketsFromTunnel];
}

- (void)readPacketsFromTunnel {
    __weak typeof(self) weakSelf = self;
    [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_authenticated) {
            return;
        }
        @autoreleasepool {
            // 同一批包合并为一次发送，减少 TLS 记录和小包开销
            NSMutableData *framedBatch = [NSMutableData data];
            for (NSUInteger i = 0; i < packets.count; i++) {
                // 服务器只转发 IPv4；丢弃 IPv6 包，促使系统回退到 IPv4 隧道，避免 IPv6 直连被墙。
                if (protocols.count > i && protocols[i].intValue != AF_INET) {
                    continue;
                }
                uint16_t length = CFSwapInt16HostToBig((uint16_t)packets[i].length);
                [framedBatch appendBytes:&length length:2];
                [framedBatch appendData:packets[i]];
            }
            if (framedBatch.length > 0) {
                [strongSelf sendFramedDataToServer:framedBatch];
            }
        }
        // 每次收到回调后再注册下一次读取，避免无限循环堆积大量未完成请求。
        [strongSelf readPacketsFromTunnel];
    }];
}

- (void)startRouteRefreshTimer {
    if (_routeRefreshTimer) {
        return;
    }
    _routeRefreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _connectionQueue);
    dispatch_source_set_timer(_routeRefreshTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                              60 * NSEC_PER_SEC,
                              5 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_routeRefreshTimer, ^{
        [weakSelf refreshRoutesIfNeeded];
    });
    dispatch_resume(_routeRefreshTimer);
}

- (void)stopRouteRefreshTimer {
    if (_routeRefreshTimer) {
        dispatch_source_cancel(_routeRefreshTimer);
        _routeRefreshTimer = nil;
    }
}

// 定期重新解析加速域名；DNS 返回新 IP（如 AWS 轮换）时更新隧道内路由。
- (void)refreshRoutesIfNeeded {
    if (!_authenticated || _acceleratedDomains.count == 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSString *> *destinationIPs = [strongSelf resolveAcceleratedIPs];
        dispatch_async(strongSelf->_connectionQueue, ^{
            if (!strongSelf->_authenticated || destinationIPs.count == 0) {
                return;
            }
            if ([destinationIPs isEqualToArray:strongSelf->_routedDestinationIPs]) {
                return;
            }

            NEPacketTunnelNetworkSettings *settings = [[IntelligentRouteManager sharedManager] generateSplitTunnelSettingsWithTunnelAddress:strongSelf->_serverHost
                                                                                                                   destinationIPs:destinationIPs
                                                                                                                          domains:strongSelf->_acceleratedDomains];
            __weak typeof(strongSelf) weakProvider = strongSelf;
            [strongSelf setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
                __strong typeof(weakProvider) provider = weakProvider;
                if (!provider) return;
                if (error) {
                    WriteLog(@"⚠️ [PacketTunnel] 刷新分流路由失败: %@", error);
                    return;
                }
                provider->_routedDestinationIPs = destinationIPs;
                WriteLog(@"🔄 [PacketTunnel] 分流路由已刷新，共 %lu 个目标 IP", (unsigned long)destinationIPs.count);
            }];
        });
    });
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    WriteLog(@"🛑 [PacketTunnel] 停止 VPN 隧道，原因码: %ld", (long)reason);
    _authenticated = NO;
    [self stopRouteRefreshTimer];
    if (_connection) {
        nw_connection_cancel(_connection);
        _connection = nil;
    }
    completionHandler();
    WriteLog(@"✅ [PacketTunnel] 停止完成");
}

- (NSString *)extractDestinationIPFromIPPacket:(NSData *)packet {
    if (packet.length < 20) {
        return nil;
    }

    const unsigned char *bytes = packet.bytes;
    int ihl = (bytes[0] & 0x0F) * 4;
    if (ihl < 20 || packet.length < ihl) {
        return nil;
    }

    uint8_t ip1 = bytes[16];
    uint8_t ip2 = bytes[17];
    uint8_t ip3 = bytes[18];
    uint8_t ip4 = bytes[19];

    return [NSString stringWithFormat:@"%d.%d.%d.%d", ip1, ip2, ip3, ip4];
}

- (void)sendFramedDataToServer:(NSData *)framedData {
    if (!_connection || !_authenticated) {
        return;
    }

    // 用析构 block 捕获数据，保证发送完成前内存有效；不能用 DEFAULT，否则会 free 非 malloc 指针。
    dispatch_data_t sendData = dispatch_data_create(framedData.bytes, framedData.length,
                                                     _connectionQueue, ^{
        (void)framedData;
    });
    __weak typeof(self) weakSelf = self;
    nw_connection_send(_connection, sendData, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (error) {
            WriteLog(@"❌ [PacketTunnel] 发送数据包失败: %@", error);
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_authenticated) {
                NSError *tunnelError = [NSError errorWithDomain:@"PacketTunnel" code:-7 userInfo:@{
                    NSLocalizedDescriptionKey: @"向服务器发送数据失败"
                }];
                [strongSelf failTunnelWithError:tunnelError];
            }
        }
    });
}

@end
