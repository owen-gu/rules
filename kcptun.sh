#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ===================== 固定配置 =====================
KCPTUN_INSTALL_DIR="/usr/local/kcptun"
KCPTUN_LOG_DIR="/var/log/kcptun"
BIN_FILE="$KCPTUN_INSTALL_DIR/server_linux_amd64"
CONFIG_FILE="$KCPTUN_INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/kcptun.service"

# ===================== 默认参数 =====================
D_LISTEN_PORT=29900
D_TARGET_ADDR="127.0.0.1"
D_TARGET_PORT=12984
D_KEY="very fast"
D_CRYPT="aes"
D_MODE="fast"
D_MTU=1350
D_SNDWND=512
D_RCVWND=512
D_DATASHARD=10
D_PARITYSHARD=3
D_DSCP=0
D_NOCOMP="true"
D_QUIET="false"
D_TCP="false"

# ===================== 工具函数 =====================
check_root() {
    [ "$(id -u)" -ne 0 ] && echo "请用 root 运行" && exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_number() {
    expr "$1" + 1 >/dev/null 2>&1
}

first_character() {
    echo "$1" | cut -c1
}

# ===================== 检查本地二进制 =====================
check_bin() {
    mkdir -p $KCPTUN_INSTALL_DIR
    mkdir -p $KCPTUN_LOG_DIR

    if [ ! -f "$BIN_FILE" ]; then
        echo "============================================="
        echo " 错误：请把服务端放到 $BIN_FILE"
        echo " 文件名必须是：server_linux_amd64"
        echo "============================================="
        exit 1
    fi
    chmod +x $BIN_FILE
}

# ===================== 配置交互 =====================
set_config() {
    echo "===== Kcptun 单实例配置 ====="

    read -p "监听端口 (默认 $D_LISTEN_PORT): " listen_port
    listen_port=${listen_port:-$D_LISTEN_PORT}

    read -p "加速目标IP (默认 $D_TARGET_ADDR): " target_addr
    target_addr=${target_addr:-$D_TARGET_ADDR}

    read -p "加速目标端口 (默认 $D_TARGET_PORT): " target_port
    target_port=${target_port:-$D_TARGET_PORT}

    read -p "密码 (默认 $D_KEY): " key
    key=${key:-$D_KEY}

    read -p "加密方式 (默认 $D_CRYPT): " crypt
    crypt=${crypt:-$D_CRYPT}

    read -p "加速模式 (默认 $D_MODE): " mode
    mode=${mode:-$D_MODE}

    read -p "MTU (默认 $D_MTU): " mtu
    mtu=${mtu:-$D_MTU}

    read -p "发送窗口 sndwnd (默认 $D_SNDWND): " sndwnd
    sndwnd=${sndwnd:-$D_SNDWND}

    read -p "接收窗口 rcvwnd (默认 $D_RCVWND): " rcvwnd
    rcvwnd=${rcvwnd:-$D_RCVWND}

    read -p "datashard (默认 $D_DATASHARD): " datashard
    datashard=${datashard:-$D_DATASHARD}

    read -p "parityshard (默认 $D_PARITYSHARD): " parityshard
    parityshard=${parityshard:-$D_PARITYSHARD}

    read -p "dscp (默认 $D_DSCP): " dscp
    dscp=${dscp:-$D_DSCP}

    read -p "关闭压缩? y/n (默认 $D_NOCOMP): " nocomp
    nocomp=${nocomp:-$D_NOCOMP}

    read -p "关闭日志? y/n (默认 $D_QUIET): " quiet
    quiet=${quiet:-$D_QUIET}

    read -p "使用TCP? y/n (默认 $D_TCP): " tcp
    tcp=${tcp:-$D_TCP}
}

# ===================== 生成配置文件 =====================
gen_config() {
    cat > $CONFIG_FILE <<EOF
{
  "listen": "0.0.0.0:$listen_port",
  "target": "$target_addr:$target_port",
  "key": "$key",
  "crypt": "$crypt",
  "mode": "$mode",
  "mtu": $mtu,
  "sndwnd": $sndwnd,
  "rcvwnd": $rcvwnd,
  "datashard": $datashard,
  "parityshard": $parityshard,
  "dscp": $dscp,
  "nocomp": $nocomp,
  "quiet": $quiet,
  "tcp": $tcp
}
EOF
}

# ===================== 生成 systemd 服务 =====================
gen_service() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Kcptun Server
After=network.target

[Service]
ExecStart=$BIN_FILE -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable kcptun
    systemctl restart kcptun
}

# ===================== 防火墙放行 =====================
firewall() {
    if command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port=${listen_port}/udp
        firewall-cmd --reload
    elif command_exists iptables; then
        iptables -I INPUT -p udp --dport $listen_port -j ACCEPT
    fi
}

# ===================== 主程序 =====================
main() {
    check_root
    check_bin
    set_config
    gen_config
    firewall
    gen_service

    echo "====================================="
    echo "安装完成！"
    echo "配置文件：$CONFIG_FILE"
    echo "状态：systemctl status kcptun"
    echo "====================================="
}

main
