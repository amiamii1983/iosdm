import SwiftUI

/// Minimalist, low-power floating download monitor inside iosdm.
/// Disabled by default; only renders when enabled in Settings AND at least one task is actively downloading.
struct DownloadMonitorOverlay: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings

    @State private var isExpanded = false
    @State private var committedOffset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero

    private var activeTasks: [DownloadTaskModel] {
        manager.tasks.filter { $0.status == .downloading || $0.status == .probing }
    }

    private var aggregateProgress: Double {
        let knownTasks = activeTasks.filter { $0.totalBytes > 0 }
        guard !knownTasks.isEmpty else { return 0 }
        let totalExpected = knownTasks.reduce(Int64(0)) { $0 + $1.totalBytes }
        let totalDownloaded = knownTasks.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        guard totalExpected > 0 else { return 0 }
        return min(1.0, max(0.0, Double(totalDownloaded) / Double(totalExpected)))
    }

    private var hasKnownProgress: Bool {
        activeTasks.contains { $0.totalBytes > 0 }
    }

    var body: some View {
        if settings.showFloatingMonitor && !activeTasks.isEmpty {
            Group {
                if isExpanded {
                    expandedCard
                } else {
                    compactCapsule
                }
            }
            .offset(
                x: committedOffset.width + dragDelta.width,
                y: committedOffset.height + dragDelta.height
            )
            .gesture(
                DragGesture()
                    .updating($dragDelta) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let nextX = max(-220, min(20, committedOffset.width + value.translation.width))
                        let nextY = max(-360, min(20, committedOffset.height + value.translation.height))
                        committedOffset = CGSize(width: nextX, height: nextY)
                    }
            )
            .padding(.trailing, 14)
            .padding(.bottom, 16)
            .transition(.opacity)
        }
    }

    private var compactCapsule: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.22), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: hasKnownProgress ? aggregateProgress : 0.25)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(hasKnownProgress ? String(format: "%.1f%%", aggregateProgress * 100) : "下载中")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)
                    Text(ByteFormatter.formatSpeed(manager.totalSpeedBytesPerSec))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.blue)
                }

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("iosdm 下载监视小窗")
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("iosdm 监视 (\(activeTasks.count))")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(ByteFormatter.formatSpeed(manager.totalSpeedBytesPerSec))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.blue)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(activeTasks.prefix(3)) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.fileName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if task.totalBytes > 0 {
                            Text(String(format: "%.1f%%", task.progress * 100))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        Button {
                            manager.pause(taskId: task.id)
                        } label: {
                            Image(systemName: "pause.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    SegmentProgressStrip(
                        segments: task.segments,
                        overallProgress: task.progress,
                        isCompleted: false,
                        height: 4
                    )
                }
            }
        }
        .padding(12)
        .frame(width: 248)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}
