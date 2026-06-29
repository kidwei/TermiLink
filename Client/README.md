# TermiLink iOS 客户端项目 (Objective-C 版本)

这是一个完整的 iOS 客户端项目，Objective-C 版本，包含一个主 App 目标和一个 Network Extension 目标。

**这个版本已经添加了与服务器匹配的 TLS 加密和 Token 鉴权功能。**

## ✅ 功能特性

- ✅ **TLS 加密传输** - 与服务器 TLS 加密握手
- ✅ **Token 鉴权** - 完整的鉴权握手流程
- ✅ **完整的 IP 数据包转发** - 支持流量经过 VPN 路由
- ✅ **适配当前服务器配置** - 端口 10011，IP 网段 `192.168.50.0/24`

## 🚀 如何在 Xcode 中使用

1. **解压项目**:
   将项目解压到你的 Mac 电脑上。

2. **新建 Xcode 项目**:
   - 打开 Xcode，选择 **Create a new Xcode project**。
   - 选择 **iOS** -> **App**，项目名称填 `TermiLink`。
   - 界面选择 **Storyboard**，语言选择 **Objective-C**。
   - 组织标识符（Organization Identifier）填你的标识符（如 `com.yourcompany`）。

3. **添加 Network Extension 目标**:
   - 在 Xcode 菜单栏选择 `File` -> `New` -> `Target`。
   - 选择 **Network Extension**，Product Name 填 `PacketTunnel`。
   - Provider Type 选择 **Packet Tunnel**，语言选择 **Objective-C**。

4. **导入代码**:
   - **主 App 目标 (TermiLink)**: 将 `TermiLink/` 目录下的所有 `.h` `.m` `.entitlements` 文件拖入 Xcode 的 `TermiLink` 组中：
     - `main.m`
     - `AppDelegate.h` / `AppDelegate.m`
     - `ViewController.h` / `ViewController.m`
     - `VPNManager.h` / `VPNManager.m`
     - `TermiLink.entitlements`
   - **Extension 目标 (PacketTunnel)**: 将 `PacketTunnel/` 目录下的所有文件拖入 Xcode 的 `PacketTunnel` 组中：
     - `PacketTunnelProvider.h` / `PacketTunnelProvider.m`
     - `PacketTunnel.entitlements`
     - `Info.plist` (覆盖默认文件)

5. **配置签名与能力（Capabilities）**:
   - **主 App 目标 (TermiLink)**:
     - 在 `Signing & Capabilities` 标签页中，点击 `+ Capability`，添加 **Network Extensions**。
     - 勾选 **Packet Tunnel**。
   - **Extension 目标 (PacketTunnel)**:
     - 同样在 `Signing & Capabilities` 中，添加 **Network Extensions**。
     - 勾选 **Packet Tunnel**。

6. **修改 Bundle Identifier**:
   在 `VPNManager.m` 中，修改 `providerBundleIdentifier` 为你的实际 Bundle ID：
   ```objc
   proto.providerBundleIdentifier = @"com.yourcompany.TermiLink.PacketTunnel";
   ```

7. **配置认证 Token（可选）**:
   默认 Token 是 `kidwei123456`，如果你修改了服务器的 Token，可以在项目的 Scheme 设置中添加环境变量 `TERMILINK_AUTH_TOKEN` 来指定。

8. **运行与测试**:
   - 将你的 iPhone 连接到 Mac（需要真机测试，模拟器不支持 Network Extension）。
   - 选择 `TermiLink` 目标，点击 **Run**。
   - 启动后输入你的 VPN 服务器 IP，点击 **连接 VPN** 即可！

## 🔧 协议说明

客户端与服务器的通信协议:

1. **连接建立**: TCP + TLS 握手
2. **鉴权握手**:
   ```
   [ 2字节 魔数 "AH" (0x4148) ][ 2字节 Token长度 ][ Token数据(UTF-8) ]
   ```
3. **服务器响应**:
   - `OK` → 鉴权成功，开始转发
   - `ER` → 鉴权失败，断开连接
4. **数据包转发**:
   ```
   [ 2字节 IP包长度 ][ IP包数据 ]
   ```
   长度使用大端字节序 (big-endian) 编码。

## ⚠️ 注意事项

1. **需要开发者账号**：Network Extension 只能在真机上运行，需要 Apple 开发者账号。
2. **服务器需要开放端口**: 确保服务器的 10011/TCP 端口在安全组/防火墙中开放。
3. **Token 必须一致**: 客户端 Token 必须与服务器 `.env` 文件中的 `VALID_TOKENS` 配置一致，否则鉴权会失败。

## 📝 对比原 Swift 版本

| 特性 | 原 Swift 版本 | Objective-C 版本 |
|------|--------------|------------------|
| TLS 加密 | ❌ 明文 | ✅ 已启用 |
| Token 鉴权 | ❌ 无 | ✅ 完整实现 |
| 端口 | 8099 | 10011 (匹配服务器) |
| IP 网段 | 10.0.0.2 | 192.168.50.2 (匹配服务器配置) |
| 语言 | Swift | Objective-C |
