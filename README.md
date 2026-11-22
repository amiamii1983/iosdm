# iosdm

轻量、简洁的原生 iOS / iPadOS 多线程断点续传下载器（支持 **iOS / iPadOS 15.0+** 至最新系统）。

## 功能特点

- **HTTP / HTTPS 断点续传**：多线程分片加速、随时暂停恢复、重启不丢进度。
- **海外网盘直链解析**：支持 MediaFire、Google Drive、Dropbox、Pixeldrain、Gofile、OneDrive、GitHub，自动拦截误下网页。
- **代理与国内外分流**：支持自动跟随系统 / VPN 代理软件（Shadowrocket、Surge、Quantumult X、Loon、Clash 等），也支持手动配置 HTTP / SOCKS5 与国内直连分流。
- **轻量省电 & 导出方便**：空闲零后台耗电；下载完成后可直接在 App 内预览、一键保存到「文件」App 或分享给其他应用。

## 下载安装包

前往 [Releases](https://github.com/amiamii1983/iosdm/releases) 下载未签名 `.ipa`：
- `iosdm-iPhone.ipa`：iPhone 手机专用版
- `iosdm.ipa`：iPhone + iPad 通用版

## 安装方式

### 方式一：LiveContainer + SideStore 稳定版（推荐）

1. 电脑端用 **iLoader** 连接设备安装 **LiveContainer + SideStore 稳定版**，并在设备「设置 -> 通用 -> VPN 与设备管理」信任证书（按需开启开发者模式）。
2. 设备安装 **LocalDevVPN**，配置并开启连接：
   - **通道 IP**：`10.7.0.0/24`
   - **装置 IP**：`10.7.0.255/24`
3. 在 SideStore / LiveContainer 中完成登录与刷新后，导入 `iosdm.ipa` 或 `iosdm-iPhone.ipa` 即可使用。
4. 刷新完毕后，下载国外网盘时切回常用代理软件并保持 iosdm 默认「自动代理」即可。

### 方式二：其他方式

- **TrollStore（巨魔商店）**：直接导入 `.ipa` 安装。
- **其他工具**：使用 Sideloadly、AltStore、爱思助手或 Xcode 签名安装。

## 本地构建

```bash
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```
