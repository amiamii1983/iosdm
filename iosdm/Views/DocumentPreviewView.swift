import SwiftUI
import QuickLook
import UIKit

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissSelf)
        )
        context.coordinator.controller = nav
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        if let ql = uiViewController.viewControllers.first as? QLPreviewController {
            ql.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        weak var controller: UIViewController?

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        @objc func dismissSelf() {
            controller?.dismiss(animated: true)
        }
    }
}

enum DeviceStorageText {
    static var deviceContainerName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "我的 iPad" : "我的 iPhone"
    }

    static func filesAppLocation(fileName: String? = nil) -> String {
        if let fileName, !fileName.isEmpty {
            return "文件 App / \(deviceContainerName) / iosdm / \(fileName)"
        }
        return "「文件」App -> \(deviceContainerName) -> iosdm"
    }
}

/// iosdm multi-segment visual progress bar showing each thread's progress in its exact slice.
struct SegmentProgressStrip: View {
    let segments: [DownloadSegment]
    let overallProgress: Double
    let isCompleted: Bool
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            if isCompleted {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.green)
            } else if segments.count > 1 {
                HStack(spacing: 1.5) {
                    ForEach(segments) { seg in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                            GeometryReader { segGeo in
                                Rectangle()
                                    .fill(segmentColor(for: seg.state))
                                    .frame(width: max(0, segGeo.size.width * seg.progress))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(singleBarColor)
                        .frame(width: max(0, geo.size.width * min(1, max(0, overallProgress))))
                }
            }
        }
        .frame(height: height)
    }

    private var singleBarColor: Color {
        if let state = segments.first?.state {
            return segmentColor(for: state)
        }
        return .accentColor
    }

    private func segmentColor(for state: SegmentState) -> Color {
        switch state {
        case .downloading: return .blue
        case .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        case .pending: return .blue.opacity(0.45)
        }
    }
}

enum FileIconHelper {
    static func symbolName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm", "flv", "m4v", "ts":
            return "film.fill"
        case "mp3", "m4a", "flac", "wav", "aac", "ogg":
            return "music.note"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "svg":
            return "photo.fill"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso":
            return "archivebox.fill"
        case "ipa", "apk", "deb", "exe", "pkg":
            return "shippingbox.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "md", "json", "xml", "csv", "log":
            return "doc.text.fill"
        default:
            return "doc.fill"
        }
    }

    static func tintColor(for status: DownloadTaskStatus) -> Color {
        switch status {
        case .downloading: return .blue
        case .probing, .queued: return .indigo
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}
