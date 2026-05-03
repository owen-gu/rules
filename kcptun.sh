#!/bin/bash

# ===== 基本参数 =====
KCP_BIN="/root/kcptun/server_linux_amd64"
KCP_LISTEN_PORT="12346"
TARGET_TUN_PORT="127.0.0.1:56116"
KCP_KEY="376415"

# ===== 写入 systemd 服务 =====
cat > /etc/systemd/system/kcptun.service <<EOF
[Unit]
Description=Kcptun Server (US Line Optimized)
After=network.target

[Service]
Type=simple
User=root
ExecStart=${KCP_BIN} \
-l :${KCP_LISTEN_PORT} \
-t ${TARGET_TUN_PORT} \
-key ${KCP_KEY} \
-crypt aes-128 \
-mode fast2 \
-mtu 1350 \
-sndwnd 1024 \
-rcvwnd 1024 \
-datashard 30 \
-parityshard 15 \
-dscp 0 \
-nocomp \
-acknodelay true \
-smuxver 1

Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

# ===== 防火墙配置 =====
iptables -I INPUT -p udp --dport ${KCP_LISTEN_PORT} -j ACCEPT
iptables -I OUTPUT -p udp --sport ${KCP_LISTEN_PORT} -j ACCEPT
ip6tables -I INPUT -p udp --dport ${KCP_LISTEN_PORT} -j ACCEPT 2>/dev/null

# ===== UFW 兼容 =====
if command -v ufw &> /dev/null; then
    ufw allow ${KCP_LISTEN_PORT}/udp
fi

# ===== 启动服务 =====
systemctl daemon-reload
systemctl enable kcptun
systemctl restart kcptun

# ===== 输出状态 =====
echo "====================================="
echo "✅ kcptun 已启动（美区优化版）"
echo "监听端口：${KCP_LISTEN_PORT}/UDP"
echo "转发目标：${TARGET_TUN_PORT}"
echo "加密方式：aes-128"
echo "====================================="

systemctl status kcptun --no-pager
