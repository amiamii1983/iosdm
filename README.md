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

发布包为未签名 `arm64` IPA：
- **TrollStore（巨魔商店）**：直接导入安装即可。
- **未越狱设备**：可使用 **Sideloadly / AltStore / SideStore / 爱思助手 / 自有证书** 重签名安装，或使用 Xcode 打开 `iosdm.xcodeproj` 登录 Apple ID 直接安装到设备。

## 本地编译打包

```bash
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

编译产物位于 `dist/iosdm.ipa`（通用版）与 `dist/iosdm-iPhone.ipa`（iPhone 专用版）。
