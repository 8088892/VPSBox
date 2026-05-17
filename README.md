# 🖥️ VPSBox — 全能服务器管家

一键搞定 VPS 系统优化、BBR 调优、代理节点部署、防火墙管理。

```bash
bash <(curl -sL https://raw.githubusercontent.com/vmenzo/VPSBox/main/vpsbox.sh)
```

---

## 📋 功能菜单

### 基础系统管理与安全防护
| # | 功能 | 说明 |
|---|------|------|
| 1 | 系统概览 | CPU/内存/磁盘/网络流量/BBR/核心状态 |
| 2 | 系统更新 | 更新软件源 + 升级系统组件 + 安装必备工具 |
| 3 | 系统清理 | 卸载旧依赖 + 清理缓存 + 清理 7 天前日志 |
| 4 | 修改 root 密码 | 交互式密码修改，支持重试 |
| 5 | SSH 安全管理 | 添加/删除公钥、禁用/开启密码登录 |
| 6 | 修改主机名 | 支持字母数字连字符 |
| 7 | 时区设置 | 一键设为北京时间 (Asia/Shanghai) |
| 8 | Swap 管理 | 创建/修改/关闭虚拟内存 |
| 9 | DNS 优化 | 替换为 1.1.1.1 + 8.8.8.8，智能兼容 systemd-resolved |
| 10 | 修改 SSH 端口 | 支持 22 + 1025-65534，自动放行警告 |

### 网络协议与性能优化
| # | 功能 | 说明 |
|---|------|------|
| 11 | TCP 智能调优 | 自研 AWK 引擎，输入带宽/延迟/爬升曲线，自动计算最优参数 |
| 12 | 参数备份管理 | 备份/还原/删除 sysctl 调优参数 |
| 13 | BBR 管理中心 | 一键开启 BBRv1 / 安装 BBRv3 (XanMod) / 卸载回退 |

### 节点部署
| # | 功能 | 说明 |
|---|------|------|
| 14 | IP 质量检测 | 流媒体解锁检测 (Check.Place) |
| 15 | VLESS-Reality | 无需域名，借用大厂 SNI，防封锁 |
| 16 | VLESS-WS-TLS | 支持 CDN，被墙 IP 可"起死回生" |
| 17 | Hysteria2 | UDP 暴力加速，晚高峰拉满带宽 |
| 18 | 节点管理 | 查看已部署节点 / 二维码 / 备份还原 |
| 19 | 删除节点 | 按端口号移除 Xray / Sing-box 节点 |

### 附加工具
| # | 功能 | 说明 |
|---|------|------|
| 20 | Docker 安装 | Docker CE + Compose，智能适配 Debian/Ubuntu 版本代号 |
| 21 | Fail2Ban | SSH 防暴力破解，3 次失败封 24 小时 |
| 22 | Cloudflare WARP | 一键解锁流媒体 |
| 23 | UFW 防火墙 | 查看/放行/删除端口，一键仅放行占用端口 |
| 24 | 脚本管理 | 检查更新 + 一键卸载 |

---

## ✨ 特色亮点

- **兼容 Debian / Ubuntu**，自动识别系统差异
- **支持 Xray-core 和 Sing-box 双内核**，部署时自由选择
- **自研 TCP 动态调优引擎** — 纯 AWK 实现，无 Python 依赖，输入带宽/延迟自动计算最优内核参数
- **BBRv3 安装**，CPU 无 AVX2 时自动降级 x64v2
- **Reality / WS-TLS / Hysteria2** 三种协议支持
- **配置校验机制** — 部署前先用 `xray run -test` / `sing-box check` 验证配置合法性
- **智能 DNS** — 自动检测 systemd-resolved 避免冲突
- **Oracle Cloud 兼容** — 安装 UFW 时自动清理 REJECT 规则
- **安全防护** — 危险操作默认 n（删除密钥、卸载、关闭防火墙）

---

## 🚀 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/8088892/VPSBox/main/vpsbox.sh)
```

安装后可通过 `vpsbox` 命令随时打开。

---

## 📌 要求

- **系统**: Debian 11+ / Ubuntu 20.04+
- **权限**: root
- **架构**: x86_64 / ARM64

---

## 🔄 更新

在菜单中选 **24 → 1** 即可从 GitHub 拉取最新版本。

---

## 📜 许可证

MIT
