import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var completedBytes: Int64 = 0
    @State private var partialBytes: Int64 = 0
    @State private var showClearCompletedDialog = false
    @State private var cleanedToast = false
    @State private var showProxySheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("网络代理（小火箭 / 手动分流）") {
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
                    Picker("默认分片线程数", selection: $settings.defaultThreadCount) {
                        ForEach(AppSettings.supportedThreadCounts, id: \.self) { count in
                            Text("\(count) 线程").tag(count)
                        }
                    }

                    Stepper("最大同时下载任务：\(settings.maxConcurrentTasks)", value: $settings.maxConcurrentTasks, in: 1...4)

                    Toggle("允许使用蜂窝移动网络", isOn: $settings.allowsCellularAccess)
                    Toggle("下载时保持屏幕常亮", isOn: $settings.keepScreenAwakeWhileDownloading)
                    Toggle("回到前台自动续传中断任务", isOn: $settings.autoResumeOnForeground)
                } header: {
                    Text("iosdm 下载引擎")
                } footer: {
                    Text("默认采用轻量 4 线程与低频刷新策略，空闲时零后台轮询，降低设备发热与电量消耗。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认 User-Agent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("User-Agent", text: $settings.defaultUserAgent, axis: .vertical)
                            .lineLimit(2...4)
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

                Section {
                    LabeledContent("已完成文件占用", value: ByteFormatter.formatBytes(completedBytes))
                    LabeledContent("未完成分片缓存", value: ByteFormatter.formatBytes(partialBytes))

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
                } header: {
                    Text("存储管理")
                } footer: {
                    Text("所有下载完成的文件均保存在系统的\(DeviceStorageText.filesAppLocation()) 目录中，可直接访问或 AirDrop 传出。")
                }

                Section("关于 iosdm") {
                    LabeledContent("版本", value: "1.1.0")
                    LabeledContent("支持协议", value: "HTTP / HTTPS / 热门海外网盘")
                    LabeledContent("核心特性", value: "多线程分片 · 断点续传 · 轻量低耗 · 代理分流")
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
        }
    }

    private func refreshStorageStats() {
        completedBytes = manager.storage.completedStorageBytes()
        partialBytes = manager.storage.partialStorageBytes()
    }
}
