#!/bin/bash
# One-key AnyTLS Installer (Standalone - No Database)
[[ $EUID -ne 0 ]] && echo "This script must be run as root" && exit 1

# System Checks and Dependencies
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add")
n=0
for i in `echo ${linux_os[@]}`
do
	if [ $i == $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') ]
	then
		break
	else
		n=$[$n+1]
	fi
done
if [ $n == 5 ]
then
	echo 当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配
	echo 默认使用APT包管理器
	n=0
fi
if [ -z $(type -P unzip) ]; then
	${linux_update[$n]}
	${linux_install[$n]} unzip
fi
if [ -z $(type -P curl) ]; then
	${linux_update[$n]}
	${linux_install[$n]} curl
fi
if [ -z $(type -P systemctl) ]; then
	${linux_update[$n]}
	${linux_install[$n]} systemctl
fi
if [ -z $(type -P openssl) ]; then
    ${linux_update[$n]}
    ${linux_install[$n]} openssl
fi
if [ -z $(type -P lsof) ]; then
    ${linux_update[$n]}
    ${linux_install[$n]} lsof
fi

function installtunnel(){
    mkdir -p /opt/argotunnel/
    
    LISTEN_IP="0.0.0.0"

    # AnyTLS Binary Download
    mkdir -p /opt/argotunnel/
    if [ ! -f "/opt/argotunnel/anytls-server" ]; then
        echo "Downloading anytls-server..."
        LATEST=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$LATEST" ]; then
             echo "Failed to fetch latest version. Using fallback v0.0.11"
             LATEST="v0.0.11"
        fi
        VERSION_NO_V=${LATEST#v}
        ARCH="amd64"
        case "$(uname -m)" in
            x86_64 | x64 | amd64 ) ARCH="amd64" ;;
            armv8 | arm64 | aarch64 ) ARCH="arm64" ;;
             * ) echo "Architecture $(uname -m) not supported for auto-download"; exit 1 ;;
        esac
        
        URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${VERSION_NO_V}_linux_${ARCH}.zip"
        echo "Downloading $URL..."
        curl -L -o /tmp/anytls.zip "$URL"
        if [ $? -ne 0 ]; then
             echo "Download failed."
             exit 1
        fi
        unzip -o /tmp/anytls.zip -d /tmp/anytls_bin
        mv /tmp/anytls_bin/anytls-server /opt/argotunnel/
        chmod +x /opt/argotunnel/anytls-server
        rm -rf /tmp/anytls.zip /tmp/anytls_bin
    fi
    
    if [ -f "/opt/argotunnel/anytls.pass" ]; then
        ANYTLS_PASS=$(cat /opt/argotunnel/anytls.pass)
    else
        ANYTLS_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
        echo "$ANYTLS_PASS" > /opt/argotunnel/anytls.pass
    fi

    echo "AnyTLS Mode Setup"
    port=443 # Force 443 for interactive setup context
    
    if [ -f "/opt/argotunnel/domain.txt" ]; then
        default_domain=$(cat /opt/argotunnel/domain.txt)
    fi
    
    if [ -n "$default_domain" ]; then
        estimated_base=$(echo $default_domain | head -n1 | awk '{print $1}' | cut -d. -f2-)
        read -p "输入域名 (例如: example.com, 默认: $estimated_base): " base_domain
        [ -z "$base_domain" ] && base_domain=$estimated_base
    else
        read -p "输入域名 (例如: example.com): " base_domain
    fi
    
    if [ -z "$base_domain" ] || [ $(echo $base_domain | grep "\." | wc -l) == 0 ]; then
        echo 域名格式不正确
        exit
    fi
    
    echo "Using domain: $base_domain"
    domain="$base_domain"
    echo "$domain" > /opt/argotunnel/domain.txt
    first_domain=$domain

    ENABLE_SSL="n"
    SKIP_ISSUANCE=0
    CERT_FILE="/opt/argotunnel/cert/fullchain.crt"
    
    echo "Checking for valid certificate..."
    if [ -f "$CERT_FILE" ]; then
         if openssl x509 -noout -text -in "$CERT_FILE" | grep -q "$first_domain"; then
             echo "Certificate domain match: YES"
             if openssl x509 -checkend 86400 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
                 echo "Certificate is valid."
                 ask_ssl="y"
                 SKIP_ISSUANCE=1
             else
                 echo "Certificate expired."
             fi
         else
             echo "Certificate domain match: NO"
         fi
    fi

    if [ "$SKIP_ISSUANCE" == "0" ]; then
         read -p "是否申请SSL证书 (需占用80端口)? (y/n, 默认n): " ask_ssl
    fi

    if [ "$ask_ssl" == "y" ] || [ "$ask_ssl" == "Y" ]; then
        ENABLE_SSL="y"
        if [ "$SKIP_ISSUANCE" == "0" ]; then
            if [ ! -f "/root/.acme.sh/acme.sh" ]; then
                curl https://get.acme.sh | sh
                /root/.acme.sh/acme.sh --register-account -m admin@${base_domain}
            fi

            # Check Port 80 occupancy
            if lsof -i :80 > /dev/null 2>&1; then
                echo "Warning: Port 80 is currently in use by the following process(es):"
                lsof -i :80
                echo "The script needs to stop these processes to request the certificate."
                read -p "Press Enter to stop these processes and continue, or Ctrl+C to abort..."
            fi

            systemctl stop nginx >/dev/null 2>&1
            fuser -k 80/tcp >/dev/null 2>&1
            
            /root/.acme.sh/acme.sh --issue --server letsencrypt --standalone -d $domain --force
            
            if [ $? -eq 0 ]; then
                echo "Certificate issued."
                mkdir -p /opt/argotunnel/cert
                /root/.acme.sh/acme.sh --install-cert -d ${first_domain} \
                    --key-file       /opt/argotunnel/cert/private.key  \
                    --fullchain-file /opt/argotunnel/cert/fullchain.crt \
                    --reloadcmd      "systemctl restart anytls.service"
                
                SSL_CERT_PATH="/opt/argotunnel/cert/fullchain.crt"
                SSL_KEY_PATH="/opt/argotunnel/cert/private.key"
            else
                echo "Certificate failed. Fallback to insecure."
                ENABLE_SSL="n"
            fi
        else
            SSL_CERT_PATH="/opt/argotunnel/cert/fullchain.crt"
            SSL_KEY_PATH="/opt/argotunnel/cert/private.key"
        fi
    fi

    # Generate AnyTLS Link
    echo -e "AnyTLS Links Generated\n" >/opt/argotunnel/anytls_links.txt
    
    link="anytls://${ANYTLS_PASS}@${domain}:${port}/?insecure=1#${isp}"
    if [ "$ENABLE_SSL" == "y" ]; then
         link="anytls://${ANYTLS_PASS}@${domain}:${port}/?insecure=0#${isp}"
    fi
    
    echo -e "--- AnyTLS Link for ${domain} (Port $port) ---" >>/opt/argotunnel/anytls_links.txt
    echo "$link" >>/opt/argotunnel/anytls_links.txt
    echo "" >>/opt/argotunnel/anytls_links.txt

    # Service Creation Logic
    echo "Creating AnyTLS Service..."
    cat > /lib/systemd/system/anytls.service <<EOF
[Unit]
Description=AnyTLS Server
After=network.target

[Service]
Type=simple
ExecStart=/opt/argotunnel/anytls-server -l $LISTEN_IP:$port -p $ANYTLS_PASS
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable anytls.service >/dev/null 2>&1
    systemctl --system daemon-reload
    systemctl restart anytls.service

    echo "------------------------------------------------"
    echo "Checking AnyTLS Service Status..."
    if systemctl is-active --quiet anytls.service; then
        echo -e "\033[32m[SUCCESS] AnyTLS is RUNNING\033[0m"
    else
        echo -e "\033[31m[ERROR] AnyTLS FAILED to start\033[0m"
        echo "Systemd Status output:"
        systemctl status anytls.service --no-pager
    fi
    echo "------------------------------------------------"
    cat /opt/argotunnel/anytls_links.txt
}


function uninstall_anytls() {
    echo "正在卸载 AnyTLS..."
    systemctl stop anytls.service >/dev/null 2>&1
    systemctl disable anytls.service >/dev/null 2>&1
    rm -f /lib/systemd/system/anytls.service
    rm -f /opt/argotunnel/anytls-server
    rm -f /opt/argotunnel/anytls.pass
    rm -f /opt/argotunnel/anytls_links.txt
    rm -f /tmp/anytls.zip
    rm -rf /tmp/anytls_bin
    
    # Optionally remove certs if they were created by us
    # rm -rf /opt/argotunnel/cert 
    
    systemctl --system daemon-reload
    echo "AnyTLS 卸载完成"
}

# START EXECUTION
ips=4
# Load ISP
country=$(curl -$ips -k -s https://cloudflare.com/cdn-cgi/trace | grep loc= | cut -d= -f2)
random_suffix=$(tr -dc 'A-Z' < /dev/urandom | head -c 3)
[ -z "$country" ] && country="UN"
isp="${country}${random_suffix}"

echo "=============================="
echo "   AnyTLS 一键安装/卸载脚本   "
echo "=============================="
echo "1. 安装 AnyTLS"
echo "2. 卸载 AnyTLS"
echo "0. 退出"
read -p "请选择菜单 (默认1): " menu
[ -z "$menu" ] && menu=1

if [ "$menu" == "1" ]; then
    installtunnel
    echo "AnyTLS模式安装完成"
elif [ "$menu" == "2" ]; then
    uninstall_anytls
else
    echo "退出"
    exit 0
fi


