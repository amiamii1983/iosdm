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

    init(
        documentsDirectory: URL? = nil,
        appSupportDirectory: URL? = nil
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
        reservedNames: Set<String> = []
    ) -> String {
        let sanitized = ByteFormatter.sanitizeFileName(preferred)
        let nsName = sanitized as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? sanitized : nsName.deletingPathExtension

        let fm = FileManager.default
        func isAvailable(_ candidate: String) -> Bool {
            if reservedNames.contains(candidate.lowercased()) {
                return false
            }
            return !fm.fileExists(atPath: completedFileURL(for: candidate).path)
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
