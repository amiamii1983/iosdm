import Foundation

struct StoragePaths: Sendable {
    static let shared = StoragePaths()

    static var isRunningInLiveContainer: Bool {
        let bundlePath = Bundle.main.bundlePath.lowercased()
        let homePath = NSHomeDirectory().lowercased()
        return bundlePath.contains("livecontainer") || homePath.contains("livecontainer")
    }

    let documentsDirectory: URL
    let appSupportDirectory: URL
    let partialsDirectory: URL
    let tasksMetadataURL: URL
    let customDirectoryOverride: URL?

    init(
        documentsDirectory: URL? = nil,
        appSupportDirectory: URL? = nil,
        customDirectoryOverride: URL? = nil
    ) {
        let fm = FileManager.default
        let docs = documentsDirectory
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let supportRoot = appSupportDirectory
            ?? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true))
                .appendingPathComponent("iosdm", isDirectory: true)

        self.documentsDirectory = docs
        self.appSupportDirectory = supportRoot
        self.partialsDirectory = supportRoot.appendingPathComponent("Partials", isDirectory: true)
        self.tasksMetadataURL = supportRoot.appendingPathComponent("tasks.json", isDirectory: false)
        self.customDirectoryOverride = customDirectoryOverride
    }

    func ensureDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: partialsDirectory, withIntermediateDirectories: true)
    }

    func partialFileURL(for taskId: UUID) -> URL {
        partialsDirectory.appendingPathComponent("\(taskId.uuidString).part", isDirectory: false)
    }

    func completedFileURL(for fileName: String) -> URL {
        documentsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func uniqueCompletedFileName(
        preferred: String,
        in directory: URL? = nil,
        reservedNames: Set<String> = []
    ) -> String {
        let targetDir = directory ?? documentsDirectory
        let sanitized = ByteFormatter.sanitizeFileName(preferred)
        let nsName = sanitized as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? sanitized : nsName.deletingPathExtension

        let fm = FileManager.default
        func isAvailable(_ candidate: String) -> Bool {
            if reservedNames.contains(candidate.lowercased()) {
                return false
            }
            return !fm.fileExists(atPath: targetDir.appendingPathComponent(candidate, isDirectory: false).path)
        }

        if isAvailable(sanitized) {
            return sanitized
        }

        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            if isAvailable(candidate) {
                return candidate
            }
            index += 1
        }
    }

    /// Moves a file across same or different volumes safely (falls back to copy + remove on cross-volume move).
    static func moveOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        do {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fm.copyItem(at: sourceURL, to: destinationURL)
            try? fm.removeItem(at: sourceURL)
        }
    }

    /// Verifies that a user-selected external directory is actually writable under security-scoped access.
    static func verifyDirectoryWritable(_ dirURL: URL) throws {
        let accessed = dirURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                dirURL.stopAccessingSecurityScopedResource()
            }
        }
        let probeURL = dirURL.appendingPathComponent(".iosdm_write_probe_\(UUID().uuidString)", isDirectory: false)
        do {
            try Data("ok".utf8).write(to: probeURL, options: [.atomic])
            try? FileManager.default.removeItem(at: probeURL)
        } catch {
            throw NSError(
                domain: "com.iosdm.storage",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey: "当前所选目录没有写入权限（若使用 LiveContainer 运行，可直接在已完成文件详情页点「另存到『文件』App」导出）：\(error.localizedDescription)"
                ]
            )
        }
    }

    /// Creates a persistent bookmark for a user-selected folder or file.
    static func makeBookmarkData(for url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves a previously stored bookmark back to a URL.
    static func resolveBookmarkData(_ data: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
    }

    func partialStorageBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: partialsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return items.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    func completedStorageBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return items.reduce(0) { sum, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return sum
            }
            return sum + Int64(values.fileSize ?? 0)
        }
    }
}
