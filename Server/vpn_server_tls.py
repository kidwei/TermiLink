import socket
import struct
import threading
import os
import ssl
import time

from fastapi import FastAPI, Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import uvicorn

# Get the absolute path of the script directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Try to load environment variables from .env file
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
                    # Strip quotes
                    value = value.strip('"\'')
                    os.environ[key] = value

# Read VALID_TOKENS from environment variable, format: token1,token2
def load_valid_tokens():
    # Try to load .env file first
    load_env()
    tokens_str = os.getenv("VALID_TOKENS", "")
    if not tokens_str:
        # If environment variable is not set, use default value
        return {"my_secure_token_123456"}
    # Split by comma and strip whitespace
    tokens = [t.strip() for t in tokens_str.split(",")]
    return set(tokens)

# Read ADMIN_TOKEN from environment variable, used to protect the control API
def load_admin_token():
    # load_valid_tokens() already loaded the .env file
    token = os.getenv("ADMIN_TOKEN", "")
    if not token:
        # If environment variable is not set, use default value
        return "my_admin_token_123456"
    return token.strip()

# Load environment variables and get valid tokens
VALID_TOKENS = load_valid_tokens()
# Admin token that protects the control API endpoints
ADMIN_TOKEN = load_admin_token()

# Global list: stores all connected client TLS sockets
connected_clients = []
clients_lock = threading.Lock()


class VPNServer:
    """Manages the lifecycle of the TLS VPN service so it can be
    started/stopped on demand via the FastAPI control endpoints."""

    def __init__(self, host="0.0.0.0", port=10011):
        self.host = host
        self.port = port
        self.running = False
        self.tun_fd = None
        self.listener = None
        self.tun_thread = None
        self.accept_thread = None
        self._lock = threading.Lock()

    def is_running(self):
        return self.running

    def start(self):
        """Start the VPN service. Returns (success, message)."""
        with self._lock:
            if self.running:
                return False, "VPN service is already running"

            # Create TUN virtual network interface
            # Note: root privileges required to run on Linux
            try:
                tun_fd = os.open("/dev/net/tun", os.O_RDWR)
                # TUNSETIFF flags: IFF_TUN (IP packet), IFF_NO_PI (no extra packet info)
                import fcntl
                import array
                ifr = array.array('B', b'tun0' + b'\x00' * 12 + struct.pack('H', 0x0001 | 0x1000))
                fcntl.ioctl(tun_fd, 0x400454ca, ifr)  # TUNSETIFF
                print("[+] TUN interface tun0 created successfully")
            except Exception as e:
                print(f"[-] Failed to create TUN interface (requires root privileges): {e}")
                return False, f"Failed to create TUN interface: {e}"

            # Configure TLS context
            context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
            cert_path = os.path.join(SCRIPT_DIR, "server.crt")
            key_path = os.path.join(SCRIPT_DIR, "server.key")

            # Check if certificate files exist
            if not os.path.exists(cert_path) or not os.path.exists(key_path):
                os.close(tun_fd)
                msg = f"TLS certificate files not found at {SCRIPT_DIR}"
                print(f"[-] {msg}")
                print("[-] Please generate server.crt and server.key before running")
                return False, msg

            context.load_cert_chain(certfile=cert_path, keyfile=key_path)
            print(f"[+] TLS certificate loaded: {cert_path} / {key_path}")

            # Start TCP listener
            try:
                listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((self.host, self.port))
                listener.listen(128)
            except Exception as e:
                os.close(tun_fd)
                print(f"[-] Failed to bind listener: {e}")
                return False, f"Failed to bind listener: {e}"

            self.tun_fd = tun_fd
            self.listener = listener
            self.running = True

            # Start dedicated TUN reader thread
            self.tun_thread = threading.Thread(target=self._tun_reader_loop, daemon=True)
            self.tun_thread.start()
            print("[+] TUN reader thread started")

            # Start accept loop thread
            self.accept_thread = threading.Thread(
                target=self._accept_loop, args=(context,), daemon=True
            )
            self.accept_thread.start()
            print(f"[+] TLS VPN server started, listening on port {self.port}...")

            return True, "VPN service started"

    def stop(self):
        """Stop the VPN service. Returns (success, message)."""
        with self._lock:
            if not self.running:
                return False, "VPN service is not running"

            self.running = False

            # Close listener to break the accept loop
            if self.listener is not None:
                try:
                    self.listener.close()
                except Exception:
                    pass
                self.listener = None

            # Disconnect all connected clients
            with clients_lock:
                for client_socket in connected_clients:
                    try:
                        client_socket.close()
                    except Exception:
                        pass
                connected_clients.clear()

            # Close TUN interface to break the reader loop
            if self.tun_fd is not None:
                try:
                    os.close(self.tun_fd)
                except Exception:
                    pass
                self.tun_fd = None

            print("[+] VPN service stopped")
            return True, "VPN service stopped"

    def _tun_reader_loop(self):
        """Dedicated thread reads packets from TUN and broadcasts to all connected clients"""
        while self.running:
            try:
                ip_packet = os.read(self.tun_fd, 4096)
                if not ip_packet:
                    continue

                length = len(ip_packet)
                header = struct.pack("!H", length)
                packet_to_send = header + ip_packet

                # Broadcast to all connected clients
                with clients_lock:
                    failed_clients = []
                    for client_socket in connected_clients:
                        try:
                            client_socket.sendall(packet_to_send)
                        except Exception:
                            # Send failed - client disconnected
                            failed_clients.append(client_socket)

                    # Remove failed clients
                    for failed in failed_clients:
                        connected_clients.remove(failed)
                        try:
                            failed.close()
                        except Exception:
                            pass

            except Exception as e:
                if not self.running:
                    break
                print(f"[-] TUN read exception: {e}")
                # If an error occurs, wait and retry, don't exit the thread
                time.sleep(1)
                continue

    def _accept_loop(self, context):
        while self.running:
            try:
                client_socket, addr = self.listener.accept()
                print(f"[+] [{addr}] New connection received, starting TLS handshake...")
                # Wrap raw socket with TLS
                tls_client = context.wrap_socket(client_socket, server_side=True)
                print(f"[+] [{addr}] TLS handshake completed successfully")
                # One thread per client to handle inbound traffic
                threading.Thread(
                    target=self._handle_client, args=(tls_client,), daemon=True
                ).start()
            except Exception as e:
                if not self.running:
                    break
                print(f"[-] Failed to establish TLS connection: {e}")

    def _handle_client(self, tls_socket):
        client_addr = tls_socket.getpeername()
        try:
            # === Phase 1: Authentication ===
            # 1. Read first 4 bytes (magic + Token length)
            header = tls_socket.recv(4)
            if len(header) < 4:
                print(f"[-] [{client_addr}] Authentication failed: incomplete header")
                tls_socket.close()
                return

            magic, token_len = struct.unpack("!2sH", header)
            if magic != b"AH":  # Auth Header
                print(f"[-] [{client_addr}] Authentication failed: invalid protocol header")
                tls_socket.close()
                return

            # 2. Read Token string
            token_bytes = tls_socket.recv(token_len)
            token = token_bytes.decode('utf-8')

            # 3. Verify Token
            if token in VALID_TOKENS:
                print(f"[+] [{client_addr}] Authentication succeeded, Token: {token}")
                tls_socket.sendall(b"OK")  # Reply success
            else:
                print(f"[-] [{client_addr}] Authentication failed: invalid Token: {token}")
                tls_socket.sendall(b"ER")  # Reply error
                tls_socket.close()
                return

            # === Add client to global list so TUN reader thread can broadcast packets back ===
            with clients_lock:
                connected_clients.append(tls_socket)
            print(f"[+] [{client_addr}] Client added to forwarding list, active clients: {len(connected_clients)}")
            print(f"[+] [{client_addr}] Connection established successfully")

            # === Phase 2: Packet forwarding ===
            # Responsibility: read IP packets from client → write to server TUN interface
            buffer = b""
            packet_count = 0
            while self.running:
                try:
                    data = tls_socket.recv(65535)
                    if not data:
                        print(f"[+] [{client_addr}] Client disconnected, connection closed")
                        break
                    buffer += data
                    packet_count += 1
                    while len(buffer) >= 2:
                        length = struct.unpack("!H", buffer[:2])[0]
                        if len(buffer) < 2 + length:
                            break
                        ip_packet = buffer[2:2 + length]
                        buffer = buffer[2 + length:]

                        # Write to Linux TUN interface
                        if self.tun_fd is not None:
                            os.write(self.tun_fd, ip_packet)
                except Exception as e:
                    print(f"[-] [{client_addr}] Client receive exception: {e}")
                    break

        except Exception as e:
            print(f"[-] [{client_addr}] Client handling exception: {e}")
        finally:
            # Remove client from global list
            with clients_lock:
                if tls_socket in connected_clients:
                    connected_clients.remove(tls_socket)
                    print(f"[+] [{client_addr}] Client removed, active clients: {len(connected_clients)}")
            try:
                tls_socket.close()
            except Exception:
                pass


# Single shared VPN service instance controlled by the API
vpn_server = VPNServer()

app = FastAPI(title="VPNTool Control API")

# Bearer token authentication for the control API
security = HTTPBearer()


def verify_admin_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Validate the Bearer token against ADMIN_TOKEN."""
    if credentials.credentials != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid or missing admin token")
    return credentials.credentials


@app.get("/api/status")
def status(_: str = Depends(verify_admin_token)):
    return {"running": vpn_server.is_running()}


@app.post("/api/start_server")
def start_server(_: str = Depends(verify_admin_token)):
    success, message = vpn_server.start()
    return {"success": success, "message": message, "running": vpn_server.is_running()}


@app.post("/api/stop_server")
def stop_server(_: str = Depends(verify_admin_token)):
    success, message = vpn_server.stop()
    return {"success": success, "message": message, "running": vpn_server.is_running()}


if __name__ == "__main__":
    # Launch the FastAPI control server. The VPN itself only starts once
    # /api/start_server is called, and stops on /api/stop_server.
    uvicorn.run(app, host="0.0.0.0", port=8000)
