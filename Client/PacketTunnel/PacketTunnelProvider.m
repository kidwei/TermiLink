#import "PacketTunnelProvider.h"
#import "IntelligentRouteManager.h"

// 文件日志帮助函数
static void WriteLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // 同时输出到系统日志
    NSLog(@"%@", message);

    // 写入文件到 App Group
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *groupURL = [[fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.kidwei.vpntool"] URLByAppendingPathComponent:@"packettunnel.log"];

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];

    // 追加写入
    if ([fm fileExistsAtPath:groupURL.path]) {
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:groupURL.path];
        [file seekToEndOfFile];
        [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    } else {
        [line writeToFile:groupURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

@implementation PacketTunnelProvider {
    nw_connection_t _connection;       // Network.framework 连接
    dispatch_queue_t _connectionQueue; // 连接专用队列
    NSMutableData *_readBuffer;        // 读缓冲区
    void (^_pendingCompletion)(NSError * _Nullable);
    BOOL _authenticated;               // 是否已完成鉴权
}

- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    WriteLog(@"✅ [PacketTunnel] 开始启动 VPN 隧道（智能分割隧道模式）");

    NSString *serverHost = [[self protocolConfiguration] serverAddress];
    WriteLog(@"📝 [PacketTunnel] 服务器地址: %@", serverHost);

    NEPacketTunnelNetworkSettings *initialSettings = [[IntelligentRouteManager sharedManager] generateUpdatedSettingsWithTunnelAddress:serverHost];

    [self setTunnelNetworkSettings:initialSettings completionHandler:^(NSError *error) {
        if (error) {
            WriteLog(@"❌ [PacketTunnel] 设置虚拟网卡失败: %@ (code: %ld)", error, (long)error.code);
            completionHandler(error);
            return;
        }

        WriteLog(@"✅ [PacketTunnel] 虚拟网卡配置完成，开始连接服务器");

        self->_readBuffer = [[NSMutableData alloc] init];
        self->_pendingCompletion = completionHandler;
        self->_authenticated = NO;
        self->_connectionQueue = dispatch_queue_create("com.kidwei.vpntool.connection", DISPATCH_QUEUE_SERIAL);

        [self connectToServer:serverHost port:@"10011"];
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
                [strongSelf doAuthentication];
                break;
            case nw_connection_state_failed:
                WriteLog(@"❌ [PacketTunnel] 连接状态: failed, error: %@", error);
                if (strongSelf->_pendingCompletion) {
                    NSError *err = [NSError errorWithDomain:@"PacketTunnel" code:-2 userInfo:@{
                        NSLocalizedDescriptionKey: @"连接失败"
                    }];
                    strongSelf->_pendingCompletion(err);
                    strongSelf->_pendingCompletion = nil;
                }
                break;
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
        if (strongSelf->_pendingCompletion) {
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
                if (strongSelf->_pendingCompletion) {
                    strongSelf->_pendingCompletion(nil);
                    strongSelf->_pendingCompletion = nil;
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
            return;
        }

        if (content) {
            NSData *data = [strongSelf dataFromDispatchData:content];
            [strongSelf->_readBuffer appendData:data];

            // 解析长度前缀协议: [2字节长度][IP包]
            while (strongSelf->_readBuffer.length >= 2) {
                uint16_t lengthBigEndian;
                [strongSelf->_readBuffer getBytes:&lengthBigEndian range:NSMakeRange(0, 2)];
                int length = CFSwapInt16BigToHost(lengthBigEndian);

                if (strongSelf->_readBuffer.length < 2 + length) {
                    break;
                }

                NSData *ipPacket = [strongSelf->_readBuffer subdataWithRange:NSMakeRange(2, length)];
                [strongSelf->_readBuffer replaceBytesInRange:NSMakeRange(0, 2 + length) withBytes:NULL length:0];

                [strongSelf.packetFlow writePackets:@[ipPacket] withProtocols:@[@(AF_INET)]];
            }
        }

        // 继续接收
        if (!is_complete) {
            [strongSelf startReceivingFromServer];
        }
    });
}

- (void)startPacketForwarding {
    WriteLog(@"✅ [PacketTunnel] 开始从虚拟网卡读取数据包");

    // 全局代理模式：从虚拟网卡读取的所有数据包都发送给服务器
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (YES) {
            @autoreleasepool {
                [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
                    for (NSData *packet in packets) {
                        [self sendPacketToServer:packet];
                    }
                }];
            }
        }
    });
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    WriteLog(@"🛑 [PacketTunnel] 停止 VPN 隧道，原因码: %ld", (long)reason);
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

- (void)sendPacketToServer:(NSData *)packet {
    if (!_connection || !_authenticated) {
        return;
    }

    uint16_t length = CFSwapInt16HostToBig((uint16_t)packet.length);
    NSMutableData *payload = [[NSMutableData alloc] init];
    [payload appendBytes:&length length:2];
    [payload appendData:packet];

    dispatch_data_t sendData = dispatch_data_create([payload bytes], [payload length],
                                                     _connectionQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(_connection, sendData, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (error) {
            WriteLog(@"❌ [PacketTunnel] 发送数据包失败: %@", error);
        }
    });
}

@end
