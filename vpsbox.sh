#!/bin/bash
# =====================================================================
# 项目名称: VPS Box (轻量级节点管理与网络优化引擎)
# 版本: v2.6.0 (内置自研完全体 TCP 引擎 & 内核自适应防崩溃安全注入)
# =====================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BACKUP_DIR="/etc/vpsbox_backups"
CUSTOM_CONF="/etc/sysctl.d/99-vpsbox-tcp.conf"
SHORTCUT_PATH="/usr/local/bin/vpsbox"
NODE_RECORD_FILE="/etc/vpsbox_nodes.txt"
INSTALL_LOG="/tmp/vpsbox_install.log"

mkdir -p "$BACKUP_DIR"
if [ "$EUID" -ne 0 ]; then
    echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
    exit 1
fi
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo -e "\n${RED}[错误] VPSBox 当前仅支持 Debian 或 Ubuntu 系统！${NC}\n"
        exit 1
    fi
else
    echo -e "\n${RED}[错误] 无法识别的操作系统！${NC}\n"
    exit 1
fi
if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.1.1 $(hostname)" >> /etc/hosts
fi
if [[ "$(realpath "$0")" != "$SHORTCUT_PATH" ]]; then
    curl -sL https://raw.githubusercontent.com/8088892/VPSBox/main/vpsbox.sh -o "$SHORTCUT_PATH" 2>/dev/null
    chmod +x "$SHORTCUT_PATH"
fi

CPU_CORES=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(( (RAM_MB + 512) / 1024 ))
[ "$RAM_GB" -eq 0 ] && RAM_GB=1
HW_PROFILE="${CPU_CORES}C${RAM_GB}G"
CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
SERVER_IP=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 ip.sb)
IP_FORMAT="v4"
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ip.sb)
    IP_FORMAT="v6"
fi

get_term_width() {
    local cols=$(tput cols 2>/dev/null || echo 80)
    if [ "$cols" -gt 100 ]; then echo 100; else echo "$cols"; fi
}

print_divider() {
    local w=$(get_term_width)
    echo -e "${CYAN}$(printf "%0.s=" $(seq 1 $w))${NC}"
}

print_separator() {
    local w=$(get_term_width)
    echo -e "${CYAN}$(printf "%0.s-" $(seq 1 $w))${NC}"
}

print_center() {
    local text="$1"
    local color="$2"
    local term_width=$(get_term_width)
    local plain_text=$(echo -e "$text" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
    local text_len=${#plain_text}
    local padding=$(( (term_width - text_len) / 2 ))
    [ $padding -lt 0 ] && padding=0
    printf "%${padding}s" ""
    echo -e "${color}${text}${NC}"
}

pause_for_enter() {
    echo ""
    print_divider
    echo -ne "${YELLOW}> 操作已完成，请按 [回车键] 返回主菜单...${NC}"
    read -r
}

confirm_action() {
    local action_name=$1
    echo ""
    read -r -p "> 是否确认执行 [${action_name}]？(y/n, 默认 n): " confirm
    confirm="${confirm// /}"
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "\n${YELLOW}已取消 [${action_name}] 操作。${NC}"
        return 1
    fi
    return 0
}

install_dependencies() {
    local apps=("curl" "wget" "jq" "openssl" "socat" "fuser" "unzip" "qrencode")
    local missing_apps=()
    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then missing_apps+=("$app"); fi
    done
    if ! dpkg -l | grep -qw cron; then missing_apps+=("cron"); fi
    if [ ${#missing_apps[@]} -ne 0 ]; then
        echo -e "\n${CYAN}[系统] 检测到缺失必要底层组件，正在自动补全...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y > "$INSTALL_LOG" 2>&1
        apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils qrencode cron >> "$INSTALL_LOG" 2>&1
        systemctl enable --now cron >> "$INSTALL_LOG" 2>&1
        if [ $? -ne 0 ]; then echo -e "${RED}[警告] 某些组件安装可能存在异常，请查看 $INSTALL_LOG 排查原因。${NC}"; fi
    fi
}

system_update() {
    clear; print_divider
    print_center "[ 更新系统与安装必备组件 ]" "$CYAN"
    print_divider
    if ! confirm_action "更新系统与安装组件"; then pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在更新软件源并升级系统组件 (这可能需要几分钟)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    if [ $? -ne 0 ]; then echo -e "\n${RED}[错误] 升级系统组件失败，请检查网络或源状态。${NC}"; pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在安装必备工具包...${NC}"
    apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils qrencode cron
    systemctl enable --now cron >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo -e "\n${RED}[错误] 必备工具包安装失败。${NC}"; pause_for_enter; return; fi
    echo -e "\n${GREEN}[成功] 系统更新与组件安装完毕！${NC}"
    pause_for_enter
}

system_clean() {
    clear; print_divider
    print_center "[ 系统垃圾与废弃依赖清理 ]" "$CYAN"
    print_divider
    if ! confirm_action "清理系统垃圾与冗余日志"; then pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在卸载无用的旧依赖包...${NC}"
    apt-get autoremove -y || { echo -e "\n${RED}[错误] 卸载旧依赖包失败！${NC}"; pause_for_enter; return; }
    echo -e "\n${CYAN}>>> 正在清理系统下载缓存...${NC}"
    apt-get clean -y || echo -e "${RED}[错误] 缓存清理异常。${NC}"
    echo -e "\n${CYAN}>>> 正在清理超过 7 个月的系统日志...${NC}"
    journalctl --vacuum-time=7d >/dev/null 2>&1 || echo -e "${RED}[错误] 日志清理异常。${NC}"
    echo -e "\n${GREEN}[成功] 系统清理完毕，存储空间已释放！${NC}"
    pause_for_enter
}

change_root_password() {
    clear; print_divider
    print_center "[ 修改系统 root 密码 ]" "$CYAN"
    print_divider
    if ! confirm_action "修改 root 密码"; then pause_for_enter; return; fi
    echo -e "\n${YELLOW}提示：输入密码时屏幕不会显示字符，属于正常安全机制。${NC}\n"
    while true; do
        passwd root
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}[成功] 密码已成功修改！${NC}"; break
        else
            echo -e "\n${RED}[错误] 密码修改失败！${NC}"
            read -r -p "> 是否继续尝试修改密码？(y/n, 默认 y): " retry_pwd
            retry_pwd="${retry_pwd// /}"
            if [[ "$retry_pwd" =~ ^[nN]$ ]]; then echo -e "\n${YELLOW}已退出密码修改。${NC}"; break; fi
            echo -e "\n${CYAN}>>> 请重新设置密码：${NC}"
        fi
    done
    pause_for_enter
}

manage_ssh_security() {
    while true; do
        clear; print_divider
        print_center "[ SSH 密钥与登录安全管理 ]" "$CYAN"
        print_divider
        echo -e "  ${GREEN}1.${NC} 添加/覆盖 SSH 公钥\n  ${GREEN}2.${NC} 删除所有 SSH 公钥\n  ${GREEN}3.${NC} 禁用密码登录 (强制使用密钥)\n  ${GREEN}4.${NC} 开启密码登录\n  ${GREEN}0.${NC} 返回主菜单"
        print_separator; echo ""
        read -r -p "> 请选择操作 [0-4]: " ssh_opt
        ssh_opt="${ssh_opt// /}"
        case $ssh_opt in
            1)
                while true; do
                    read -r -p "> 请粘贴您的公钥 (通常以 ssh-rsa 开头, 输入 0 取消): " pub_key
                    if [ "$pub_key" == "0" ]; then break; fi
                    if [ -z "$pub_key" ]; then echo -e "${RED}[错误] 密钥内容不能为空，请重新输入！${NC}"; continue; fi
                    if ! confirm_action "导入此 SSH 公钥"; then break; fi
                    mkdir -p ~/.ssh; chmod 700 ~/.ssh
                    if [ -s ~/.ssh/authorized_keys ]; then
                        echo -e "\n${YELLOW}[发现] 系统中已存在其他 SSH 密钥记录。${NC}"
                        read -r -p "> 是否清空旧密钥并覆盖？(y-覆盖清空 / n-保留追加, 默认 n): " overwrite_opt
                        overwrite_opt="${overwrite_opt// /}"
                        if [[ "$overwrite_opt" =~ ^[yY]$ ]]; then > ~/.ssh/authorized_keys; echo -e "${CYAN}>>> 已清空历史废弃密钥。${NC}"; fi
                    fi
                    echo "$pub_key" >> ~/.ssh/authorized_keys
                    if [ $? -ne 0 ]; then echo -e "\n${RED}[错误] 写入密钥失败，请检查系统权限或磁盘空间。${NC}"; else chmod 600 ~/.ssh/authorized_keys; echo -e "\n${GREEN}[成功] 密钥已成功添加！请先测试使用密钥登录，再关闭密码登录功能。${NC}"; fi
                    pause_for_enter; break
                done ;;
            2)
                if ! confirm_action "删除系统中所有的 SSH 公钥"; then continue; fi
                > ~/.ssh/authorized_keys
                if [ $? -eq 0 ]; then echo -e "\n${GREEN}[成功] 所有 SSH 公钥已彻底清空！${NC}"; else echo -e "\n${RED}[错误] 清空密钥失败！${NC}"; fi
                pause_for_enter ;;
            3)
                if ! confirm_action "禁用密码登录 (⚠️ 请确保您已成功配置密钥)"; then continue; fi
                sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/g' /etc/ssh/sshd_config
                systemctl restart sshd || { echo -e "\n${RED}[错误] SSH 服务重启失败，设置可能未生效。${NC}"; pause_for_enter; continue; }
                echo -e "\n${GREEN}[成功] 密码登录已成功禁用！现在只能通过密钥连接服务器。${NC}"; pause_for_enter ;;
            4)
                if ! confirm_action "开启密码登录"; then continue; fi
                sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
                systemctl restart sshd || { echo -e "\n${RED}[错误] SSH 服务重启失败。${NC}"; pause_for_enter; continue; }
                echo -e "\n${GREEN}[成功] 密码登录已成功开启！${NC}"; pause_for_enter ;;
            0) return ;;
            *) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
        esac
    done
}

change_ssh_port() {
    clear; print_divider
    print_center "[ 修改 SSH 默认登录端口 ]" "$CYAN"
    print_divider
    while true; do
        read -r -p "> 请输入新的 SSH 端口号 (建议 10000-65535，恢复默认请输 22，输入 0 取消): " new_port
        new_port="${new_port// /}"
        if [ "$new_port" == "0" ] || [ -z "$new_port" ]; then return; fi
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || ( [ "$new_port" -ne 22 ] && ([ "$new_port" -le 1024 ] || [ "$new_port" -ge 65535 ]) ); then
            echo -e "${RED}[错误] 端口号必须是 22 或者在 1024 到 65535 之间！请重新输入。${NC}"; continue
        fi
        break
    done
    if ! confirm_action "将 SSH 端口修改为 $new_port"; then pause_for_enter; return; fi
    sed -i "s/^#\?Port .*/Port $new_port/g" /etc/ssh/sshd_config
    systemctl restart sshd
    if [ $? -ne 0 ]; then echo -e "\n${RED}[错误] SSH 服务重启失败，端口修改可能未生效。${NC}"; else echo -e "\n${GREEN}[成功] SSH 端口已修改为 $new_port！${NC}"; echo -e "${RED}[警告] 请确保您的云服务商防火墙已放行 $new_port 端口，否则下次将无法连接！${NC}"; fi
    pause_for_enter
}

change_hostname() {
    clear; print_divider
    print_center "[ 修改系统主机名 (Hostname) ]" "$CYAN"
    print_divider
    echo -e "当前主机名: ${YELLOW}$(hostname)${NC}"
    while true; do
        read -r -p "> 请输入新的主机名 (仅限字母、数字和连字符, 输入 0 取消): " new_hostname
        new_hostname="${new_hostname// /}"
        if [ "$new_hostname" == "0" ]; then return; fi
        if [ -z "$new_hostname" ]; then echo -e "${RED}[错误] 主机名不能为空，请重新输入！${NC}"; continue; fi
        if ! [[ "$new_hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then echo -e "${RED}[错误] 格式不正确！仅限输入字母、数字和连字符(-)。${NC}"; continue; fi
        break
    done
    if ! confirm_action "将主机名修改为 $new_hostname"; then pause_for_enter; return; fi
    hostnamectl set-hostname "$new_hostname" || { echo -e "\n${RED}[错误] 修改主机名失败。${NC}"; pause_for_enter; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1 $new_hostname/g" /etc/hosts
    echo -e "\n${GREEN}[成功] 主机名已修改为 $new_hostname！(重新连接 SSH 后即可看到变化)${NC}"
    pause_for_enter
}

set_china_timezone() {
    clear; print_divider
    print_center "[ 修改系统时区为北京时间 (Asia/Shanghai) ]" "$CYAN"
    print_divider
    if ! confirm_action "修改系统时区为中国北京时间"; then pause_for_enter; return; fi
    timedatectl set-timezone Asia/Shanghai || { echo -e "\n${RED}[错误] 设置时区失败，请检查系统 timedatectl 服务。${NC}"; pause_for_enter; return; }
    CURRENT_TZ="Asia/Shanghai"
    echo -e "\n${GREEN}[成功] 系统时区已同步为中国北京时间。${NC}"
    pause_for_enter
}

manage_swap() {
    clear; print_divider
    print_center "[ 虚拟内存 (Swap) 一键管理 ]" "$CYAN"
    print_divider
    local swap_size=$(free -m | grep -i swap | awk '{print $2}')
    echo -e "当前 Swap 大小: ${GREEN}${swap_size} MB${NC}\n"
    while true; do
        echo -e "  ${GREEN}1.${NC} 创建/修改 Swap (推荐 1024MB 或 2048MB)\n  ${GREEN}2.${NC} 关闭并删除现有 Swap\n  ${GREEN}0.${NC} 取消返回"
        read -r -p "> 请选择操作 [0-2]: " swap_opt
        swap_opt="${swap_opt// /}"
        case $swap_opt in
            1)
                while true; do
                    read -r -p "> 请输入 Swap 大小 (单位 MB，例如 1024): " input_size
                    input_size="${input_size// /}"
                    if [[ "$input_size" =~ ^[0-9]+$ ]]; then break; else echo -e "${RED}[错误] 输入无效，请输入纯数字。${NC}"; fi
                done
                if ! confirm_action "设置 ${input_size}MB 的 Swap"; then return; fi
                echo -e "\n${CYAN}>>> 正在配置 ${input_size}MB Swap，请稍候...${NC}"
                swapoff -a; rm -f /swapfile
                dd if=/dev/zero of=/swapfile bs=1M count=$input_size status=progress || { echo -e "${RED}[错误] 磁盘空间不足或无权限！${NC}"; pause_for_enter; return; }
                chmod 600 /swapfile
                mkswap /swapfile || { echo -e "${RED}[错误] mkswap 初始化失败！${NC}"; pause_for_enter; return; }
                swapon /swapfile || { echo -e "${RED}[错误] 挂载 Swap 失败！${NC}"; pause_for_enter; return; }
                if ! grep -q "/swapfile" /etc/fstab; then echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi
                echo -e "${GREEN}[成功] Swap 设置成功！${NC}"; pause_for_enter; return ;;
            2)
                if ! confirm_action "关闭并删除现有 Swap"; then return; fi
                swapoff -a; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab
                echo -e "\n${GREEN}[成功] Swap 已彻底关闭并清理！${NC}"; pause_for_enter; return ;;
            0) return ;;
            *) echo -e "\n${RED}[错误] 输入无效！请输入 0、1 或 2 进行选择。${NC}\n" ;;
        esac
    done
}

optimize_dns() {
    clear; print_divider
    print_center "[ 系统 DNS 极速优化 ]" "$CYAN"
    print_divider
    if ! confirm_action "将系统 DNS 替换为 1.1.1.1 和 8.8.8.8"; then pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在优化系统 DNS 配置并锁定文件...${NC}"
    chattr -i /etc/resolv.conf >/dev/null 2>&1
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    if [ $? -ne 0 ]; then echo -e "${RED}[错误] 写入 /etc/resolv.conf 失败。${NC}"; else chattr +i /etc/resolv.conf >/dev/null 2>&1; echo -e "${GREEN}[成功] 系统 DNS 已优化成功，并已锁定防止系统篡改！${NC}"; fi
    pause_for_enter
}

get_bbr_status() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$cc" == "bbr" ]]; then
        if uname -r | grep -qi "xanmod"; then echo -e "${YELLOW}BBRv3 (基于 Google 官方源码)${NC}"; else echo -e "${GREEN}BBRv1 (Linux 系统原生)${NC}"; fi
    else 
        echo -e "${RED}未开启 (当前为 $cc)${NC}"
    fi
}

manage_bbr() {
    while true; do
        clear; print_divider
        print_center "BBR 拥塞控制智能管理中心" "$PURPLE"
        print_divider
        echo -e "  当前内核版本 : ${YELLOW}$(uname -r)${NC}\n  当前 BBR 状态: $(get_bbr_status)"
        print_separator
        echo -e "  ${GREEN}1.${NC} 开启 BBRv1 (极速秒开 / 适合所有系统)\n  ${GREEN}2.${NC} 安装 BBRv3 (合入谷歌最新 V3 分支 / 延迟更低更激进)\n  ${GREEN}3.${NC} 卸载 BBRv3 (安全回退至系统原生默认内核)"
        print_separator; echo -e "  ${GREEN}0.${NC} 返回主菜单"; print_divider; echo ""
        read -r -p "> 请输入编号 [0-3]: " bbr_opt
        bbr_opt="${bbr_opt// /}"
        case $bbr_opt in
            1)
                if ! confirm_action "立即开启系统原生 BBRv1"; then continue; fi
                echo -e "\n${CYAN}[正在配置] 启用系统原生 BBRv1...${NC}"
                modprobe tcp_bbr > /dev/null 2>&1 || echo -e "${YELLOW}[提示] modprobe tcp_bbr 执行失败，但配置仍会继续。${NC}"
                echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
                cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                sysctl -p /etc/sysctl.d/99-bbr.conf > /dev/null 2>&1
                if [ $? -eq 0 ]; then echo -e "${GREEN}[成功] BBRv1 已成功开启！${NC}"; else echo -e "${RED}[错误] BBR 参数应用失败。${NC}"; fi
                sleep 2 ;;
            2)
                if ! command -v apt &> /dev/null; then echo -e "\n${RED}[错误] BBRv3 安装仅支持 Debian/Ubuntu。${NC}"; sleep 2; continue; fi
                if ! grep -qa "avx2" /proc/cpuinfo; then echo -e "\n${RED}[拦截] 您的 CPU 过于老旧 (不支持 x86-64-v3 指令集)！安装此内核将导致无法开机！${NC}"; sleep 3; continue; fi
                if ! confirm_action "安装 BBRv3 内核"; then continue; fi
                echo -e "\n${CYAN}>>> 正在连接 Ubuntu 官方服务器获取 XanMod 密钥 (防拦截模式)...${NC}"
                gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 86F7D09EE734E623 > /dev/null 2>&1
                gpg --export 86F7D09EE734E623 > /usr/share/keyrings/xanmod-archive-keyring.gpg
                if [ ! -s /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then echo -e "\n${RED}[错误] 密钥获取失败！请检查网络或稍后重试。${NC}"; rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg; sleep 3; continue; fi
                echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-release.list
                echo -e "\n${CYAN}>>> 正在更新软件源...${NC}"
                apt update -y || { echo -e "\n${RED}[错误] 源更新失败。${NC}"; sleep 2; continue; }
                echo -e "\n${CYAN}>>> 正在安装 XanMod BBRv3 内核 (x64v3 标准版)...${NC}"
                apt install -y linux-xanmod-x64v3
                if [ $? -eq 0 ]; then
                    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                    update-grub
                    echo -e "\n${GREEN}[提示] BBRv3 核心部署完毕！需要重启后生效。${NC}"
                    read -r -p "> 是否立即重启服务器？(y/n, 默认 n): " do_reboot
                    if [[ "${do_reboot// /}" =~ ^[yY]$ ]]; then echo -e "${YELLOW}正在重启服务器...${NC}"; sleep 2; reboot; else echo -e "${YELLOW}请记得稍后手动执行 reboot 命令使新内核生效。${NC}"; sleep 2; fi
                else
                    echo -e "\n${RED}[错误] 内核安装失败！请查看上方 apt 的具体报错。${NC}"; sleep 3
                fi ;;
            3)
                if ! confirm_action "卸载 BBRv3 (完成后将重启服务器)"; then continue; fi
                if ! dpkg -l | grep -qE "linux-image-(generic|amd64)"; then
                    echo -e "\n${YELLOW}>>> [安全拦截] 未检测到系统原生备用内核，正在自动安装...${NC}"
                    if grep -qi ubuntu /etc/os-release; then apt install -y linux-image-generic; else apt install -y linux-image-amd64; fi
                fi
                echo -e "\n${CYAN}>>> 正在清理内核文件...${NC}"
                apt purge -y "^linux-image.*xanmod.*" "^linux-headers.*xanmod.*" || { echo -e "${RED}[错误] 清理旧内核失败。${NC}"; sleep 2; continue; }
                rm -f /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg
                apt update -y > /dev/null 2>&1; update-grub
                echo -e "\n${GREEN}[成功] 卸载成功！即将重启服务器回退至系统原生内核...${NC}"
                sleep 3; reboot ;;
            0) break ;;
            *) echo -e "\n${RED}[提示] 编号错误！${NC}"; sleep 1 ;;
        esac
    done
}

# =====================================================================
# 核心亮点：VPS Box 自研 TCP 智能调优引擎 (智能过滤内核兼容性)
# =====================================================================
apply_tuning() {
    clear; print_divider
    print_center "[ VPS Box 自研动态 TCP 智能调优引擎 ]" "$CYAN"
    print_divider
    local local_bw server_bw latency ramp_up bbr_ver qdisc
    while true; do
        read -r -p "> 请输入本地/客户端下行带宽 (Mbps, 例如 500): " local_bw
        [[ "${local_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    while true; do
        read -r -p "> 请输入服务器上行带宽 (Mbps, 例如 1000): " server_bw
        [[ "${server_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    while true; do
        read -r -p "> 请输入预估网络延迟 (ms, 例如 150): " latency
        [[ "${latency// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    
    # 增加小白提示：爬升曲线调节详解
    echo -e "\n${YELLOW}--- 小白科普：TCP 爬升曲线 (Ramp-up) 该怎么选？ ---${NC}"
    echo -e "  ${GREEN}0.1 - 0.3 (保守平稳型)${NC} : 适合建站、写博客。不抢占过多网络，提供极度稳定的连接质量。"
    echo -e "  ${CYAN}0.4 - 0.6 (均衡通用型)${NC} : 适合日常科学上网代理。速度与稳定兼顾，是绝大多数人的默认最佳选择。"
    echo -e "  ${RED}0.7 - 1.0 (激进吞吐型)${NC} : 适合看 4K/8K 视频、大文件传输。极具侵略性，能榨干线路带宽，但极差网络下可能丢包。"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    
    while true; do
        read -r -p "> 请输入爬升曲线调节 (0.1 - 1.0) [默认 0.5]: " ramp_up
        ramp_up="${ramp_up// /}"; [ -z "$ramp_up" ] && ramp_up="0.5"
        awk -v r="$ramp_up" 'BEGIN{if(r>=0.1 && r<=1.0) exit 0; else exit 1}' && break
        echo -e "${RED}[错误] 请输入 0.1 到 1.0 之间的有效数字！${NC}"
    done
    while true; do
        read -r -p "> 请选择拥塞控制算法 (1: bbr, 2: cubic) [默认 1]: " bbr_choice
        bbr_choice="${bbr_choice// /}"; [ -z "$bbr_choice" ] && bbr_choice=1
        if [ "$bbr_choice" == "1" ]; then bbr_ver="bbr"; break; fi
        if [ "$bbr_choice" == "2" ]; then bbr_ver="cubic"; break; fi
    done
    while true; do
        read -r -p "> 请选择队列算法 (1: fq, 2: cake) [默认 1]: " qdisc_choice
        qdisc_choice="${qdisc_choice// /}"; [ -z "$qdisc_choice" ] && qdisc_choice=1
        if [ "$qdisc_choice" == "1" ]; then qdisc="fq"; break; fi
        if [ "$qdisc_choice" == "2" ]; then qdisc="cake"; break; fi
    done
    
    local w_ram=$(free -m | awk '/^Mem:/{print $2}')
    [ -z "$w_ram" ] || [ "$w_ram" -le 0 ] && w_ram=1024
    echo -e "\n${CYAN}>>> 系统自动探测内存: ${GREEN}${w_ram} MB${NC}"
    if ! confirm_action "执行并使上述 TCP 调优参数生效"; then pause_for_enter; return; fi
    
    read -r -p "> 是否在调优前备份当前参数？(y/n, 默认 y): " NEED_BACKUP
    NEED_BACKUP="${NEED_BACKUP// /}"
    [[ -z "$NEED_BACKUP" || "$NEED_BACKUP" =~ ^[yY]$ ]] && backup_config_silently
    
    echo -e "\n${CYAN}>>> 正在运行 VPS Box 自研引擎计算并安全注入配置...${NC}"
    
    # 清空旧的配置文件，为动态写入做准备
    > "$CUSTOM_CONF"

    # 使用内置 AWK 计算高精度变量，并按 k=v 格式输出，杜绝 Python 依赖
    TUNING_VARS=$(awk -v lb="$local_bw" -v sb="$server_bw" -v lat="$latency" \
        -v mem="$w_ram" -v ramp="$ramp_up" -v bbr="$bbr_ver" -v qd="$qdisc" '
    function min(x,y){return x<y?x:y}
    function max(x,y){return x>y?x:y}
    function clamp(v,lo,hi){return v<lo?lo:v>hi?hi:v}
    function ceil(x){y=int(x);return y<x?y+1:y}
    function sigmoid(e,t,n){return 1/(1+exp(-t*(e-n)))}
    function tcpcong(e,n){return min(n*(1+.5*e),n+10*e)}
    function qtheory(e,t,n){return t/(1-min(n,.95))*e}
    function memawe(e,t,n){return min(e,1024*t*1024*n)}
    BEGIN {
      lb=clamp(lb,1,100000);sb=clamp(sb,1,100000)
      lat=clamp(lat,1,2000);mem=clamp(mem,64,32768)
      ramp=clamp(ramp,.1,1)

      if(lat<=120){
        f=max(1,min(2,1.5*sqrt(lb/sb)))
        T=1024*min(lb*f,sb)*1024/8
        n_bdp=ceil(T*lat/1000);p_bdp=max(n_bdp,24576)
        ar=mem<=256?.1:.125;ib=mem<=256?4194304:8388608
        u=max(memawe(ceil(1.5*ramp*n_bdp),mem,ar),ib)
        resp=mem<=256?2.5:mem<=512?2.2:mem<=1024?2:1.8
        bfm=mem<=256?.24:mem<=512?.378:mem<=1024?.56:1.08
        cf=sigmoid(ramp,4,.3)*resp/2;cf=clamp(cf,.3,2)
        lfe=exp((lat/120-1)*log(2));lf=clamp(lfe*cf*resp,.8,5)
        ef=max(lat,50);lbe=exp((ef/120-1)*log(2));lbf=clamp(lbe*cf*resp,.8,5)
        bf=clamp(lbf*tcpcong(cf,1)*(cf<.877?bfm*(1+1.8*(1-cf/.877)):bfm),.5,3)
        ci=qtheory(T/65536*1.2,lat/1000*2,.8*cf)
        qf=clamp(log(ci+1)/log(1000)*.8*1.3,.3,2)
        bb=ceil(T*lat/1000);ws=bb>0?ceil(log(2*bb/65535)/log(2)):0
        aw=clamp(lf/1.5*ws*1.2*cf,1,4);aws=max(2,ceil(aw))
        V=mem<=256?2.5:mem<=512?3:mem<=1024?3:4
        H=mem<=256?1.2:mem<=512?1.5:mem<=1024?1.5:2
        w2=min(int(p_bdp*V*bf),u);k2=min(int(p_bdp*H*bf),u)
        qq=ceil(max(100,min(10000,2*T/65536))*qf)
        xm=mem<=256?.6:mem<=512?.8:mem<=1024?1:1.2
        so=int(clamp(.2*qq*xm,256,2048))
        nd=int(clamp(.4*qq*xm,2000,4000))
        sy=int(clamp(.8*qq*xm,2048,16384))
        r2=mem<=256?.015:mem<=512?.02:mem<=1024?.025:.03
        mf=int(clamp(1024*mem*r2+.5*T/1024,32768,1048576))
        op=int(min(65536,p_bdp/4))
        rd=87380;wd=65536;sw=10;ft=10;ts=1;mt=1;ns=3
        nl=4096;mr=1;fack=0;nms=0;mo=65536
        nt3=8192;nt2=4096;nt1=1024
        br=0;bp=0;ko=0;ki=0;kp=0;tm=""
      } else {
        f=max(1,min(5,lat/40))
        tr=max(1.5,min(5,2*sqrt(lb/sb)*f))
        T=1024*min(lb*tr,2*sb)*1024/8
        vhl=ceil(T*lat/1000)
        hv=memawe(ceil(2*ramp*vhl),mem,.125)
        u=hv;if(lat>500)u=max(hv,ceil(.5*vhl))
        lhl=max(vhl,T*lat/800)
        km=clamp(1.8*f,4,8)*ramp
        qm=clamp(2.5*f,5,10)*ramp
        w2=min(int(lhl*qm),u);k2=min(int(lhl*km),u)
        j=ceil(max(50,min(20000,3*T/131072))*ramp)
        z=mem<=512?.8:mem<=1024?1:mem<=2048?1.3:1.5
        so=int(clamp(.15*j*z,2560,16384))
        nd=int(clamp(.3*j*z,8192,32768))
        sy=int(clamp(.6*j*z,8192,65536))
        r2=mem<=512?.02:mem<=1024?.025:mem<=2048?.03:.035
        mf=int(clamp(1024*mem*r2+.6*T/1024,65536,1048576))
        op=int(min(262144,lhl/2));aws=max(2,ceil(f*8))
        mo=mem<=256?16384:32768;ns=2
        nt3=mem<=512?2048:4096;nt2=mem<=512?1024:2048;nt1=mem<=512?256:512
        rd=262144;wd=262144;sw=5;ft=10;ts=1;mt=1;mr=1
        nl=int(min(lhl/2,524288));fack=1;nms=1
        br=0;bp=0;ko=0;ki=0;kp=0;tm=""
      }
      printf("kernel.pid_max=65535\nkernel.panic=1\nkernel.sysrq=1\nkernel.core_pattern=core_%%e\n")
      printf("kernel.printk=3 4 1 3\nkernel.numa_balancing=0\nkernel.sched_autogroup_enabled=0\n")
      printf("vm.swappiness=%d\nvm.dirty_ratio=10\nvm.dirty_background_ratio=5\n",sw)
      printf("vm.panic_on_oom=1\nvm.overcommit_memory=1\nvm.min_free_kbytes=%d\n",mf)
      printf("vm.vfs_cache_pressure=100\nvm.dirty_expire_centisecs=3000\nvm.dirty_writeback_centisecs=500\n")
      printf("net.core.default_qdisc=%s\nnet.core.netdev_max_backlog=%d\n",qd,nd)
      printf("net.core.rmem_max=%d\nnet.core.wmem_max=%d\n",int(u),int(u))
      printf("net.core.rmem_default=%d\nnet.core.wmem_default=%d\n",rd,wd)
      printf("net.core.somaxconn=%d\nnet.core.optmem_max=%d\n",so,op)
      if(br+0>0)printf("net.core.busy_read=%d\n",br)
      if(bp+0>0)printf("net.core.busy_poll=%d\n",bp)
      printf("net.ipv4.tcp_fastopen=3\nnet.ipv4.tcp_timestamps=%d\nnet.ipv4.tcp_tw_reuse=1\n",ts)
      printf("net.ipv4.tcp_fin_timeout=%d\nnet.ipv4.tcp_slow_start_after_idle=0\n",ft)
      printf("net.ipv4.tcp_max_tw_buckets=32768\nnet.ipv4.tcp_sack=1\nnet.ipv4.tcp_fack=%d\n",fack)
      printf("net.ipv4.tcp_rmem=%d %d %d\n",8192,rd,int(w2))
      printf("net.ipv4.tcp_wmem=%d %d %d\n",8192,wd,int(k2))
      printf("net.ipv4.tcp_mtu_probing=%d\nnet.ipv4.tcp_congestion_control=%s\n",mt,bbr)
      printf("net.ipv4.tcp_notsent_lowat=%d\nnet.ipv4.tcp_window_scaling=1\n",nl)
      printf("net.ipv4.tcp_adv_win_scale=%d\nnet.ipv4.tcp_moderate_rcvbuf=%d\n",aws,mr)
      printf("net.ipv4.tcp_no_metrics_save=%d\nnet.ipv4.tcp_max_syn_backlog=%d\n",nms,sy)
      printf("net.ipv4.tcp_max_orphans=%d\n",mo)
      printf("net.ipv4.tcp_synack_retries=2\nnet.ipv4.tcp_syn_retries=%d\n",ns)
      printf("net.ipv4.tcp_abort_on_overflow=0\nnet.ipv4.tcp_stdurg=0\n")
      printf("net.ipv4.tcp_rfc1337=0\nnet.ipv4.tcp_syncookies=1\n")
      if(ko+0>0)printf("net.ipv4.tcp_keepalive_time=%d\n",ko)
      if(ki+0>0)printf("net.ipv4.tcp_keepalive_intvl=%d\n",ki)
      if(kp+0>0)printf("net.ipv4.tcp_keepalive_probes=%d\n",kp)
      if(length(tm)>0)printf("net.ipv4.tcp_mem=%s\n",tm)
      printf("net.ipv4.ip_forward=0\nnet.ipv4.ip_local_port_range=1024 65535\n")
      printf("net.ipv4.ip_no_pmtu_disc=0\nnet.ipv4.route.gc_timeout=100\n")
      printf("net.ipv4.neigh.default.gc_stale_time=120\n")
      printf("net.ipv4.neigh.default.gc_thresh3=%d\n",nt3)
      printf("net.ipv4.neigh.default.gc_thresh2=%d\n",nt2)
      printf("net.ipv4.neigh.default.gc_thresh1=%d\n",nt1)
      printf("net.ipv4.icmp_echo_ignore_broadcasts=1\n")
      printf("net.ipv4.icmp_ignore_bogus_error_responses=1\n")
      printf("net.ipv4.conf.all.rp_filter=1\nnet.ipv4.conf.default.rp_filter=1\n")
      printf("net.ipv4.conf.all.arp_announce=2\nnet.ipv4.conf.default.arp_announce=2\n")
      printf("net.ipv4.conf.all.arp_ignore=1\nnet.ipv4.conf.default.arp_ignore=1\n")
      printf("net.ipv4.conf.all.accept_redirects=0\nnet.ipv4.conf.default.accept_redirects=0\n")
      printf("net.ipv4.conf.all.secure_redirects=0\nnet.ipv4.conf.default.secure_redirects=0\n")
      printf("net.ipv4.conf.all.accept_source_route=0\nnet.ipv4.conf.default.accept_source_route=0\n")
      printf("net.ipv4.conf.all.forwarding=0\nnet.ipv4.conf.default.forwarding=0\n")
    }')

    # 预加载 BBR 模块防止未初始化报错
    modprobe tcp_bbr > /dev/null 2>&1 || true

    # 安全试探注入核心逻辑：逐行尝试生效，内核不支持则智能跳过，防止全部配置崩溃
    echo "$TUNING_VARS" | while IFS='=' read -r key val; do
        if [ -n "$key" ] && [ -n "$val" ]; then
            # 使用 sysctl -w 进行试探
            if sysctl -w "$key=$val" >/dev/null 2>&1; then
                # 如果成功，则将其保存到持久化配置文件中
                echo "$key = $val" >> "$CUSTOM_CONF"
            fi
        fi
    done
    
    if [ ! -s "$CUSTOM_CONF" ]; then
        echo -e "\n${RED}[错误] 动态参数注入完全失败！请检查系统权限或虚拟化架构限制。${NC}"
    else
        echo -e "\n${GREEN}[成功] TCP 动态调优参数已安全注入并生效！${NC}"
        echo -e "${YELLOW}(注: 系统已智能跳过了当前内核不支持的参数指令，防止了重启后 sysctl 奔溃配置丢失)${NC}"
        echo -e "[提示] 当前 BBR 状态: $(get_bbr_status)"
    fi
    pause_for_enter
}

backup_config_silently() {
    local ts=$(date +"%Y%m%d_%H%M%S")
    sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"
    if [ $? -eq 0 ]; then echo -e "${GREEN}[成功] 参数已自动备份。${NC}"; else echo -e "${YELLOW}[警告] 自动备份异常或不支持当前系统。${NC}"; fi
}

manage_backup() {
    while true; do
        clear; print_divider
        print_center "[ 网络调优参数备份与还原管理 ]" "$CYAN"
        print_divider
        echo -e "  ${GREEN}1.${NC} 立即备份当前参数\n  ${GREEN}2.${NC} 还原历史备份\n  ${GREEN}3.${NC} 删除历史备份\n  ${GREEN}0.${NC} 返回主菜单"
        echo ""; read -r -p "> 请选择操作 [0-3]: " b_opt
        b_opt="${b_opt// /}"
        case $b_opt in
            1)
                if ! confirm_action "备份当前网络参数"; then continue; fi
                local ts=$(date +"%Y%m%d_%H%M%S")
                sysctl -a 2>/dev/null | grep -E "net\.ipv4\.tcp_(rmem|wmem|congestion|sack)" > "${BACKUP_DIR}/backup_${ts}.conf"
                if [ $? -eq 0 ]; then echo -e "\n${GREEN}[成功] TCP 参数备份成功！${NC}"; else echo -e "\n${RED}[错误] 备份执行失败。${NC}"; fi
                pause_for_enter ;;
            2)
                shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
                if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${RED}无备份记录。${NC}"; pause_for_enter; continue; fi
                while true; do
                    echo -e "\n${CYAN}请选择要恢复的时间点：${NC}"
                    for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
                    read -r -p "> 请输入编号 (0取消): " res_opt
                    res_opt="${res_opt// /}"
                    if [ "$res_opt" == "0" ]; then break; fi
                    if [[ "$res_opt" =~ ^[0-9]+$ ]] && [ "$res_opt" -ge 1 ] && [ "$res_opt" -le "${#backups[@]}" ]; then
                        if ! confirm_action "覆盖当前配置并还原至此备份"; then break; fi
                        sysctl -p "${backups[$((res_opt-1))]}" > /dev/null 2>&1
                        if [ $? -eq 0 ]; then rm -f "$CUSTOM_CONF"; echo -e "\n${GREEN}[成功] 参数已成功还原！${NC}"; else echo -e "\n${RED}[错误] 还原参数失败。${NC}"; fi
                        pause_for_enter; break
                    else
                        echo -e "${RED}[错误] 输入无效编号，请重新输入！${NC}"
                    fi
                done ;;
            3)
                shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
                if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${YELLOW}备份目录为空。${NC}"; pause_for_enter; continue; fi
                while true; do
                    echo -e "\n${CYAN}请选择要删除的备份：${NC}"
                    for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
                    echo -e "  ${RED}99.${NC} 清空所有"
                    read -r -p "> 请输入编号 (0取消): " del_opt
                    del_opt="${del_opt// /}"
                    if [ "$del_opt" == "0" ]; then break; fi
                    if [[ "$del_opt" =~ ^[0-9]+$ ]] && [ "$del_opt" -ge 1 ] && [ "$del_opt" -le "${#backups[@]}" ]; then
                        if ! confirm_action "永久删除此备份"; then break; fi
                        rm -f "${backups[$((del_opt-1))]}"; echo -e "\n${GREEN}[成功] 记录已删除。${NC}"; pause_for_enter; break
                    elif [ "$del_opt" -eq 99 ]; then
                        if ! confirm_action "永久清空所有备份"; then break; fi
                        rm -f "${BACKUP_DIR}"/backup_*.conf; echo -e "\n${GREEN}[成功] 已清空所有备份。${NC}"; pause_for_enter; break
                    else
                        echo -e "${RED}[错误] 编号输入无效，请重新选择列表中存在的选项！${NC}"
                    fi
                done ;;
            0) return ;;
            *) echo -e "\n${RED}[错误] 输入无效，请输入 0-3 之间的数字！${NC}"; sleep 1 ;;
        esac
    done
}

check_media_unlock() {
    clear; print_divider
    print_center "[ IP 质量检测与流媒体解锁 ]" "$CYAN"
    print_divider
    echo -e "${CYAN}>>> 正在载入权威检测引擎，请稍候...${NC}\n"
    bash <(curl -sL https://Check.Place) -I || echo -e "\n${RED}[错误] 脚本载入失败，请检查您的服务器网络与墙外连通性。${NC}"
    pause_for_enter
}

view_deployed_nodes() {
    while true; do
        clear; print_divider
        print_center "[ 节点状态、分享与配置备份管理 ]" "$CYAN"
        print_divider
        install_dependencies
        echo -e "${CYAN}--- 服务端底层配置状态 ---${NC}"
        if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
            jq -r '.inbounds[] | "【Xray】 端口: \(.port) | 协议: \(.protocol) | 网络: \(if .protocol == "hysteria" then "udp" else (.streamSettings.network // "tcp") end) | 安全: \(.streamSettings.security // "none")"' /usr/local/etc/xray/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
        else
            echo -e "${YELLOW}未检测到 Xray 节点配置。${NC}"
        fi
        if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
            jq -r '.inbounds[] | "【Sing-box】 端口: \(.listen_port) | 协议: \(.type) | 网络: \(if .type == "hysteria2" then "udp" else (.transport.type // "tcp") end) | 安全: \(if (.tls?.reality?.enabled? // false) then "reality" elif (.tls?.enabled? // false) then "tls" else "none" end)"' /etc/sing-box/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
        else
            echo -e "${YELLOW}未检测到 Sing-box 节点配置。${NC}"
        fi
        echo -e "\n${CYAN}--- 已保存的节点分享链接 ---${NC}"
        local links=()
        if [ -f "$NODE_RECORD_FILE" ]; then
            mapfile -t links < "$NODE_RECORD_FILE"
            if [ ${#links[@]} -eq 0 ]; then
                echo -e "${YELLOW}暂无保存的分享链接。${NC}"
            else
                for i in "${!links[@]}"; do
                    local info=$(echo "${links[$i]}" | awk -F' \\| ' '{print $1" "$2}')
                    echo -e "  ${GREEN}$((i+1)).${NC} $info"
                done
            fi
        else
            echo -e "${YELLOW}暂无保存的分享链接记录。${NC}"
        fi
        print_separator
        echo -e "  [${GREEN}1-${#links[@]}${NC}] 输入编号：查看对应节点的二维码与完整链接"
        echo -e "  [${GREEN}B${NC}] 备份：为所有节点配置文件创建快照\n  [${GREEN}R${NC}] 还原：从历史快照恢复节点配置\n  [${GREEN}0${NC}] 返回主菜单"
        echo ""; read -r -p "> 请选择操作: " vn_opt
        vn_opt="${vn_opt// /}"
        if [ "$vn_opt" == "0" ]; then break; fi
        if [[ "$vn_opt" =~ ^[0-9]+$ ]] && [ "$vn_opt" -ge 1 ] && [ "$vn_opt" -le "${#links[@]}" ]; then
            local target_link=$(echo "${links[$((vn_opt-1))]}" | awk -F' \\| ' '{print $3}')
            echo -e "\n${CYAN}>>> 节点分享链接：${NC}\n${target_link}\n"
            echo -e "${YELLOW}>>> 节点二维码 (紧凑版，长内容自动换行无影响)：${NC}"
            qrencode -t UTF8 -m 1 "$target_link" || echo -e "${RED}[错误] 二维码生成失败，请确认系统是否安装 qrencode。${NC}"
            pause_for_enter
        elif [[ "$vn_opt" =~ ^[bB]$ ]]; then
            if ! confirm_action "备份当前节点配置"; then continue; fi
            local ts=$(date +"%Y%m%d_%H%M%S")
            local bk_path="${BACKUP_DIR}/node_backup_${ts}"
            mkdir -p "$bk_path"
            [ -f "/usr/local/etc/xray/config.json" ] && cp /usr/local/etc/xray/config.json "$bk_path/xray_config.json"
            [ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json "$bk_path/singbox_config.json"
            [ -f "$NODE_RECORD_FILE" ] && cp "$NODE_RECORD_FILE" "$bk_path/vpsbox_nodes.txt"
            echo -e "\n${GREEN}[成功] 节点配置已成功备份至: $bk_path ${NC}"; pause_for_enter
        elif [[ "$vn_opt" =~ ^[rR]$ ]]; then
            shopt -s nullglob; local n_backups=("${BACKUP_DIR}"/node_backup_*); shopt -u nullglob
            if [ ${#n_backups[@]} -eq 0 ]; then echo -e "\n${RED}未找到节点备份记录。${NC}"; pause_for_enter; continue; fi
            echo -e "\n${CYAN}请选择要还原的备份：${NC}"
            for i in "${!n_backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份时间: $(basename "${n_backups[$i]}" | sed 's/node_backup_//')"; done
            read -r -p "> 请输入编号 (0取消): " n_res_opt
            n_res_opt="${n_res_opt// /}"
            if [ "$n_res_opt" == "0" ]; then continue; fi
            if [[ "$n_res_opt" =~ ^[0-9]+$ ]] && [ "$n_res_opt" -ge 1 ] && [ "$n_res_opt" -le "${#n_backups[@]}" ]; then
                if ! confirm_action "还原此备份 (当前配置将被覆盖，且服务会重启)"; then continue; fi
                local sel_bk="${n_backups[$((n_res_opt-1))]}"
                [ -f "$sel_bk/xray_config.json" ] && cp "$sel_bk/xray_config.json" /usr/local/etc/xray/config.json && systemctl restart xray
                [ -f "$sel_bk/singbox_config.json" ] && cp "$sel_bk/singbox_config.json" /etc/sing-box/config.json && systemctl restart sing-box
                [ -f "$sel_bk/vpsbox_nodes.txt" ] && cp "$sel_bk/vpsbox_nodes.txt" "$NODE_RECORD_FILE"
                echo -e "\n${GREEN}[成功] 节点配置已成功还原！服务已尝试重启。${NC}"; pause_for_enter
            else
                echo -e "${RED}[错误] 输入无效编号！${NC}"; sleep 1
            fi
        else
            echo -e "\n${RED}[错误] 输入无效，请重新选择！${NC}"; sleep 1
        fi
    done
}

delete_node() {
    clear; print_divider
    print_center "[ 删除指定的已部署节点 ]" "$CYAN"
    print_divider
    echo -e "正在扫描当前已部署的节点...\n"
    local nodes_found=0
    if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
        echo -e "${CYAN}【Xray 节点】${NC}"
        jq -r '.inbounds[] | "  - 端口: \(.port) | 主协议: \(.protocol)"' /usr/local/etc/xray/config.json 2>/dev/null
        nodes_found=1
    fi
    if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
        echo -e "\n${CYAN}【Sing-box 节点】${NC}"
        jq -r '.inbounds[] | "  - 端口: \(.listen_port) | 主协议: \(.type)"' /etc/sing-box/config.json 2>/dev/null
        nodes_found=1
    fi
    if [ "$nodes_found" -eq 0 ]; then echo -e "${YELLOW}未检测到任何已部署的节点，无需删除。${NC}"; pause_for_enter; return; fi
    echo ""
    while true; do
        read -r -p "> 请输入要删除的节点【端口号】 (输入 0 取消): " del_port
        del_port="${del_port// /}"
        if [ "$del_port" == "0" ]; then return; fi
        if [ -z "$del_port" ] || ! [[ "$del_port" =~ ^[0-9]+$ ]]; then echo -e "${RED}[错误] 端口号必须是有效的纯数字！请重新输入。${NC}"; continue; fi
        local port_exists=0
        if [ -f "/usr/local/etc/xray/config.json" ] && jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then port_exists=1; fi
        if [ -f "/etc/sing-box/config.json" ] && jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then port_exists=1; fi
        if [ "$port_exists" -eq 0 ]; then echo -e "${RED}[错误] 当前部署中未找到端口为 $del_port 的节点，请检查！${NC}"; continue; fi
        break
    done
    if ! confirm_action "永久删除端口为 $del_port 的节点"; then pause_for_enter; return; fi
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        if jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.port == $del_port))" /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
            if [ -s /tmp/xray_tmp.json ]; then
                mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json; systemctl restart xray
                echo -e "${GREEN}[成功] 已成功移除 Xray 中占用端口 $del_port 的节点配置！${NC}"
            else
                rm -f /tmp/xray_tmp.json; echo -e "${RED}[错误] Xray 节点删除失败，配置可能受损！${NC}"
            fi
        fi
    fi
    if [ -f "/etc/sing-box/config.json" ]; then
        if jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.listen_port == $del_port))" /etc/sing-box/config.json > /tmp/sb_tmp.json
            if [ -s /tmp/sb_tmp.json ]; then
                mv /tmp/sb_tmp.json /etc/sing-box/config.json; systemctl restart sing-box
                echo -e "${GREEN}[成功] 已成功移除 Sing-box 中占用端口 $del_port 的节点配置！${NC}"
            else
                rm -f /tmp/sb_tmp.json; echo -e "${RED}[错误] Sing-box 节点删除失败，配置可能受损！${NC}"
            fi
        fi
    fi
    if [ -f "$NODE_RECORD_FILE" ]; then sed -i "/端口:${del_port} /d" "$NODE_RECORD_FILE" 2>/dev/null; fi
    pause_for_enter
}

append_inbound() {
    local CONFIG_FILE=$1; local NEW_INBOUND=$2; local TARGET_PORT=$3; local CORE_NAME=$4
    local TMP_FILE="/tmp/vpsbox_test_config.json"
    if [ -f "$CONFIG_FILE" ] && grep -q "inbounds" "$CONFIG_FILE"; then
        echo -e "${YELLOW}[系统] 检测到已有配置，正在生成并验证测试配置...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.listen_port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE"
        else jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE"; fi
    else
        echo -e "${YELLOW}[系统] 首次部署，正在初始化并验证配置文件...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"type":"direct"}]}
EOF
        else cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"protocol":"freedom"}]}
EOF
        fi
    fi
    local TEST_PASS=0
    if [ "$CORE_NAME" == "Sing-box" ]; then local SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); if "$SB_BIN" check -c "$TMP_FILE" >/dev/null 2>&1; then TEST_PASS=1; fi
    else local X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); if "$X_BIN" run -test -c "$TMP_FILE" >/dev/null 2>&1; then TEST_PASS=1; fi
    fi
    if [ "$TEST_PASS" -eq 1 ]; then mv "$TMP_FILE" "$CONFIG_FILE"; return 0; else rm -f "$TMP_FILE"; return 1; fi
}

install_reality_node() {
    clear; print_divider
    print_center "[ 部署 VLESS-Reality 节点 ]" "$CYAN"
    print_divider
    echo -e "${YELLOW}>>> 小白科普：VLESS-Reality 是一种先进的伪装技术。不需要您购买域名，直接“借用”大厂（如苹果、微软）的域名进行伪装，安全性极高，非常适合防封锁。${NC}\n"
    
    while true; do
        read -r -p "> 请输入监听端口 (默认 50000, 0 取消): " PORT
        PORT="${PORT// /}"
        if [ "$PORT" == "0" ]; then return; fi; [ -z "$PORT" ] && PORT=50000
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then echo -e "${RED}[错误] 端口号必须是 1 到 65535 之间的纯数字！请重新输入。${NC}"; continue; fi
        if ss -tulpn | grep -qw ":$PORT"; then echo -e "${RED}[错误] 端口 $PORT 已被占用！${NC}"; continue; fi
        break
    done
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
        read -r -p "> 选择运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    echo -e "\n  ${GREEN}1.${NC} gateway.icloud.com (苹果官网)\n  ${GREEN}2.${NC} www.microsoft.com (微软官网)"
    read -r -p "> 选择伪装 SNI [输入 1-2 选择，或直接输入自定义域名, 默认 1, 0 取消]: " sni_choice
    sni_choice="${sni_choice// /}"
    if [ "$sni_choice" == "0" ]; then return; fi
    if [[ -z "$sni_choice" || "$sni_choice" == "1" ]]; then SNI_DOMAIN="gateway.icloud.com"; elif [[ "$sni_choice" == "2" ]]; then SNI_DOMAIN="www.microsoft.com"; else SNI_DOMAIN="$sni_choice"; fi
    if ! confirm_action "开始部署 Reality 节点"; then pause_for_enter; return; fi
    install_dependencies
    UUID=$(cat /proc/sys/kernel/random/uuid); SHORT_ID=$(openssl rand -hex 8)
    LINK_IP="$SERVER_IP"
    if [[ "$IP_FORMAT" == "v6" ]]; then LINK_IP="[${SERVER_IP}]"; fi
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        hash -r; X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); KEYS=$("$X_BIN" x25519)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"port":'$PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"'$SNI_DOMAIN':443","serverNames":["'$SNI_DOMAIN'"],"privateKey":"'$PRI'","shortIds":["'$SHORT_ID'"]}}}'
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$PORT" "Xray"; then systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray); else SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        hash -r; SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); KEYS=$("$SB_BIN" generate reality-keypair)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$PORT',"users":[{"uuid":"'$UUID'","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"'$SNI_DOMAIN'","reality":{"enabled":true,"handshake":{"server":"'$SNI_DOMAIN'","server_port":443},"private_key":"'$PRI'","short_id":["'$SHORT_ID'"]}}}'
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$PORT" "Sing-box"; then systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box); else SERVICE_STATUS="config_error"; fi
    fi
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}[提示] VLESS-Reality 节点成功部署于 ${CORE_NAME}！${NC}"
        LINK="vless://${UUID}@${LINK_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp#${CORE_NAME}-Reality"
        echo -e "${CYAN}${LINK}${NC}\n"
        echo -e "${YELLOW}>>> 扫描下方二维码快速导入节点：${NC}"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-Reality | 端口:${PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置校验失败或服务拒绝启动，未保存任何变更！${NC}"
    fi
    pause_for_enter
}

install_ws_tls_node() {
    clear; print_divider
    print_center "[ 部署 VLESS-WS-TLS 节点 ]" "$CYAN"
    print_divider
    echo -e "${YELLOW}>>> 小白科普：WS+TLS 是非常经典的节点协议。最大的优势是可以搭配 Cloudflare 等 CDN 使用。如果您服务器的 IP 已经被墙，用这个协议配合 CDN 就能“起死回生”。${NC}\n"
    
    while true; do
        read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [ "$DOMAIN" == "0" ]; then return; fi
        if [ -z "$DOMAIN" ]; then continue; fi
        DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
        break
    done
    while true; do
        read -r -p "> 监听端口 (默认 443, 0 取消): " WS_PORT
        WS_PORT="${WS_PORT// /}"
        if [ "$WS_PORT" == "0" ]; then return; fi; [ -z "$WS_PORT" ] && WS_PORT=443
        if ! [[ "$WS_PORT" =~ ^[0-9]+$ ]] || [ "$WS_PORT" -lt 1 ] || [ "$WS_PORT" -gt 65535 ]; then continue; fi
        if ss -tulpn | grep -qw ":$WS_PORT"; then echo -e "${RED}端口 $WS_PORT 已被占用！${NC}"; continue; fi
        break
    done
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
        read -r -p "> 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
    echo -e "  ${GREEN}1.${NC} 【API模式】使用 Cloudflare API 申请\n  ${GREEN}2.${NC} 【独立模式】使用常规 80 端口申请"
    while true; do
        read -r -p "> 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
        cert_mode="${cert_mode// /}"
        if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
        if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
        if [ "$cert_mode" == "1" ]; then
            read -r -p "> 请输入您的 Cloudflare API Token: " CF_Token
            if [ -z "$CF_Token" ]; then continue; fi
            read -r -p "> 请输入您的 Cloudflare Account ID: " CF_Account_ID
            if [ -z "$CF_Account_ID" ]; then continue; fi
            export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"; break
        elif [ "$cert_mode" == "2" ]; then
            if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
                echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP ($SERVER_IP) 不符！${NC}"
                read -r -p "> 是否强行继续？(y/n, 默认 n): " force_continue
                if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
            fi
            break
        fi
    done
    if ! confirm_action "开始部署 WS+TLS 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh -s email=dummy@vpsbox.com >/dev/null 2>&1
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then echo -e "\n${RED}[错误] Acme.sh 安装失败！${NC}"; pause_for_enter; return; fi
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    echo -e "\n${CYAN}>>> 正在申请 SSL 证书...${NC}"
    PORT_80_SERVICE=""
    if /root/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        echo -e "${GREEN}[成功] 检测到本地有效证书，复用机制触发！${NC}"
        CERT_RES=0
    else
        if [ "$cert_mode" == "1" ]; then
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256; CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                PORT_80_SERVICE=$(ss -tlnp | grep "\b:80\b" | awk -F'"' '{print $2}' | grep -v "^$" | head -n 1)
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE="未知程序"
                echo -e "\n${YELLOW}[警告] 检测到 80 端口正被 [ ${PORT_80_SERVICE} ] 占用！${NC}"
                read -r -p "> 是否仍要临时关闭强行申请？(y/n, 默认 n): " force_kill_80
                if [[ ! "${force_kill_80// /}" =~ ^[yY]$ ]]; then echo -e "${CYAN}已取消操作。${NC}"; pause_for_enter; return; fi
                systemctl stop "$PORT_80_SERVICE" > /dev/null 2>&1; fuser -k 80/tcp > /dev/null 2>&1; sleep 2
             fi
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; CERT_RES=$?
            if [ -n "$PORT_80_SERVICE" ] && [ "$PORT_80_SERVICE" != "未知程序" ]; then
                systemctl start "$PORT_80_SERVICE" >/dev/null 2>&1 || echo -e "${RED}[注意] ${PORT_80_SERVICE} 恢复失败。${NC}"
            fi
        fi
    fi
    if [ "$CERT_RES" -ne 0 ] && [ "$CERT_RES" -ne 2 ]; then echo -e "\n${RED}[错误] 证书申请失败，中止。${NC}"; pause_for_enter; return; fi
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" --reloadcmd "systemctl restart xray 2>/dev/null; systemctl restart sing-box 2>/dev/null" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem; chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    UUID=$(cat /proc/sys/kernel/random/uuid); WSPATH="/$(openssl rand -hex 4)"
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        NEW_INBOUND='{"port":'$WS_PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"wsSettings":{"path":"'$WSPATH'"}}}'
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$WS_PORT" "Xray"; then systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray); else SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$WS_PORT',"users":[{"uuid":"'$UUID'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"},"transport":{"type":"ws","path":"'$WSPATH'"}}'
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$WS_PORT" "Sing-box"; then systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box); else SERVICE_STATUS="config_error"; fi
    fi
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}[提示] VLESS-WS-TLS 部署成功！${NC}"
        LINK="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WSPATH}#${CORE_NAME}-WS-TLS"
        echo -e "${CYAN}${LINK}${NC}\n"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-WS-TLS | 端口:${WS_PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置服务拒绝启动，未保存任何变更！${NC}"
    fi
    pause_for_enter
}

install_hy2_node() {
    clear; print_divider
    print_center "[ 部署 Hysteria2 节点 ]" "$CYAN"
    print_divider
    echo -e "${YELLOW}>>> 小白科普：Hysteria2 是一种基于 UDP 协议的暴力加速代理方案。如果您的服务器到国内的线路非常差（比如晚高峰卡顿），这个协议能无视拥塞强行拉满网速，体验飞跃！${NC}\n"

    while true; do
        read -r -p "> 请输入域名 (输入 0 取消): " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [ "$DOMAIN" == "0" ]; then return; fi
        if [ -z "$DOMAIN" ]; then continue; fi
        DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
        break
    done
    while true; do
        read -r -p "> 监听端口 (默认 8443, 0 取消): " HY2_PORT
        HY2_PORT="${HY2_PORT// /}"
        if [ "$HY2_PORT" == "0" ]; then return; fi; [ -z "$HY2_PORT" ] && HY2_PORT=8443
        if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then continue; fi
        if ss -tulpn | grep -qw ":$HY2_PORT"; then echo -e "${RED}端口 $HY2_PORT 已被占用！${NC}"; continue; fi
        break
    done
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
        read -r -p "> 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
    echo -e "  ${GREEN}1.${NC} 【API模式】使用 Cloudflare API 申请\n  ${GREEN}2.${NC} 【独立模式】使用常规 80 端口申请"
    while true; do
        read -r -p "> 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
        cert_mode="${cert_mode// /}"
        if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
        if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
        if [ "$cert_mode" == "1" ]; then
            read -r -p "> 请输入您的 Cloudflare API Token: " CF_Token
            if [ -z "$CF_Token" ]; then continue; fi
            read -r -p "> 请输入您的 Cloudflare Account ID: " CF_Account_ID
            if [ -z "$CF_Account_ID" ]; then continue; fi
            export CF_Token="$CF_Token"; export CF_Account_ID="$CF_Account_ID"; break
        elif [ "$cert_mode" == "2" ]; then
            if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
                echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP ($SERVER_IP) 不符！${NC}"
                read -r -p "> 是否强行继续？(y/n, 默认 n): " force_continue
                if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
            fi
            break
        fi
    done
    if ! confirm_action "开始部署 Hysteria2 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh -s email=dummy@vpsbox.com >/dev/null 2>&1
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then echo -e "\n${RED}[错误] Acme.sh 安装失败！${NC}"; pause_for_enter; return; fi
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    echo -e "\n${CYAN}>>> 正在申请 SSL 证书...${NC}"
    PORT_80_SERVICE=""
    if /root/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        echo -e "${GREEN}[成功] 检测到本地有效证书，复用！${NC}"
        CERT_RES=0
    else
        if [ "$cert_mode" == "1" ]; then
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256; CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                PORT_80_SERVICE=$(ss -tlnp | grep "\b:80\b" | awk -F'"' '{print $2}' | grep -v "^$" | head -n 1)
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE="未知程序"
                echo -e "\n${YELLOW}[警告] 检测到 80 端口正被 [ ${PORT_80_SERVICE} ] 占用！${NC}"
                read -r -p "> 是否仍要临时关闭强行申请？(y/n, 默认 n): " force_kill_80
                if [[ ! "${force_kill_80// /}" =~ ^[yY]$ ]]; then echo -e "${CYAN}已取消操作。${NC}"; pause_for_enter; return; fi
                systemctl stop "$PORT_80_SERVICE" > /dev/null 2>&1; fuser -k 80/tcp > /dev/null 2>&1; sleep 2
             fi
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256; CERT_RES=$?
            if [ -n "$PORT_80_SERVICE" ] && [ "$PORT_80_SERVICE" != "未知程序" ]; then
                systemctl start "$PORT_80_SERVICE" >/dev/null 2>&1 || echo -e "${RED}[注意] ${PORT_80_SERVICE} 恢复失败。${NC}"
            fi
        fi
    fi
    if [ "$CERT_RES" -ne 0 ] && [ "$CERT_RES" -ne 2 ]; then echo -e "\n${RED}[错误] 证书申请失败，中止。${NC}"; pause_for_enter; return; fi
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" --reloadcmd "systemctl restart xray 2>/dev/null; systemctl restart sing-box 2>/dev/null" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem; chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    HY2_PASS=$(openssl rand -hex 8)
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        NEW_INBOUND='{"listen":"0.0.0.0","port":'$HY2_PORT',"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"'$HY2_PASS'","email":"user@vpsbox"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"minVersion":"1.3","certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"'$HY2_PASS'","udpIdleTimeout":60}}}'
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$HY2_PORT" "Xray"; then systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray); else SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        NEW_INBOUND='{"type":"hysteria2","listen":"::","listen_port":'$HY2_PORT',"users":[{"password":"'$HY2_PASS'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$HY2_PORT" "Sing-box"; then systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box); else SERVICE_STATUS="config_error"; fi
    fi
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}[提示] Hysteria2 部署成功！${NC}"
        LINK="hy2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}&insecure=0#${CORE_NAME}-Hys2"
        echo -e "${CYAN}${LINK}${NC}\n"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-Hys2 | 端口:${HY2_PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置服务拒绝启动，未保存任何变更！${NC}"
    fi
    pause_for_enter
}

install_warp() {
    clear; print_divider
    print_center "[ Cloudflare WARP 一键解锁 ]" "$CYAN"
    print_divider
    if ! confirm_action "部署 Cloudflare WARP"; then pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在启动 WARP 脚本...${NC}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh || echo -e "\n${RED}[错误] WARP 脚本下载或执行失败，请检查网络。${NC}"
    pause_for_enter
}

manage_ufw() {
    while true; do
        clear; print_divider
        print_center "[ UFW 防火墙端口管理 ]" "$CYAN"
        print_divider
        if ! command -v ufw &> /dev/null; then
            echo -e "${YELLOW}[系统] 正在自动安装 UFW 防火墙...${NC}"
            apt-get update -y > /dev/null 2>&1; apt-get install ufw -y > /dev/null 2>&1 || echo -e "${RED}[错误] UFW 安装失败。${NC}"
        fi
        echo -e "  ${GREEN}1.${NC} 查看当前防火墙状态与已放行端口\n  ${GREEN}2.${NC} 放行指定新端口 (TCP/UDP)\n  ${GREEN}3.${NC} 删除某个端口规则\n  ${GREEN}4.${NC} 开启防火墙\n  ${GREEN}5.${NC} 彻底关闭防火墙\n  ${GREEN}0.${NC} 返回主菜单"
        print_separator; echo ""
        read -r -p "> 请选择操作 [0-5]: " ufw_opt
        ufw_opt="${ufw_opt// /}"
        case $ufw_opt in
            1) echo -e "\n${CYAN}>>> 防火墙状态：${NC}"; ufw status numbered || echo -e "${RED}[错误] 读取状态失败。${NC}"; pause_for_enter ;;
            2)
                read -r -p "> 请输入要放行的端口号: " port
                port="${port// /}"
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then ufw allow "$port"; echo -e "${GREEN}[成功] 端口 $port 已成功添加放行规则！${NC}"; ufw reload > /dev/null 2>&1; else echo -e "${RED}[错误] 端口号输入无效！${NC}"; fi
                pause_for_enter ;;
            3)
                echo -e "\n${CYAN}>>> 当前规则列表：${NC}"; ufw status numbered; echo ""
                read -r -p "> 请输入要删除的【规则编号】: " rule_num
                rule_num="${rule_num// /}"
                if [[ "$rule_num" =~ ^[0-9]+$ ]]; then ufw --force delete "$rule_num" || echo -e "${RED}[错误] 删除规则失败。${NC}"; echo -e "${GREEN}[成功] 规则 $rule_num 已尝试删除！${NC}"; fi
                pause_for_enter ;;
            4)
                if ! confirm_action "开启防火墙并默认拦截外部访问 (系统将自动防呆放行 SSH)"; then continue; fi
                CURRENT_SSH_PORT=$(ss -tlnp | grep -w sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
                [ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
                [ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=22
                echo -e "\n${CYAN}>>> 检测到当前 SSH 登录端口为: ${CURRENT_SSH_PORT}${NC}"
                ufw default deny incoming > /dev/null 2>&1; ufw default allow outgoing > /dev/null 2>&1
                ufw allow "$CURRENT_SSH_PORT"/tcp > /dev/null 2>&1
                ufw --force enable || { echo -e "\n${RED}[错误] 开启防火墙失败。${NC}"; pause_for_enter; continue; }
                echo -e "\n${GREEN}[成功] 防火墙已成功开启！当前 SSH 端口 $CURRENT_SSH_PORT 已安全放行。${NC}"; pause_for_enter ;;
            5)
                if ! confirm_action "彻底关闭防火墙"; then continue; fi
                ufw disable || { echo -e "${RED}[错误] 关闭防火墙失败。${NC}"; pause_for_enter; continue; }
                echo -e "${GREEN}[成功] 防火墙已完全关闭！${NC}"; pause_for_enter ;;
            0) break ;;
            *) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
        esac
    done
}

update_script() {
    clear; print_divider
    print_center "[ 一键更新 VPSBox 脚本自身 ]" "$CYAN"
    print_divider
    if ! confirm_action "从 GitHub 拉取最新版 VPSBox 并覆盖当前脚本"; then pause_for_enter; return; fi
    echo -e "\n${CYAN}>>> 正在连接 GitHub 下载最新版本...${NC}"
    curl -sL "https://raw.githubusercontent.com/8088892/VPSBox/main/vpsbox.sh" -o /tmp/vpsbox_update.sh
    if [ -f /tmp/vpsbox_update.sh ] && grep -q "VPSBox" /tmp/vpsbox_update.sh; then
        mv /tmp/vpsbox_update.sh "$SHORTCUT_PATH"; chmod +x "$SHORTCUT_PATH"
        echo -e "\n${GREEN}[成功] VPSBox 已成功更新到最新版本！即将自动重启脚本...${NC}"; sleep 2; exec "$SHORTCUT_PATH"
    else
        echo -e "\n${RED}[错误] 下载失败或获取到的文件异常。${NC}"; rm -f /tmp/vpsbox_update.sh; pause_for_enter
    fi
}

uninstall_vpsbox() {
    print_separator; echo -e "${YELLOW}[警告] 此操作将彻底删除 VPSBox 的快捷命令、本地备份及所有缓存日志。${NC}"
    if ! confirm_action "彻底卸载 VPSBox"; then return; fi
    rm -f /usr/local/bin/vpsbox; rm -rf /etc/vpsbox_backups; rm -f "$NODE_RECORD_FILE"; rm -f "$INSTALL_LOG"
    echo -e "\n${GREEN}[成功] VPSBox 已彻底卸载！系统已无任何残留，期待与您下次相遇！${NC}"
    exit 0
}

while true; do
    clear; echo ""; print_divider
    print_center "VPS Box 节点部署与服务器管家 v2.6.0" "$PURPLE"
    print_divider
    echo -e "  公网 IP  : ${YELLOW}${SERVER_IP} ${CYAN}[${IP_FORMAT}]${NC}\n  硬件规格 : ${YELLOW}${HW_PROFILE}${NC}\n  系统时区 : ${YELLOW}${CURRENT_TZ}${NC}\n  BBR 状态 : $(get_bbr_status)"
    print_separator
    echo -e "  ${CYAN}【基础系统管理与安全防护】${NC}"
    echo -e "  ${GREEN}1.${NC} 更新系统并安装必备组件        ${GREEN}2.${NC} 系统垃圾与废弃依赖清理"
    echo -e "  ${GREEN}3.${NC} 修改系统 root 密码            ${GREEN}4.${NC} SSH 密钥与登录安全管理"
    echo -e "  ${GREEN}5.${NC} 修改系统主机名 (Hostname)     ${GREEN}6.${NC} 修改时区为 [北京时间]"
    echo -e "  ${GREEN}7.${NC} 虚拟内存 (Swap) 一键管理      ${GREEN}8.${NC} 系统 DNS 极速优化"
    echo -e "  ${GREEN}9.${NC} 修改 SSH 默认登录端口"
    echo -e "\n  ${CYAN}【网络协议与性能极速优化】${NC}"
    echo -e "  ${GREEN}10.${NC} 自研动态 TCP 智能调优引擎\n  ${GREEN}11.${NC} 网络调优参数备份/还原管理\n  ${GREEN}12.${NC} BBR 拥塞控制智能管理中心"
    echo -e "\n  ${CYAN}【流媒体检测与节点防冲突部署】${NC}"
    echo -e "  ${GREEN}13.${NC} IP 质量检测与流媒体解锁\n  ${GREEN}14.${NC} 部署 VLESS-Reality\n  ${GREEN}15.${NC} 部署 VLESS-WS-TLS\n  ${GREEN}16.${NC} 部署 Hysteria2\n  ${GREEN}17.${NC} 查看已部署节点与备份管理\n  ${GREEN}18.${NC} 删除指定的已部署节点"
    echo -e "\n  ${CYAN}【附加实用工具与安全拓展】${NC}"
    echo -e "  ${GREEN}19.${NC} Cloudflare WARP 一键解锁\n  ${GREEN}20.${NC} UFW 防火墙简单端口管理\n  ${GREEN}21.${NC} 一键更新 VPSBox 脚本自身\n  ${RED}99.${NC} 彻底卸载 VPSBox 及系统残留"
    print_separator; echo -e "  ${GREEN}0.${NC} 安全退出"; print_divider; echo ""
    read -r -p "> 请输入选择 [0-21, 99]: " OPTION
    OPTION="${OPTION// /}" 
    case $OPTION in
        1) system_update ;; 2) system_clean ;; 3) change_root_password ;; 4) manage_ssh_security ;; 5) change_hostname ;; 6) set_china_timezone ;;
        7) manage_swap ;; 8) optimize_dns ;; 9) change_ssh_port ;; 10) apply_tuning ;; 11) manage_backup ;; 12) manage_bbr ;;
        13) check_media_unlock ;; 14) install_reality_node ;; 15) install_ws_tls_node ;; 16) install_hy2_node ;; 17) view_deployed_nodes ;; 18) delete_node ;;
        19) install_warp ;; 20) manage_ufw ;; 21) update_script ;; 99) uninstall_vpsbox ;; 0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
    esac
done
