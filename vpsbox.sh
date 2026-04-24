#!/bin/bash

# =====================================================================
# 项目名称: VPS Box (全能服务器优化与多节点部署工具箱)
# 核心特性: 全局防冲突部署、智能复用证书、双内核自适应、系统管家
# 版本: v2.5.0 (长效稳定版：修复证书续签失联、IPv6双栈、底层环境健壮性)
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
NODE_RECORD_FILE="/etc/vpsbox_nodes.txt"
INSTALL_LOG="/tmp/vpsbox_install.log"

mkdir -p "$BACKUP_DIR"

if [ "$EUID" -ne 0 ]; then
    echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
    exit 1
fi

# 系统兼容性拦截
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        echo -e "\n${RED}[错误] VPSBox 当前仅支持 Debian 或 Ubuntu 系统！您的系统是 $ID，强行运行可能导致系统损坏。${NC}\n"
        exit 1
    fi
else
    echo -e "\n${RED}[错误] 无法识别的操作系统！${NC}\n"
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

# 修复：完美兼容 IPv4 / IPv6 双栈机器
SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
IP_FORMAT="v4"
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s6 ifconfig.me || curl -s6 ip.sb)
    IP_FORMAT="v6"
fi

# --- UI 与交互组件 (自适应排版核心) ---
get_term_width() {
    local cols=$(tput cols 2>/dev/null || echo 65)
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
    confirm="${confirm// /}"
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "\n${YELLOW}已取消 [${action_name}] 操作。${NC}"
        return 1
    fi
    return 0
}

# 智能依赖检测
install_dependencies() {
    local apps=("curl" "wget" "jq" "openssl" "socat" "fuser" "unzip" "qrencode")
    local missing_apps=()

    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then
            missing_apps+=("$app")
        fi
    done

    if [ ${#missing_apps[@]} -ne 0 ]; then
        echo -e "\n${CYAN}[系统] 检测到缺失必要底层组件，正在自动补全...${NC}"
        apt-get update -y > "$INSTALL_LOG" 2>&1
        apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils qrencode >> "$INSTALL_LOG" 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}[警告] 某些组件安装可能存在异常，请查看 $INSTALL_LOG 排查原因。${NC}"
        fi
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
    apt-get install -y curl wget sudo unzip tar openssl socat psmisc iputils-ping jq gnupg2 dnsutils bsdutils qrencode
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
    
    while true; do
        passwd root
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}✅ 密码已成功修改！${NC}"
            break
        else
            echo -e "\n${RED}[错误] 密码修改失败！(可能是两次输入不一致，或者密码为空/仅包含空格)${NC}"
            read -r -p "▶ 是否继续尝试修改密码？(y/n, 默认 y): " retry_pwd
            retry_pwd="${retry_pwd// /}"
            if [[ "$retry_pwd" =~ ^[nN]$ ]]; then
                echo -e "\n${YELLOW}已退出密码修改。${NC}"
                break
            fi
            echo -e "\n${CYAN}>>> 请重新设置密码：${NC}"
        fi
    done
    pause_for_enter
}

setup_ssh_key() {
    clear; print_divider; echo -e "       🛡️ 配置 SSH 密钥免密登录    "; print_divider
    
    while true; do
        read -r -p "▶ 请粘贴您的公钥 (通常以 ssh-rsa 开头, 输入 0 取消): " pub_key
        if [ "$pub_key" == "0" ]; then return; fi
        if [ -z "$pub_key" ]; then 
            echo -e "${RED}[错误] 密钥内容不能为空，请重新输入！${NC}"
            continue
        fi
        break
    done
    
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
    
    while true; do
        read -r -p "▶ 请输入新的 SSH 端口号 (建议 10000-65535，输入 0 取消): " new_port
        new_port="${new_port// /}"
        if [ "$new_port" == "0" ] || [ -z "$new_port" ]; then return; fi
        
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 1024 ] || [ "$new_port" -ge 65535 ]; then
            echo -e "${RED}[错误] 端口号必须在 1024 到 65535 之间！请重新输入。${NC}"
            continue
        fi
        break
    done
    
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
    
    while true; do
        read -r -p "▶ 请输入新的主机名 (仅限字母、数字和连字符, 输入 0 取消): " new_hostname
        new_hostname="${new_hostname// /}"
        if [ "$new_hostname" == "0" ]; then return; fi
        if [ -z "$new_hostname" ]; then
            echo -e "${RED}[错误] 主机名不能为空，请重新输入！${NC}"
            continue
        fi
        if ! [[ "$new_hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then
            echo -e "${RED}[错误] 格式不正确！仅限输入字母、数字和连字符(-)。${NC}"
            continue
        fi
        break
    done
    
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
    
    while true; do
        echo -e "  ${GREEN}1.${NC} 创建/修改 Swap (推荐 1024MB 或 2048MB)"
        echo -e "  ${GREEN}2.${NC} 关闭并删除现有 Swap"
        echo -e "  ${GREEN}0.${NC} 取消返回"
        read -r -p "▶ 请选择操作 [0-2]: " swap_opt
        swap_opt="${swap_opt// /}"
        
        case $swap_opt in
            1)
               while true; do
                    read -r -p "▶ 请输入 Swap 大小 (单位 MB，例如 1024): " input_size
                    input_size="${input_size// /}"
                    if [[ "$input_size" =~ ^[0-9]+$ ]]; then
                        break
                    else
                        echo -e "${RED}[错误] 输入无效，请输入纯数字。${NC}"
                    fi
               done
                if ! confirm_action "设置 ${input_size}MB 的 Swap"; then return; fi
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
                return
                ;;
            2)
                if ! confirm_action "关闭并删除现有 Swap"; then return; fi
                swapoff -a
                rm -f /swapfile
                sed -i '/\/swapfile/d' /etc/fstab
                echo -e "\n${GREEN}✅ Swap 已彻底关闭并清理！${NC}"
                return
                ;;
            0) return ;;
            *) echo -e "\n${RED}[错误] 输入无效！请输入 0、1 或 2 进行选择。${NC}\n" ;;
        esac
    done
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
    # 修复：加上不可变锁，防止重启后被 systemd-resolved 覆盖
    chattr +i /etc/resolv.conf
    echo -e "\n${GREEN}✅ 系统 DNS 已优化成功，并已锁定防止系统篡改！${NC}"
    pause_for_enter
}

# =========================================================
#                    【2】 网络调优与 BBR 模块
# =========================================================

get_bbr_status() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$cc" == "bbr" ]]; then
        if uname -r | grep -qi "xanmod"; then 
            echo -e "${YELLOW}BBRv3 (基于 Google 官方源码)${NC}"
        else 
            echo -e "${GREEN}BBRv1 (Linux 系统原生)${NC}"
        fi
    else 
        echo -e "${RED}未开启 (当前为 $cc)${NC}"
    fi
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
        bbr_opt="${bbr_opt// /}"
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
                if ! confirm_action "安装 BBRv3 内核"; then continue; fi
                echo -e "\n${CYAN}>>> 正在下载 XanMod 官方密钥 (增强防拦截模式)...${NC}"
                
                # 使用 curl 绕过 CDN 拦截并强制覆盖现有密钥，解决 gpg 数据无效报错
                curl -fSsL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg 
                
                # 严格检查密钥文件是否下载成功（文件大小不为0）
                if [ ! -s /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then
                    echo -e "\n${RED}[错误] 密钥下载失败！文件为空，可能是 CDN 暂时拦截，请重试。${NC}"
                    rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
                    sleep 3; continue
                fi

                echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-release.list
                
                echo -e "\n${CYAN}>>> 正在更新软件源...${NC}"
                apt update -y
        
                echo -e "\n${CYAN}>>> 正在安装 XanMod BBRv3 内核 (x64v3 标准版)...${NC}"
                apt install -y linux-xanmod-x64v3
                
                # 加入安装状态码拦截，只有成功安装内核后才写入 BBR 配置
                if [ $? -eq 0 ]; then
                    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                    update-grub
                    echo -e "\n${GREEN}🎉 BBRv3 核心部署完毕！需要重启后生效。${NC}"
                    
                    # 拦截强制重启，将决定权交给用户
                    read -r -p "▶ 是否立即重启服务器？(y/n, 默认 n): " do_reboot
                    if [[ "${do_reboot// /}" =~ ^[yY]$ ]]; then
                        echo -e "${YELLOW}正在重启服务器...${NC}"
                        sleep 2; reboot
                    else
                        echo -e "${YELLOW}请记得稍后手动执行 reboot 命令使新内核生效。${NC}"
                        sleep 2
                    fi
                else
                    echo -e "\n${RED}[错误] 内核安装失败！请查看上方 apt 的具体报错。${NC}"
                    sleep 3
                fi
                ;;
            3)
                if ! confirm_action "卸载 BBRv3 (完成后将重启服务器)"; then continue; fi
                if ! dpkg -l | grep -qE "linux-image-(generic|amd64)"; then
                    echo -e "\n${YELLOW}>>> [安全拦截] 未检测到系统原生备用内核，正在自动安装...${NC}"
                    if grep -qi ubuntu /etc/os-release; then
                        apt install -y linux-image-generic
                    else
                        apt install -y linux-image-amd64
                    fi
                fi
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
    clear; print_divider; echo -e "       ⚙️ 动态 TCP 自动调优注入 (VPSBox 核心)    "; print_divider
    echo -e "${YELLOW}【模式说明】${NC}"
    echo -e "  ${GREEN}1. 正常模式${NC}: 科学稳健，结合你的带宽和延迟智能计算 BDP，适合日常建站、常规代理。"
    echo -e "  ${RED}2. 激进模式${NC}: Beta特性，无视慢启动，极致压榨带宽，高并发利器。${YELLOW}(警告：可能增加丢包率与内存消耗)${NC}"
    print_separator
    
    # 1. 模式选择
    local mode_choice
    while true; do
        read -r -p "▶ 请选择调优模式 [1-正常 / 2-激进, 输入 0 取消]: " mode_choice
        mode_choice="${mode_choice// /}"
        if [ "$mode_choice" == "0" ]; then return; fi
        if [[ "$mode_choice" == "1" || "$mode_choice" == "2" ]]; then break; fi
        echo -e "${RED}[错误] 请输入 1 或 2！${NC}"
    done

    # 2. 参数收集 (带有防呆检测，严格要求手动输入)
    local local_bw server_bw latency ramp_up
    while true; do
        read -r -p "▶ 请输入本地/客户端下行带宽 (Mbps, 例如 500): " local_bw
        [[ "${local_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    while true; do
        read -r -p "▶ 请输入服务器上行带宽 (Mbps, 例如 1000): " server_bw
        [[ "${server_bw// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    while true; do
        read -r -p "▶ 请输入预估网络延迟 (ms, 例如 150): " latency
        [[ "${latency// /}" =~ ^[0-9]+$ ]] && break || echo -e "${RED}[错误] 请输入有效的纯数字！${NC}"
    done
    while true; do
        echo -e "\n${CYAN}【爬升曲线指南】${NC}"
        echo -e " ${GREEN}0.1 - 0.4${NC}: 保守稳定 (适合 512M 等极小内存机器)"
        echo -e " ${GREEN}0.5 - 0.6${NC}: 平稳传输 (适合日常建站，不抢占资源)"
        echo -e " ${YELLOW}0.7 - 0.9${NC}: 快速响应 (推荐，自动关闭慢启动，看剧极速)"
        echo -e " ${RED}1.0      ${NC}: 极限跑分 (双倍 BDP 冗余，强力压榨带宽)"
        read -r -p "▶ 请输入爬升曲线调节 (0.1 - 1.0): " ramp_up
     
        if awk -v r="${ramp_up// /}" 'BEGIN{if(r>=0.1 && r<=1.0) exit 0; else exit 1}'; then
            break
        fi
        echo -e "${RED}[错误] 请输入 0.1 到 1.0 之间的有效数字！${NC}"
    done

    # 3. 自动探测内存
    local w_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ -z "$w_ram" ] || [ "$w_ram" -le 0 ]; then w_ram=1024; fi
    echo -e "\n${CYAN}>>> 系统自动探测内存: ${GREEN}${w_ram} MB${NC}"

    # 4. 动态核心计算 (全逻辑重构版)
    eval $(awk -v mode="$mode_choice" -v lbw="$local_bw" -v sbw="$server_bw" -v lat="$latency" -v ramp="$ramp_up" -v w="$w_ram" '
    function min(a, b) { return a < b ? a : b }
    function max(a, b) { return a > b ? a : b }
    BEGIN {
        bw = min(lbw, sbw)
        init_win = int(4096 + (65536 - 4096) * ramp)
        def_win = int(65536 + (524288 - 65536) * ramp)
        slow_start = (ramp >= 0.7) ? 0 : 1

        gc1 = (w <= 512) ? 256 : 512
        gc2 = (w <= 512) ? 1024 : 2048
        gc3 = (w <= 512) ? 2048 : 4096
        
        # 全局内存安全墙 (单连接最大允许占用物理内存的 1/16，防止 OOM)
        global_ram_cap = (w * 1048576) / 16.0 

        if (mode == "1") {
            bdp = (bw * 125000) * (lat / 1000.0)
            
            # 修复1: 将曲线完美融入最大缓冲区，0.7 对应 1.7 倍 BDP，1.0 对应 2 倍 BDP
            max_buf = int(max(bdp * (1.0 + ramp), 16777216))
            # 增加兜底保护：即使填写 1.0 拉满，也绝不能超过全局内存安全墙
            max_buf = int(min(max_buf, global_ram_cap))
            
            t_mem = int(384*w) " " int(512*w) " " int(768*w)
            m_free = int(max(131072, 32*w))

            printf "INIT_WIN=%d\nDEF_WIN=%d\nMAX_BUF=%d\nTCP_MEM=\"%s\"\nSLOW_START=%d\nMIN_FREE=%d\n", init_win, def_win, max_buf, t_mem, slow_start, m_free
        } else {
            M = bw * 125000
            b = lat
            bdp_mult = min(12.0, 6.0 + (w / 1024.0))
            ram_cap = 1024.0 * w * 153.6
            
            # 修复2: 激进模式强制引入用户填写的 ramp 乘数
            x_var = int(max(min(M * b / 1000.0 * bdp_mult * ramp, ram_cap), 4194304))
            # 同样受到全局安全墙保护
            x_var = int(min(x_var, global_ram_cap))
            
            k = min(b / 100.0, 5.0)
            q = min(M / 1048576.0, 15000.0)
            S = min(6 * w, 24576)

            nd_max = int(min(S, 6000 + q * k))
            t_max_syn = int(min(S / 2.0, 3000 + (q * k) / 2.0))
            m_orphans = (w <= 256) ? 16384 : 32768
            
            # 修复3: 根据当前填写的延迟，智能分配忙轮询策略
            if (b <= 50) {
                b_read = 100;
                b_poll = 100
            } else if (b <= 150) {
                b_read = 50;
                b_poll = 50
            } else {
                b_read = 0;
                b_poll = 0
            }
            
            t_mem = int(512*w) " " int(768*w) " " int(1024*w)

            printf "X_VAR=%d\nND_MAX=%d\nT_MAX_SYN=%d\nM_ORPHANS=%d\nB_READ=%d\nB_POLL=%d\nTCP_MEM=\"%s\"\n", x_var, nd_max, t_max_syn, m_orphans, b_read, b_poll, t_mem
        }
        printf "GC1=%d\nGC2=%d\nGC3=%d\n", gc1, gc2, gc3
    }')

    # 5. 确认执行
    
    echo -e "${CYAN}>>> 动态参数计算完毕！准备注入底层。${NC}"
    if ! confirm_action "执行并使上述 TCP 调优参数生效"; then pause_for_enter; return; fi
    
    # 备份原有参数
    read -r -p "▶ 是否在调优前备份当前参数？(y/n, 默认 y): " NEED_BACKUP
    NEED_BACKUP="${NEED_BACKUP// /}"
    [[ -z "$NEED_BACKUP" || "$NEED_BACKUP" =~ ^[yY]$ ]] && backup_config_silently

    # 6. 生成配置文件
    cat > "$CUSTOM_CONF" <<EOF
# ==========================================
# VPSBox 网络调优核心逻辑 (动态计算生成)
# ==========================================
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh1 = $GC1
net.ipv4.neigh.default.gc_thresh2 = $GC2
net.ipv4.neigh.default.gc_thresh3 = $GC3
net.ipv4.ip_forward = 0
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.default.forwarding = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
EOF

    if [ "$mode_choice" == "1" ]; then
        cat >> "$CUSTOM_CONF" <<EOF
# --- 正常模式 (爬升率: $ramp_up) ---
net.core.rmem_max = $MAX_BUF
net.core.wmem_max = $MAX_BUF
net.core.rmem_default = $DEF_WIN
net.core.wmem_default = $DEF_WIN
net.ipv4.tcp_rmem = $INIT_WIN $DEF_WIN $MAX_BUF
net.ipv4.tcp_wmem = $INIT_WIN $DEF_WIN $MAX_BUF
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.tcp_slow_start_after_idle = $SLOW_START
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
vm.swappiness = 10
vm.min_free_kbytes = $MIN_FREE
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 8192
EOF
    else
        cat >> "$CUSTOM_CONF" <<EOF
# --- 激进模式 (Extreme Beta - 爬升率: $ramp_up) ---
net.core.rmem_max = $(( 2 * X_VAR ))
net.core.wmem_max = $X_VAR
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.ipv4.tcp_rmem = 65536 524288 $(( 2 * X_VAR ))
net.ipv4.tcp_wmem = 65536 524288 $X_VAR
net.ipv4.tcp_mem = $TCP_MEM
net.core.netdev_max_backlog = $ND_MAX
net.ipv4.tcp_max_syn_backlog = $T_MAX_SYN
net.core.somaxconn = 32768
net.ipv4.tcp_max_orphans = $M_ORPHANS
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 32768
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
vm.min_free_kbytes = $(( w_ram < 4096 ? 262144 : 64 * w_ram ))
vm.swappiness = 1
net.core.optmem_max = $(( w_ram < 1024 ? 163840 : 160 * w_ram ))
kernel.sched_min_granularity_ns = 3000000
net.core.busy_read = $B_READ
net.core.busy_poll = $B_POLL
EOF
    fi

    # 尝试加载 BBR 并应用配置
    modprobe tcp_bbr > /dev/null 2>&1
    sysctl -p "$CUSTOM_CONF" > /dev/null 2>&1
    
    echo -e "\n${GREEN}✅ TCP 动态调优参数已成功注入并生效！${NC}"
    echo -e "⚡ 当前 BBR 状态: $(get_bbr_status)"
    pause_for_enter
}

backup_config_silently() {
    local ts=$(date +"%Y%m%d_%H%M%S")
    sysctl -a --pattern net.ipv4.tcp | grep -E "rmem|wmem|congestion|sack" > "${BACKUP_DIR}/backup_${ts}.conf" 2>/dev/null
    echo -e "${GREEN}✅ 参数已自动备份。${NC}"
}

manage_backup() {
    while true; do
        clear; print_divider; echo -e "       📦 网络调优参数备份与还原管理    "; print_divider
        echo -e "  ${GREEN}1.${NC} 立即备份当前参数"
        echo -e "  ${GREEN}2.${NC} 还原历史备份"
        echo -e "  ${GREEN}3.${NC} 删除历史备份"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -r -p "▶ 请选择操作 [0-3]: " b_opt
        b_opt="${b_opt// /}"
        
        case $b_opt in
            1)
                if ! confirm_action "备份当前网络参数"; then continue; fi
                local ts=$(date +"%Y%m%d_%H%M%S")
                sysctl -a --pattern net.ipv4.tcp | grep -E "rmem|wmem|congestion|sack" > "${BACKUP_DIR}/backup_${ts}.conf" 2>/dev/null
                echo -e "\n${GREEN}✅ TCP 参数备份成功！${NC}"
                pause_for_enter
                ;;
            2)
                shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
                if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${RED}无备份记录。${NC}"; pause_for_enter; continue; fi
                
                while true; do
                    echo -e "\n${CYAN}请选择要恢复的时间点：${NC}"
                    for i in "${!backups[@]}"; do 
                        echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
                    read -r -p "▶ 请输入编号 (0取消): " res_opt
                    res_opt="${res_opt// /}"
                    
                    if [ "$res_opt" == "0" ]; then break; fi
                    if [[ "$res_opt" =~ ^[0-9]+$ ]] && [ "$res_opt" -ge 1 ] && [ "$res_opt" -le "${#backups[@]}" ]; then
                        if ! confirm_action "覆盖当前配置并还原至此备份"; then break; fi
                        sysctl -p "${backups[$((res_opt-1))]}" > /dev/null 2>&1
                        rm -f "$CUSTOM_CONF"; echo -e "\n${GREEN}✅ 参数已成功还原！${NC}"
                        pause_for_enter
                        break
                    else
                        echo -e "${RED}[错误] 输入无效编号，请重新输入！${NC}"
                    fi
                done
                ;;
            3)
                shopt -s nullglob; local backups=("${BACKUP_DIR}"/backup_*.conf); shopt -u nullglob
                if [ ${#backups[@]} -eq 0 ]; then echo -e "\n${YELLOW}备份目录为空。${NC}"; pause_for_enter; continue; fi
                
                while true; do
                    echo -e "\n${CYAN}请选择要删除的备份：${NC}"
                    for i in "${!backups[@]}"; do 
                        echo -e "  ${GREEN}$((i+1)).${NC} 备份日期: $(stat -c "%y" "${backups[$i]}" | cut -d'.' -f1)"; done
                    echo -e "  ${RED}99.${NC} 清空所有"
                    read -r -p "▶ 请输入编号 (0取消): " del_opt
                    del_opt="${del_opt// /}"
                    
                    if [ "$del_opt" == "0" ]; then break; fi
                    if [[ "$del_opt" =~ ^[0-9]+$ ]] && [ "$del_opt" -ge 1 ] && [ "$del_opt" -le "${#backups[@]}" ]; then
                        if ! confirm_action "永久删除此备份"; then break; fi
                        rm -f "${backups[$((del_opt-1))]}"; echo -e "\n${GREEN}✅ 记录已删除。${NC}"
                        pause_for_enter
                        break
                    elif [ "$del_opt" -eq 99 ]; then
                        if ! confirm_action "永久清空所有备份"; then break; fi
                        rm -f "${BACKUP_DIR}"/backup_*.conf; echo -e "\n${GREEN}✅ 已清空所有备份。${NC}"
                        pause_for_enter
                        break
                    else
                        echo -e "${RED}[错误] 编号输入无效，请重新选择列表中存在的选项！${NC}"
                    fi
                done
                ;;
            0) return ;;
            *) echo -e "\n${RED}[错误] 输入无效，请输入 0-3 之间的数字！${NC}"; sleep 1 ;;
        esac
    done
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

# 节点查看与备份管理二合一
view_deployed_nodes() {
    while true; do
        clear; print_divider; echo -e "       📋 节点状态、分享与配置备份管理    "; print_divider
        install_dependencies
        
        echo -e "${CYAN}--- 服务端底层配置状态 ---${NC}"
        if [ -f "/usr/local/etc/xray/config.json" ] && grep -q "inbounds" "/usr/local/etc/xray/config.json"; then
            jq -r '.inbounds[] | "【Xray】 端口: \(.port) | 协议: \(.protocol) | 网络: \(if .protocol == "hysteria" then "udp" else (.streamSettings.network // "tcp") end) | 安全: \(.streamSettings.security // "none")"' /usr/local/etc/xray/config.json 2>/dev/null || echo -e "${YELLOW}配置文件解析失败。${NC}"
        else
            echo -e "${YELLOW}未检测到 Xray 节点配置。${NC}"
        fi
        
        if [ -f "/etc/sing-box/config.json" ] && grep -q "inbounds" "/etc/sing-box/config.json"; then
            # 完美修复：利用 jq 安全导航符 ?. 防止极端空指针崩溃
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
        echo -e "  [${GREEN}B${NC}] 备份：为所有节点配置文件创建快照"
        echo -e "  [${GREEN}R${NC}] 还原：从历史快照恢复节点配置"
        echo -e "  [${GREEN}0${NC}] 返回主菜单"
        echo ""
        read -r -p "▶ 请选择操作: " vn_opt
        vn_opt="${vn_opt// /}"
        
        if [ "$vn_opt" == "0" ]; then break; fi
        
        if [[ "$vn_opt" =~ ^[0-9]+$ ]] && [ "$vn_opt" -ge 1 ] && [ "$vn_opt" -le "${#links[@]}" ]; then
            local target_link=$(echo "${links[$((vn_opt-1))]}" | awk -F' \\| ' '{print $3}')
            echo -e "\n${CYAN}>>> 节点分享链接：${NC}"
            echo -e "${target_link}\n"
            echo -e "${YELLOW}>>> 节点二维码 (紧凑版，长内容自动换行无影响)：${NC}"
            qrencode -t UTF8 -m 1 "$target_link"
            pause_for_enter
        elif [[ "$vn_opt" =~ ^[bB]$ ]]; then
            if ! confirm_action "备份当前节点配置"; then continue; fi
            local ts=$(date +"%Y%m%d_%H%M%S")
            local bk_path="${BACKUP_DIR}/node_backup_${ts}"
            mkdir -p "$bk_path"
            [ -f "/usr/local/etc/xray/config.json" ] && cp /usr/local/etc/xray/config.json "$bk_path/xray_config.json"
            [ -f "/etc/sing-box/config.json" ] && cp /etc/sing-box/config.json "$bk_path/singbox_config.json"
            [ -f "$NODE_RECORD_FILE" ] && cp "$NODE_RECORD_FILE" "$bk_path/vpsbox_nodes.txt"
            echo -e "\n${GREEN}✅ 节点配置已成功备份至: $bk_path ${NC}"
            pause_for_enter
        elif [[ "$vn_opt" =~ ^[rR]$ ]]; then
            shopt -s nullglob
            local n_backups=("${BACKUP_DIR}"/node_backup_*)
            shopt -u nullglob
            if [ ${#n_backups[@]} -eq 0 ]; then
                echo -e "\n${RED}未找到节点备份记录。${NC}"; pause_for_enter; continue
            fi
            
            echo -e "\n${CYAN}请选择要还原的备份：${NC}"
            for i in "${!n_backups[@]}"; do
                echo -e "  ${GREEN}$((i+1)).${NC} 备份时间: $(basename "${n_backups[$i]}" | sed 's/node_backup_//')"
            done
            read -r -p "▶ 请输入编号 (0取消): " n_res_opt
            n_res_opt="${n_res_opt// /}"
            
            if [ "$n_res_opt" == "0" ]; then continue; fi
            if [[ "$n_res_opt" =~ ^[0-9]+$ ]] && [ "$n_res_opt" -ge 1 ] && [ "$n_res_opt" -le "${#n_backups[@]}" ]; then
                if ! confirm_action "还原此备份 (当前配置将被覆盖，且服务会重启)"; then continue; fi
                local sel_bk="${n_backups[$((n_res_opt-1))]}"
                [ -f "$sel_bk/xray_config.json" ] && cp "$sel_bk/xray_config.json" /usr/local/etc/xray/config.json && systemctl restart xray
                [ -f "$sel_bk/singbox_config.json" ] && cp "$sel_bk/singbox_config.json" /etc/sing-box/config.json && systemctl restart sing-box
                [ -f "$sel_bk/vpsbox_nodes.txt" ] && cp "$sel_bk/vpsbox_nodes.txt" "$NODE_RECORD_FILE"
                echo -e "\n${GREEN}✅ 节点配置已成功还原！服务已重启。${NC}"
                pause_for_enter
            else
                echo -e "${RED}[错误] 输入无效编号！${NC}"; sleep 1
            fi
        else
            echo -e "\n${RED}[错误] 输入无效，请重新选择！${NC}"; sleep 1
        fi
    done
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
    while true; do
        read -r -p "▶ 请输入要删除的节点【端口号】 (输入 0 取消): " del_port
        del_port="${del_port// /}"
        if [ "$del_port" == "0" ]; then return; fi
        if [ -z "$del_port" ] || ! [[ "$del_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[错误] 端口号必须是有效的纯数字！请重新输入。${NC}"
            continue
        fi
        
        local port_exists=0
        if [ -f "/usr/local/etc/xray/config.json" ] && jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then port_exists=1; fi
        if [ -f "/etc/sing-box/config.json" ] && jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then port_exists=1; fi
        
        if [ "$port_exists" -eq 0 ]; then
            echo -e "${RED}[错误] 当前部署中未找到端口为 $del_port 的节点，请检查！${NC}"
            continue
        fi
        break
    done

    if ! confirm_action "永久删除端口为 $del_port 的节点"; then pause_for_enter; return; fi
    
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        if jq -e ".inbounds[] | select(.port == $del_port)" /usr/local/etc/xray/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.port == $del_port))" /usr/local/etc/xray/config.json > /tmp/xray_tmp.json
            if [ -s /tmp/xray_tmp.json ]; then
                mv /tmp/xray_tmp.json /usr/local/etc/xray/config.json
                systemctl restart xray
                echo -e "${GREEN}✅ 已成功移除 Xray 中占用端口 $del_port 的节点配置！${NC}"
            else
                rm -f /tmp/xray_tmp.json
                echo -e "${RED}[错误] Xray 节点删除失败，配置可能受损！${NC}"
            fi
        fi
    fi
    if [ -f "/etc/sing-box/config.json" ]; then
        if jq -e ".inbounds[] | select(.listen_port == $del_port)" /etc/sing-box/config.json > /dev/null 2>&1; then
            jq "del(.inbounds[] | select(.listen_port == $del_port))" /etc/sing-box/config.json > /tmp/sb_tmp.json
            if [ -s /tmp/sb_tmp.json ]; then
                mv /tmp/sb_tmp.json /etc/sing-box/config.json
                systemctl restart sing-box
                echo -e "${GREEN}✅ 已成功移除 Sing-box 中占用端口 $del_port 的节点配置！${NC}"
            else
                rm -f /tmp/sb_tmp.json
                echo -e "${RED}[错误] Sing-box 节点删除失败，配置可能受损！${NC}"
            fi
        fi
    fi
    
    if [ -f "$NODE_RECORD_FILE" ]; then
        sed -i "/端口:${del_port} /d" "$NODE_RECORD_FILE" 2>/dev/null
    fi
    pause_for_enter
}

# --- 节点部署核心引擎 ---
append_inbound() {
    local CONFIG_FILE=$1
    local NEW_INBOUND=$2
    local TARGET_PORT=$3
    local CORE_NAME=$4
    local TMP_FILE="/tmp/vpsbox_test_config.json"
    
    if [ -f "$CONFIG_FILE" ] && grep -q "inbounds" "$CONFIG_FILE"; then
        echo -e "${YELLOW}[系统] 检测到已有配置，正在生成并验证测试配置...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then
            jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.listen_port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE"
        else
            jq --argjson new_in "$NEW_INBOUND" --argjson port "$TARGET_PORT" 'del(.inbounds[] | select(.port == $port)) | .inbounds += [$new_in]' "$CONFIG_FILE" > "$TMP_FILE"
        fi
    else
        echo -e "${YELLOW}[系统] 首次部署，正在初始化并验证配置文件...${NC}"
        if [ "$CORE_NAME" == "Sing-box" ]; then
            cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"type":"direct"}]}
EOF
        else
            cat > "$TMP_FILE" <<EOF
{"inbounds":[$NEW_INBOUND],"outbounds":[{"protocol":"freedom"}]}
EOF
        fi
    fi

    local TEST_PASS=0
    if [ "$CORE_NAME" == "Sing-box" ]; then
        local SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
        if "$SB_BIN" check -c "$TMP_FILE" >/dev/null 2>&1; then TEST_PASS=1; fi
    else
        local X_BIN=$(command -v xray || echo "/usr/local/bin/xray")
        if "$X_BIN" run -test -c "$TMP_FILE" >/dev/null 2>&1; then TEST_PASS=1; fi
    fi

    if [ "$TEST_PASS" -eq 1 ]; then
        mv "$TMP_FILE" "$CONFIG_FILE"
        return 0
    else
        rm -f "$TMP_FILE"
        return 1
    fi
}

install_reality_node() {
    clear; print_divider; echo -e "       🌍 部署 VLESS-Reality (直连低延迟 / 强力防封锁)    "; print_divider
    echo -e "\n${YELLOW}【提醒】此模式抗封锁能力极强，但必须使用本机真实 IP 直连。${NC}\n"
    
    while true; do
        read -r -p "▶ 请输入监听端口 (默认 50000, 0 取消): " PORT
        PORT="${PORT// /}"
        if [ "$PORT" == "0" ]; then return; fi; [ -z "$PORT" ] && PORT=50000
        
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}[错误] 端口号必须是 1 到 65535 之间的纯数字！请重新输入。${NC}"
            continue
        fi
        if ss -tulpn | grep -qw ":$PORT"; then
            echo -e "${RED}[错误] 端口 $PORT 已被占用！${NC}"
            continue
        fi
        break
    done
    
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core (经典稳定)\n  ${GREEN}2.${NC} Sing-box (轻量极速)"
        read -r -p "▶ 选择运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    
    echo -e "\n  ${GREEN}1.${NC} gateway.icloud.com (苹果官网)\n  ${GREEN}2.${NC} www.microsoft.com (微软官网)"
    read -r -p "▶ 选择伪装 SNI [输入 1-2 选择，或直接输入自定义域名, 默认 1, 0 取消]: " sni_choice
    sni_choice="${sni_choice// /}"
    if [ "$sni_choice" == "0" ]; then return; fi
    
    if [[ -z "$sni_choice" || "$sni_choice" == "1" ]]; then 
        SNI_DOMAIN="gateway.icloud.com"
    elif [[ "$sni_choice" == "2" ]]; then 
        SNI_DOMAIN="www.microsoft.com"
    else 
        SNI_DOMAIN="$sni_choice"; fi
    
    if ! confirm_action "开始部署 Reality 节点"; then pause_for_enter; return; fi
    install_dependencies
    
    UUID=$(cat /proc/sys/kernel/random/uuid); SHORT_ID=$(openssl rand -hex 8)
    # 修复：对纯 IPv6 地址的 URL 拼接格式化处理
    LINK_IP="$SERVER_IP"
    if [[ "$IP_FORMAT" == "v6" ]]; then LINK_IP="[${SERVER_IP}]"; fi
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        hash -r; X_BIN=$(command -v xray || echo "/usr/local/bin/xray"); KEYS=$("$X_BIN" x25519)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"port":'$PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"'$SNI_DOMAIN':443","serverNames":["'$SNI_DOMAIN'"],"privateKey":"'$PRI'","shortIds":["'$SHORT_ID'"]}}}'
        
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$PORT" "Xray"; then
            systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray)
        else 
            SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        hash -r; SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box"); KEYS=$("$SB_BIN" generate reality-keypair)
        PRI=$(echo "$KEYS" | awk -F'[: ]+' '/Private/{print $NF}'); PUB=$(echo "$KEYS" | awk -F'[: ]+' '/Public/{print $NF}')
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$PORT',"users":[{"uuid":"'$UUID'","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"'$SNI_DOMAIN'","reality":{"enabled":true,"handshake":{"server":"'$SNI_DOMAIN'","server_port":443},"private_key":"'$PRI'","short_id":["'$SHORT_ID'"]}}}'
        
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$PORT" "Sing-box"; then
            systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box)
        else 
            SERVICE_STATUS="config_error"; fi
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 VLESS-Reality 节点成功部署于 ${CORE_NAME}！${NC}"
        LINK="vless://${UUID}@${LINK_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp#${CORE_NAME}-Reality"
        echo -e "${CYAN}${LINK}${NC}\n"
        echo -e "${YELLOW}>>> 扫描下方二维码快速导入节点：${NC}"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-Reality | 端口:${PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置校验失败或拒绝启动，未保存任何变更！${NC}"
    fi
    pause_for_enter
}

install_ws_tls_node() {
    clear; print_divider; echo -e "       ☁️ 部署 VLESS-WS-TLS (套 CDN 优选 IP /拯救被墙机器)    "; print_divider
    
    while true; do
        read -r -p "▶ 请输入域名 (输入 0 取消): " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [ "$DOMAIN" == "0" ]; then return; fi
        if [ -z "$DOMAIN" ]; then continue; fi
        DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
        break
    done
    
    while true; do
        read -r -p "▶ 监听端口 (默认 443, 0 取消): " WS_PORT
        WS_PORT="${WS_PORT// /}"
        if [ "$WS_PORT" == "0" ]; then return; fi; [ -z "$WS_PORT" ] && WS_PORT=443
        if ! [[ "$WS_PORT" =~ ^[0-9]+$ ]] || [ "$WS_PORT" -lt 1 ] || [ "$WS_PORT" -gt 65535 ]; then continue; fi
        if ss -tulpn | grep -qw ":$WS_PORT"; then echo -e "${RED}端口 $WS_PORT 已被占用！${NC}"; continue; fi
        break
    done
    
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
        read -r -p "▶ 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    
    echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
    echo -e "  ${GREEN}1.${NC} 【推荐】我已开启 CDN (小黄云) -> 使用 Cloudflare API 申请"
    echo -e "  ${GREEN}2.${NC} 【常规】我未开启 CDN (真实 IP) -> 使用常规 80 端口申请"
    while true; do
        read -r -p "▶ 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
        cert_mode="${cert_mode// /}"
        if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
        if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
        
        if [ "$cert_mode" == "1" ]; then
            read -r -p "▶ 请输入您的 Cloudflare API Token: " CF_Token
            if [ -z "$CF_Token" ]; then continue; fi
            export CF_Token="$CF_Token"
            break
        elif [ "$cert_mode" == "2" ]; then
            if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
                echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP ($SERVER_IP) 不符！${NC}"
                read -r -p "▶ 是否确认你已关闭小黄云强制继续？(y/n, 默认 n): " force_continue
                if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
            fi
            break
        fi
    done

    if ! confirm_action "开始部署 WS+TLS 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    
    # 完美修复：最新版本 Acme.sh 强制要求提供邮箱参数，否则报错无法安装
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh -s email=dummy@vpsbox.com >/dev/null 2>&1
    
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        echo -e "\n${RED}[错误] Acme.sh 证书脚本安装失败！可能是网络被阻断。${NC}"
        pause_for_enter
        return
    fi

    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    
    echo -e "\n${CYAN}>>> 正在申请 SSL 证书...${NC}"
    PORT_80_SERVICE=""
    
    if /root/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        echo -e "${GREEN}✅ 检测到本地有效证书，复用机制触发！${NC}"
        CERT_RES=0
    else
        if [ "$cert_mode" == "1" ]; then
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256
            CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                PORT_80_SERVICE=$(ss -tlnp | grep "\b:80\b" | awk -F'"' '{print $2}' | grep -v "^$" | head -n 1)
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE="未知程序"
                
                echo -e "\n${YELLOW}[警告] 检测到 80 端口正被 [ ${PORT_80_SERVICE} ] 占用！${NC}"
                echo -e "${YELLOW}由于您选择了常规 80 端口申请模式，强行继续会临时关闭该程序，并在申请结束后尝试重启它。${NC}"
                echo -e "${RED}⚠️ 严重提示：如果该程序后续继续长期占用 80 端口，将导致您的证书无法自动续签！建议您返回主菜单，改用【DNS API 模式】。${NC}"
                
                read -r -p "▶ 是否仍要临时关闭 [${PORT_80_SERVICE}] 强行继续申请？(y/n, 默认 n): " force_kill_80
                if [[ ! "${force_kill_80// /}" =~ ^[yY]$ ]]; then
                    echo -e "${CYAN}已取消当前操作。${NC}"
                    pause_for_enter
                    return
                fi
                # 完美修复：先用 systemctl 停用服务防止被守护进程秒拉活，再用 fuser 暴力补刀
                systemctl stop "$PORT_80_SERVICE" > /dev/null 2>&1
                fuser -k 80/tcp > /dev/null 2>&1
                sleep 2
            fi
            
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
            CERT_RES=$?
            
            if [ -n "$PORT_80_SERVICE" ] && [ "$PORT_80_SERVICE" != "未知程序" ]; then
                echo -e "${CYAN}>>> 正在尝试为您恢复原本的 [${PORT_80_SERVICE}] 服务...${NC}"
                systemctl start "$PORT_80_SERVICE" >/dev/null 2>&1 || echo -e "${RED}[注意] ${PORT_80_SERVICE} 恢复失败，请稍后手动检查。${NC}"
            fi
        fi
    fi

    if [ "$CERT_RES" -ne 0 ] && [ "$CERT_RES" -ne 2 ]; then
        echo -e "\n${RED}[错误] 证书申请失败，中止。${NC}"
        pause_for_enter
        return
    fi
    
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" --reloadcmd "systemctl restart xray 2>/dev/null; systemctl restart sing-box 2>/dev/null" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem
    chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    
    UUID=$(cat /proc/sys/kernel/random/uuid); WSPATH="/$(openssl rand -hex 4)"
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        NEW_INBOUND='{"port":'$WS_PORT',"protocol":"vless","settings":{"clients":[{"id":"'$UUID'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"wsSettings":{"path":"'$WSPATH'"}}}'
        
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$WS_PORT" "Xray"; then
            systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray)
        else 
            SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        NEW_INBOUND='{"type":"vless","listen":"::","listen_port":'$WS_PORT',"users":[{"uuid":"'$UUID'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"},"transport":{"type":"ws","path":"'$WSPATH'"}}'
        
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$WS_PORT" "Sing-box"; then
            systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box)
        else 
            SERVICE_STATUS="config_error"; fi
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 VLESS-WS-TLS 部署成功！${NC}"
        LINK="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WSPATH}#${CORE_NAME}-WS-TLS"
        echo -e "${CYAN}${LINK}${NC}\n"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-WS-TLS | 端口:${WS_PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置拒绝启动，未保存任何变更！${NC}"
    fi
    pause_for_enter
}

install_hy2_node() {
    clear; print_divider; echo -e "       ⚡ 部署 Hysteria2 (暴力 UDP 发包 / 抢占高带宽)    "; print_divider
    
    while true; do
        read -r -p "▶ 请输入域名 (输入 0 取消): " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [ "$DOMAIN" == "0" ]; then return; fi
        if [ -z "$DOMAIN" ]; then continue; fi
        DOMAIN_IP=$(ping -c 1 -n "$DOMAIN" 2>/dev/null | head -n 1 | awk -F '[()]' '{print $2}')
        break
    done
    
    while true; do
        read -r -p "▶ 监听端口 (默认 8443, 0 取消): " HY2_PORT
        HY2_PORT="${HY2_PORT// /}"
        if [ "$HY2_PORT" == "0" ]; then return; fi; [ -z "$HY2_PORT" ] && HY2_PORT=8443
        if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then continue; fi
        if ss -tulpn | grep -qw ":$HY2_PORT"; then echo -e "${RED}端口 $HY2_PORT 已被占用！${NC}"; continue; fi
        break
    done
    
    while true; do
        echo -e "\n  ${GREEN}1.${NC} Xray-core\n  ${GREEN}2.${NC} Sing-box"
        read -r -p "▶ 运行内核 [1-2, 默认 1, 0 取消]: " core_choice
        core_choice="${core_choice// /}"
        if [ "$core_choice" == "0" ]; then return; fi; [ -z "$core_choice" ] && core_choice=1
        if [[ "$core_choice" != "1" && "$core_choice" != "2" ]]; then continue; fi
        break
    done
    
    echo -e "\n${CYAN}>>> 证书申请模式选择${NC}"
    echo -e "  ${GREEN}1.${NC} 【推荐】我已开启 CDN (小黄云) -> 使用 Cloudflare API 申请"
    echo -e "  ${GREEN}2.${NC} 【常规】我未开启 CDN (真实 IP) -> 使用常规 80 端口申请"
    while true; do
        read -r -p "▶ 选择模式 [1-2, 默认 2, 0 取消]: " cert_mode
        cert_mode="${cert_mode// /}"
        if [ "$cert_mode" == "0" ]; then return; fi; [ -z "$cert_mode" ] && cert_mode=2
        if [[ "$cert_mode" != "1" && "$cert_mode" != "2" ]]; then continue; fi
        
        if [ "$cert_mode" == "1" ]; then
            read -r -p "▶ 请输入您的 Cloudflare API Token: " CF_Token
            if [ -z "$CF_Token" ]; then continue; fi
            export CF_Token="$CF_Token"
            break
        elif [ "$cert_mode" == "2" ]; then
            if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then 
                echo -e "\n${YELLOW}[警告] 域名解析 IP ($DOMAIN_IP) 与本机 IP ($SERVER_IP) 不符！${NC}"
                read -r -p "▶ 是否强制继续？(y/n, 默认 n): " force_continue
                if [[ ! "${force_continue// /}" =~ ^[yY]$ ]]; then continue; fi
            fi
            break
        fi
    done
    
    if ! confirm_action "开始部署 Hysteria2 节点并申请证书"; then pause_for_enter; return; fi
    install_dependencies
    
    [ ! -d "/root/.acme.sh" ] && curl https://get.acme.sh | sh -s email=dummy@vpsbox.com >/dev/null 2>&1
    
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        echo -e "\n${RED}[错误] Acme.sh 证书脚本安装失败！可能是网络被阻断。${NC}"
        pause_for_enter
        return
    fi

    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m dummy@vpsbox.com >/dev/null 2>&1
    
    echo -e "\n${CYAN}>>> 正在申请 SSL 证书...${NC}"
    PORT_80_SERVICE=""

    if /root/.acme.sh/acme.sh --list | grep -q "$DOMAIN"; then
        echo -e "${GREEN}✅ 检测到本地有效证书，复用！${NC}"
        CERT_RES=0
    else
        if [ "$cert_mode" == "1" ]; then
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256
            CERT_RES=$?
        else
            if ss -tlnp | grep -q "\b:80\b"; then
                PORT_80_SERVICE=$(ss -tlnp | grep "\b:80\b" | awk -F'"' '{print $2}' | grep -v "^$" | head -n 1)
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE=$(fuser 80/tcp 2>/dev/null | awk '{print $1}')
                [ -z "$PORT_80_SERVICE" ] && PORT_80_SERVICE="未知程序"
                
                echo -e "\n${YELLOW}[警告] 检测到 80 端口正被 [ ${PORT_80_SERVICE} ] 占用！${NC}"
                echo -e "${YELLOW}由于您选择了常规 80 端口申请模式，强行继续会临时关闭该程序，并在申请结束后尝试重启它。${NC}"
                echo -e "${RED}⚠️ 严重提示：如果该程序后续继续长期占用 80 端口，将导致您的证书无法自动续签！建议您返回主菜单，改用【DNS API 模式】。${NC}"
                
                read -r -p "▶ 是否仍要临时关闭 [${PORT_80_SERVICE}] 强行继续申请？(y/n, 默认 n): " force_kill_80
                if [[ ! "${force_kill_80// /}" =~ ^[yY]$ ]]; then
                    echo -e "${CYAN}已取消当前操作。${NC}"
                    pause_for_enter
                    return
                fi
                systemctl stop "$PORT_80_SERVICE" > /dev/null 2>&1
                fuser -k 80/tcp > /dev/null 2>&1
                sleep 2
            fi
            
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
            CERT_RES=$?
            
            if [ -n "$PORT_80_SERVICE" ] && [ "$PORT_80_SERVICE" != "未知程序" ]; then
                echo -e "${CYAN}>>> 正在尝试为您恢复原本的 [${PORT_80_SERVICE}] 服务...${NC}"
                systemctl start "$PORT_80_SERVICE" >/dev/null 2>&1 || echo -e "${RED}[注意] ${PORT_80_SERVICE} 恢复失败，请稍后手动检查。${NC}"
            fi
        fi
    fi

    if [ "$CERT_RES" -ne 0 ] && [ "$CERT_RES" -ne 2 ]; then
        echo -e "\n${RED}[错误] 证书申请失败，中止。${NC}"
        pause_for_enter
        return
    fi
    
    CERT_DIR="/etc/vpsbox-cert"; mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" --reloadcmd "systemctl restart xray 2>/dev/null; systemctl restart sing-box 2>/dev/null" >/dev/null 2>&1
    chmod 755 "$CERT_DIR"; chmod 644 "$CERT_DIR"/*.pem
    chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null
    
    HY2_PASS=$(openssl rand -hex 8)
    
    if [ "$core_choice" == "1" ]; then
        CORE_NAME="Xray"
        if ! command -v xray &> /dev/null; then bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1; fi
        NEW_INBOUND='{"listen":"0.0.0.0","port":'$HY2_PORT',"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"'$HY2_PASS'","email":"user@vpsbox"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"minVersion":"1.3","certificates":[{"certificateFile":"'$CERT_DIR'/fullchain.pem","keyFile":"'$CERT_DIR'/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"'$HY2_PASS'","udpIdleTimeout":60}}}'
        
        if append_inbound "/usr/local/etc/xray/config.json" "$NEW_INBOUND" "$HY2_PORT" "Xray"; then
            systemctl restart xray && systemctl enable xray >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active xray)
        else 
            SERVICE_STATUS="config_error"; fi
    else
        CORE_NAME="Sing-box"
        if ! command -v sing-box &> /dev/null; then bash <(curl -fsSL https://sing-box.app/install.sh) > /dev/null 2>&1; fi
        NEW_INBOUND='{"type":"hysteria2","listen":"::","listen_port":'$HY2_PORT',"users":[{"password":"'$HY2_PASS'"}],"tls":{"enabled":true,"server_name":"'$DOMAIN'","certificate_path":"'$CERT_DIR'/fullchain.pem","key_path":"'$CERT_DIR'/privkey.pem"}}'
        
        if append_inbound "/etc/sing-box/config.json" "$NEW_INBOUND" "$HY2_PORT" "Sing-box"; then
            systemctl restart sing-box && systemctl enable sing-box >/dev/null 2>&1; SERVICE_STATUS=$(systemctl is-active sing-box)
        else 
            SERVICE_STATUS="config_error"; fi
    fi
    
    if [ "$SERVICE_STATUS" == "active" ]; then
        echo -e "\n${GREEN}🎉 Hysteria2 部署成功！${NC}"
        LINK="hy2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}?sni=${DOMAIN}&insecure=0#${CORE_NAME}-Hys2"
        echo -e "${CYAN}${LINK}${NC}\n"
        qrencode -t UTF8 -m 1 "$LINK"
        echo "${CORE_NAME}-Hys2 | 端口:${HY2_PORT} | ${LINK}" >> "$NODE_RECORD_FILE"
    else
        echo -e "\n${RED}[错误] 配置拒绝启动，未保存任何变更！${NC}"
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
        echo -e "  ${GREEN}4.${NC} 开启防火墙 (系统会自动防呆，强制放行当前 SSH 端口)"
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
                if ! confirm_action "开启防火墙并自动放行 SSH 端口"; then continue; fi
                # 修复：防止多行配置带来的 UFW 报错锁死
                CURRENT_SSH_PORT=$(ss -tlnp | grep -w sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
                [ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
                [ -z "$CURRENT_SSH_PORT" ] && CURRENT_SSH_PORT=22
                
                echo -e "\n${YELLOW}为防止你与服务器失联，正在强制放行当前 SSH 端口 ($CURRENT_SSH_PORT)...${NC}"
                ufw allow "$CURRENT_SSH_PORT"/tcp
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
#                       附加维护模块
# =========================================================

update_script() {
    clear; print_divider; echo -e "       一键更新 VPSBox 脚本自身    "; print_divider
    if ! confirm_action "从 GitHub 拉取最新版 VPSBox 并覆盖当前脚本"; then pause_for_enter; return; fi

    echo -e "\n${CYAN}>>> 正在连接 GitHub 下载最新版本...${NC}"
    curl -sL "https://raw.githubusercontent.com/8088892/VPSBox/main/vpsbox.sh" -o /tmp/vpsbox_update.sh

    if [ -f /tmp/vpsbox_update.sh ] && grep -q "VPSBox" /tmp/vpsbox_update.sh; then
        mv /tmp/vpsbox_update.sh "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
        echo -e "\n${GREEN}✅ VPSBox 已成功更新到最新版本！即将自动重启脚本...${NC}"
        sleep 2
        exec "$SHORTCUT_PATH"
    else
        echo -e "\n${RED}[错误] 下载失败或获取到的文件异常，原脚本未作更改，请稍后重试。${NC}"
        rm -f /tmp/vpsbox_update.sh
        pause_for_enter
    fi
}

uninstall_vpsbox() {
    print_separator
    echo -e "${YELLOW}【警告】此操作将彻底删除 VPSBox 的快捷命令、本地备份及所有缓存日志。${NC}"
    if ! confirm_action "彻底卸载 VPSBox"; then return; fi
    
    rm -f /usr/local/bin/vpsbox
    rm -rf /etc/vpsbox_backups
    rm -f "$NODE_RECORD_FILE"
    rm -f "$INSTALL_LOG"
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
    echo -e "${PURPLE}           🌟 VPS Box 全能服务器管家与部署工具箱 v2.5.0 🌟${NC}"
    print_divider
    
    echo -e "  公网 IP  : ${YELLOW}${SERVER_IP} ${CYAN}[${IP_FORMAT}]${NC}"
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
    echo -e "  ${GREEN}10.${NC} 动态 TCP 自动调优注入         ${YELLOW}(智能动态适应，提升吞吐)${NC}"
    echo -e "  ${GREEN}11.${NC} 网络调优参数备份/还原管理\n  ${GREEN}12.${NC} BBR 拥塞控制智能管理中心      ${YELLOW}[支持 Google BBRv3]${NC}"
    
    echo -e "\n  ${CYAN}【流媒体检测与节点防冲突部署】${NC}"
    echo -e "  ${GREEN}13.${NC} ip质量检测与流媒体解锁"
    echo -e "  ${GREEN}14.${NC} 部署 VLESS-Reality            ${YELLOW}(直连低延迟 / 强力防封锁)${NC}"
    echo -e "  ${GREEN}15.${NC} 部署 VLESS-WS-TLS             ${YELLOW}(套 CDN 优选 IP / 拯救被墙机器)${NC}"
    echo -e "  ${GREEN}16.${NC} 部署 Hysteria2                ${YELLOW}(UDP 暴力发包 / 抢占高带宽)${NC}"
    echo -e "  ${GREEN}17.${NC} 查看已部署节点与备份管理"
    echo -e "  ${GREEN}18.${NC} 删除指定的已部署节点"
    
    echo -e "\n  ${CYAN}【附加实用工具与安全拓展】${NC}"
    echo -e "  ${GREEN}19.${NC} Cloudflare WARP 一键解锁      ${YELLOW}(获取干净 IP / 规避验证码)${NC}"
    echo -e "  ${GREEN}20.${NC} UFW 防火墙简单端口管理        ${YELLOW}(防呆管理 / 一键放行端口)${NC}"
    echo -e "  ${GREEN}21.${NC} 一键更新 VPSBox 脚本自身"
    echo -e "  ${RED}99.${NC} 彻底卸载 VPSBox 及系统残留"

    print_separator
    echo -e "  ${GREEN}0.${NC} 安全退出"
    print_divider
    echo ""
    read -r -p "▶ 请输入选择 [0-21, 99]: " OPTION
    OPTION="${OPTION// /}" 
    
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
        10) apply_tuning ;;
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
        21) update_script ;;
        99) uninstall_vpsbox ;;
        0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}[提示] 编号不存在！${NC}"; sleep 1 ;;
    esac
done
