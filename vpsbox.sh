#!/bin/bash

# =====================================================================
# 项目名称: VPS Box (全能服务器优化与多节点部署工具箱)
# 核心特性: 全局防冲突部署、智能复用证书、双内核自适应、系统管家
# 版本: v1.8.2 (引入智能依赖检测 + 保持原版 UI 描述与自适应排版)
# =====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 底层路径
BACKUP_DIR="/etc/vpsbox_backups"
CUSTOM_CONF="/etc/sysctl.d/99-vpsbox-tcp.conf"
SHORTCUT_PATH="/usr/local/bin/vpsbox"

mkdir -p "$BACKUP_DIR"

if [ "$EUID" -ne 0 ]; then
    echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
    exit 1
fi

if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.1.1 $(hostname)" >> /etc/hosts
fi

# 注册全局快捷命令
if [[ "$(realpath "$0")" != "$SHORTCUT_PATH" ]]; then
    curl -sL https://raw.githubusercontent.com/8088892/VPSBox/main/vpsbox.sh -o "$SHORTCUT_PATH"
    chmod +x "$SHORTCUT_PATH"
fi

CPU_CORES=$(nproc)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(( (RAM_MB + 512) / 1024 ))
[ "$RAM_GB" -eq 0 ] && RAM_GB=1
HW_PROFILE="${CPU_CORES}C${RAM_GB}G"
CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)

# --- UI 与交互组件 (自适应排版核心) ---
get_term_width() {
    # 动态获取终端宽度，失败则默认 65
    local cols=$(tput cols 2>/dev/null || echo 65)
    # 限制最大宽度为 75，防止在电脑大屏上界面过于松散
    if [ "$cols" -gt 75 ]; then echo 75; else echo "$cols"; fi
}

print_divider() {
    local w=$(get_term_width)
    echo -e "${CYAN}$(printf "%0.s=" $(seq 1 $w))${NC}"
}

print_separator() {
    local w=$(get_term_width)
    echo -e "${CYAN}$(printf "%0.s-" $(seq 1 $w))${NC}"
}

pause_for_enter() {
    echo ""
    print_divider
    echo -ne "${YELLOW}▶ 操作已完成，请按 [回车键] 返回主菜单...${NC}"
    read -r
}

confirm_action() {
    local action_name=$1
    echo ""
    read -r -p "▶ 是否确认执行 [${action_name}]？(y/n, 默认 n): " confirm
    confirm="${confirm// /}" # iPad空格剔除
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "\n${YELLOW}已取消 [${action_name}] 操作。${NC}"
        return 1
    fi
    return 0
}

# 智能依赖检测：只在缺失时提示并安装
install_dependencies() {
    # 定义核心工具检测列表
    local apps=("curl" "wget" "jq" "openssl" "socat" "fuser" "unzip")
    local missing_apps=()

    # 循环检测哪些没安装
    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then
            missing_apps+=("$app")
        fi
    done

    # 只有发现缺失时，才显示提示并执行后台静默安装
    if [ ${#missing_apps[@]} -ne 0 ]; then
        echo -e "\n${CYAN}[系统] 检测到缺失必要底层组件，正在自动补全...${NC}"
        apt-get update -y > /dev/null 2>&1
        apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils > /dev/null 2>&1
    fi
}

# =========================================================
#                    【1】 系统基础管理模块
# =========================================================

system_update() {
    clear; print_divider; echo -e "       🔄 更新系统与安装必备组件    "; print_divider
    if ! confirm_action "更新系统与安装组件"; then pause_for_enter; return; fi
    
    echo -e "\n${CYAN}>>> 正在更新软件源并升级系统组件 (这可能需要几分钟)...${NC}"
    apt-get update -y && apt-get upgrade -y
    echo -e "\n${CYAN}>>> 正在安装必备工具包...${NC}"
    apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils
    echo -e "\n${GREEN}✅ 系统更新与组件安装完毕！${NC}"
    pause_for_enter
}

system_clean() {
    clear; print_divider; echo -e "       🧹 系统垃圾与废弃依赖清理    "; print_divider
    if ! confirm_action "清理系统垃圾与冗余日志"; then pause_for_enter; return; fi
    
    echo -e "\n${CYAN}>>> 正在卸载无用的旧依赖包...${NC}"
    apt-get autoremove -y
    echo -e "\n${CYAN}>>> 正在清理系统下载缓存...${NC}"
    apt-get clean -y
    echo -e "\n${CYAN}>>> 正在清理超过 7 个月的系统日志...${NC}"
    journalctl --vacuum-time=7d >/dev/null 2>&1
    echo -e "\n${GREEN}✅ 系统清理完毕，存储空间已释放！${NC}"
    pause_for_enter
}

change_root_password() {
    clear; print_divider; echo -e "       🔑 修改系统 root 密码    "; print_divider
    if ! confirm_action "修改 root 密码"; then pause_for_enter; return; fi
    
    echo -e "\n${YELLOW}提示：输入密码时屏幕不会显示字符，属于正常安全机制。${NC}\n"
    passwd root
    echo -e "\n${GREEN}✅ 密码修改操作结束（若无报错提示则已生效）。${NC}"
    pause_for_enter
}

setup_ssh_key() {
    clear; print_divider; echo -e "       🛡️ 配置 SSH 密钥免密登录    "; print_divider
    read -r -p "▶ 请粘贴您的公钥 (通常以 ssh-rsa 开头, 输入 0 取消): " pub_key
    pub_key="${pub_key// /}" # iPad空格剔除
    if [ "$pub_key" == "0" ] || [ -z "$pub_key" ]; then return; fi
    
    if ! confirm_action "导入此 SSH 公钥"; then pause_for_enter; return; fi

    mkdir -p ~/.ssh
    echo "$pub_key" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    echo -e "\n${GREEN}✅ 密钥已成功添加！请先测试使用密钥登录，再关闭密码登录功能。${NC}"
    pause_for_enter
}

change_ssh_port() {
    clear; print_divider; echo -e "       🚪 修改 SSH 默认登录端口    "; print_divider
    echo -e "${YELLOW}【防爆破】修改默认 22 端口可以有效抵御 90% 的脚本扫描。${NC}"
    read -r -p "▶ 请输入新的 SSH 端口号 (建议 10000-65535，输入 0 取消): " new_port
    new_port="${new_port// /}" # iPad空格剔除
    if [ "$new_port" == "0" ] || [ -z "$new_port" ]; then return; fi
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 1024 ] || [ "$new_port" -ge 65535 ]; then
        echo -e "${RED}[错误] 端口号必须在 1024 到 65535 之间！${NC}"
        pause_for_enter; return
    fi
    
    if ! confirm_action "将 SSH 端口修改为 $new_port"; then pause_for_enter; return; fi
    
    sed -i "s/^#\?Port .*/Port $new_port/g" /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "\n${GREEN}✅ SSH 端口已修改为 $new_port！${NC}"
    echo -e "${RED}⚠️ 警告: 请确保您的云服务商防火墙已放行 $new_port 端口，否则下次将无法连接！${NC}"
    pause_for_enter
}

change_hostname() {
    clear; print_divider; echo -e "       🏷️ 修改系统主机名 (Hostname)    "; print_divider
    echo -e "当前主机名: ${YELLOW}$(hostname)${NC}"
    read -r -p "▶ 请输入新的主机名 (仅限字母、数字和连字符, 输入 0 取消): " new_hostname
    new_hostname="${new_hostname// /}" # iPad空格剔除
    if [ "$new_hostname" == "0" ] || [ -z "$new_hostname" ]; then return; fi
    
    if ! confirm_action "将主机名修改为 $new_hostname"; then pause_for_enter; return; fi

    hostnamectl set-hostname "$new_hostname"
    sed -i "s/127.0.1.1.*/127.0.1.1 $new_hostname/g" /etc/hosts
    echo -e "\n${GREEN}✅ 主机名已修改为 $new_hostname！(重新连接 SSH 后即可看到变化)${NC}"
    pause_for_enter
}

set_china_timezone() {
    clear; print_divider; echo -e "       🕒 修改系统时区为 [北京时间] (Asia/Shanghai)    "; print_divider
    if ! confirm_action "修改系统时区为中国北京时间"; then pause_for_enter; return; fi
    
    timedatectl set-timezone Asia/Shanghai
    CURRENT_TZ="Asia/Shanghai"
    echo -e "\n${GREEN}✅ 系统时区已同步为中国北京时间。${NC}"
    pause_for_enter
}

manage_swap() {
    clear; print_divider; echo -e "       💾 虚拟内存 (Swap) 一键管理    "; print_divider
    echo -e "${YELLOW}【防宕机】小内存机器(<=1GB)开启 Swap 可有效防止内存溢出导致内核死机。${NC}"
    local swap_size=$(free -m | grep -i swap | awk '{print $2}')
    echo -e "当前 Swap 大小: ${GREEN}${swap_size} MB${NC}\n"
    
    echo -e "  ${GREEN}1.${NC} 创建/修改 Swap (推荐 1024MB 或 2048MB)"
    echo -e "  ${GREEN}2.${NC} 关闭并删除现有 Swap"
    echo -e "  ${GREEN}0.${NC} 取消返回"
    read -r -p "▶ 请选择操作 [0-2]: " swap_opt
    swap_opt="${swap_opt// /}" # iPad空格剔除
    
    case $swap_opt in
        1)
            read -r -p "▶ 请输入 Swap 大小 (单位 MB，例如 1024): " input_size
            input_size="${input_size// /}" # iPad空格剔除
            if [[ "$input_size" =~ ^[0-9]+$ ]]; then
                if ! confirm_action "设置 ${input_size}MB 的 Swap"; then pause_for_enter; return; fi
                echo -e "\n${CYAN}>>> 正在配置 ${input_size}MB Swap，请稍候...${NC}"
                swapoff -a
                rm -f /swapfile
                dd if=/dev/zero of=/swapfile bs=1M count=$input_size status=progress
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                if ! grep -q "/swapfile" /etc/fstab; then
                    echo "/swapfile none swap sw 0 0" >> /etc/fstab
                fi
                echo -e "${GREEN}✅ Swap 设置成功！${NC}"
            else
                echo -e "${RED}[错误] 输入无效。${NC}"
            fi
            ;;
        2)
            if ! confirm_action "关闭并删除现有 Swap"; then pause_for_enter; return; fi
            swapoff -a
            rm -f /swapfile
            sed -i '/\/swapfile/d' /etc/fstab
            echo -e "\n${GREEN}✅ Swap 已彻底关闭并清理！${NC}"
            ;;
    esac
    pause_for_enter
}

optimize_dns() {
    clear; print_divider; echo -e "       🌐 系统 DNS 极速优化    "; print_divider
    echo -e "${YELLOW}【防超时】将系统 DNS 切换为 Cloudflare 和 Google 公共节点，加快解析速度。${NC}"
    if ! confirm_action "将系统 DNS 替换为 1.1.1.1 和 8.8.8.8"; then pause_for_enter; return; fi
    
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    echo -e "\n${GREEN}✅ 系统 DNS 已优化成功！${NC}"
    pause_for_enter
}

# =========================================================
#                    【2】 网络调优与 BBR 模块
# =========================================================

get_bbr_status() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$cc" == "bbr" ]]; then
        if uname -r | grep -qi "xanmod"; then echo -e "${PURPLE}BBRv3 (基于 Google 官方源码)${NC}"
        else echo -e "${GREEN}BBRv1 (Linux 系统原生)${NC}"; fi
    else echo -e "${RED}未开启 (当前为 $cc)${NC}"; fi
}

manage_bbr() {
    while true; do
        clear; print_divider; echo -e "${PURPLE}                  🚀 BBR 拥塞控制智能管理中心${NC}"; print_divider
        echo -e "  📊 当前内核版本 : ${YELLOW}$(uname -r)${NC}"
        echo -e "  ⚡ 当前 BBR 状态: $(get_bbr_status)"
        echo -e "  💡 说明: 使用业内最稳定的 XanMod 内核为您无缝安装纯正的 Google BBRv3。"
        print_separator
        echo -e "  ${GREEN}1.${NC} 开启 BBRv1 (极速秒开 / 适合所有系统)"
        echo -e "  ${GREEN}2.${NC} 安装 BBRv3 (合入谷歌最新 V3 分支 / 延迟更低更激进)"
        echo -e "  ${GREEN}3.${NC} 卸载 BBRv3 (安全回退至系统原生默认内核)"
        print_separator; echo -e "  ${GREEN}0.${NC} 返回主菜单"; print_divider; echo ""
        
        read -r -p "▶ 请输入编号 [0-3]: " bbr_opt
        bbr_opt="${bbr_opt// /}" # iPad空格剔除
        case $bbr_opt in
            1)
                if ! confirm_action "立即开启系统原生 BBRv1"; then continue; fi
                echo -e "\n${CYAN}[正在配置] 启用系统原生 BBRv1...${NC}"
                modprobe tcp_bbr > /dev/null 2>&1
                echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
                cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                sysctl -p /etc/sysctl.d/99-bbr.conf > /dev/null 2>&1
                echo -e "${GREEN}✅ BBRv1 已成功开启！${NC}"; sleep 2
                ;;
            2)
                if ! command -v apt &> /dev/null; then echo -e "\n${RED}[错误] BBRv3 安装仅支持 Debian/Ubuntu。${NC}"; sleep 2; continue; fi
                if ! confirm_action "安装 BBRv3 内核 (完成后将重启服务器)"; then continue; fi
                echo -e "\n${CYAN}>>> 正在下载并部署 XanMod 核心...${NC}"
                apt update -y > /dev/null 2>&1
                wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
                echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-release.list
                apt update -y > /dev/null 2>&1
                apt install -y linux-xanmod-lts
                cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                update-grub
                echo -e "\n${GREEN}🎉 BBRv3 核心部署完毕！即将重启服务器生效...${NC}"
                sleep 3; reboot
                ;;
            3)
                if ! confirm_action "卸载 BBRv3 (完成后将重启服务器)"; then continue; fi
                echo -e "\n${CYAN}>>> 正在清理内核文件...${NC}"
                apt purge -y "^linux-image.*xanmod.*" "^linux-headers.*xanmod.*"
                rm -f /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg
                apt update -y > /dev/null 2>&1; update-grub
                echo -e "\n${GREEN}✅ 卸载成功！即将重启服务器回退至系统原生内核...${NC}"
                sleep 3; reboot
                ;;
            0) break ;;
            *) echo -e "\n${RED}[提示] 编号错误！${NC}"; sleep 1 ;;
        esac
    done
}

apply_tuning() {
    local PROFILE=$1; local TCP_RMEM=$2; local TCP_WMEM=$3
    clear; print_divider; echo -e "       ⚙️ TCP 自动调优注入    "; print_divider
    if ! confirm_action "注入 TCP 底层调优参数"; then pause_for_enter; return; fi
    
    read -r -p "▶ 是否在调优前备份当前参数？(y/n, 默认 y): " NEED_BACKUP
    NEED_BACKUP="${NEED_BACKUP// /}" # iPad空格剔除
    [[ -z "$NEED_BACKUP" || "$NEED_BACKUP" =~ ^[yY]$ ]] && backup_config_silently
    
    cat > "$CUSTOM_CONF" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl -p "$CUSTOM_CONF" > /dev/null 2>&1
    echo -e "\n${GREEN}✅ 网络调优注入成功！底层并发吞吐已优化。${NC}"
    pause_for_enter
}

backup_config_silently() {
    local ts=$(date +"%Y%m%d_%H%M%S")
    sysctl -a --pattern net.ipv4.tcp | grep -E "rmem|wmem|congestion|sack" > "${BACKUP_DIR}/backup_${ts}.conf" 2>/dev/null
    echo -e "${GREEN}✅ 参数已自动备份。${NC}"
}

manage_backup() {
    clear; print_divider; echo -e "       📦 网络调优参数备份与还原管理    "; print_divider
    echo -e "  ${GREEN}1.${NC} 立即备份当前参数"
    echo -e "  ${GREEN}2.${NC} 还原历史备份"
    echo -e "  ${GREEN}3.${NC} 删除历史备份"
    echo -e "  ${GREEN}0.${NC} 返回主菜单"
    echo ""
    read -r -p "▶ 请选择操作 [0-3]: " b_opt
    b_opt="${b_opt// /}" # iPad空格剔除
    case $b_opt in
        1)
            if ! confirm_action "备份当前网络参数"; then return; fi
            local ts=$(date +"%Y%m%d_%H%M%S")
            sysctl -a --pattern net.ipv4.tcp | grep -E "rmem|wmem|congestion|sack" > "${BACKUP_DIR}/backup_${ts}.conf" 2>/dev/null
            echo -e "\n${GREEN}✅ TCP 参数备份成功！${NC}"
            pause_for_enter
            ;;
        2)
            shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
            if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${RED}无备份记录。${NC}"; pause_for_enter; return; fi
            echo -e "\n${CYAN}请选择要恢复的时间点：${NC}"
            for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
            read -r -p "▶ 请输入编号 (0取消): " res_opt
            res_opt="${res_opt// /}" # iPad空格剔除
            if [[ "$res_opt" =~ ^[0-9]+$ ]] && [ "$res_opt" -ge 1 ] && [ "$res_opt" -le "${#backups[@]}" ]; then
                if ! confirm_action "覆盖当前配置并还原至此备份"; then return; fi
                sysctl -p "${backups[$((res_opt-1))]}" > /dev/null 2>&1
                rm -f "$CUSTOM_CONF"; echo -e "\n${GREEN}✅ 参数已成功还原！${NC}"
            fi
            pause_for_enter
            ;;
        3)
            shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
            if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${YELLOW}备份目录为空。${NC}"; pause_for_enter; return; fi
            echo -e "\n${CYAN}请选择要删除的备份：${NC}"
            for i in "${!backups[@]}"; do echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
            echo -e "  ${RED}99.${NC} 清空所有"
            read -r -p "▶ 请输入编号 (0取消): " del_opt
            del_opt="${del_opt// /}" # iPad空格剔除
            if [[ "$del_opt" =~ ^[0-9]+$ ]] && [ "$del_opt" -ge 1 ] && [ "$del_opt" -le "${#backups[@]}" ]; then
                if ! confirm_action "永久删除此备份"; then return; fi
                rm -f "${backups[$((del_opt-1))]}"; echo -e "\n${GREEN}✅ 记录已删除。${NC}"
            elif [ "$del_opt" -eq 99 ]; then
                if ! confirm_action "永久清空所有备份"; then return; fi
                rm -f "${BACKUP_DIR}"/backup_*.conf; echo -e "\n${GREEN}✅ 已清空所有备份。${NC}"
            fi
            pause_for_enter
            ;;
    esac
}

# =========================================================
#             【3】 流媒体检测与节点管理模块
# =========================================================

check_media_unlock() {
    clear; print_divider; echo -e "       📺 ip质量检测与流媒体解锁    "; print_divider
    echo -e "${CYAN}>>> 正在载入权威检测引擎，请稍候...${NC}\n"
    
    bash <(curl -sL https://Check.Place) -I
    
    pause_for_enter
}

view_deployed_nodes() {
    clear; print_divider; echo -e "       📋 查看当前已部署节点状态    "; print_divider
    install_dependencies
    
    echo -e "${CYAN}--- Xray 内核节点 ---${NC}"
    if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
        # 修复 Hysteria 的 UDP 显示
        jq -r '.inbounds[] | "端口: \(.port) | 主协议: \(.protocol) | 网络/伪装: \(if .protocol == "hysteria" then "udp" else (.streamSettings.network // "tcp") end) | 安全/加密: \(.streamSettings.security // "none")"' /usr/local/etc/xray/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
    else
        echo -e "${YELLOW}未检测到 Xray 节点配置。${NC}"
    fi
    
    echo -e "\n${CYAN}--- Sing-box 内核节点 ---${NC}"
    if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
        # 修复 Hysteria2 的 UDP 显示
        jq -r '.inbounds[] | "端口: \(.listen_port) | 主协议: \(.type) | 网络/伪装: \(if .type == "hysteria2" then "udp" else (.transport.type // "tcp") end) | 安全/加密: \(if .tls.reality.enabled then "reality" elif .tls.enabled then "tls" else "none" end)"' /etc/sing-box/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
    else
        echo -e "${YELLOW}未检测到 Sing-box 节点配置。${NC}"
    fi
    pause_for_enter
}

delete_node() {
    clear; print_divider; echo -e "       🗑️ 删除指定的已部署节点    "; print_divider
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
    
    if [ "$nodes_found" -eq 0 ]; then
        echo -e "${YELLOW}未检测到任何已部署的节点，无需删除。${NC}"
        pause_for_enter
        return
    fi

    echo ""
    read -r -p "▶ 请输入要删除的节点【端口号】 (输入 0 取消): " del_port
    del_port="${del_port// /}" # iPad空格剔除
    if [ "$del_port" == "0" ] || [ -z "$del_port" ]; then return; fi
    
    if ! [[ "$del_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[错误] 端口号必须是纯数字！${NC}"
        pause_for_enter; return
    fi

    if ! confirm_action "永久删除端口为 $del_port 的节点"; then pause_for_enter; return; fi
    
    local deleted=0
    
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        if jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.port == $del_port))" /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
            mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json
            systemctl restart xray
            echo -e "${GREEN}✅ 已成功移除 Xray 中占用端口 $del_port 的节点配置！${NC}"
            deleted=1
        fi
    fi
    
    if [ -f "/etc/sing-box/config.json" ]; then
        if jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.listen_port == $del_port))" /etc/sing-box/config.json > /tmp/sb_tmp.json
            mv /tmp/sb_tmp.json /etc/sing-box/config.json
            systemctl restart sing-box
            echo -e "${GREEN}✅ 已成功移除 Sing-box 中占用端口 $del_port 的节点配置！${NC}"
            deleted=1
        fi
    fi
    
    if [ "$deleted" -eq 0 ]; then
        echo -e "${RED}[错误] 当前配置文件中未找到端口为 $del_port 的节点。${NC}"
    fi
    
    pause_for_enter
}

# --- 节点部署核心引擎 ---
append_inbound() {
    local CONFIG_FILE=$1
    local NEW_INBOUND=$2
    local TARGET_PORT=$3
    local CORE_NAME=$4
    
    if [ -f "$CONFIG_FILE" ] && grep -q "inbounds" "$CONFIG_FILE"; then
        echo -e "${YELLOW}[系统] 检测到已有配置，执行安全追加...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then
            jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.listen_port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > /tmp/v2_tmp.json
        else
            jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > /tmp/v2_tmp.json
        fi
        mv /tmp/v2_tmp.json "$CONFIG_FILE"
    else
        echo -e "${YELLOW}[系统] 首次部署，正在初始化配置文件...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then
            cat > "$CONFIG_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"type":"direct"}]}
EOF
        else
            cat > "$CONFIG_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"protocol":"freedom"}]}
EOF
        fi
    fi
}

install_reality_node() {
    clear; print_divider; echo -e "       🌍 部署 VLESS-Reality (直连低延迟 / 强力防封锁)    "; print_divider
    echo -e "\n${YELLOW}【提醒】此模式抗封锁能力极强，但必须使用本机真实 IP 直连。${NC}\n"
    read -r -p "▶ 请输入监听端口 (默认 50000, 0 取消): " PORT
    PORT="${PORT// /}" # iPad空格剔除
    if [ "$PORT" == "0" ]; then return; fi; [ -z "$PORT" ] && PORT=50000
    
    echo -e "\n  ${GREEN}1.${NC} Xray-core (经典稳定)\n  ${GREEN}2.${NC} Sing-box (轻量极速)"
    read -r -p "▶ 选择运行内核 [1-2, 默认 1, 0 取消]: " core_choice
    core_choice="${core_choice// /}" # iPad空格剔除
    if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
    
    echo -e "\n  ${GREEN}1.${NC} gateway.icloud.com (苹果官网)\n  ${GREEN}2.${NC} www.microsoft.com (微软官网)"
    read -r -p "▶ 选择伪装 SNI [1-2, 默认 1, 0 取消]: " sni_choice
    sni_choice="${sni_choice// /}" # iPad空格剔除
    if [ "$sni_choice" == "0" ]; then return; fi; [ "$sni_choice" == "2" ] && SNI_DOMAIN="www.microsoft.com" || SNI_DOMAIN="gateway.icloud.com"
    
    if ! confirm_action "开始部署 Reality 节点"; then pause_for_enter; return; fi
    install_dependencies
    
    UUID=$(cat /proc/sys/kernel/random/uuid); SHORT_ID=$(openssl rand -hex 8)
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
        hash -r; X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); KEYS=$("$X_BIN" x25519)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"port":'$PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"'$SNI_DOMAIN':443","serverNames":["'$SNI_DOMAIN'"],"privateKey":"'$PRI'","shortIds":["'$SHORT_ID'"]}}}'
        append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$PORT" "Xray"
        systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray)
    else
        CORE_NAME="Sing-box"
        bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1
        hash -r; SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); KEYS=$("$SB_BIN" generate reality-keypair)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$PORT',"users":[{"uuid":"'$UUID'","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"'$SNI_DOMAIN'","reality":{"enabled":true,"handshake":{"server":"'$SNI_DOMAIN'","server_port":443},"private_key":"'$PRI'","short_id":["'$SHORT_ID'"]}}}'
        append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$PORT" "Sing-box"
        systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box)
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 VLESS-Reality 节点成功部署于 ${CORE_NAME}！${NC}"
        echo -e "${CYAN}vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp#${CORE_NAME}-Reality${NC}\n"
    else
        echo -e "\n${RED}[错误] 启动失败，请检查端口冲突。${NC}"
    fi
    pause_for_enter
}

install_ws_tls_node() {
    clear; print_divider; echo -e "       ☁️ 部署 VLESS-WS-TLS (套 CDN 优选 IP / 拯救被墙机器)    "; print_divider
    echo -e "\n${YELLOW}【提醒】此模式完美支持 Cloudflare，适合隐藏 IP 或复活机器。${NC}\n"
    read -r -p "▶ 请输入域名 (直接回车或输入 0 取消): " DOMAIN
    DOMAIN="${DOMAIN// /}" # iPad空格剔除
    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "0" ]; then return; fi
    DOMAIN_IP=$(ping -c 1 "$DOMAIN" 2>/dev/null | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -1)
    
    if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
        echo -e "${RED}[错误] 域名解析 IP ($DOMAIN_IP) 与本机 IP ($SERVER_IP) 不符！${NC}"
        pause_for_enter; return
    fi
    
    read -r -p "▶ 监听端口 (默认 443, 0 取消): " WS_PORT
    WS_PORT="${WS_PORT// /}" # iPad空格剔除
    if [ "$WS_PORT" == "0" ]; then return; fi; [ -z "$WS_PORT" ] && WS_PORT=443
    
    echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
    read -r -p "▶ 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
    core_choice="${core_choice// /}" # iPad空格剔除
    if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
    
    if ! confirm_action "开始部署 WS+TLS 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN" --server letsencrypt >/dev/null 2>&1
    fuser -k 80/tcp > /dev/null 2>&1
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --server letsencrypt >/dev/null 2>&1
    
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem
    chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    
    UUID=$(cat /proc/sys/kernel/random/uuid); WSPATH="/$(openssl rand -hex 4)"
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        NEW_INBOUND='{"port":'$WS_PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"wsSettings":{"path":"'$WSPATH'"}}}'
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
        append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$WS_PORT" "Xray"
        systemctl restart xray; SERVICE_STATUS=$(systemctl is-active xray)
    else
        CORE_NAME="Sing-box"
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$WS_PORT',"users":[{"uuid":"'$UUID'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"},"transport":{"type":"ws","path":"'$WSPATH'"}}'
        bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1
        append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$WS_PORT" "Sing-box"
        systemctl restart sing-box; SERVICE_STATUS=$(systemctl is-active sing-box)
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 VLESS-WS-TLS 节点成功部署于 ${CORE_NAME}！${NC}"
        echo -e "${CYAN}vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WSPATH}#${CORE_NAME}-WS-TLS${NC}\n"
    else
        echo -e "\n${RED}[错误] 启动失败，请检查端口冲突。${NC}"
    fi
    pause_for_enter
}

install_hy2_node() {
    clear; print_divider; echo -e "       ⚡ 部署 Hysteria2 (暴力 UDP 发包 / 抢占高带宽)    "; print_divider
    read -r -p "▶ 请输入域名 (直接回车或输入 0 取消): " DOMAIN
    DOMAIN="${DOMAIN// /}" # iPad空格剔除
    if [ -z "$DOMAIN" ] || [ "$DOMAIN" == "0" ]; then return; fi
    DOMAIN_IP=$(ping -c 1 "$DOMAIN" 2>/dev/null | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -1)
    
    if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
        echo -e "${RED}[错误] 域名解析错误！${NC}"
        pause_for_enter; return
    fi
    
    read -r -p "▶ 监听端口 (默认 8443, 0 取消): " HY2_PORT
    HY2_PORT="${HY2_PORT// /}" # iPad空格剔除
    if [ "$HY2_PORT" == "0" ]; then return; fi; [ -z "$HY2_PORT" ] && HY2_PORT=8443
    
    echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
    read -r -p "▶ 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
    core_choice="${core_choice// /}" # iPad空格剔除
    if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
    
    if ! confirm_action "开始部署 Hysteria2 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh >/dev/null 2>&1
    fuser -k 80/tcp > /dev/null 2>&1
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --server letsencrypt >/dev/null 2>&1
    
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem
    chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    
    HY2_PASS=$(openssl rand -hex 8)
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        NEW_INBOUND='{"port":'$HY2_PORT',"protocol":"hysteria","settings":{"clients":[{"auth":"'$HY2_PASS'"}]},"streamSettings":{"network":"hysteria","security":"tls","hysteriaSettings":{"version":2,"congestion":{"ignoreClientBandwidth":false}},"tlsSettings":{"serverName":"'$DOMAIN'","alpn":["h3"],"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]}}}'
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
        append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$HY2_PORT" "Xray"
        systemctl restart xray; SERVICE_STATUS=$(systemctl is-active xray)
    else
        CORE_NAME="Sing-box"
        NEW_INBOUND='{"type":"hysteria2","listen":"::","listen_port":'$HY2_PORT',"users":[{"password":"'$HY2_PASS'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
        bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1
        append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$HY2_PORT" "Sing-box"
        systemctl restart sing-box; SERVICE_STATUS=$(systemctl is-active sing-box)
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 Hysteria2 节点成功部署于 ${CORE_NAME}！${NC}"
        echo -e "${CYAN}hy2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}&insecure=0#${CORE_NAME}-Hys2${NC}\n"
    else
        echo -e "\n${RED}[错误] 启动失败，请检查端口冲突。${NC}"
    fi
    pause_for_enter
}

# =========================================================
#             【4】 新增功能模块 (WARP 与 UFW)
# =========================================================

install_warp() {
    clear; print_divider; echo -e "       ☁️ Cloudflare WARP 一键解锁    "; print_divider
    echo -e "${YELLOW}【用途】为 VPS 获取 Cloudflare 干净 IP，解锁流媒体及规避验证码。${NC}"
    if ! confirm_action "部署 Cloudflare WARP"; then pause_for_enter; return; fi
    
    echo -e "\n${CYAN}>>> 正在启动 WARP 脚本...${NC}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
    pause_for_enter
}

manage_ufw() {
    while true; do
        clear; print_divider; echo -e "       🛡️ UFW 防火墙端口管理    "; print_divider
        
        if ! command -v ufw &> /dev/null; then
            echo -e "${YELLOW}[系统] 正在自动安装 UFW 防火墙...${NC}"
            apt-get update -y > /dev/null 2>&1
            apt-get install ufw -y > /dev/null 2>&1
        fi
        
        echo -e "  ${GREEN}1.${NC} 查看当前防火墙状态与已放行端口"
        echo -e "  ${GREEN}2.${NC} 放行指定新端口 (TCP/UDP)"
        echo -e "  ${GREEN}3.${NC} 删除某个端口规则"
        echo -e "  ${GREEN}4.${NC} 开启防火墙 (系统会自动防呆，强制放行 22 SSH端口)"
        echo -e "  ${GREEN}5.${NC} 彻底关闭防火墙"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        print_separator
        echo ""
        read -r -p "▶ 请选择操作 [0-5]: " ufw_opt
        ufw_opt="${ufw_opt// /}"
        
        case $ufw_opt in
            1) 
                echo -e "\n${CYAN}>>> 防火墙状态：${NC}"
                ufw status numbered
                pause_for_enter
                ;;
            2)
                read -r -p "▶ 请输入要放行的端口号 (如 80, 443, 8443): " port
                port="${port// /}"
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    ufw allow "$port"
                    echo -e "${GREEN}✅ 端口 $port 已成功添加放行规则！${NC}"
                    ufw reload > /dev/null 2>&1
                else
                    echo -e "${RED}[错误] 端口号输入无效！${NC}"
                fi
                pause_for_enter
                ;;
            3)
                echo -e "\n${CYAN}>>> 当前规则列表：${NC}"
                ufw status numbered
                echo ""
                read -r -p "▶ 请输入要删除的【规则编号】(最左侧括号内的数字): " rule_num
                rule_num="${rule_num// /}"
                if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
                    ufw --force delete "$rule_num"
                    echo -e "${GREEN}✅ 规则 $rule_num 已删除！${NC}"
                fi
                pause_for_enter
                ;;
            4)
                if ! confirm_action "开启防火墙并强制放行 22 端口"; then continue; fi
                echo -e "\n${YELLOW}为防止你与服务器失联，正在强制放行 22 端口...${NC}"
                ufw allow 22/tcp
                ufw --force enable
                echo -e "${GREEN}✅ 防火墙已成功开启！${NC}"
                pause_for_enter
                ;;
            5)
                if ! confirm_action "彻底关闭防火墙"; then continue; fi
                ufw disable
                echo -e "${GREEN}✅ 防火墙已完全关闭！${NC}"
                pause_for_enter
                ;;
            0) break ;;
            *) echo -e "\n${RED}输入无效！${NC}"; sleep 1 ;;
        esac
    done
}

# =========================================================
#                       卸载模块
# =========================================================

uninstall_vpsbox() {
    print_separator
    echo -e "${YELLOW}【警告】此操作将彻底删除 VPSBox 的快捷命令及本地备份目录。${NC}"
    if ! confirm_action "彻底卸载 VPSBox"; then return; fi
    
    rm -f /usr/local/bin/vpsbox
    rm -rf /etc/vpsbox_backups
    echo -e "\n${GREEN}[成功] VPSBox 已彻底卸载！系统已无任何残留，期待与您下次相遇！${NC}"
    exit 0
}

# =========================================================
#                       主界面循环
# =========================================================

while true; do
    clear
    echo ""
    print_divider
    echo -e "${PURPLE}           🌟 VPS Box 全能服务器管家与部署工具箱 v1.8.2 🌟${NC}"
    print_divider
    
    # 顶部基础信息 (无图标)
    echo -e "  公网 IP  : ${YELLOW}${SERVER_IP}${NC}"
    echo -e "  硬件规格 : ${YELLOW}${HW_PROFILE}${NC}"
    echo -e "  系统时区 : ${YELLOW}${CURRENT_TZ}${NC}"
    echo -e "  ⚡ BBR 状态 : $(get_bbr_status)"
    print_separator
    
    echo -e "  ${CYAN}【基础系统管理与安全防护】${NC}"
    echo -e "  ${GREEN}1.${NC} 更新系统并安装必备组件        ${GREEN}2.${NC} 系统垃圾与废弃依赖清理"
    echo -e "  ${GREEN}3.${NC} 修改系统 root 密码            ${GREEN}4.${NC} 配置 SSH 密钥免密登录"
    echo -e "  ${GREEN}5.${NC} 修改系统主机名 (Hostname)     ${GREEN}6.${NC} 修改时区为 [北京时间]"
    echo -e "  ${GREEN}7.${NC} 虚拟内存 (Swap) 一键管理      ${GREEN}8.${NC} 系统 DNS 极速优化"
    echo -e "  ${GREEN}9.${NC} 修改 SSH 默认登录端口"
    
    echo -e "\n  ${CYAN}【网络协议与性能极速优化】${NC}"
    echo -e "  ${GREEN}10.${NC} TCP自动调优 (含 BBR+FQ+SACK)  ${YELLOW}(提升底层并发与吞吐)${NC}"
    echo -e "  ${GREEN}11.${NC} 网络调优参数备份/还原管理\n  ${GREEN}12.${NC} BBR 拥塞控制智能管理中心      ${YELLOW}[支持 Google BBRv3]${NC}"
    
    echo -e "\n  ${CYAN}【流媒体检测与节点防冲突部署】${NC}"
    echo -e "  ${GREEN}13.${NC} ip质量检测与流媒体解锁"
    echo -e "  ${GREEN}14.${NC} 部署 VLESS-Reality            ${YELLOW}(直连低延迟 / 强力防封锁)${NC}"
    echo -e "  ${GREEN}15.${NC} 部署 VLESS-WS-TLS             ${YELLOW}(套 CDN 优选 IP / 拯救被墙机器)${NC}"
    echo -e "  ${GREEN}16.${NC} 部署 Hysteria2                ${YELLOW}(UDP 暴力发包 / 抢占高带宽)${NC}"
    echo -e "  ${GREEN}17.${NC} 查看当前已部署的节点状态      ${GREEN}18.${NC} 删除指定的已部署节点"
    
    echo -e "\n  ${CYAN}【附加实用工具与安全拓展】${NC}"
    echo -e "  ${GREEN}19.${NC} Cloudflare WARP 一键解锁      ${YELLOW}(获取干净 IP / 规避验证码)${NC}"
    echo -e "  ${GREEN}20.${NC} UFW 防火墙简单端口管理        ${YELLOW}(防呆管理 / 一键放行端口)${NC}"
    echo -e "  ${RED}99.${NC} 彻底卸载 VPSBox 及系统残留"

    print_separator
    echo -e "  ${GREEN}0.${NC} 安全退出"
    print_divider
    echo ""
    read -r -p "▶ 请输入选择 [0-20, 99]: " OPTION
    OPTION="${OPTION// /}" # iPad空格剔除
    
    case $OPTION in
        1) system_update ;;
        2) system_clean ;;
        3) change_root_password ;;
        4) setup_ssh_key ;;
        5) change_hostname ;;
        6) set_china_timezone ;;
        7) manage_swap ;;
        8) optimize_dns ;;
        9) change_ssh_port ;;
        10) if [ "$RAM_GB" -le 1 ]; then apply_tuning "$HW_PROFILE" "4096 87380 16777216" "4096 16384 16777216"; elif [ "$RAM_GB" -le 2 ]; then apply_tuning "$HW_PROFILE" "8192 131072 67108864" "4096 16384 67108864"; else apply_tuning "高配" "8192 262144 1073741824" "4096 16384 1073741824"; fi ;;
        11) manage_backup ;;
        12) manage_bbr ;;
        13) check_media_unlock ;;
        14) install_reality_node ;;
        15) install_ws_tls_node ;;
        16) install_hy2_node ;;
        17) view_deployed_nodes ;;
        18) delete_node ;;
        19) install_warp ;;
        20) manage_ufw ;;
        99) uninstall_vpsbox ;;
        0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
    esac
done
