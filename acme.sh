#!/bin/bash
set -e

# ===============================
# 高级证书管理脚本 V2.5.3
# ===============================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== 高级证书管理脚本 V2.5.3 ===${NC}"

# -----------------------------
# 0️⃣ 依赖安装
# -----------------------------
echo -e "\n[1/8] 检查环境依赖..."
if [ -f /etc/debian_version ]; then
    sudo apt-get update -y && sudo apt-get install -y curl socat cron lsof
elif [ -f /etc/redhat-release ]; then
    sudo yum install -y curl socat crontabs lsof
fi
sudo systemctl enable cron --now || true

ACME_BIN="$HOME/.acme.sh/acme.sh"
[ ! -f "$ACME_BIN" ] && curl https://get.acme.sh | sh && source "$HOME/.bashrc"

# -----------------------------
# 🔹 端口检测与防火墙处理
# -----------------------------
check_and_open_port(){
    local PORT=$1
    if lsof -iTCP:$PORT -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${RED}⚠️ 端口 $PORT 已被占用，尝试释放...${NC}"
        PID=$(lsof -iTCP:$PORT -sTCP:LISTEN -t)
        kill -9 $PID && echo "✅ 已释放端口 $PORT" || echo "❌ 无法自动释放端口 $PORT，请手动处理"
    else
        echo -e "${GREEN}✅ 端口 $PORT 可用${NC}"
    fi

    # 放行防火墙端口
    if command -v ufw >/dev/null; then
        sudo ufw allow $PORT/tcp && echo "✅ ufw: 端口 $PORT 已放行" || true
    elif command -v firewall-cmd >/dev/null; then
        sudo firewall-cmd --add-port=$PORT/tcp --permanent
        sudo firewall-cmd --reload
        echo "✅ firewalld: 端口 $PORT 已放行"
    fi
}

# -----------------------------
# 1️⃣ 验证模式选择
# -----------------------------
echo -e "\n请选择验证方式:"
echo "1) DNS API 验证 (推荐，支持泛域名和多域名)"
echo "2) Standalone 模式 (自动占用 80 端口验证，需空闲)"
echo "3) Webroot 模式 (将验证文件放入已有网站根目录，不占用端口)"
read -p "输入数字选择: " AUTH_MODE

case $AUTH_MODE in
    1)
        echo -e "\n请选择 DNS 服务商（官方 API 支持自动添加 TXT 记录）:"
        echo "1) Cloudflare (推荐，支持泛域名，需 API Token, Zone.DNS 编辑权限)"
        echo "2) Aliyun (阿里云，需 Access Key ID + Secret)"
        echo "3) GoDaddy (需 API Key + Secret)"
        read -p "选择: " DNS_CHOICE
        case $DNS_CHOICE in
            1) DNS_PROVIDER="dns_cf"; read -s -p "CF Token: " CF_Token; export CF_Token; echo "" ;;
            2) DNS_PROVIDER="dns_ali"; read -p "Ali Key: " Ali_Key; read -s -p "Ali Secret: " Ali_Secret; export Ali_Key; export Ali_Secret; echo "" ;;
            3) DNS_PROVIDER="dns_gd"; read -p "GD Key: " GD_Key; read -s -p "GD Secret: " GD_Secret; export GD_Key; export GD_Secret; echo "" ;;
            *) echo -e "${RED}无效选择，默认 Cloudflare${NC}"; DNS_PROVIDER="dns_cf"; read -s -p "CF Token: " CF_Token; export CF_Token; echo "" ;;
        esac
        ISSUE_CMD="--dns $DNS_PROVIDER"
        ;;
    2)
        echo -e "${RED}Standalone 模式需要端口 80 开放${NC}"
        check_and_open_port 80
        ISSUE_CMD="--standalone"
        ;;
    3)
        read -p "请输入网站根目录路径 (例: /var/www/html): " WEB_PATH
        check_and_open_port 80
        check_and_open_port 443
        ISSUE_CMD="--webroot $WEB_PATH"
        ;;
    *)
        echo -e "${RED}无效选择，退出脚本${NC}"; exit 1 ;;
esac

# -----------------------------
# 2️⃣ CA & 域名处理
# -----------------------------
echo -e "\n选择 CA:"
echo "1) Let's Encrypt | 2) ZeroSSL"
read -p "选择 CA: " CA_CHOICE

if [ "$CA_CHOICE" == "2" ]; then
    CA_SERVER="--server zerossl"
    if [ ! -f "$HOME/.acme.sh/account.conf" ] || ! grep -q "ZEROSSL_EMAIL" "$HOME/.acme.sh/account.conf"; then
        read -p "请输入邮箱 (ZeroSSL 注册需要): " EMAIL
        "$ACME_BIN" --register-account -m "$EMAIL" --server zerossl
    else
        echo "✅ 已检测到 ZeroSSL 已注册账户，跳过注册"
    fi
else
    CA_SERVER="--server letsencrypt"
fi

# -----------------------------
# 域名输入
# -----------------------------
read -p "请输入域名 (逗号分隔，支持泛域名 *.example.com): " DOMAIN_INPUT
IFS=',' read -ra DOMAINS <<< "$(echo $DOMAIN_INPUT | tr -d ' ')"
ACME_DOMAIN_ARGS=""
for d in "${DOMAINS[@]}"; do ACME_DOMAIN_ARGS="$ACME_DOMAIN_ARGS -d $d"; done
MAIN_DOMAIN="${DOMAINS[0]}"

# -----------------------------
# 3️⃣ 证书类型 & 路径 & Reloadcmd
# -----------------------------
echo -e "\n选择证书类型:"
echo "1) ECC | 2) RSA | 3) Both"
read -p "选择: " CERT_TYPE_CHOICE

read -p "请输入安装目录 (默认 ~/cert/$MAIN_DOMAIN): " CERT_DIR
CERT_DIR=${CERT_DIR:-"$HOME/cert/$MAIN_DOMAIN"}
mkdir -p "$CERT_DIR"

echo -e "\n选择更新证书后的操作:"
echo "1) 无 | 2) 系统命令 | 3) 重启 Docker"
read -p "选择: " RELOAD_TYPE
RELOADCMD=""
case $RELOAD_TYPE in
    2) read -p "命令: " RELOADCMD ;;
    3) read -p "容器名: " DOCKER_NAME; [ -n "$DOCKER_NAME" ] && RELOADCMD="docker restart $DOCKER_NAME" ;;
esac

# -----------------------------
# 4️⃣ 核心签发逻辑
# -----------------------------
issue_and_install(){
    local MODE=$1
    local KEY_LEN="ec-256"; local ECC_FLAG="--ecc"
    [ "$MODE" = "rsa" ] && KEY_LEN="2048" && ECC_FLAG=""
    
    echo -e "${GREEN}>>> 签发 $MODE 证书...${NC}"
    
    "$ACME_BIN" --issue $ACME_DOMAIN_ARGS --keylength $KEY_LEN $CA_SERVER $ISSUE_CMD
    
    RELOAD_ARG=${RELOADCMD:+--reloadcmd "$RELOADCMD"}
    "$ACME_BIN" --install-cert -d "$MAIN_DOMAIN" $ECC_FLAG \
        --key-file "$CERT_DIR/private_$MODE.key" \
        --fullchain-file "$CERT_DIR/fullchain_$MODE.crt" \
        $RELOAD_ARG
    
    echo -e "${GREEN}✅ $MODE 证书安装完成${NC}"
}

# -----------------------------
# 5️⃣ 执行证书签发
# -----------------------------
case $CERT_TYPE_CHOICE in
    1) issue_and_install "ecc" ;;
    2) issue_and_install "rsa" ;;
    3) issue_and_install "ecc"; issue_and_install "rsa" ;;
esac

echo -e "\n${GREEN}✅ 任务完成！证书已部署在: $CERT_DIR${NC}"
