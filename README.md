# TermiLink TLS VPN 完整项目包

## 项目结构
```
TermiLink_TLS/
├── Server/
│   ├── vpn_server_tls.py    # 支持 TLS 加密和 Token 鉴权的 Python VPN 服务器
│   ├── server.crt           # 预先生成的自签名公钥证书
│   └── server.key           # 预先生成的私钥
├── PacketTunnel/
│   └── PacketTunnelProvider.swift  # iOS 客户端 Network Extension 实现
└── README.md
```

## 服务器部署步骤

1. 将 Server 目录上传到你的 Linux 服务器
2. 以 root 权限运行：
```bash
# 配置 TUN 网卡和 iptables 转发
sudo sysctl -w net.ipv4.ip_forward=1
sudo ip addr add 10.0.0.1/24 dev tun0
sudo ip link set dev tun0 up
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# 启动 VPN 服务器
sudo python3 vpn_server_tls.py
```

## iOS 客户端配置

1. 在 Xcode 中创建 Network Extension Target
2. 将 PacketTunnelProvider.swift 替换默认文件
3. 修改 serverHost 为你的服务器公网 IP
4. 确保 authToken 与服务器 VALID_TOKENS 中的值一致
5. 主 App 中使用 VPNManager 启动隧道

## 安全特性

✅ **TLS 1.3 端到端加密**：所有流量经过 TLS 加密传输
✅ **Token 鉴权**：只有持有合法 Token 的客户端才能连接
✅ **自签名证书**：不需要购买商业 SSL 证书
✅ **防窃听防篡改**：中间人无法读取或修改流量

## 默认配置

- 服务器端口：10011
- 虚拟网段：10.0.0.0/24
- 默认 Token：`my_secure_token_123456`
- 证书有效期：10 年
