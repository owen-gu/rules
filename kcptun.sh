#!/bin/sh

: <<-'EOF'
Copyright 2017-2019 Xingwang Liao <kuoruan@gmail.com>
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
you may obtain a copy of the License at
	http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
EOF

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 版本信息，请勿修改
# =================
SHELL_VERSION=26
CONFIG_VERSION=7
INIT_VERSION=3
# =================

# ========== 关键修改：本地固定目录，不联网下载 ==========
KCPTUN_INSTALL_DIR='/usr/local/kcptun'
KCPTUN_LOG_DIR='/var/log/kcptun'

# 禁用自动下载jq，使用系统自带
JQ_BIN="$(command -v jq)"

# 默认参数
# =======================
D_LISTEN_PORT=29900
D_TARGET_ADDR='127.0.0.1'
D_TARGET_PORT=12984
D_KEY="very fast"
D_CRYPT='aes'
D_MODE='fast'
D_MTU=1350
D_SNDWND=512
D_RCVWND=512
D_DATASHARD=10
D_PARITYSHARD=3
D_DSCP=0
D_NOCOMP='true'
D_QUIET='false'
D_TCP='false'
D_SNMPPERIOD=60
D_PPROF='false'

# 隐藏参数
D_ACKNODELAY='false'
D_NODELAY=1
D_INTERVAL=20
D_RESEND=2
D_NC=1
D_SOCKBUF=67108868
D_SMUXBUF=67108868
D_KEEPALIVE=10

D_SMUXVER=2
D_STREAMBUF=16777217
# ======================

current_instance_id=""
run_user='kcptun'

clear

cat >&1 <<-'EOF'
#########################################################
# Kcptun 服务端一键安装脚本【本地文件版】                #
# 已改造：不联网下载，使用服务器本地已有二进制文件       #
# 支持安装、配置、多实例、卸载、防火墙、supervisor       #
#########################################################
EOF

# 打印帮助信息
usage() {
	cat >&1 <<-EOF

	请使用: $0 <option>

	可使用的参数 <option> 包括:

	    install          仅配置安装(使用本地已有程序)
	    uninstall        卸载
	    add              添加一个实例, 多端口加速
	    reconfig <id>    重新配置实例
	    show <id>        显示实例详细配置
	    log <id>         显示实例日志
	    del <id>         删除一个实例

	注: 已移除 update / manual 联网更新功能
	EOF

	exit $1
}

# 判断命令是否存在
command_exists() {
	command -v "$@" >/dev/null 2>&1
}

# 判断输入内容是否为数字
is_number() {
	expr "$1" + 1 >/dev/null 2>&1
}

# 按任意键继续
any_key_to_continue() {
	echo "请按任意键继续或 Ctrl + C 退出"
	local saved=""
	saved="$(stty -g)"
	stty -echo
	stty cbreak
	dd if=/dev/tty bs=1 count=1 2>/dev/null
	stty -raw
	stty echo
	stty $saved
}

first_character() {
	if [ -n "$1" ]; then
		echo "$1" | cut -c1
	fi
}

# 检查是否具有 root 权限
check_root() {
	local user=""
	user="$(id -un 2>/dev/null || true)"
	if [ "$user" != "root" ]; then
		cat >&2 <<-'EOF'
		权限错误, 请使用 root 用户运行此脚本!
		EOF
		exit 1
	fi
}

# 获取服务器的IP地址
get_server_ip() {
	local server_ip=""
	local interface_info=""

	if command_exists ip; then
		interface_info="$(ip addr)"
	elif command_exists ifconfig; then
		interface_info="$(ifconfig)"
	fi

	server_ip=$(echo "$interface_info" | \
		grep -oE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | \
		grep -vE "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | \
		head -n 1)

	if [ -z "$server_ip" ]; then
		 server_ip="$(wget -qO- --no-check-certificate https://ipv4.icanhazip.com 2>/dev/null || curl -s icanhazip.com)"
	fi

	echo "$server_ip"
}

# 禁用 selinux
disable_selinux() {
	local selinux_config='/etc/selinux/config'
	if [ -s "$selinux_config" ]; then
		if grep -q "SELINUX=enforcing" "$selinux_config"; then
			sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' "$selinux_config"
			setenforce 0
		fi
	fi
}

# 获取操作系统信息
get_os_info() {
	lsb_dist=""
	dist_version=""
	if command_exists lsb_release; then
		lsb_dist="$(lsb_release -si)"
	fi

	if [ -z "$lsb_dist" ]; then
		[ -r /etc/lsb-release ] && lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
		[ -r /etc/debian_version ] && lsb_dist='debian'
		[ -r /etc/fedora-release ] && lsb_dist='fedora'
		[ -r /etc/oracle-release ] && lsb_dist='oracleserver'
		[ -r /etc/centos-release ] && lsb_dist='centos'
		[ -r /etc/redhat-release ] && lsb_dist='redhat'
		[ -r /etc/photon-release ] && lsb_dist='photon'
		[ -r /etc/os-release ] && lsb_dist="$(. /etc/os-release && echo "$ID")"
	fi

	lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

	if [ "${lsb_dist}" = "redhatenterpriseserver" ]; then
		lsb_dist='redhat'
	fi

	case "$lsb_dist" in
		ubuntu)
			if command_exists lsb_release; then
				dist_version="$(lsb_release --codename | cut -f2)"
			fi
			if [ -z "$dist_version" ] && [ -r /etc/lsb-release ]; then
				dist_version="$(. /etc/lsb-release && echo "$DISTRIB_CODENAME")"
			fi
			;;
		debian|raspbian)
			dist_version="$(cat /etc/debian_version | sed 's/\/.*//' | sed 's/\..*//')"
			case "$dist_version" in
				9) dist_version="stretch" ;;
				8) dist_version="jessie" ;;
				7) dist_version="wheezy" ;;
			esac
			;;
		oracleserver)
			lsb_dist="oraclelinux"
			dist_version="$(rpm -q --whatprovides redhat-release --queryformat "%{VERSION}\n" | sed 's/\/.*//' | sed 's/\..*//' | sed 's/Server*//')"
			;;
		fedora|centos|redhat)
			dist_version="$(rpm -q --whatprovides ${lsb_dist}-release --queryformat "%{VERSION}\n" | sed 's/\/.*//' | sed 's/\..*//' | sed 's/Server*//' | sort | tail -1)"
			;;
		*)
			if command_exists lsb_release; then
				dist_version="$(lsb_release --codename | cut -f2)"
			fi
			if [ -z "$dist_version" ] && [ -r /etc/os-release ]; then
				dist_version="$(. /etc/os-release && echo "$VERSION_ID")"
			fi
			;;
	esac

	if [ -z "$lsb_dist" ] || [ -z "$dist_version" ]; then
		cat >&2 <<-EOF
		无法确定服务器系统版本信息。
		EOF
		exit 1
	fi
}

# 获取架构
get_arch() {
	architecture="$(uname -m)"
	case "$architecture" in
		amd64|x86_64)
			spruce_type='linux-amd64'
			file_suffix='linux_amd64'
			;;
		i386|i486|i586|i686|x86)
			spruce_type='linux-386'
			file_suffix='linux_386'
			;;
		*)
			cat 1>&2 <<-EOF
			当前仅支持 32/64 位 x86 系统
			你的系统为: $architecture
			EOF
			exit 1
			;;
	esac
}

# 改造：不自动下载jq，只检测系统有没有jq
install_jq() {
	if ! command_exists jq; then
		cat >&2 <<-EOF
		请先手动安装 jq 工具：
		CentOS: yum install -y jq
		Debian/Ubuntu: apt install -y jq
		EOF
		exit 1
	fi
	JQ_BIN=$(command -v jq)
}

# 读取json
get_json_string() {
	install_jq
	local content="$1"
	local selector="$2"
	local regex="$3"
	local str=""
	if [ -n "$content" ]; then
		str="$(echo "$content" | $JQ_BIN -r "$selector" 2>/dev/null)"
		if [ -n "$str" ] && [ -n "$regex" ]; then
			str="$(echo "$str" | grep -oE "$regex")"
		fi
	fi
	echo "$str"
}

# 配置文件路径
get_current_file() {
	case "$1" in
		config) printf '%s/server-config%s.json' "$KCPTUN_INSTALL_DIR" "$current_instance_id" ;;
		log) printf '%s/server%s.log' "$KCPTUN_LOG_DIR" "$current_instance_id" ;;
		snmp) printf '%s/snmplog%s.log' "$KCPTUN_LOG_DIR" "$current_instance_id" ;;
		supervisor) printf '/etc/supervisor/conf.d/kcptun%s.conf' "$current_instance_id" ;;
	esac
}

# 实例数量
get_instance_count() {
	if [ -d '/etc/supervisor/conf.d/' ]; then
		ls -l '/etc/supervisor/conf.d/' 2>/dev/null | grep "^-" | awk '{print $9}' | grep -cP "^kcptun\d*\.conf$"
	else
		echo "0"
	fi
}

# 改造：直接使用本地已有二进制，跳过下载
install_kcptun() {
	if [ -z "$file_suffix" ]; then
		get_arch
	fi

	local kcptun_server_file="$(get_kcptun_server_file)"

	# 创建目录
	[ ! -d "$KCPTUN_INSTALL_DIR" ] && mkdir -p "$KCPTUN_INSTALL_DIR"
	[ ! -d "$KCPTUN_LOG_DIR" ] && mkdir -p "$KCPTUN_LOG_DIR" && chmod a+w "$KCPTUN_LOG_DIR"

	# 检查本地是否已有服务端程序
	if [ ! -f "$kcptun_server_file" ]; then
		cat >&2 <<-EOF
		=============================================
		错误：未找到本地 kcptun 服务端二进制文件
		请手动把服务端文件放到：
		${KCPTUN_INSTALL_DIR}/server_${file_suffix}
		并赋予执行权限 chmod +x 文件名
		=============================================
		EOF
		exit 1
	fi

	chmod a+x "$kcptun_server_file"
}

# 安装依赖（仅系统基础依赖，不下载任何kcptun/jq）
install_deps() {
	if [ -z "$lsb_dist" ]; then
		get_os_info
	fi

	case "$lsb_dist" in
		ubuntu|debian|raspbian)
			apt-get update -y >/dev/null 2>&1
			apt-get install -y -q wget ca-certificates gawk tar python python-pip >/dev/null 2>&1
			;;
		fedora|centos|redhat|oraclelinux|photon)
			yum install -y -q wget ca-certificates gawk tar python python-pip epel-release >/dev/null 2>&1
			;;
		*)
			cat >&2 <<-EOF
			暂时不支持当前系统：${lsb_dist} ${dist_version}
			EOF
			exit 1
			;;
	esac

	install_jq
}

# 安装supervisor（保留原逻辑，仅屏蔽在线启动文件下载）
install_supervisor() {
	if [ -s /etc/supervisord.conf ] && command_exists supervisord; then
		cat >&2 <<-EOF
		检测到已有Supervisor，避免冲突请先卸载旧版
		EOF
		exit 1
	fi

	if ! command_exists python; then
		cat >&2 <<-'EOF'
		python 环境未安装，请手动安装 python2.7+
		EOF
		exit 1
	fi

	local python_version="$(python -V 2>&1)"
	local version_string="$(echo "$python_version" | cut -d' ' -f2 | head -n1)"
	local major_version="$(echo "$version_string" | cut -d'.' -f1)"
	local minor_version="$(echo "$version_string" | cut -d'.' -f2)"

	local is_python_26="false"
	if [ "$major_version" -lt "2" ] || ( [ "$major_version" = "2" ] && [ "$minor_version" -lt "6" ] ); then
		cat >&2 <<-EOF
		不支持的python版本，请升级到2.7+
		EOF
		exit 1
	elif [ "$major_version" = "2" ] && [ "$minor_version" = "6" ]; then
		is_python_26="true"
	fi

	# 安装pip
	if ! command_exists pip; then
		wget -qO- https://bootstrap.pypa.io/get-pip.py | python
	fi

	if ! command_exists pip; then
		cat >&2 <<-EOF
		pip 安装失败，请手动安装后再运行
		EOF
		exit 1
	fi

	# 安装supervisor
	if [ "$is_python_26" = "true" ]; then
		pip install 'supervisor>=3.0.0,<4.0.0'
	else
		pip install --upgrade supervisor
	fi

	[ ! -d /etc/supervisor/conf.d ] && mkdir -p /etc/supervisor/conf.d
	ln -sf $(command -v supervisord) /usr/local/bin/supervisord
	ln -sf $(command -v supervisorctl) /usr/local/bin/supervisorctl
	ln -sf $(command -v pidproxy) /usr/local/bin/pidproxy

	local cfg_file='/etc/supervisor/supervisord.conf'
	if [ ! -s "$cfg_file" ]; then
		echo_supervisord_conf >"$cfg_file" 2>&1
	fi

	if ! grep -q '^files[[:space:]]*=[[:space:]]*/etc/supervisor/conf.d/\*\.conf$' "$cfg_file"; then
		if grep -q '^\[include\]$' "$cfg_file"; then
			sed -i '/^\[include\]$/a files = \/etc\/supervisor\/conf.d\/\*\.conf' "$cfg_file"
		else
			sed -i '$a [include]\nfiles = /etc/supervisor/conf.d/*.conf' "$cfg_file"
		fi
	fi
}

# 屏蔽在线下载启动文件，改用本地自建
download_startup_file() {
	local supervisor_startup_file=""
	if command_exists systemctl; then
		supervisor_startup_file="/etc/systemd/system/supervisord.service"
		# 写入基础systemd配置，不远程下载
		cat > "$supervisor_startup_file" <<EOF
[Unit]
Description=Supervisor daemon
Documentation=http://supervisord.org
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/supervisord -c /etc/supervisor/supervisord.conf
ExecStop=/usr/local/bin/supervisorctl shutdown
ExecReload=/usr/local/bin/supervisorctl reload
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload >/dev/null 2>&1
	elif command_exists service; then
		supervisor_startup_file='/etc/init.d/supervisord'
		# 简单init脚本
		cat > "$supervisor_startup_file" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          supervisord
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Supervisor init script
### END INIT INFO

case "\$1" in
start) /usr/local/bin/supervisord -c /etc/supervisor/supervisord.conf ;;
stop) /usr/local/bin/supervisorctl shutdown ;;
restart) \$0 stop && \$0 start ;;
status) /usr/local/bin/supervisorctl status ;;
esac
EOF
		chmod a+x "$supervisor_startup_file"
	fi
}

start_supervisor() {
	if command_exists systemctl; then
		systemctl restart supervisord.service
	elif command_exists service; then
		service supervisord restart
	fi
}

enable_supervisor() {
	if command_exists systemctl; then
		systemctl enable "supervisord.service"
	elif command_exists service; then
		case "$lsb_dist" in
			ubuntu|debian) update-rc.d -f supervisord defaults ;;
			centos|redhat) chkconfig --add supervisord; chkconfig supervisord on ;;
		esac
	fi
}

# ========== 下面所有配置交互、生成配置、防火墙、多实例逻辑完全保留不变 ==========
set_kcptun_config() {
	is_port() {
		local port="$1"
		is_number "$port" && [ $port -ge 1 ] && [ $port -le 65535 ]
	}
	port_using() {
		if command_exists netstat; then
			( netstat -ntul | grep -qE "[0-9:*]:${port}\s" )
		elif command_exists ss; then
			( ss -ntul | grep -qE "[0-9:*]:${port}\s" )
		else
			return 0
		fi
		return $?
	}

	local input=""
	local yn=""
	[ -z "$listen_port" ] && listen_port="$D_LISTEN_PORT"
	while true
	do
		cat >&1 <<-'EOF'
		请输入 Kcptun 服务端运行端口 [1~65535]
		EOF
		read -p "(默认: ${listen_port}): " input
		if [ -n "$input" ]; then
			if is_port "$input"; then
				listen_port="$input"
			else
				echo "输入有误, 请输入 1~65535 之间的数字!"
				continue
			fi
		fi
		if port_using "$listen_port" && [ "$listen_port" != "$current_listen_port" ]; then
			echo "端口已被占用, 请重新输入!"
			continue
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	端口 = ${listen_port}
	---------------------------
	EOF

	[ -z "$target_addr" ] && target_addr="$D_TARGET_ADDR"
	cat >&1 <<-'EOF'
	请输入需要加速的地址
	EOF
	read -p "(默认: ${target_addr}): " input
	if [ -n "$input" ]; then
		target_addr="$input"
	fi

	input=""
	cat >&1 <<-EOF
	---------------------------
	加速地址 = ${target_addr}
	---------------------------
	EOF

	[ -z "$target_port" ] && target_port="$D_TARGET_PORT"
	while true
	do
		cat >&1 <<-'EOF'
		请输入需要加速的端口 [1~65535]
		EOF
		read -p "(默认: ${target_port}): " input
		if [ -n "$input" ]; then
			if is_port "$input"; then
				if [ "$input" = "$listen_port" ]; then
					echo "加速端口不能和 Kcptun 端口一致!"
					continue
				fi
				target_port="$input"
			else
				echo "输入有误, 请输入 1~65535 之间的数字!"
				continue
			fi
		fi
		break
	done

	input=""
	yn=""
	cat >&1 <<-EOF
	---------------------------
	加速端口 = ${target_port}
	---------------------------
	EOF

	[ -z "$key" ] && key="$D_KEY"
	cat >&1 <<-'EOF'
	请设置 Kcptun 密码(key)
	EOF
	read -p "(默认密码: ${key}): " input
	[ -n "$input" ] && key="$input"

	input=""
	cat >&1 <<-EOF
	---------------------------
	密码 = ${key}
	---------------------------
	EOF

	[ -z "$crypt" ] && crypt="$D_CRYPT"
	local crypt_list="aes aes-128 aes-192 salsa20 blowfish twofish cast5 3des tea xtea xor none"
	local i=0
	cat >&1 <<-'EOF'
	请选择加密方式(crypt)
	EOF
	while true
	do
		for c in $crypt_list; do
			i=$(expr $i + 1)
			echo "(${i}) ${c}"
		done
		read -p "(默认: ${crypt}) 请选择 [1~$i]: " input
		if [ -n "$input" ]; then
			if is_number "$input" && [ $input -ge 1 ] && [ $input -le $i ]; then
				crypt=$(echo "$crypt_list" | cut -d' ' -f ${input})
			else
				echo "请输入有效数字 1~$i!"
				i=0
				continue
			fi
		fi
		break
	done

	input=""
	i=0
	cat >&1 <<-EOF
	-----------------------------
	加密方式 = ${crypt}
	-----------------------------
	EOF

	[ -z "$mode" ] && mode="$D_MODE"
	local mode_list="normal fast fast2 fast3 manual"
	i=0
	cat >&1 <<-'EOF'
	请选择加速模式(mode)
	EOF
	while true
	do
		for m in $mode_list; do
			i=$(expr $i + 1)
			echo "(${i}) ${m}"
		done
		read -p "(默认: ${mode}) 请选择 [1~$i]: " input
		if [ -n "$input" ]; then
			if is_number "$input" && [ $input -ge 1 ] && [ $input -le $i ]; then
				mode=$(echo "$mode_list" | cut -d ' ' -f ${input})
			else
				echo "请输入有效数字 1~$i!"
				i=0
				continue
			fi
		fi
		break
	done

	input=""
	i=0
	cat >&1 <<-EOF
	---------------------------
	加速模式 = ${mode}
	---------------------------
	EOF

	if [ "$mode" = "manual" ]; then
		set_manual_parameters
	else
		nodelay=""
		interval=""
		resend=""
		nc=""
	fi

	[ -z "$mtu" ] && mtu="$D_MTU"
	while true
	do
		cat >&1 <<-'EOF'
		请设置 MTU 值
		EOF
		read -p "(默认: ${mtu}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then
				echo "输入有误, 请输入大于0的数字!"
				continue
			fi
			mtu=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	MTU = ${mtu}
	---------------------------
	EOF

	[ -z "$sndwnd" ] && sndwnd="$D_SNDWND"
	while true
	do
		cat >&1 <<-'EOF'
		请设置发送窗口 sndwnd
		EOF
		read -p "(默认: ${sndwnd}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then
				echo "输入有误, 请输入大于0的数字!"
				continue
			fi
			sndwnd=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	sndwnd = ${sndwnd}
	---------------------------
	EOF

	[ -z "$rcvwnd" ] && rcvwnd="$D_RCVWND"
	while true
	do
		cat >&1 <<-'EOF'
		请设置接收窗口 rcvwnd
		EOF
		read -p "(默认: ${rcvwnd}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then
				echo "输入有误, 请输入大于0的数字!"
				continue
			fi
			rcvwnd=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	rcvwnd = ${rcvwnd}
	---------------------------
	EOF

	[ -z "$datashard" ] && datashard="$D_DATASHARD"
	while true
	do
		cat >&1 <<-'EOF'
		请设置 datashard
		EOF
		read -p "(默认: ${datashard}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -lt 0 ]; then
				echo "输入有误, 请输入大于等于0的数字!"
				continue
			fi
			datashard=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	datashard = ${datashard}
	---------------------------
	EOF

	[ -z "$parityshard" ] && parityshard="$D_PARITYSHARD"
	while true
	do
		cat >&1 <<-'EOF'
		请设置 parityshard
		EOF
		read -p "(默认: ${parityshard}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -lt 0 ]; then
				echo "输入有误, 请输入大于等于0的数字!"
				continue
			fi
			parityshard=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	parityshard = ${parityshard}
	---------------------------
	EOF

	[ -z "$dscp" ] && dscp="$D_DSCP"
	while true
	do
		cat >&1 <<-'EOF'
		请设置 DSCP
		EOF
		read -p "(默认: ${dscp}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -lt 0 ]; then
				echo "输入有误, 请输入大于等于0的数字!"
				continue
			fi
			dscp=$input
		fi
		break
	done

	input=""
	cat >&1 <<-EOF
	---------------------------
	DSCP = ${dscp}
	---------------------------
	EOF

	[ -z "$nocomp" ] && nocomp="$D_NOCOMP"
	while true
	do
		cat >&1 <<-'EOF'
		是否关闭数据压缩? [y/n]
		EOF
		read -p "(默认: ${nocomp}) [y/n]: " yn
		if [ -n "$yn" ]; then
			case "$(first_character "$yn")" in
				y|Y) nocomp='true' ;;
				n|N) nocomp='false' ;;
				*) echo "输入有误，请重新输入!"; continue ;;
			esac
		fi
		break
	done

	yn=""
	cat >&1 <<-EOF
	---------------------------
	nocomp = ${nocomp}
	---------------------------
	EOF

	[ -z "$quiet" ] && quiet="$D_QUIET"
	while true
	do
		cat >&1 <<-'EOF'
		是否屏蔽日志输出? [y/n]
		EOF
		read -p "(默认: ${quiet}) [y/n]: " yn
		if [ -n "$yn" ]; then
			case "$(first_character "$yn")" in
				y|Y) quiet='true' ;;
				n|N) quiet='false' ;;
				*) echo "输入有误，请重新输入!"; continue ;;
			esac
		fi
		break
	done

	yn=""
	cat >&1 <<-EOF
	---------------------------
	quiet = ${quiet}
	---------------------------
	EOF

	[ -z "$tcp" ] && tcp="$D_TCP"
	while true
	do
		cat >&1 <<-'EOF'
		是否使用 TCP 传输? [y/n]
		EOF
		read -p "(默认: ${tcp}) [y/n]: " yn
		if [ -n "$yn" ]; then
			case "$(first_character "$yn")" in
				y|Y) tcp='true' ;;
				n|N) tcp='false' ;;
				*) echo "输入有误，请重新输入!"; continue ;;
			esac
		fi
		break
	done

	if [ "$tcp" = "true" ]; then
		run_user="root"
	fi

	yn=""
	cat >&1 <<-EOF
	---------------------------
	tcp = ${tcp}
	---------------------------
	EOF

	unset_snmp() {
		snmplog=""
		snmpperiod=""
	}
	read -p "是否记录 SNMP 日志? (默认: 否) [y/n]: " yn
	if [ -n "$yn" ]; then
		case "$(first_character "$yn")" in
			y|Y) set_snmp ;;
			n|N|*) unset_snmp ;;
		esac
	else
		unset_snmp
	fi

	[ -z "$pprof" ] && pprof="$D_PPROF"
	while true
	do
		cat >&1 <<-'EOF'
		是否开启性能监控 pprof? [y/n]
		EOF
		read -p "(默认: ${pprof}) [y/n]: " yn
		if [ -n "$yn" ]; then
			case "$(first_character "$yn")" in
				y|Y) pprof='true' ;;
				n|N) pprof='false' ;;
				*) echo "输入有误，请重新输入!"; continue ;;
			esac
		fi
		break
	done

	yn=""
	unset_hidden_parameters() {
		acknodelay=""
		sockbuf=""
		smuxbuf=""
		keepalive=""
		streambuf=""
		smuxver=""
	}
	read -p "是否设置额外隐藏参数? (默认: 否) [y/n]: " yn
	if [ -n "$yn" ]; then
		case "$(first_character "$yn")" in
			y|Y) set_hidden_parameters ;;
			n|N|*) unset_hidden_parameters ;;
		esac
	else
		unset_hidden_parameters
	fi

	if [ "$listen_port" -le 1024 ]; then
		run_user="root"
	fi

	echo "配置完成。"
	any_key_to_continue
}

set_snmp() {
	snmplog="$(get_current_file 'snmp')"
	local input=""
	[ -z "$snmpperiod" ] && snmpperiod="$D_SNMPPERIOD"
	while true
	do
		read -p "SNMP记录间隔(默认${snmpperiod}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -lt 0 ]; then
				echo "输入有误"; continue
			fi
			snmpperiod=$input
		fi
		break
	done
}

set_manual_parameters() {
	local input=""
	local yn=""
	[ -z "$nodelay" ] && nodelay="$D_NODELAY"
	while true
	do
		read -p "启用nodelay模式?(0/1 默认${nodelay}): " input
		if [ -n "$input" ]; then
			case "$input" in 0|1) nodelay=$input ;; *) echo "输入有误"; continue ;; esac
		fi
		break
	done

	[ -z "$interval" ] && interval="$D_INTERVAL"
	while true
	do
		read -p "interval间隔ms(默认${interval}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then echo "输入有误"; continue; fi
			interval=$input
		fi
		break
	done

	[ -z "$resend" ] && resend="$D_RESEND"
	while true
	do
		read -p "快速重传resend(0-2 默认${resend}): " input
		if [ -n "$input" ]; then
			case "$input" in 0|1|2) resend=$input ;; *) echo "输入有误"; continue ;; esac
		fi
		break
	done

	[ -z "$nc" ] && nc="$D_NC"
	while true
	do
		read -p "关闭流控nc?(0/1 默认${nc}): " input
		if [ -n "$input" ]; then
			case "$input" in 0|1) nc=$input ;; *) echo "输入有误"; continue ;; esac
		fi
		break
	done
}

set_hidden_parameters() {
	local input=""
	local yn=""
	[ -z "$acknodelay" ] && acknodelay="$D_ACKNODELAY"
	while true
	do
		read -p "启用acknodelay?[y/n 默认${acknodelay}]: " yn
		if [ -n "$yn" ]; then
			case "$(first_character "$yn")" in
				y|Y) acknodelay="true" ;;
				n|N) acknodelay="false" ;;
				*) echo "输入有误"; continue ;;
			esac
		fi
		break
	done

	[ -z "$sockbuf" ] && sockbuf="$D_SOCKBUF"
	while true
	do
		read -p "sockbuf大小MB(默认$(expr ${sockbuf}/1024/1024)): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then echo "输入有误"; continue; fi
			sockbuf=$(expr $input \* 1024 \* 1024)
		fi
		break
	done

	[ -z "$smuxbuf" ] && smuxbuf="$D_SMUXBUF"
	while true
	do
		read -p "smuxbuf大小MB(默认$(expr ${smuxbuf}/1024/1024)): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then echo "输入有误"; continue; fi
			smuxbuf=$(expr $input \* 1024 \* 1024)
		fi
		break
	done

	[ -z "$keepalive" ] && keepalive="$D_KEEPALIVE"
	while true
	do
		read -p "keepalive间隔秒(默认${keepalive}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then echo "输入有误"; continue; fi
			keepalive=$input
		fi
		break
	done

	[ -z "$smuxver" ] && smuxver="$D_SMUXVER"
	while true
	do
		read -p "smux版本1/2(默认${smuxver}): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -lt 1 ]; then echo "输入有误"; continue; fi
			smuxver=$input
		fi
		break
	done

	[ -z "$streambuf" ] && streambuf="$D_STREAMBUF"
	while true
	do
		read -p "streambuf大小MB(默认$(expr ${streambuf}/1024/1024)): " input
		if [ -n "$input" ]; then
			if ! is_number "$input" || [ $input -le 0 ]; then echo "输入有误"; continue; fi
			streambuf=$(expr $input \* 1024 \* 1024)
		fi
		break
	done
}

gen_kcptun_config() {
	mk_file_dir() {
		local dir="$(dirname "$1")"
		[ ! -d "$dir" ] && mkdir -p "$dir"
		[ -n "$2" ] && chmod $2 "$dir"
	}
	local config_file="$(get_current_file 'config')"
	local supervisor_config_file="$(get_current_file 'supervisor')"
	mk_file_dir "$config_file"
	mk_file_dir "$supervisor_config_file"
	[ -n "$snmplog" ] && mk_file_dir "$snmplog" '777'

	cat > "$config_file"<<-EOF
	{
	  "listen": "0.0.0.0:${listen_port}",
	  "target": "${target_addr}:${target_port}",
	  "key": "${key}",
	  "crypt": "${crypt}",
	  "mode": "${mode}",
	  "mtu": ${mtu},
	  "sndwnd": ${sndwnd},
	  "rcvwnd": ${rcvwnd},
	  "datashard": ${datashard},
	  "parityshard": ${parityshard},
	  "dscp": ${dscp},
	  "nocomp": ${nocomp},
	  "quiet": ${quiet},
	  "tcp": ${tcp}
	}
	EOF

	write_configs_to_file() {
		install_jq
		local k; local v
		local json="$(cat "$config_file")"
		for k in "$@"; do
			v="$(eval echo "\$$k")"
			if [ -n "$v" ]; then
				if is_number "$v" || [ "$v" = "false" ] || [ "$v" = "true" ]; then
					json="$(echo "$json" | $JQ_BIN ".$k=$v")"
				else
					json="$(echo "$json" | $JQ_BIN ".$k=\"$v\"")"
				fi
			fi
		done
		echo "$json" >"$config_file"
	}

	write_configs_to_file "snmplog" "snmpperiod" "pprof" "acknodelay" "nodelay" \
		"interval" "resend" "nc" "sockbuf" "smuxbuf" "keepalive" "streambuf" "smuxver"

	if ! grep -q "^${run_user}:" '/etc/passwd'; then
		useradd -U -s '/usr/sbin/nologin' -d '/nonexistent' "$run_user" 2>/dev/null
	fi

	cat > "$supervisor_config_file"<<-EOF
	[program:kcptun${current_instance_id}]
	user=${run_user}
	directory=${KCPTUN_INSTALL_DIR}
	command=$(get_kcptun_server_file) -c "${config_file}"
	process_name=%(program_name)s
	autostart=true
	redirect_stderr=true
	stdout_logfile=$(get_current_file 'log')
	stdout_logfile_maxbytes=1MB
	stdout_logfile_backups=0
	EOF
}

set_firewall() {
	if command_exists firewall-cmd; then
		firewall-cmd --reload >/dev/null 2>&1
		if ! firewall-cmd --quiet --zone=public --query-port=${listen_port}/udp; then
			firewall-cmd --quiet --permanent --zone=public --add-port=${listen_port}/udp
			firewall-cmd --reload
		fi
	elif command_exists iptables; then
		if ! iptables -C INPUT -p udp --dport ${listen_port} -j ACCEPT >/dev/null 2>&1; then
			iptables -I INPUT -p udp --dport ${listen_port} -j ACCEPT >/dev/null 2>&1
			service iptables save >/dev/null 2>&1
		fi
	fi
}

select_instance() {
	if [ "$(get_instance_count)" -gt 1 ]; then
		echo "当前有多个Kcptun实例："
		local files=$(ls -lt '/etc/supervisor/conf.d/' 2>/dev/null | grep "^-" | awk '{print $9}' | grep "^kcptun[0-9]*\.conf$")
		local i=0
		local array=""
		local id=""
		for file in $files; do
			id="$(echo "$file" | grep -oE "[0-9]+")"
			array="${array}${id}#"
			i=$(expr $i + 1)
			echo "(${i}) ${file%.*}"
		done
		local sel=""
		while true
		do
			read -p "请选择 [1~${i}]: " sel
			if is_number "$sel" && [ $sel -ge 1 ] && [ $sel -le $i ]; then
				current_instance_id=$(echo "$array" | cut -d '#' -f ${sel})
				break
			fi
			echo "输入无效"
		done
	fi
}

get_kcptun_server_file() {
	if [ -z "$file_suffix" ]; then
		get_arch
	fi
	echo "${KCPTUN_INSTALL_DIR}/server_$file_suffix"
}

get_new_instance_id() {
	if [ -f "/etc/supervisor/conf.d/kcptun.conf" ]; then
		local i=2
		while [ -f "/etc/supervisor/conf.d/kcptun${i}.conf" ]; do
			i=$(expr $i + 1)
		done
		echo "$i"
	fi
}

get_installed_version() {
	local server_file="$(get_kcptun_server_file)"
	if [ -f "$server_file" ]; then
		[ ! -x "$server_file" ] && chmod a+x "$server_file"
		echo "$(${server_file} -v 2>/dev/null | awk '{print $3}')"
	fi
}

load_instance_config() {
	local config_file="$(get_current_file 'config')"
	[ ! -s "$config_file" ] && echo "配置文件不存在" && exit 1
	local config_content="$(cat ${config_file})"
	install_jq
	local lines="$(get_json_string "$config_content" 'to_entries | map("\(.key)=\(.value | @sh)") | .[]')"
	OLDIFS=$IFS
	IFS=$(printf '\n')
	for line in $lines; do eval "$line"; done
	IFS=$OLDIFS
	if [ -n "$listen" ]; then
		listen_port="$(echo "$listen" | rev | cut -d ':' -f1 | rev)"
		listen_addr="$(echo "$listen" | sed "s/:${listen_port}$//")"
	fi
	if [ -n "$target" ]; then
		target_port="$(echo "$target" | rev | cut -d ':' -f1 | rev)"
		target_addr="$(echo "$target" | sed "s/:${target_port}$//")"
	fi
	if [ -n "$listen_port" ]; then
		current_listen_port="$listen_port"
	fi
}

show_version_and_client_url() {
	local version="$(get_installed_version)"
	if [ -n "$version" ]; then
		echo "当前Kcptun版本: ${version}"
	fi
	echo "请自行下载客户端配置"
}

show_current_instance_info() {
	local server_ip="$(get_server_ip)"
	printf '服务器IP: \033[41;37m %s \033[0m\n' "$server_ip"
	printf '端口: \033[41;37m %s \033[0m\n' "$listen_port"
	printf '加速地址: \033[41;37m %s:%s \033[0m\n' "$target_addr" "$target_port"

	show_configs() {
		local k; local v
		for k in "$@"; do
			v="$(eval echo "\$$k")"
			if [ -n "$v" ]; then
				printf '%s: \033[41;37m %s \033[0m\n' "$k" "$v"
			fi
		done
	}

	show_configs "key" "crypt" "mode" "mtu" "sndwnd" "rcvwnd" "datashard" \
		"parityshard" "dscp" "nocomp" "quiet" "tcp" "nodelay" "interval" "resend" \
		"nc" "acknodelay" "sockbuf" "smuxbuf" "keepalive" "streambuf" "smuxver"

	install_jq
	local client_config="{\"localaddr\":\":${target_port}\",\"remoteaddr\":\"${server_ip}:${listen_port}\",\"key\":\"${key}\"}"
	gen_client_configs() {
		local k; local v
		for k in "$@"; do
			if [ "$k" = "sndwnd" ]; then v="$rcvwnd"
			elif [ "$k" = "rcvwnd" ]; then v="$sndwnd"
			else v="$(eval echo "\$$k")"; fi
			if [ -n "$v" ]; then
				if is_number "$v" || [ "$v" = "true" ] || [ "$v" = "false" ]; then
					client_config="$(echo "$client_config" | $JQ_BIN -r ".${k}=${v}")"
				else
					client_config="$(echo "$client_config" | $JQ_BIN -r ".${k}=\"${v}\"")"
				fi
			fi
		done
	}
	gen_client_configs "crypt" "mode" "mtu" "sndwnd" "rcvwnd" "datashard" \
		"parityshard" "dscp" "nocomp" "quiet" "tcp" "nodelay" "interval" "resend" \
		"nc" "acknodelay" "sockbuf" "smuxbuf" "keepalive" "streambuf" "smuxver"

	cat >&1 <<-EOF

客户端JSON配置：
${client_config}
EOF
}

do_install() {
	check_root
	disable_selinux
	installed_check
	set_kcptun_config
	install_deps
	install_kcptun
	install_supervisor
	download_startup_file
	gen_kcptun_config
	set_firewall
	start_supervisor
	enable_supervisor

	cat >&1 <<-EOF

恭喜! Kcptun 服务端安装成功。
EOF

	show_current_instance_info

	cat >&1 <<-EOF
Kcptun 安装目录: ${KCPTUN_INSTALL_DIR}

已将 Supervisor 加入开机自启,
Kcptun 服务端会随 Supervisor 的启动而启动

更多使用说明: ${0} help
EOF
}

# 卸载操作
do_uninstall() {
	check_root
	cat >&1 <<-'EOF'
你选择了卸载 Kcptun 服务端
EOF
	any_key_to_continue
	echo "正在卸载 Kcptun 服务端并停止 Supervisor..."

	if command_exists supervisorctl; then
		supervisorctl shutdown
	fi

	if command_exists systemctl; then
		systemctl stop supervisord.service
	elif command_exists serice; then
		service supervisord stop
	fi

	(
		set -x
		rm -f "/etc/supervisor/conf.d/kcptun*.conf"
		rm -rf "$KCPTUN_INSTALL_DIR"
		rm -rf "$KCPTUN_LOG_DIR"
	)

	cat >&1 <<-'EOF'
是否同时卸载 Supervisor ?
注意: Supervisor 的配置文件将同时被删除
EOF

	read -p "(默认: 不卸载) 请选择 [y/n]: " yn
	if [ -n "$yn" ]; then
		case "$(first_character "$yn")" in
			y|Y)
				if command_exists systemctl; then
					systemctl disable supervisord.service
					rm -f "/lib/systemd/system/supervisord.service" \
						"/etc/systemd/system/supervisord.service"
				elif command_exists service; then
					if [ -z "$lsb_dist" ]; then
						get_os_info
					fi
					case "$lsb_dist" in
						ubuntu|debian|raspbian)
							(
								set -x
								update-rc.d -f supervisord remove
							)
							;;
						fedora|centos|redhat|oraclelinux|photon)
							(
								set -x
								chkconfig supervisord off
								chkconfig --del supervisord
							)
							;;
					esac
					rm -f '/etc/init.d/supervisord'
				fi

				(
					set -x
					# 新版使用 pip 卸载
					if command_exists pip; then
						pip uninstall -y supervisor 2>/dev/null || true
					fi

					# 旧版使用 easy_install 卸载
					if command_exists easy_install; then
						rm -rf "$(easy_install -mxN supervisor | grep 'Using.*supervisor.*\.egg' | awk '{print $2}')"
					fi

					rm -rf '/etc/supervisor/'
					rm -f '/usr/local/bin/supervisord' \
						'/usr/local/bin/supervisorctl' \
						'/usr/local/bin/pidproxy' \
						'/usr/local/bin/echo_supervisord_conf' \
						'/usr/bin/supervisord' \
						'/usr/bin/supervisorctl' \
						'/usr/bin/pidproxy' \
						'/usr/bin/echo_supervisord_conf'
				)
				;;
			n|N|*)
				start_supervisor
				;;
		esac
	fi

	cat >&1 <<-EOF
卸载完成, 欢迎再次使用。
EOF
}

# 添加实例
instance_add() {
	pre_ckeck

	cat >&1 <<-'EOF'
你选择了添加实例, 正在开始操作...
EOF
	current_instance_id="$(get_new_instance_id)"

	set_kcptun_config
	gen_kcptun_config
	set_firewall
	start_supervisor

	cat >&1 <<-EOF
恭喜, 实例 kcptun${current_instance_id} 添加成功!
EOF
	show_current_instance_info
}

# 删除实例
instance_del() {
	pre_ckeck

	if [ -n "$1" ]; then
		if is_number "$1"; then
			if [ "$1" != "1" ]; then
				current_instance_id="$1"
			fi
		else
			cat >&2 <<-EOF
			参数有误, 请使用 $0 del <id>
			<id> 为实例ID, 当前共有 $(get_instance_count) 个实例
			EOF

			exit 1
		fi
	fi

	cat >&1 <<-EOF
你选择了删除实例 kcptun${current_instance_id}
注意: 实例删除后无法恢复
EOF
