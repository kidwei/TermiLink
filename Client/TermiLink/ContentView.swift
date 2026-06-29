import SwiftUI

struct ContentView: View {
    @ObservedObject var vpnManager = VPNManager.shared
    @State private var serverIP = "1.2.3.4" // 默认服务器IP
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器配置")) {
                    TextField("服务器 IP", text: $serverIP)
                        .keyboardType(.decimalPad)
                        .disabled(vpnManager.isConnected)
                }
                
                Section(header: Text("连接状态")) {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(vpnManager.statusText)
                            .foregroundColor(vpnManager.isConnected ? .green : .gray)
                            .bold()
                    }
                }
                
                Section {
                    Button(action: {
                        Task {
                            if vpnManager.isConnected {
                                vpnManager.stopVPN()
                            } else {
                                do {
                                    try await vpnManager.startVPN(serverIP: serverIP)
                                } catch {
                                    print("启动失败: \(error)")
                                }
                            }
                        }
                    }) {
                        Text(vpnManager.isConnected ? "断开连接" : "连接 VPN")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .bold()
                            .foregroundColor(.white)
                    }
                    .listRowBackground(vpnManager.isConnected ? Color.red : Color.blue)
                }
            }
            .navigationTitle("TermiLink")
        }
    }
}

struct ContentView_Previews: View {
    var body: some View {
        ContentView()
    }
}
