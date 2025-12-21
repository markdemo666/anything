#!/bin/bash
# Hysteria2 All-in-One Installer (Bundled version of s-hy2)
# Original Author: sindricn
# Bundled by: Antigravity Agent

# ==============================================================================
# PART 1: Common Utilities (from common.sh)
# ==============================================================================
EXT_RED='\033[0;31m'
EXT_GREEN='\033[0;32m'
EXT_YELLOW='\033[1;33m'
EXT_BLUE='\033[0;34m'
EXT_NC='\033[0m'

log_info() { echo -e "${EXT_BLUE}[INFO]${EXT_NC} $1"; }
log_warn() { echo -e "${EXT_YELLOW}[WARN]${EXT_NC} $1"; }
log_error() { echo -e "${EXT_RED}[ERROR]${EXT_NC} $1"; }
log_success() { echo -e "${EXT_GREEN}[SUCCESS]${EXT_NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${EXT_RED}错误: 此脚本必须以 root 身份运行${EXT_NC}"
        exit 1
    fi
}

get_server_ip() {
    local ip=""
    ip=$(curl -s --connect-timeout 5 ipv4.icanhazip.com 2>/dev/null) || \
    ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null) || \
    ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
    echo "${ip:-127.0.0.1}"
    echo "${ip:-127.0.0.1}"
}

get_isp_name() {
    local country=$(curl -s https://cloudflare.com/cdn-cgi/trace | grep loc= | cut -d= -f2)
    [ -z "$country" ] && country="UN"
    local random_suffix=$(tr -dc 'A-Z' < /dev/urandom | head -c 3)
    echo "${country}${random_suffix}"
    echo "${country}${random_suffix}"
}

get_main_interface() {
    ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}'
}

# ==============================================================================
# PART 2: Service Management (from service.sh)
# ==============================================================================
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

install_service() {
    log_info "正在创建 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=5
# CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
# AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
# NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
}

# ==============================================================================
# PART 3: Optimization & ACME
# ==============================================================================
optimize_sysctl() {
    log_info "正在优化 QUIC/UDP 内核参数..."
    cat > /etc/sysctl.d/99-hysteria.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1
    log_success "内核参数优化完成。"
}

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
# AnyTLS/Shared Cert Directory
CERT_DIR="/opt/argotunnel"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"


handle_cert_issuance() {
    local domain=$1
    if [ -z "$domain" ]; then
        log_error "申请 SSL 证书需要提供域名。"
        return 1
    fi

    # Check for existing certificate
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        # Try to extract CN. handling different openssl output formats
        local cert_cn=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null | sed -n '/^subject/s/^.*CN *= *//p')
        
        # If successfully extracted and matches
        if [[ -n "$cert_cn" && "$cert_cn" == "$domain" ]]; then
            log_success "检测到域名 $domain 的现有证书。"
            read -e -p "是否使用现有证书? [Y/n]: " use_exist
            use_exist=${use_exist:-Y}
            if [[ "$use_exist" == "y" || "$use_exist" == "Y" ]]; then
                log_info "已选择使用现有证书。"
                return 0
            fi
        fi
    fi

    log_info "准备为 $domain 申请 SSL 证书..."
    
    # Install acme.sh if missing
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh
        /root/.acme.sh/acme.sh --register-account -m admin@${domain}
    fi

    # Check Port 80
    if lsof -i :80 > /dev/null 2>&1; then
        log_warn "80 端口被占用。正在尝试释放..."
        container_id=$(docker ps --format '{{.ID}}\t{{.Ports}}' | grep "0.0.0.0:80->" | awk '{print $1}')
        if [ -n "$container_id" ]; then
             log_info "正在停止 Docker 容器 $container_id..."
             docker stop $container_id
        else
             systemctl stop nginx >/dev/null 2>&1
             fuser -k 80/tcp >/dev/null 2>&1
        fi
        sleep 2
    fi
    
    /root/.acme.sh/acme.sh --issue --server letsencrypt --standalone -d $domain --force
    if [ $? -eq 0 ]; then
        log_success "证书申请成功。"
        mkdir -p "$CONFIG_DIR"
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d ${domain} \
            --key-file       "$KEY_FILE"  \
            --fullchain-file "$CERT_FILE" 
            #--reloadcmd      "systemctl restart hysteria-server"
        return 0
    else
        log_error "证书申请失败。"
        return 1
    fi
}

generate_config() {
    local port=${1:-443}
    local password=${2:-$(openssl rand -hex 8)}
    
    # 1. Ask for Domain
    read -e -p "请输入您的域名 (例如: example.com): " domain
    if [ -z "$domain" ]; then
        log_error "域名不能为空。"
        exit 1
    fi

    # 2. Issue Cert
    if ! handle_cert_issuance "$domain"; then
        read -e -p "SSL 证书申请失败。是否生成自签名证书代替? [y/N]: " fallback
        if [[ "$fallback" == "y" || "$fallback" == "Y" ]]; then
            log_info "正在生成自签名证书..."
            mkdir -p "$CERT_DIR"
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$KEY_FILE" \
                -out "$CERT_FILE" \
                -subj "/CN=$domain" \
                -days 3650 2>/dev/null
            local insecure=1
        else
            log_error "安装已中止。"
            exit 1
        fi
    else
        local insecure=0
    fi

    # 3. Port Hopping Configuration
    local hopping_config=""
    local mport_param=""
    echo ""
    read -e -p "是否开启端口跳跃 (Port Hopping)? [y/N]: " enable_hopping
    if [[ "$enable_hopping" == "y" || "$enable_hopping" == "Y" ]]; then
        read -e -p "请输入起始端口 (默认 20000): " hop_start
        hop_start=${hop_start:-20000}
        read -e -p "请输入结束端口 (默认 50000): " hop_end
        hop_end=${hop_end:-50000}
        
        # Apply iptables rule
        local iface=$(get_main_interface)
        if [[ -n "$iface" ]]; then
            log_info "正在应用端口跳跃规则 (接口: $iface, 范围: $hop_start-$hop_end -> $port)..."
            iptables -t nat -A PREROUTING -i $iface -p udp --dport $hop_start:$hop_end -j REDIRECT --to-ports $port
            
            # Persistence via Systemd
            cat > /etc/systemd/system/hysteria-hopping.service <<EOF
[Unit]
Description=Hysteria 2 Port Hopping Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A PREROUTING -i $iface -p udp --dport $hop_start:$hop_end -j REDIRECT --to-ports $port
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable hysteria-hopping.service
            systemctl start hysteria-hopping.service
            log_success "端口跳跃已启用并设置为开机自启。"
            
            mport_param="&mport=$hop_start-$hop_end"
        else
            log_error "无法检测到主网卡接口，端口跳跃设置失败。"
        fi
    fi

    # 3. Generate Config YAML
    cat > "$CONFIG_FILE" <<EOF
listen: :$port

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    log_success "配置文件已生成于 $CONFIG_FILE"
    
    # 4. Generate Link
    local insecure_param=""
    if [[ "$insecure" == "1" ]]; then
        insecure_param="&insecure=1"
    fi
    # Use ISP-based naming
    local node_name=$(get_isp_name)
    local link="hysteria2://${password}@${domain}:${port}/?sni=${domain}&obfs=none${insecure_param}${mport_param}#${node_name}"
    
    echo ""
    log_success "---------------------------------------------------"
    echo -e "${EXT_GREEN}Hysteria 2 连接链接:${EXT_NC}"
    echo -e "${EXT_YELLOW}$link${EXT_NC}"
    log_success "---------------------------------------------------"
    echo ""
    echo "域名: $domain"
    echo "密码: $password"
    echo "端口: $port"
}


# ==============================================================================
# PART 4: Installation Logic (Main)
# ==============================================================================
install_hysteria() {
    log_info "正在安装依赖..."
    if command -v apt >/dev/null; then
        apt update && apt install -y curl wget unzip openssl lsof iptables
    elif command -v yum >/dev/null; then
        yum install -y curl wget unzip openssl lsof iptables
    fi

    log_info "正在下载 Hysteria 2 二进制文件..."
    # Always get latest release
    local latest_url=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep "browser_download_url" | grep "linux-amd64" | head -1 | cut -d '"' -f 4)
    # Fallback if GitHub API fails
    if [[ -z "$latest_url" ]]; then
         latest_url="https://github.com/apernet/hysteria/releases/download/app/v2.2.4/hysteria-linux-amd64"
    fi
     
    # Direct GitHub Download
    log_info "下载地址: $latest_url"
    
    curl -L -o /usr/local/bin/hysteria "$latest_url"
    chmod +x /usr/local/bin/hysteria
    
    if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
        log_error "Hysteria 二进制文件安装失败。"
        exit 1
    fi
    log_success "Hysteria 安装成功。"
    
    optimize_sysctl
    generate_config 443 
    install_service
    systemctl restart hysteria-server
    
    log_success "Hysteria 2 正在运行!"
    echo "---------------------------------------------------"
    echo "配置文件: $CONFIG_FILE"
    echo "端口: 443"
    echo "密码: $(grep 'password:' $CONFIG_FILE | awk '{print $2}')"
    echo "---------------------------------------------------"
}

uninstall_hysteria() {
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f "$SERVICE_FILE"
    rm -f /usr/local/bin/hysteria
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    log_success "Hysteria 2 已卸载。"
}

# ==============================================================================
# Entry Point
# ==============================================================================
check_root

echo "=================================="
echo "   Hysteria 2 一键安装脚本   "
echo "=================================="
echo "1. 安装 Hysteria 2 (支持 ACME 证书)"
echo "2. 卸载 Hysteria 2"
echo "0. 退出"
read -p "请选择 [1]: " choice
choice=${choice:-1}

case $choice in
    1) install_hysteria ;;
    2) uninstall_hysteria ;;
    *) exit 0 ;;
esac
