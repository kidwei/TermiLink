import socket
import ssl
import struct
import time
import random
import json
import urllib.request
import urllib.error

SERVER_IP = "129.226.94.203"  # 替换为你的服务器 IP
SERVER_PORT = 10011           # VPN 隧道端口
API_PORT = 8000               # FastAPI 控制接口端口
AUTH_TOKEN = "kidwei123456"   # 必须与服务器 VALID_TOKENS 一致
ADMIN_TOKEN = "zhaowei1111"   # 必须与服务器 ADMIN_TOKEN 一致（保护 /api/* 接口）

API_BASE = f"http://{SERVER_IP}:{API_PORT}"


def _api_request(path, method="GET"):
    """调用服务端 FastAPI 控制接口，返回解析后的 JSON dict。"""
    url = f"{API_BASE}{path}"
    headers = {"Authorization": f"Bearer {ADMIN_TOKEN}"}
    req = urllib.request.Request(url, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        print(f"[-] 接口 {method} {path} 返回 HTTP {e.code}: {detail}")
        return None
    except Exception as e:
        print(f"[-] 接口 {method} {path} 请求失败: {e}")
        return None


def api_status():
    print("[*] 查询 VPN 服务状态: GET /api/status")
    result = _api_request("/api/status")
    if result is not None:
        print(f"[<-] 状态: {result}")
    return result


def api_start_server():
    print("[*] 请求启动 VPN 服务: POST /api/start_server")
    result = _api_request("/api/start_server", method="POST")
    if result is not None:
        print(f"[<-] 返回: {result}")
    return result


def api_stop_server():
    print("[*] 请求停止 VPN 服务: POST /api/stop_server")
    result = _api_request("/api/stop_server", method="POST")
    if result is not None:
        print(f"[<-] 返回: {result}")
    return result

# 构造一个标准的 ICMP Echo Request (Ping) 数据包
def build_icmp_ping_packet():
    # IP 头部 (20 字节)
    ip_header = bytearray(20)
    ip_header[0] = 0x45  # Version 4, IHL 5
    ip_header[1] = 0x00  # TOS
    struct.pack_into("!H", ip_header, 2, 84)  # 总长度 84 字节
    struct.pack_into("!H", ip_header, 4, random.randint(1000, 65535))  # 标识
    struct.pack_into("!H", ip_header, 6, 0)  # 标志和偏移
    ip_header[8] = 64  # TTL
    ip_header[9] = 1  # 协议 ICMP
    struct.pack_into("!4s", ip_header, 12, socket.inet_aton("192.168.50.2"))  # 源 IP (虚拟客户端 - matches server subnet)
    struct.pack_into("!4s", ip_header, 16, socket.inet_aton("8.8.8.8"))  # 目标 IP (Google DNS)

    # 计算 IP 头部校验和
    checksum = 0
    for i in range(0, 20, 2):
        checksum += struct.unpack("!H", ip_header[i:i+2])[0]
    checksum = (checksum >> 16) + (checksum & 0xFFFF)
    checksum = ~checksum & 0xFFFF
    struct.pack_into("!H", ip_header, 10, checksum)
    
    # ICMP 头部 (8 字节) + 数据 (56 字节)
    icmp_header = bytearray(64)
    icmp_header[0] = 8  # ICMP Echo Request
    icmp_header[1] = 0  # Code
    struct.pack_into("!H", icmp_header, 4, random.randint(1000, 65535))  # 标识符
    struct.pack_into("!H", icmp_header, 6, 1)  # 序列号
    
    # 计算 ICMP 校验和
    checksum = 0
    for i in range(0, 64, 2):
        checksum += struct.unpack("!H", icmp_header[i:i+2])[0]
    checksum = (checksum >> 16) + (checksum & 0xFFFF)
    checksum = ~checksum & 0xFFFF
    struct.pack_into("!H", icmp_header, 2, checksum)
    
    return ip_header + icmp_header

def test_forwarding():
    print("[*] 开始端到端转发测试...")
    
    # 1. 建立 TLS 连接
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    
    raw_socket = socket.create_connection((SERVER_IP, SERVER_PORT), timeout=10)
    ssl_socket = context.wrap_socket(raw_socket, server_hostname=SERVER_IP)
    print("[+] TLS 握手成功")
    
    # 2. 鉴权握手
    token_bytes = AUTH_TOKEN.encode('utf-8')
    header = struct.pack("!2sH", b"AH", len(token_bytes))
    ssl_socket.sendall(header + token_bytes)
    
    response = ssl_socket.recv(2)
    if response != b"OK":
        print(f"[-] 鉴权失败，服务器返回: {response}")
        return
    print("[+] 鉴权成功")
    
    # 3. 发送 Ping 数据包
    ping_packet = build_icmp_ping_packet()
    length = len(ping_packet)
    payload = struct.pack("!H", length) + ping_packet
    
    print(f"[->] 发送 Ping 数据包，长度: {length} 字节，目标: 8.8.8.8")
    ssl_socket.sendall(payload)
        
    
    # 4. 等待服务器回包...
    print("[*] 正在监听并过滤服务器回包...")
    try:
        ssl_socket.settimeout(5)
        buffer = b""
        start_time = time.time()
        
        while time.time() - start_time < 5: # 最多等待 5 秒
            # 读取 2 字节长度
            header = ssl_socket.recv(2)
            if len(header) < 2:
                continue
                
            length = struct.unpack("!H", header)[0]
            # 读取完整的 IP 数据包
            ip_packet = ssl_socket.recv(length)
            if len(ip_packet) < 20:
                continue
            
            # 解析 IP 头部
            proto = ip_packet[9] # 协议类型 (1 代表 ICMP)
            src_ip = socket.inet_ntoa(ip_packet[12:16])
            dst_ip = socket.inet_ntoa(ip_packet[16:20])
            
            print(f"[<-] 收到隧道数据包: 源 {src_ip} -> 目标 {dst_ip}, 协议: {proto}")
            
            # 💡 严格匹配：只有当源 IP 是 8.8.8.8，目标 IP 是我们的虚拟 IP，且协议是 ICMP 时才判定成功
            if src_ip == "8.8.8.8" and dst_ip == "192.168.50.2" and proto == 1:
                print("\n[🎉] ==================================================")
                print("[🎉] ✅ 恭喜！端到端网络转发测试 100% 成功！")
                print("[🎉] 服务器已成功将客户端流量 NAT 转发至外网，并正确返回了响应！")
                print("[🎉] ==================================================\n")
                ssl_socket.close()
                return True

    except socket.timeout:
        print("[-] ❌ 超时，未收到预期的 8.8.8.8 Ping 响应包")

    ssl_socket.close()
    return False


def main():
    """完整测试流程：通过 API 启动 VPN -> 端到端转发测试 -> 通过 API 停止 VPN。"""
    print("=" * 60)
    print("[*] 步骤 1：查询初始状态")
    api_status()

    print("\n" + "=" * 60)
    print("[*] 步骤 2：调用 /api/start_server 启动 VPN")
    start_result = api_start_server()
    if not start_result or not start_result.get("running"):
        print("[-] VPN 未能启动，测试终止")
        return

    # 等待服务端 listener / TUN 就绪
    time.sleep(2)
    api_status()

    print("\n" + "=" * 60)
    print("[*] 步骤 3：端到端转发测试")
    try:
        success = test_forwarding()
    except Exception as e:
        print(f"[-] 转发测试异常: {e}")
        success = False

    print("\n" + "=" * 60)
    print("[*] 步骤 4：调用 /api/stop_server 停止 VPN")
    api_stop_server()
    api_status()

    print("\n" + "=" * 60)
    print(f"[*] 测试结果: {'✅ 成功' if success else '❌ 失败'}")


if __name__ == "__main__":
    main()
