import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var serverConnection: NWTCPConnection?
    private let serverHost = "1.2.3.4" // 替换为你的 VPN 服务器公网 IP
    private let serverPort: UInt16 = 8099
    
    private let virtualClientIP = "10.0.0.2"
    private let virtualSubnetMask = "255.255.255.0"
    private let dnsServers = ["8.8.8.8", "1.1.1.1"]
    
    override func startTunnel(options: [String : NSObject]? = nil) async throws {
        NSLog("✅ 开始启动 VPN 隧道")
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverHost)
        settings.ipv4Settings = NEIPv4Settings(
            addresses: [virtualClientIP],
            subnetMasks: [virtualSubnetMask]
        )
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        
        try await setTunnelNetworkSettings(settings)
        NSLog("✅ 虚拟网卡配置完成，开始连接服务器")
        
        let endpoint = NWHostEndpoint(hostname: serverHost, port: "\(serverPort)")
        serverConnection = createTCPConnection(to: endpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.serverConnection?.addObserver(self, forKeyPath: "state", options: .new, context: nil)
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if self.serverConnection?.state != .connected {
                    continuation.resume(throwing: NSError(domain: "PacketTunnel", code: -1, userInfo: [NSLocalizedDescriptionKey: "连接服务器超时"]))
                }
            }
        }
        
        NSLog("✅ 服务器连接成功，开始转发数据包")
        startPacketForwarding()
    }
    
    private func startPacketForwarding() {
        Task {
            while true {
                do {
                    let (packets, _) = try await self.packetFlow.packets()
                    for packet in packets {
                        var length = UInt16(packet.count).bigEndian
                        var payload = Data()
                        payload.append(UnsafeBufferPointer(start: &length, count: 1))
                        payload.append(packet)
                        
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
        
        Task {
            var buffer = Data()
            while true {
                do {
                    guard let data = try await self.serverConnection?.read(minimumLength: 2, maximumLength: 65535) else {
                        break
                    }
                    buffer.append(data)
                    
                    while buffer.count >= 2 {
                        let length = Int(buffer.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                        guard buffer.count >= 2 + length else {
                            break
                        }
                        let ipPacket = buffer.subdata(in: 2..<2+length)
                        buffer.removeFirst(2 + length)
                        self.packetFlow.writePackets([ipPacket], withProtocols: [AF_INET as NSNumber])
                    }
                } catch {
                    NSLog("❌ 读取服务器数据失败: \(error)")
                    break
                }
            }
            self.stopTunnel(with: .connectionFailed, completionHandler: {})
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 停止 VPN 隧道，原因: \(reason.rawValue)")
        serverConnection?.cancel()
        serverConnection?.removeObserver(self, forKeyPath: "state")
        completionHandler()
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "state", let connection = object as? NWTCPConnection {
            if connection.state == .connected {
                NSLog("✅ 服务器 TCP 连接已建立")
            } else if connection.state == .disconnected {
                NSLog("❌ 服务器连接断开")
            }
        }
    }
}
