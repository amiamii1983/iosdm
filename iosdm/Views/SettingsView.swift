import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var completedBytes: Int64 = 0
    @State private var partialBytes: Int64 = 0
    @State private var showClearCompletedDialog = false
    @State private var showProxySheet = false

    @State private var isCheckingUpdate = false
    @State private var updateOutcome: UpdateCheckOutcome?
    @State private var showUpdateAlert = false
    @State private var queuedUpdateToast = false

    var body: some View {
        CompatNavigationStack {
            Form {
                Section("网络代理") {
                    Button {
                        showProxySheet = true
                    } label: {
                        HStack {
                            Label("代理设置", systemImage: "network")
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
                    Picker("下载加速线程", selection: $settings.defaultThreadCount) {
                        ForEach(AppSettings.supportedThreadCounts, id: \.self) { count in
                            Text(count == 4 ? "4 线程（推荐）" : "\(count) 线程").tag(count)
                        }
                    }

                    Stepper("同时下载数量：\(settings.maxConcurrentTasks)", value: $settings.maxConcurrentTasks, in: 1...4)

                    Toggle("允许流量下载", isOn: $settings.allowsCellularAccess)
                    Toggle("下载时保持亮屏", isOn: $settings.keepScreenAwakeWhileDownloading)
                    Toggle("切回软件自动继续下载", isOn: $settings.autoResumeOnForeground)
                } header: {
                    Text("下载设置")
                } footer: {
                    Text("无下载任务时不会在后台耗电。下载完成后点开文件即可预览、保存到「文件」App 或分享。")
                }

                Section("存储空间") {
                    CompatLabeledRow(title: "已下载文件", value: ByteFormatter.formatBytes(completedBytes))
                    CompatLabeledRow(title: "临时缓存", value: ByteFormatter.formatBytes(partialBytes))

                    Button(role: .destructive) {
                        showClearCompletedDialog = true
                    } label: {
                        Label("清空已完成记录", systemImage: "trash")
                    }
                }

                Section("关于 iosdm") {
                    CompatLabeledRow(title: "当前版本", value: "v\(UpdateChecker.currentAppVersion)")

                    Button {
                        runManualUpdateCheck()
                    } label: {
                        HStack {
                            if isCheckingUpdate {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("正在检查更新...")
                            } else {
                                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .disabled(isCheckingUpdate)
                }
            }
            .navigationTitle("设置")
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
            .confirmationDialog("清空已完成记录", isPresented: $showClearCompletedDialog, titleVisibility: .visible) {
                Button("仅清空列表（保留文件）") {
                    manager.clearCompletedTasks(deleteFiles: false)
                    refreshStorageStats()
                }
                Button("清空列表并删除文件", role: .destructive) {
                    manager.clearCompletedTasks(deleteFiles: true)
                    refreshStorageStats()
                }
                Button("取消", role: .cancel) {}
            }
            .alert("已开始下载新版", isPresented: $queuedUpdateToast) {
                Button("好", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("新版 iosdm 安装包已加入下载列表。")
            }
            .alert(updateAlertTitle, isPresented: $showUpdateAlert) {
                if case .updateAvailable(_, _, let releaseURL, let directIPAURL) = updateOutcome {
                    if let directIPAURL {
                        Button("直接下载新版 IPA") {
                            _ = try? manager.addDownload(urlString: directIPAURL.absoluteString, startImmediately: true)
                            queuedUpdateToast = true
                        }
                    }
                    Button("打开下载页面") {
                        openURL(releaseURL)
                    }
                    Button("暂不更新", role: .cancel) {}
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
            return "当前 iosdm v\(current) 已是最新。"
        case .updateAvailable(_, let notes, _, _):
            return notes.isEmpty ? "已有新版 iosdm 可供更新。" : notes
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
