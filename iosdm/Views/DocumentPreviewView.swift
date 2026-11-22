import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

// MARK: - QuickLook Preview (supports security-scoped external files)

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
        context.coordinator.updateURL(url)
        if let ql = uiViewController.viewControllers.first as? QLPreviewController {
            ql.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private var url: URL
        private var isAccessingSecurityScope = false
        weak var controller: UIViewController?

        init(url: URL) {
            self.url = url
            self.isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
            super.init()
        }

        deinit {
            if isAccessingSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        func updateURL(_ newURL: URL) {
            guard newURL != url else { return }
            if isAccessingSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            url = newURL
            isAccessingSecurityScope = newURL.startAccessingSecurityScopedResource()
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

// MARK: - Export Single File to Apple Files App (works reliably even inside LiveContainer)

struct FileExportPickerView: UIViewControllerRepresentable {
    let fileURL: URL
    let onCompleted: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onCompleted: onCompleted, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let fileURL: URL
        private var isAccessing = false
        let onCompleted: () -> Void
        let onCancel: () -> Void

        init(fileURL: URL, onCompleted: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.fileURL = fileURL
            self.isAccessing = fileURL.startAccessingSecurityScopedResource()
            self.onCompleted = onCompleted
            self.onCancel = onCancel
            super.init()
        }

        deinit {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
                isAccessing = false
            }
            onCompleted()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
                isAccessing = false
            }
            onCancel()
        }
    }
}

// MARK: - iOS 15+ SwiftUI Compatibility Wrappers

struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct CompatLabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct CompatMultilineField: View {
    let placeholder: String
    @Binding var text: String
    var minLines: Int = 2
    var maxLines: Int = 4

    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(minLines...maxLines)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

struct CompatShareButton<Label: View>: View {
    let fileURL: URL
    let fileName: String
    let symbolName: String
    var requiresSecurityScope: Bool = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(iOS 16.0, *), !requiresSecurityScope {
            ShareLink(
                item: fileURL,
                preview: SharePreview(fileName, image: Image(systemName: symbolName))
            ) {
                label()
            }
        } else {
            Button {
                presentScopedShareSheet(for: fileURL)
            } label: {
                label()
            }
        }
    }

    private func presentScopedShareSheet(for url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }

        topVC.present(activityVC, animated: true)
    }
}

// MARK: - Device & Storage Path Display Helper

enum DeviceStorageText {
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var deviceContainerName: String {
        isPad ? "我的 iPad" : "我的 iPhone"
    }

    static var emptyCompletedHint: String {
        "下载完成的文件会显示在这里，点开即可预览、保存到「文件」App 或分享给其他应用。"
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
