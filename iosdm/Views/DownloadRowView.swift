import SwiftUI

struct DownloadRowView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let task: DownloadTaskModel
    let completedFileURL: URL?
    let onPrimaryAction: () -> Void

    private var iconBoxSize: CGFloat {
        horizontalSizeClass == .compact ? 40 : 44
    }

    var body: some View {
        HStack(spacing: horizontalSizeClass == .compact ? 10 : 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FileIconHelper.tintColor(for: task.status).opacity(0.14))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: FileIconHelper.symbolName(for: task.fileName))
                    .font(.system(size: horizontalSizeClass == .compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(FileIconHelper.tintColor(for: task.status))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(task.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    statusBadge
                }

                if task.status != .completed {
                    if task.status == .probing || (task.status == .downloading && task.totalBytes < 0) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    } else {
                        SegmentProgressStrip(
                            segments: task.segments,
                            overallProgress: task.progress,
                            isCompleted: false,
                            height: 6
                        )
                    }
                }

                metricsLine
            }

            actionButton
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(task.status.displayTitle)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(FileIconHelper.tintColor(for: task.status).opacity(0.14))
            .foregroundStyle(FileIconHelper.tintColor(for: task.status))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var metricsLine: some View {
        switch task.status {
        case .downloading:
            HStack(spacing: 6) {
                if task.totalBytes > 0 {
                    Text("\(ByteFormatter.formatBytes(task.downloadedBytes)) / \(ByteFormatter.formatBytes(task.totalBytes))")
                    Text("·")
                    Text("\(Int((task.progress * 100).rounded()))%")
                } else {
                    Text("已下载 \(ByteFormatter.formatBytes(task.downloadedBytes))")
                }
                Spacer(minLength: 4)
                Text(ByteFormatter.formatSpeed(task.speedBytesPerSec))
                    .foregroundStyle(.blue)
                    .fontWeight(.medium)
                if let eta = task.etaSeconds {
                    Text("· \(ByteFormatter.formatETA(eta))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

        case .probing:
            Text("正在连接服务器并检测断点续传能力...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .queued:
            Text("等待空闲下载通道...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .paused:
            HStack(spacing: 6) {
                if task.totalBytes > 0 {
                    Text("\(ByteFormatter.formatBytes(task.downloadedBytes)) / \(ByteFormatter.formatBytes(task.totalBytes))")
                    Text("·")
                    Text("\(Int((task.progress * 100).rounded()))%")
                } else if task.downloadedBytes > 0 {
                    Text("已下载 \(ByteFormatter.formatBytes(task.downloadedBytes))")
                } else {
                    Text("尚未开始")
                }
                Spacer(minLength: 4)
                Text(task.supportsRange ? "可续传" : "需重下")
                    .foregroundStyle(task.supportsRange ? .green : .orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

        case .completed:
            HStack(spacing: 6) {
                Text(ByteFormatter.formatBytes(task.totalBytes))
                if let completedAt = task.completedAt {
                    Text("·")
                    Text(completedAt, style: .date)
                    Text(completedAt, style: .time)
                }
                Spacer(minLength: 4)
                if task.segments.count > 1 {
                    Text("\(task.segments.count)线程")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

        case .failed:
            Text(task.errorMessage ?? "下载失败，点击右侧重试")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch task.status {
        case .downloading, .probing, .queued:
            Button(action: onPrimaryAction) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂停")

        case .paused:
            Button(action: onPrimaryAction) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("继续下载")

        case .failed:
            Button(action: onPrimaryAction) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试")

        case .completed:
            if let fileURL = completedFileURL {
                ShareLink(
                    item: fileURL,
                    preview: SharePreview(
                        task.fileName,
                        image: Image(systemName: FileIconHelper.symbolName(for: task.fileName))
                    )
                ) {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享或导出")
            } else {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .accessibilityLabel("本地文件不存在")
            }
        }
    }
}
