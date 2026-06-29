import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    // 与服务器的 TLS 连接
    private var serverConnection: NWTCPConnection?
    
    // 服务器配置
    private let serverHost = "1.2.3.4" // 替换为你的 VPN 服务器公网 IP
    private let serverPort: UInt16 = 8099
    private let authToken = "my_secure_token_123456" // 与服务器一致的鉴权 Token
    
    // 虚拟网卡配置
    private let virtualClientIP = "10.0.0.2"
    private let virtualSubnetMask = "255.255.255.0"
    private let dnsServers = ["8.8.8.8", "1.1.1.1"]
    
    // MARK: - 启动 VPN 隧道
    
    override func startTunnel(options: [String : NSObject]? = nil) async throws {
        
        NSLog("✅ 开始启动 TLS VPN 隧道")
        
        // 1. 配置虚拟网卡 (TUN 接口)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverHost)
        
        // 配置 IPv4 地址和子网掩码
        settings.ipv4Settings = NEIPv4Settings(
            addresses: [virtualClientIP],
            subnetMasks: [virtualSubnetMask]
        )
        
        // 配置路由：将所有流量 (0.0.0.0/0) 路由到虚拟网卡
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        
        // 配置 DNS 服务器，防止 DNS 泄露
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        
        // 2. 应用网络配置
        try await setTunnelNetworkSettings(settings)
        
        NSLog("✅ 虚拟网卡配置完成，开始 TLS 连接服务器")
        
        // 3. 建立与 VPN 服务器的 TLS 加密连接
        let endpoint = NWHostEndpoint(hostname: serverHost, port: "\(serverPort)")
        
        // 配置 TLS 参数，信任我们的自签名证书
        let tlsParams = NWParameters.tls
        tlsParams.tlsOptions.allowInvalidCertificates = true // 信任自签名证书
        tlsParams.tlsOptions.disableSNI = true
        
        serverConnection = createTCPConnection(to: endpoint, enableTLS: true, tlsParameters: tlsParams, delegate: nil)
        
        // 4. 等待 TLS 连接建立并进行鉴权握手
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            
            // 启动一个 Task 进行握手
            Task {
                // A. 等待 TLS 物理连接建立
                while self.serverConnection?.state != .connected {
                    try await Task.sleep(nanoseconds: 100_000_000) // 等待 100ms
                }
                
                NSLog("✅ TLS 连接建立成功，开始鉴权")
                
                // B. 准备鉴权数据
                guard let tokenData = authToken.data(using: .utf8) else {
                    continuation.resume(throwing: NSError(domain: "Tunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Token 编码失败"]))
                    return
                }
                
                var authHeader = Data()
                authHeader.append("AH".data(using: .utf8)!) // 2 字节魔数
                var tokenLen = UInt16(tokenData.count).bigEndian
                authHeader.append(UnsafeBufferPointer(start: &tokenLen, count: 1)) // 2 字节长度
                authHeader.append(tokenData) // Token 字符串
                
                // C. 发送鉴权包
                self.serverConnection?.write(authHeader) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    }
                }
                
                // D. 读取服务器的鉴权回复（期待 2 字节 "OK"）
                guard let response = try await self.serverConnection?.read(minimumLength: 2, maximumLength: 2) else {
                    continuation.resume(throwing: NSError(domain: "Tunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器无响应"]))
                    return
                }
                
                let status = String(data: response, encoding: .utf8)
                if status == "OK" {
                    NSLog("✅ 鉴权成功！开始数据包转发。")
                    continuation.resume()
                } else {
                    NSLog("❌ 鉴权失败：Token 被服务器拒绝")
                    continuation.resume(throwing: NSError(domain: "Tunnel", code: 401, userInfo: [NSLocalizedDescriptionKey: "鉴权失败：Token 无效"]))
                }
            }
        }
        
        // 5. 鉴权成功后，启动双向数据包转发
        startPacketForwarding()
    }
    
    // MARK: - 双向数据包转发
    
    private func startPacketForwarding() {
        // 方向 A：从虚拟网卡读取 IP 包 → 加密发送给服务器
        Task {
            while true {
                do {
                    let (packets, _) = try await self.packetFlow.packets()
                    
                    for packet in packets {
                        // 封包：在 IP 包前加上 2 字节的长度（大端序）
                        var length = UInt16(packet.count).bigEndian
                        var payload = Data()
                        payload.append(UnsafeBufferPointer(start: &length, count: 1))
                        payload.append(packet)
                        
                        // 通过 TLS 加密通道发送给服务器
                        self.serverConnection?.write(payload) { error in
                            if let error = error {
                                NSLog("❌ 发送数据包失败: \(error)")
                            }
                        }
                    }
                } catch {
                    NSLog("❌ 读取网卡数据包失败: \(error)")
                    break
                }
            }
        }
        
        // 方向 B：从服务器读取加密回包 → 解密写入虚拟网卡
        Task {
            var buffer = Data()
            
            while true {
                do {
                    guard let data = try await self.serverConnection?.read(minimumLength: 2, maximumLength: 65535) else {
                        break
                    }
                    
                    buffer.append(data)
                    
                    // 解析封包格式：[2字节长度][IP包数据]
                    while buffer.count >= 2 {
                        let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                        
                        guard buffer.count >= 2 + length else {
                            break // 数据不完整，等待更多数据
                        }
                        
                        // 提取完整的 IP 包
                        let ipPacket = buffer.subdata(in: 2..<2+length)
                        buffer.removeFirst(2 + length)
                        
                        // 写入虚拟网卡，系统会自动将它转发给对应的 App
                        self.packetFlow.writePackets([ipPacket], withProtocols: [AF_INET as NSNumber])
                    }
                } catch {
                    NSLog("❌ 读取服务器数据失败: \(error)")
                    break
                }
            }
            
            // 连接断开，停止隧道
            self.stopTunnel(with: .connectionFailed, completionHandler: {})
        }
    }
    
    // MARK: - 停止 VPN 隧道
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 停止 TLS VPN 隧道，原因: \(reason.rawValue)")
        
        serverConnection?.cancel()
        
        completionHandler()
    }
}
