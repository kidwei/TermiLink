import NetworkExtension
import Combine

class VPNManager: ObservableObject {
    
    static let shared = VPNManager()
    
    private let manager = NETunnelProviderManager()
    
    @Published var isConnected = false
    @Published var statusText = "未连接"
    
    private init() {
        loadConfiguration()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }
    
    private func loadConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let existingManager = managers?.first {
                self.manager.loadFromPreferences { error in
                    self.updateStatus(existingManager.connection.status)
                }
            }
        }
    }
    
    func startVPN(serverIP: String) async throws {
        manager.localizedDescription = "TermiLink VPN"
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.yourcompany.TermiLink.PacketTunnel" // 替换为你的 Extension Bundle ID
        proto.serverAddress = serverIP
        
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        
        try manager.connection.startVPNTunnel()
    }
    
    func stopVPN() {
        manager.connection.stopVPNTunnel()
    }
    
    @objc private func vpnStatusDidChange(_ notification: Notification) {
        if let connection = notification.object as? NEVPNConnection {
            updateStatus(connection.status)
        }
    }
    
    private func updateStatus(_ status: NEVPNStatus) {
        DispatchQueue.main.async {
            switch status {
            case .connected:
                self.isConnected = true
                self.statusText = "已连接"
            case .connecting:
                self.isConnected = false
                self.statusText = "正在连接..."
            case .disconnected:
                self.isConnected = false
                self.statusText = "已断开"
            case .disconnecting:
                self.statusText = "正在断开..."
            default:
                self.isConnected = false
                self.statusText = "未知状态"
            }
        }
    }
}
