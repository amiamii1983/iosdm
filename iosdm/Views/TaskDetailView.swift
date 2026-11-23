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
                    if task.segments.count > 1 && task.status != .completed {
                        segmentsSection(task)
                    }
                    infoSection(task)
                    dangerSection(task)
                }
                .listStyle(.insetGrouped)
                .navigationTitle("任务详情")
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
                    Text("已将文件保存到您选择的文件夹。")
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
                    Button("删除任务及文件", role: .destructive) {
                        manager.deleteTask(taskId: task.id, deleteLocalFile: true)
                        if let onDeleted {
                            onDeleted()
                        } else {
                            dismiss()
                        }
                    }
                    if task.status == .completed {
                        Button("仅移除记录（保留文件）") {
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
                            .frame(width: 48, height: 48)
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
                            pill(task.isResumableDisplayText, color: task.supportsRange ? .green : .orange)
                            if let provider = task.cloudProvider {
                                pill(provider, color: .purple)
                            }
                        }
                    }
                }

                SegmentProgressStrip(
                    segments: task.segments,
                    overallProgress: task.progress,
                    isCompleted: task.status == .completed,
                    height: 10
                )

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件大小")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if task.totalBytes >= 0 {
                            Text("\(ByteFormatter.formatBytes(task.downloadedBytes)) / \(ByteFormatter.formatBytes(task.totalBytes))")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        } else {
                            Text(ByteFormatter.formatBytes(task.downloadedBytes))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(task.status == .downloading ? "速度 · 剩余时间" : "进度")
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
                    Label(task.supportsRange ? "继续下载" : "重新下载", systemImage: "play.fill")
                }
            }

            if task.status == .completed {
                let fileURL = manager.completedFileURL(for: task)
                let exists = manager.completedFileExists(for: task)

                Button {
                    showPreview = true
                } label: {
                    Label("预览文件", systemImage: "eye.fill")
                }
                .disabled(!exists)

                Button {
                    showExportPicker = true
                } label: {
                    Label("保存到「文件」App", systemImage: "folder.badge.plus")
                }
                .disabled(!exists)

                if let fileURL, exists {
                    CompatShareButton(
                        fileURL: fileURL,
                        fileName: task.fileName,
                        symbolName: FileIconHelper.symbolName(for: task.fileName)
                    ) {
                        Label("分享给其他应用", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("分享给其他应用", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }

                Button {
                    renameText = task.savedFileName ?? task.fileName
                    showRenameSheet = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                .disabled(!exists)

                if !exists {
                    Text("本地文件已被移除，可点击下方重新下载。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if task.status != .probing && task.status != .downloading {
                Button {
                    manager.restartFromBeginning(taskId: task.id)
                } label: {
                    Label("重新下载", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func segmentsSection(_ task: DownloadTaskModel) -> some View {
        Section(segmentSectionTitle(task)) {
            ForEach(task.segments) { seg in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("线程 #\(seg.id + 1)")
                            .font(.subheadline.weight(.medium))
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

                    if let segErr = seg.errorMessage, !segErr.isEmpty {
                        Text(segErr)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func infoSection(_ task: DownloadTaskModel) -> some View {
        Section("任务信息") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("下载链接")
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
                        Label(copiedToast ? "已复制" : "复制链接", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(task.originalURL)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            if let provider = task.cloudProvider {
                CompatLabeledRow(title: "来源网盘", value: provider)
            }

            CompatLabeledRow(title: "使用代理", value: manager.effectiveProxySettings(for: task).mode.shortTitle)
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

    private func segmentSectionTitle(_ task: DownloadTaskModel) -> String {
        if task.status == .downloading && task.adaptiveConcurrencyLimit > 0 {
            if task.isAdaptiveThrottled {
                return "分片进度（智能防限流 \(task.adaptiveConcurrencyLimit)/\(task.requestedThreadCount) 线程）"
            }
            return "分片进度（智能并发 \(task.adaptiveConcurrencyLimit)/\(task.requestedThreadCount) 线程）"
        }
        return "分片进度（\(task.segments.count) 分片）"
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
                    Text("将同步重命名本地文件。")
                }
            }
            .navigationTitle("重命名")
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
