import SwiftUI
import UIKit

struct TaskDetailView: View {
    let taskId: UUID
    var onDeleted: (() -> Void)? = nil
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var showPreview = false
    @State private var showExportPicker = false
    @State private var showExportedToast = false
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var showDeleteDialog = false
    @State private var copiedToast = false
    @State private var renameError: String?

    private var task: DownloadTaskModel? {
        manager.tasks.first(where: { $0.id == taskId })
    }

    var body: some View {
        Group {
            if let task {
                List {
                    overviewSection(task)
                    actionsSection(task)
                    if !task.segments.isEmpty {
                        segmentsSection(task)
                    }
                    connectionInfoSection(task)
                    dangerSection(task)
                }
                .listStyle(.insetGrouped)
                .navigationTitle("下载详情")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showPreview) {
                    if let fileURL = manager.completedFileURL(for: task) {
                        QuickLookPreview(url: fileURL)
                            .ignoresSafeArea()
                    }
                }
                .sheet(isPresented: $showExportPicker) {
                    if let fileURL = manager.completedFileURL(for: task) {
                        FileExportPickerView(
                            fileURL: fileURL,
                            onCompleted: {
                                showExportPicker = false
                                showExportedToast = true
                            },
                            onCancel: {
                                showExportPicker = false
                            }
                        )
                    }
                }
                .sheet(isPresented: $showRenameSheet) {
                    RenameFileSheet(
                        initialName: renameText,
                        onSave: { newName in
                            do {
                                try manager.renameCompletedFile(taskId: task.id, newName: newName)
                                showRenameSheet = false
                            } catch {
                                showRenameSheet = false
                                renameError = error.localizedDescription
                            }
                        },
                        onCancel: {
                            showRenameSheet = false
                        }
                    )
                }
                .alert("已保存到「文件」App", isPresented: $showExportedToast) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text("已将文件副本成功导出到您选择的目录。")
                }
                .alert("重命名失败", isPresented: Binding(
                    get: { renameError != nil },
                    set: { if !$0 { renameError = nil } }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(renameError ?? "")
                }
                .confirmationDialog("删除下载任务", isPresented: $showDeleteDialog, titleVisibility: .visible) {
                    Button("删除任务及本地文件", role: .destructive) {
                        manager.deleteTask(taskId: task.id, deleteLocalFile: true)
                        if let onDeleted {
                            onDeleted()
                        } else {
                            dismiss()
                        }
                    }
                    if task.status == .completed {
                        Button("仅移除任务记录（保留文件）") {
                            manager.deleteTask(taskId: task.id, deleteLocalFile: false)
                            if let onDeleted {
                                onDeleted()
                            } else {
                                dismiss()
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                ContentUnavailableViewCompat(
                    title: "任务不存在",
                    subtitle: "该下载任务可能已被删除",
                    systemImage: "tray"
                )
            }
        }
    }

    private func overviewSection(_ task: DownloadTaskModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(FileIconHelper.tintColor(for: task.status).opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: FileIconHelper.symbolName(for: task.fileName))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(FileIconHelper.tintColor(for: task.status))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.fileName)
                            .font(.headline)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            pill(task.status.displayTitle, color: FileIconHelper.tintColor(for: task.status))
                            pill(protocolScheme(task.effectiveURLString), color: .blue)
                            if let provider = task.cloudProvider {
                                pill(provider, color: .purple)
                            }
                            pill(task.isResumableDisplayText, color: task.supportsRange ? .green : .orange)
                        }
                    }
                }

                SegmentProgressStrip(
                    segments: task.segments,
                    overallProgress: task.progress,
                    isCompleted: task.status == .completed,
                    height: 12
                )

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已下载 / 总大小")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if task.totalBytes >= 0 {
                            Text("\(ByteFormatter.formatBytes(task.downloadedBytes)) / \(ByteFormatter.formatBytes(task.totalBytes))")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        } else {
                            Text("\(ByteFormatter.formatBytes(task.downloadedBytes)) / 未知")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(task.status == .downloading ? "实时速度 · 剩余" : "完成进度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if task.status == .downloading {
                            Text("\(ByteFormatter.formatSpeed(task.speedBytesPerSec)) · \(ByteFormatter.formatETA(task.etaSeconds))")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.blue)
                        } else {
                            Text(String(format: "%.1f%%", task.progress * 100))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                    }
                }

                if let errorMessage = task.errorMessage, !errorMessage.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func actionsSection(_ task: DownloadTaskModel) -> some View {
        Section("操作") {
            if task.canPause {
                Button {
                    manager.pause(taskId: task.id)
                } label: {
                    Label("暂停下载", systemImage: "pause.fill")
                }
                .foregroundStyle(.orange)
            }

            if task.canResume {
                Button {
                    manager.startOrResume(taskId: task.id)
                } label: {
                    Label(task.supportsRange ? "断点续传继续" : "重新开始下载", systemImage: "play.fill")
                }
            }

            if task.status == .completed {
                let fileURL = manager.completedFileURL(for: task)
                let exists = manager.completedFileExists(for: task)
                Button {
                    showPreview = true
                } label: {
                    Label("快速预览文件", systemImage: "eye.fill")
                }
                .disabled(!exists)

                Button {
                    showExportPicker = true
                } label: {
                    Label("另存到「文件」App", systemImage: "folder.badge.plus")
                }
                .disabled(!exists)

                if let fileURL, exists {
                    CompatShareButton(
                        fileURL: fileURL,
                        fileName: task.fileName,
                        symbolName: FileIconHelper.symbolName(for: task.fileName),
                        requiresSecurityScope: task.savedInCustomDirectory
                    ) {
                        Label("分享 / 导出到其他应用", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("分享 / 导出到其他应用", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }

                Button {
                    renameText = task.savedFileName ?? task.fileName
                    showRenameSheet = true
                } label: {
                    Label("重命名文件", systemImage: "pencil")
                }
                .disabled(!exists)

                if !exists {
                    Text("本地文件已被外部移动或删除，您可选择重新下载。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if task.status != .probing && task.status != .downloading {
                Button {
                    manager.restartFromBeginning(taskId: task.id)
                } label: {
                    Label("清空进度并从头重下", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func segmentsSection(_ task: DownloadTaskModel) -> some View {
        Section {
            ForEach(task.segments) { seg in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("线程 #\(seg.id + 1)")
                            .font(.subheadline.weight(.semibold))

                        Text(seg.state.displayTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(segmentBadgeColor(seg.state).opacity(0.14))
                            .foregroundStyle(segmentBadgeColor(seg.state))
                            .clipShape(Capsule())

                        Spacer()

                        if seg.state == .downloading {
                            Text(ByteFormatter.formatSpeed(seg.speedBytesPerSec))
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.blue)
                        } else {
                            Text(String(format: "%.1f%%", seg.progress * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    ProgressView(value: seg.progress)
                        .tint(segmentBadgeColor(seg.state))

                    HStack {
                        if seg.hasKnownLength {
                            Text("区间：\(ByteFormatter.formatBytes(seg.startByte)) – \(ByteFormatter.formatBytes(seg.endByte))")
                        } else {
                            Text("流式顺序下载")
                        }
                        Spacer()
                        if seg.hasKnownLength {
                            Text("\(ByteFormatter.formatBytes(seg.downloadedBytes)) / \(ByteFormatter.formatBytes(seg.totalBytes))")
                        } else {
                            Text(ByteFormatter.formatBytes(seg.downloadedBytes))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if let segErr = seg.errorMessage, !segErr.isEmpty {
                        Text(segErr)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("iosdm 分片连接状态（\(task.segments.count) 线程）")
        }
    }

    private func connectionInfoSection(_ task: DownloadTaskModel) -> some View {
        Section("连接与存储信息") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("下载地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = task.originalURL
                        copiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedToast = false
                        }
                    } label: {
                        Label(copiedToast ? "已复制" : "复制", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(task.originalURL)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            if let resolved = task.resolvedURL, resolved != task.originalURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("重定向后地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resolved)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            if task.savedFileName != nil {
                CompatLabeledRow(title: "文件位置", value: DeviceStorageText.savedFileLocation(task: task))
            }

            CompatLabeledRow(title: "代理策略", value: manager.effectiveProxySettings(for: task).mode.displayTitle)

            if let provider = task.cloudProvider {
                CompatLabeledRow(title: "网盘解析", value: provider)
            }

            if let mime = task.mimeType, !mime.isEmpty {
                CompatLabeledRow(title: "MIME 类型", value: mime)
            }

            if let eTag = task.eTag, !eTag.isEmpty {
                CompatLabeledRow(title: "ETag", value: eTag)
            }

            if !task.customHeaders.isEmpty {
                ForEach(task.customHeaders.keys.sorted(), id: \.self) { key in
                    CompatLabeledRow(title: "Header: \(key)", value: task.customHeaders[key] ?? "")
                }
            }
        }
    }

    private func dangerSection(_ task: DownloadTaskModel) -> some View {
        Section {
            Button(role: .destructive) {
                showDeleteDialog = true
            } label: {
                Label("删除任务", systemImage: "trash")
            }
        }
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func protocolScheme(_ urlString: String) -> String {
        URL(string: urlString)?.scheme?.uppercased() ?? "HTTP"
    }

    private func segmentBadgeColor(_ state: SegmentState) -> Color {
        switch state {
        case .downloading: return .blue
        case .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        case .pending: return .gray
        }
    }
}

struct RenameFileSheet: View {
    @State private var nameText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _nameText = State(initialValue: initialName)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    TextField("新文件名", text: $nameText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } footer: {
                    Text("将同步重命名本地已下载的文件。")
                }
            }
            .navigationTitle("重命名文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onSave(nameText)
                    }
                    .disabled(nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct ContentUnavailableViewCompat: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
