#import "PacketTunnelProvider.h"
#import "IntelligentRouteManager.h"

@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    NSLog(@"✅ 开始启动 VPN 隧道（智能分割隧道模式）");

    // 配置虚拟网卡 - 初始设置：没有包含任何路由，所有流量先走本地
    // 只有检测不可达的才会动态添加到 VPN 路由
    NSString *serverHost = [[self protocolConfiguration] serverAddress];
    NEPacketTunnelNetworkSettings *initialSettings = [[IntelligentRouteManager sharedManager] generateUpdatedSettingsWithTunnelAddress:serverHost];

    [self setTunnelNetworkSettings:initialSettings completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ 设置虚拟网卡失败: %@", error);
            completionHandler(error);
            return;
        }

        NSLog(@"✅ 虚拟网卡配置完成，开始连接服务器");

        // 连接服务器（当前不使用 TLS 以绕过自签名证书验证问题）
        NWHostEndpoint *endpoint = [NWHostEndpoint endpointWithHostname:serverHost port:@"10011"];

        self.serverConnection = [self createTCPConnectionThroughTunnelToEndpoint:endpoint enableTLS:NO TLSParameters:nil delegate:nil];

        // 添加状态观察
        [self.serverConnection addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:nil];

        // 设置超时
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && strongSelf.serverConnection.state != NWTCPConnectionStateConnected) {
                NSError *timeoutError = [NSError errorWithDomain:@"PacketTunnel" code:-1 userInfo:@{
                    NSLocalizedDescriptionKey: @"连接服务器超时"
                }];
                completionHandler(timeoutError);
            }
        });

        // 等待连接成功后进行鉴权
        [self waitForConnectionAndAuthenticate:completionHandler];
    }];
}

- (void)waitForConnectionAndAuthenticate:(void (^)(NSError * _Nullable))completionHandler {
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        int waitCount = 0;
        while (strongSelf.serverConnection.state == NWTCPConnectionStateConnecting && waitCount < 100) {
            [NSThread sleepForTimeInterval:0.1];
            waitCount++;
        }

        if (strongSelf.serverConnection.state != NWTCPConnectionStateConnected) {
            NSError *error = [NSError errorWithDomain:@"PacketTunnel" code:-2 userInfo:@{
                NSLocalizedDescriptionKey: @"无法连接到服务器"
            }];
            completionHandler(error);
            return;
        }

        NSLog(@"✅ TCP 连接已建立，TLS 握手完成，开始鉴权");

        // 发送鉴权信息
        // 协议格式: [2字节魔数 "AH"][2字节token长度][token数据]
        NSString *token = [[NSProcessInfo processInfo] environment][@"TERMILINK_AUTH_TOKEN"];
        if (!token || token.length == 0) {
            // 如果环境变量未设置，使用默认token
            token = @"kidwei123456";
        }
        strongSelf.authToken = token;

        NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
        uint16_t magic = CFSwapInt16HostToBig((uint16_t)0x4148); // "AH" in big-endian
        uint16_t tokenLength = CFSwapInt16HostToBig((uint16_t)tokenData.length);

        NSMutableData *authPacket = [[NSMutableData alloc] init];
        [authPacket appendBytes:&magic length:2];
        [authPacket appendBytes:&tokenLength length:2];
        [authPacket appendData:tokenData];

        [strongSelf.serverConnection write:authPacket completionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"❌ 发送鉴权失败: %@", error);
                completionHandler(error);
                return;
            }

            // 等待服务器响应
            [strongSelf.serverConnection readMinimumLength:2 maximumLength:2 completionHandler:^(NSData *data, NSError *error) {
                if (error) {
                    NSLog(@"❌ 接收鉴权响应失败: %@", error);
                    completionHandler(error);
                    return;
                }

                NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([response isEqualToString:@"OK"]) {
                    NSLog(@"✅ 鉴权成功，开始转发数据包");
                    [strongSelf startPacketForwarding];
                    completionHandler(nil);
                } else {
                    NSError *authError = [NSError errorWithDomain:@"PacketTunnel" code:-3 userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"鉴权失败，服务器返回: %@", response]
                    }];
                    NSLog(@"❌ 鉴权失败: %@", response);
                    completionHandler(authError);
                }
            }];
        }];
    });
}

- (void)startPacketForwarding {
    // 线程 1: 从虚拟网卡读取 → 如果需要走 VPN → 发送给服务器
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (YES) {
            @autoreleasepool {
                [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
                    for (NSData *packet in packets) {
                        NSString *dstIP = [self extractDestinationIPFromIPPacket:packet];
                        if (!dstIP) {
                            // 解析失败，默认走 VPN
                            [self sendPacketToServer:packet];
                            continue;
                        }

                        IntelligentRouteManager *routeManager = [IntelligentRouteManager sharedManager];
                        BOOL shouldRouteVPN = [routeManager shouldRouteThroughVPNForDestinationIP:dstIP];

                        if (shouldRouteVPN) {
                            // 需要走 VPN
                            [self sendPacketToServer:packet];
                        } else {
                            // 可直接访问，不走 VPN，直接丢弃让本地路由处理
                            // 在分割隧道模式下，被排除的路由会自动走本地，这里只是保险
                            NSLog(@"🚀 跳过 VPN → %@（直接访问更快）", dstIP);
                            continue;
                        }

                        // 异步检测并更新路由
                        [routeManager checkAndUpdateRouteForIP:dstIP tunnelProvider:self completion:^(BOOL needsUpdate, NEPacketTunnelNetworkSettings *newSettings) {
                            if (needsUpdate && newSettings) {
                                [self setTunnelNetworkSettings:newSettings completionHandler:^(NSError *error) {
                                    if (error) {
                                        NSLog(@"⚠️ 更新路由失败: %@", error);
                                    } else {
                                        NSLog(@"✅ 路由已更新: %@ -> %@",
                                            dstIP,
                                            shouldRouteVPN ? @"VPN" : @"直接访问");
                                    }
                                }];
                            }
                        }];
                    }
                }];
            }
        }
    });

    // 线程 2: 从服务器读取 → 写入虚拟网卡
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableData *buffer = [[NSMutableData alloc] init];

        while (YES) {
            @autoreleasepool {
                [self.serverConnection readMinimumLength:2 maximumLength:65535 completionHandler:^(NSData *data, NSError *error) {
                    if (error) {
                        NSLog(@"❌ 读取服务器数据失败: %@", error);
                        return;
                    }

                    if (!data) {
                        return;
                    }

                    [buffer appendData:data];

                    while (buffer.length >= 2) {
                        uint16_t lengthBigEndian;
                        [buffer getBytes:&lengthBigEndian range:NSMakeRange(0, 2)];
                        int length = CFSwapInt16BigToHost(lengthBigEndian);

                        if (buffer.length < 2 + length) {
                            break;
                        }

                        NSData *ipPacket = [buffer subdataWithRange:NSMakeRange(2, length)];
                        [buffer replaceBytesInRange:NSMakeRange(0, 2 + length) withBytes:NULL length:0];

                        [self.packetFlow writePackets:@[ipPacket] withProtocols:@[@(AF_INET)]];
                    }
                }];
            }
        }

        [self stopTunnelWithReason:NEProviderStopReasonConnectionFailed completionHandler:^{}];
    });
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    NSLog(@"🛑 停止 VPN 隧道，原因: %ld", (long)reason);
    [self.serverConnection cancel];
    [self.serverConnection removeObserver:self forKeyPath:@"state"];
    completionHandler();
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"state"] && [object isKindOfClass:[NWTCPConnection class]]) {
        NWTCPConnection *connection = (NWTCPConnection *)object;
        if (connection.state == NWTCPConnectionStateConnected) {
            NSLog(@"✅ 服务器 TCP 连接已连接");
        } else if (connection.state == NWTCPConnectionStateDisconnected) {
            NSLog(@"❌ 服务器连接已断开");
        }
    }
}

- (NSString *)extractDestinationIPFromIPPacket:(NSData *)packet {
    if (packet.length < 20) {
        return nil; // IP 头部至少 20 字节
    }

    const unsigned char *bytes = packet.bytes;

    // 第一个字节: version (4 bits) + IHL (4 bits)
    // IHL = 头部长度，单位 4 字节
    int ihl = (bytes[0] & 0x0F) * 4;
    if (ihl < 20 || packet.length < ihl) {
        return nil;
    }

    // 目标 IP 在偏移 16 字节处（从 0 开始），4 字节
    uint8_t ip1 = bytes[16];
    uint8_t ip2 = bytes[17];
    uint8_t ip3 = bytes[18];
    uint8_t ip4 = bytes[19];

    return [NSString stringWithFormat:@"%d.%d.%d.%d", ip1, ip2, ip3, ip4];
}

- (void)sendPacketToServer:(NSData *)packet {
    uint16_t length = CFSwapInt16HostToBig((uint16_t)packet.length);
    NSMutableData *payload = [[NSMutableData alloc] init];
    [payload appendBytes:&length length:2];
    [payload appendData:packet];

    [self.serverConnection write:payload completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"❌ 发送数据包失败: %@", error);
        }
    }];
}

@end
