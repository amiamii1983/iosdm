import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var completedBytes: Int64 = 0
    @State private var partialBytes: Int64 = 0
    @State private var showClearCompletedDialog = false
    @State private var cleanedToast = false
    @State private var showProxySheet = false
    @State private var showFolderPicker = false
    @State private var folderErrorMessage: String?

    // On-demand manual update check state (zero automatic requests)
    @State private var isCheckingUpdate = false
    @State private var updateOutcome: UpdateCheckOutcome?
    @State private var showUpdateAlert = false
    @State private var queuedUpdateToast = false

    var body: some View {
        CompatNavigationStack {
            Form {
                Section("网络代理（自动 / 手动分流）") {
                    Button {
                        showProxySheet = true
                    } label: {
                        HStack {
                            Label("代理设置与状态检测", systemImage: "network")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(settings.proxySettings.mode.shortTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    CompatLabeledRow(
                        title: "当前保存位置",
                        value: DeviceStorageText.currentDirectorySummary(customFolderName: settings.customDownloadFolderName)
                    )

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("选择自定义下载目录...", systemImage: "folder.badge.plus")
                    }

                    if settings.customDownloadBookmarkData != nil {
                        Button(role: .destructive) {
                            settings.clearCustomDownloadFolder()
                        } label: {
                            Label("恢复默认保存目录", systemImage: "arrow.uturn.backward")
                        }
                    }
                } header: {
                    Text("下载保存目录")
                } footer: {
                    if StoragePaths.isRunningInLiveContainer {
                        Text("选择目录时请点进具体子文件夹后再点右上角「打开」确认。检测到运行在 LiveContainer 内，若无法授予外部目录写入权限，可直接在已下载文件的详情页使用「另存到『文件』App」一键保存到「\(DeviceStorageText.deviceContainerName) / 下载」。")
                    } else {
                        Text("默认保存在「文件」App -> \(DeviceStorageText.deviceContainerName) -> iosdm；选择自选目录时请点进具体子文件夹再点右上角「打开」确认。若自定义目录暂不可用，将自动回退默认目录保存以防丢失。")
                    }
                }

                Section {
                    Picker("默认分片线程数", selection: $settings.defaultThreadCount) {
                        ForEach(AppSettings.supportedThreadCounts, id: \.self) { count in
                            Text("\(count) 线程").tag(count)
                        }
                    }

                    Stepper("最大同时下载任务：\(settings.maxConcurrentTasks)", value: $settings.maxConcurrentTasks, in: 1...4)

                    Toggle("显示下载监视悬浮小窗", isOn: $settings.showFloatingMonitor)
                    Toggle("允许使用蜂窝移动网络", isOn: $settings.allowsCellularAccess)
                    Toggle("下载时保持屏幕常亮", isOn: $settings.keepScreenAwakeWhileDownloading)
                    Toggle("回到前台自动续传中断任务", isOn: $settings.autoResumeOnForeground)
                } header: {
                    Text("iosdm 下载引擎")
                } footer: {
                    Text("悬浮监视小窗默认关闭；手动开启后仅在下载时显示极简百分比与网速，无下载自动隐藏，保持低耗电。空闲时零后台轮询。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认 User-Agent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        CompatMultilineField(
                            placeholder: "User-Agent",
                            text: $settings.defaultUserAgent,
                            minLines: 2,
                            maxLines: 4
                        )
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    }

                    Button("恢复默认标准浏览器 User-Agent") {
                        settings.defaultUserAgent = AppSettings.fallbackUserAgent
                    }
                } header: {
                    Text("网络请求头")
                }

                Section("存储管理") {
                    CompatLabeledRow(title: "默认目录已完成占用", value: ByteFormatter.formatBytes(completedBytes))
                    CompatLabeledRow(title: "未完成分片缓存", value: ByteFormatter.formatBytes(partialBytes))

                    Button {
                        manager.clearOrphanPartialFiles()
                        refreshStorageStats()
                        cleanedToast = true
                    } label: {
                        Label("清理孤立临时缓存", systemImage: "sparkles")
                    }

                    Button(role: .destructive) {
                        showClearCompletedDialog = true
                    } label: {
                        Label("清空已完成任务", systemImage: "trash")
                    }
                }

                Section {
                    CompatLabeledRow(title: "版本", value: UpdateChecker.currentAppVersion)
                    CompatLabeledRow(title: "最低系统支持", value: "iOS / iPadOS 15.0+")
                    CompatLabeledRow(title: "支持协议", value: "HTTP / HTTPS / 热门海外网盘")
                    CompatLabeledRow(title: "核心特性", value: "多线程分片 · 断点续传 · 轻量低耗 · 代理分流")

                    Button {
                        runManualUpdateCheck()
                    } label: {
                        HStack {
                            if isCheckingUpdate {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("正在检查 GitHub 最新版本...")
                            } else {
                                Label("手动检查更新", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .disabled(isCheckingUpdate)
                } header: {
                    Text("关于 iosdm")
                } footer: {
                    Text("仅在您主动点击「检查更新」时请求 GitHub 公开版本信息，后台不自动联网检查。")
                }
            }
            .navigationTitle("iosdm 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                refreshStorageStats()
            }
            .sheet(isPresented: $showProxySheet) {
                ProxySettingsView()
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try settings.setCustomDownloadFolder(url: url)
                    } catch {
                        folderErrorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    folderErrorMessage = "无法打开所选目录：\(error.localizedDescription)"
                }
            }
            .confirmationDialog("清空已完成任务", isPresented: $showClearCompletedDialog, titleVisibility: .visible) {
                Button("仅清空记录（保留本地文件）") {
                    manager.clearCompletedTasks(deleteFiles: false)
                    refreshStorageStats()
                }
                Button("清空记录并删除本地文件", role: .destructive) {
                    manager.clearCompletedTasks(deleteFiles: true)
                    refreshStorageStats()
                }
                Button("取消", role: .cancel) {}
            }
            .alert("清理完成", isPresented: $cleanedToast) {
                Button("好", role: .cancel) {}
            } message: {
                Text("已清理无关联的临时分片文件。")
            }
            .alert("设置目录失败", isPresented: Binding(
                get: { folderErrorMessage != nil },
                set: { if !$0 { folderErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(folderErrorMessage ?? "")
            }
            .alert("已添加到下载队列", isPresented: $queuedUpdateToast) {
                Button("好", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("新版 iosdm 安装包已加入下载列表，完成后可直接导入更新。")
            }
            .alert(updateAlertTitle, isPresented: $showUpdateAlert) {
                if case .updateAvailable(_, _, let releaseURL, let directIPAURL) = updateOutcome {
                    if let directIPAURL {
                        Button("用 iosdm 直接下载新版 IPA") {
                            _ = try? manager.addDownload(urlString: directIPAURL.absoluteString, startImmediately: true)
                            queuedUpdateToast = true
                        }
                    }
                    Button("前往 GitHub 页面") {
                        openURL(releaseURL)
                    }
                    Button("稍后", role: .cancel) {}
                } else {
                    Button("好", role: .cancel) {}
                }
            } message: {
                Text(updateAlertMessage)
            }
        }
    }

    private var updateAlertTitle: String {
        switch updateOutcome {
        case .upToDate: return "已是最新版本"
        case .updateAvailable(let latest, _, _, _): return "发现新版本 v\(latest)"
        case .failed: return "检查更新失败"
        case .none: return ""
        }
    }

    private var updateAlertMessage: String {
        switch updateOutcome {
        case .upToDate(let current):
            return "当前版本 iosdm v\(current) 已是最新。"
        case .updateAvailable(_, let notes, _, _):
            return notes.isEmpty ? "GitHub 仓库已发布新版 iosdm 安装包。" : notes
        case .failed(let msg):
            return msg
        case .none:
            return ""
        }
    }

    private func runManualUpdateCheck() {
        isCheckingUpdate = true
        let proxySnapshot = settings.proxySettings
        let isPad = DeviceStorageText.isPad
        Task {
            let result = await UpdateChecker.checkForUpdates(
                currentVersion: UpdateChecker.currentAppVersion,
                isPad: isPad,
                proxySettings: proxySnapshot
            )
            await MainActor.run {
                isCheckingUpdate = false
                updateOutcome = result
                showUpdateAlert = true
            }
        }
    }

    private func refreshStorageStats() {
        completedBytes = manager.storage.completedStorageBytes()
        partialBytes = manager.storage.partialStorageBytes()
    }
}
