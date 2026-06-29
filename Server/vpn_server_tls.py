import socket
import struct
import threading
import os
import ssl
import time

# 获取脚本所在目录的绝对路径
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# 尝试从 .env 文件加载环境变量
def load_env():
    env_path = os.path.join(SCRIPT_DIR, ".env")
    if os.path.exists(env_path):
        with open(env_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, value = line.split("=", 1)
                    key = key.strip()
                    value = value.strip()
                    # 去除引号
                    value = value.strip('"\'')
                    os.environ[key] = value

# 从环境变量读取 VALID_TOKENS，格式: token1,token2
def load_valid_tokens():
    # 先尝试加载 .env 文件
    load_env()
    tokens_str = os.getenv("VALID_TOKENS", "")
    if not tokens_str:
        # 如果环境变量未设置，使用默认值
        return {"my_secure_token_123456"}
    # 按逗号分割并去空格
    tokens = [t.strip() for t in tokens_str.split(",")]
    return set(tokens)

# 加载环境变量并获取有效tokens
VALID_TOKENS = load_valid_tokens()

# 全局列表：保存所有已连接的客户端 TLS sockets
connected_clients = []
clients_lock = threading.Lock()

def tun_reader_thread(tun_fd):
    """单个专用线程从 TUN 读取数据包，并广播给所有连接的客户端"""
    while True:
        try:
            ip_packet = os.read(tun_fd, 4096)
            if not ip_packet:
                continue

            length = len(ip_packet)
            header = struct.pack("!H", length)
            packet_to_send = header + ip_packet

            # 广播给所有已连接的客户端
            with clients_lock:
                failed_clients = []
                for client_socket in connected_clients:
                    try:
                        client_socket.sendall(packet_to_send)
                    except Exception as e:
                        # 发送失败 - 客户端已断开连接
                        failed_clients.append(client_socket)

                # 移除失败的客户端
                for failed in failed_clients:
                    connected_clients.remove(failed)
                    try:
                        failed.close()
                    except:
                        pass

        except Exception as e:
            print(f"[-] TUN 读取异常: {e}")
            # 如果真的出错了，给点时间然后重试，不要退出线程
            time.sleep(1)
            continue

def handle_client(tls_socket):
    try:
        # === 阶段一：安全鉴权 ===
        # 1. 读取前 4 字节（魔数 + Token长度）
        header = tls_socket.recv(4)
        if len(header) < 4:
            tls_socket.close()
            return

        magic, token_len = struct.unpack("!2sH", header)
        if magic != b"AH": # Auth Header
            print("[-] 鉴权失败：非法的协议头部")
            tls_socket.close()
            return

        # 2. 读取 Token 字符串
        token_bytes = tls_socket.recv(token_len)
        token = token_bytes.decode('utf-8')

        # 3. 校验 Token
        if token in VALID_TOKENS:
            print(f"[+] 客户端鉴权成功！Token: {token}")
            tls_socket.sendall(b"OK") # 回复成功
        else:
            print(f"[-] 鉴权失败：无效的 Token: {token}")
            tls_socket.sendall(b"ER") # 回复失败
            tls_socket.close()
            return

        # === 将客户端添加到全局列表，以便 TUN 读取线程可以广播回包 ===
        with clients_lock:
            connected_clients.append(tls_socket)
        print(f"[+] 客户端已加入转发列表，当前活跃客户端: {len(connected_clients)}")

        # === 阶段二：数据包转发 ===
        # 只负责：从客户端读取 IP 包 → 写入服务器 TUN 网卡
        buffer = b""
        while True:
            try:
                data = tls_socket.recv(65535)
                if not data:
                    break
                buffer += data
                while len(buffer) >= 2:
                    length = struct.unpack("!H", buffer[:2])[0]
                    if len(buffer) < 2 + length:
                        break
                    ip_packet = buffer[2:2+length]
                    buffer = buffer[2+length:]

                    # 写入 Linux TUN 网卡
                    os.write(tun_fd, ip_packet)
            except Exception as e:
                print(f"[-] 客户端接收异常: {e}")
                break

    except Exception as e:
        print(f"[-] 客户端处理异常: {e}")
    finally:
        # 从全局列表中移除该客户端
        with clients_lock:
            if tls_socket in connected_clients:
                connected_clients.remove(tls_socket)
                print(f"[+] 客户端已移除，当前活跃客户端: {len(connected_clients)}")
        try:
            tls_socket.close()
        except:
            pass

def main():
    # 创建 TUN 虚拟网卡
    # 注意：在 Linux 上运行需要 root 权限
    global tun_fd
    try:
        tun_fd = os.open("/dev/net/tun", os.O_RDWR)
        # TUNSETIFF flags: IFF_TUN (IP packet), IFF_NO_PI (no extra packet info)
        import fcntl
        import array
        ifr = array.array('B', b'tun0' + b'\x00' * 12 + struct.pack('H', 0x0001 | 0x1000))
        fcntl.ioctl(tun_fd, 0x400454ca, ifr) # TUNSETIFF
        print("[+] TUN 网卡 tun0 创建成功")
    except Exception as e:
        print(f"[-] 创建 TUN 网卡失败 (需要 root 权限): {e}")
        return

    # 启动专用的 TUN 读取线程（只启动一次！）
    tun_thread = threading.Thread(target=tun_reader_thread, args=(tun_fd,), daemon=True)
    tun_thread.start()
    print("[+] TUN 读取线程已启动")

    # 配置 TLS 上下文
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    cert_path = os.path.join(SCRIPT_DIR, "server.crt")
    key_path = os.path.join(SCRIPT_DIR, "server.key")
    context.load_cert_chain(certfile=cert_path, keyfile=key_path)

    # 启动 TCP 监听
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", 10011))
    listener.listen(128)
    print("[+] TLS VPN 服务器已启动，监听端口 10011...")

    while True:
        try:
            client_socket, addr = listener.accept()
            print(f"[+] 收到来自 {addr} 的连接，正在进行 TLS 握手...")
            # 用 TLS 包裹原始 Socket
            tls_client = context.wrap_socket(client_socket, server_side=True)
            print(f"[+] TLS 握手成功！")
            # 每个客户端一个线程处理入站流量
            threading.Thread(target=handle_client, args=(tls_client,), daemon=True).start()
        except Exception as e:
            print(f"[-] 建立 TLS 连接失败: {e}")

if __name__ == "__main__":
    main()
