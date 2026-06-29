#!/bin/bash
set -e

# ==============================================
# TermiLink TLS VPN 服务器一键安装脚本
# 支持 Ubuntu / Debian / CentOS
# ==============================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║             TermiLink TLS VPN 一键安装脚本                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
   error "请使用 root 用户运行此脚本 (sudo bash install.sh)"
   exit 1
fi

# 检测是否有 uv
USE_UV=false
if command -v uv &> /dev/null; then
    USE_UV=true
    info "检测到 uv，将使用 uv run 运行服务"
else
    info "未检测 to uv，将使用系统 python3 运行服务"
fi

# 1. 安装依赖
info "1/6 安装系统依赖..."
if command -v apt-get &> /dev/null; then
    apt-get update -y || true
    # 💡 加上 --no-upgrade 避免升级已有包，并在安装失败时尝试继续，防止因 404 中断
    apt-get install -y --no-upgrade python3 python3-pip iptables iproute2 openssl || {
        warn "部分软件包升级失败，尝试忽略并继续..."
        apt-get install -y python3 python3-pip iptables iproute2 || true
    }
elif command -v yum &> /dev/null; then
    yum install -y python3 python3-pip iptables iproute openssl || true
else
    error "不支持的操作系统，仅支持 Ubuntu/Debian/CentOS"
    exit 1
fi


# 2. 启用 IP 转发
info "2/6 启用内核 IP 转发..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p
info "IP 转发已永久启用"

# 3. 配置并激活 TUN 网卡
info "3/6 配置并激活 TUN 虚拟网卡..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# 💡 自动创建并激活 tun0 网卡，绑定 192.168.50.1 地址
if ! ip link show tun0 &> /dev/null; then
    info "正在创建 tun0 虚拟网卡..."
    ip tuntap add dev tun0 mode tun || true
fi

# 绑定 IP 并启动网卡
ip addr add 192.168.50.1/24 dev tun0 2>/dev/null || true
ip link set dev tun0 up
info "TUN 设备已配置并成功激活 (IP: 192.168.50.1, 状态: UP)"

# 4. 配置 iptables 防火墙和 NAT
info "4/6 配置 iptables NAT 转发规则..."

# 自动检测公网网卡
PUBLIC_IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
info "检测到公网网卡: $PUBLIC_IFACE"

# 清除旧规则（防止 10.0.0.x 残留规则干扰）
iptables -t nat -F POSTROUTING
iptables -F FORWARD

# 添加全新的 192.168.50.0/24 网段 NAT 规则
iptables -t nat -A POSTROUTING -s 192.168.50.0/24 -o $PUBLIC_IFACE -j MASQUERADE
iptables -A FORWARD -i tun0 -o $PUBLIC_IFACE -j ACCEPT
iptables -A FORWARD -i $PUBLIC_IFACE -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# 开放 10011 端口（确保与 vpn_server_tls.py 端口一致）
iptables -I INPUT -p tcp --dport 10011 -j ACCEPT

# 保存 iptables 规则
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables.rules
    info "iptables 规则已保存到 /etc/iptables.rules"
fi

# 5. 安装 VPN 服务器脚本和证书
info "5/6 安装服务器脚本和证书..."
mkdir -p /usr/local/termlink/
cp vpn_server_tls.py /usr/local/termlink/
cp server.crt server.key /usr/local/termlink/
# 安装 .env 配置文件（如果存在）
if [ -f ".env" ]; then
    cp .env /usr/local/termlink/
    info ".env 配置文件已安装"
else
    # 创建默认 .env 文件
    cat > /usr/local/termlink/.env << EOF
# TermiLink VPN 配置
# 合法 Token 列表，多个用逗号分隔
VALID_TOKENS=my_secure_token_123456,another_token_789
EOF
    info "已创建默认 .env 配置文件"
fi
chmod +x /usr/local/termlink/vpn_server_tls.py
info "文件已安装到 /usr/local/termlink/"

# 6. 创建 systemd 服务
info "6/6 创建系统服务..."
if [ "$USE_UV" = true ]; then
cat > /etc/systemd/system/termlink-vpn.service << EOF
[Unit]
Description=TermiLink TLS VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/termlink
EnvironmentFile=/usr/local/termlink/.env
ExecStart=/usr/local/bin/uv run /usr/local/termlink/vpn_server_tls.py
Restart=always
RestartSec=5
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
else
cat > /etc/systemd/system/termlink-vpn.service << EOF
[Unit]
Description=TermiLink TLS VPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/termlink
EnvironmentFile=/usr/local/termlink/.env
ExecStart=/usr/bin/python3 /usr/local/termlink/vpn_server_tls.py
Restart=always
RestartSec=5
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable termlink-vpn

echo ""
info "✅ 安装完成！"
echo ""
if [ "$USE_UV" = true ]; then
    info "服务已配置为使用 uv run 运行"
else
    info "服务已配置为使用系统 python3 运行"
fi
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  使用说明："
echo ""
echo "  启动服务:    systemctl start termlink-vpn"
echo "  停止服务:    systemctl stop termlink-vpn"
echo "  查看日志:    journalctl -u termlink-vpn -f"
echo "  查看状态:    systemctl status termlink-vpn"
echo "  重新加载:    systemctl restart termlink-vpn"
echo ""
echo "  手动运行:    cd /usr/local/termlink/ && $([ "$USE_UV" = true ] && echo "uv run" || echo "python3") vpn_server_tls.py"
echo ""
echo "  安装目录:    /usr/local/termlink/"
echo "  配置文件:    /usr/local/termlink/.env"
echo "  监听端口:    10011/TCP"
echo "  虚拟子网:    192.168.50.0/24"
echo "  服务器IP:    192.168.50.1"
echo "═══════════════════════════════════════════════════════════════"
echo ""
warn "⚠️  请确保你的服务器安全组/防火墙已开放 10011 端口的 TCP 连接"
warn "⚠️  请编辑 /usr/local/termlink/.env 修改 VALID_TOKENS"
echo ""
