# iosdm

轻量级原生 iOS / iPadOS 多线程断点续传下载器（纯 Swift / SwiftUI，无第三方重型依赖）。

## 主要特性

- **HTTP / HTTPS 全协议直链下载**：支持 `https://` 与明文 `http://` 直链，自动处理 301/302 重定向、UTF-8 `Content-Disposition` 文件名解析与重名自动去重。
- **多线程分片与断点续传**：支持 `1 / 2 / 4 / 8` 线程并发 `Range` 分片下载，使用 POSIX `pwrite` 按精确偏移直接落盘（无需完成后二次拷贝合并）；支持暂停/恢复、断流自动重试、App 重启恢复断点；遇到不支持 `Range` 的服务器自动降级为单线程下载。
- **国外热门网盘直链解析**：内置 MediaFire（自动解析 `data-scrambled-url` 与失效直链回溯）、Google Drive（含大文件二次确认页）、Dropbox、Pixeldrain、Gofile、OneDrive、GitHub 解析，并具备防误下 `text/html` 网页保护。
- **代理菜单与小火箭适配**：
  - **自动模式**：自动读取并跟随系统与 Shadowrocket（小火箭）等翻墙分流规则，中国网络与国外网络下载互不影响。
  - **手动代理**：支持 HTTP/HTTPS 与 SOCKS5，内置国内域名与局域网直连分流开关及自定义绕过规则。
  - **直连模式**：绕过系统 HTTP 代理直连。
- **轻量低功耗**：空闲时零后台定时轮询、禁用 `URLCache`、低频刷新与落盘，降低手机与 iPad 发热与电量消耗。
- **iPhone 与 iPad 原生适配**：支持 iPhone 单手窄屏布局与 iPadOS 27.2.1 宽屏双栏（`NavigationSplitView`），已完成文件直接显示在系统「文件」App 对应目录中并支持 QuickLook 预览与系统分享导出。

## 版本说明

在 [Releases](https://github.com/amiamii1983/iosdm/releases) 中同时提供两个无签名真机包（最低支持 `iOS / iPadOS 16.0`）：

- `iosdm-iPhone.ipa`：iPhone 手机专用包（`UIDeviceFamily = [1]`）
- `iosdm.ipa`：iPhone + iPadOS 通用包（`UIDeviceFamily = [1, 2]`）

## 安装方式

发布包为未签名 `arm64` IPA，推荐以下安装方案：

### 方案一：LiveContainer + SideStore 稳定版（推荐，适合未越狱 iPhone / iPad）

通过电脑端 **iLoader** 安装 **LiveContainer + SideStore 整合稳定版**，可突破免费 Apple ID 的应用数量限制并在设备本地完成签名与刷新：

1. **电脑端安装 LiveContainer + SideStore 稳定版**
   - 用数据线连接 iPhone / iPad 到电脑并在设备点击「信任此电脑」。
   - 在电脑上打开 **iLoader**，登录 Apple ID 并选择安装 **LiveContainer + SideStore 稳定版**。
   - 安装完成后，前往设备 **设置 -> 通用 -> VPN 与设备管理** 信任对应开发者证书，并在 **设置 -> 隐私与安全性 -> 开发者模式** 中开启开发者模式（按提示重启）。
2. **安装并配置 LocalDevVPN（关键步骤）**
   - 在 iPhone / iPad 上安装 **LocalDevVPN**。
   - 打开 LocalDevVPN 设置，配置以下 IP 参数并保存启用：
     - **通道 IP**：`10.7.0.0/24`
     - **装置 IP**：`10.7.0.255/24`
   - 保持设备连接 Wi-Fi，开启 **LocalDevVPN** 连接。
3. **完成 SideStore / LiveContainer 初始化并导入 iosdm**
   - 打开集成好的 **LiveContainer + SideStore**，在 SideStore 中登录与电脑端一致的 Apple ID，完成证书导入与刷新（Refresh）。
   - 从 [Releases](https://github.com/amiamii1983/iosdm/releases) 下载对应安装包（iPad / 通用选 `iosdm.ipa`，iPhone 专用选 `iosdm-iPhone.ipa`），在 **LiveContainer** 中点击 `+` 导入 `.ipa` 即可运行。

> **小提示（搭配小火箭下载国外网盘）**：iOS / iPadOS 同一时间仅能开启一个 VPN 配置。**LocalDevVPN** 仅在 SideStore 签名、刷新或首次配对时需要开启；刷新完毕后，打开 **iosdm** 下载国外网盘时，直接切回 **Shadowrocket（小火箭）** 并保持 iosdm 默认「自动代理」即可。

### 方案二：其他安装方式

- **TrollStore（巨魔商店）**：直接导入 `.ipa` 即可永久安装。
- **其他侧载 / 自签工具**：可通过 **Sideloadly / AltStore / 爱思助手 / 自有证书** 重签名安装，或使用 Xcode 打开 `iosdm.xcodeproj` 登录 Apple ID 直接安装到设备。

## 本地编译打包

```bash
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

编译产物位于 `dist/iosdm.ipa`（通用版）与 `dist/iosdm-iPhone.ipa`（iPhone 专用版）。
