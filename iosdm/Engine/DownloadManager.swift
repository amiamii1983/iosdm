import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var tasks: [DownloadTaskModel] = []
    @Published private(set) var totalSpeedBytesPerSec: Double = 0

    let storage: StoragePaths
    let settings: AppSettings

    private var activeRunners: [UUID: TaskDownloadRunner] = [:]
    private var activeProbes: [UUID: Task<Void, Never>] = [:]
    private var refreshedOnceTasks: Set<UUID> = []
    private var lastSampledBytes: [UUID: Int64] = [:]
    private var lastPersistedByteSum: Int64 = -1
    private var lastTickDate: Date = Date()
    private var lastPersistDate: Date = Date()
    private var tickTask: Task<Void, Never>?

    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(storage: StoragePaths = .shared, settings: AppSettings? = nil) {
        self.storage = storage
        self.settings = settings ?? AppSettings.shared
        storage.ensureDirectoriesExist()
        loadTasks()
    }

    // MARK: - Public Queries

    var activeDownloadCount: Int {
        tasks.filter { $0.status.isActive }.count
    }

    func completedFileURL(for task: DownloadTaskModel) -> URL? {
        guard task.status == .completed, let savedName = task.savedFileName else { return nil }
        return storage.completedFileURL(for: savedName)
    }

    func completedFileExists(for task: DownloadTaskModel) -> Bool {
        guard let url = completedFileURL(for: task) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func effectiveProxySettings(for task: DownloadTaskModel) -> ProxySettingsData {
        var resolved = settings.proxySettings
        if let override = task.proxyModeOverride {
            resolved.mode = override
        }
        return resolved
    }

    // MARK: - Task Lifecycle

    @discardableResult
    func addDownload(
        urlString: String,
        customFileName: String? = nil,
        threadCount: Int? = nil,
        customHeaders: [String: String] = [:],
        proxyModeOverride: ProxyMode? = nil,
        startImmediately: Bool = true
    ) throws -> DownloadTaskModel {
        let validURL = try URLProbe.validateURL(urlString)
        let threads = max(1, min(8, threadCount ?? settings.defaultThreadCount))

        let trimmedName = customFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialName: String
        if !trimmedName.isEmpty {
            initialName = ByteFormatter.sanitizeFileName(trimmedName)
        } else {
            let candidate = ByteFormatter.fileNameFromURL(validURL)
            if let candidate, candidate.lowercased() != "file" && candidate.lowercased() != "download" {
                initialName = candidate
            } else {
                initialName = "解析文件名中..."
            }
        }

        let cleanedHeaders = customHeaders.reduce(into: [String: String]()) { acc, item in
            let k = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty && !v.isEmpty {
                acc[k] = v
            }
        }

        let model = DownloadTaskModel(
            originalURL: validURL.absoluteString,
            cloudProvider: CloudLinkResolver.providerName(for: validURL),
            fileName: initialName,
            requestedThreadCount: threads,
            customHeaders: cleanedHeaders,
            proxyModeOverride: proxyModeOverride,
            status: startImmediately ? .queued : .paused
        )

        tasks.insert(model, at: 0)
        persistTasks()

        if startImmediately {
            scheduleNextTasks()
        }
        return model
    }

    func startOrResume(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard tasks[idx].status == .paused || tasks[idx].status == .failed else { return }

        refreshedOnceTasks.remove(taskId)
        tasks[idx].errorMessage = nil
        tasks[idx].pausedByBackground = false
        for segIdx in tasks[idx].segments.indices {
            if tasks[idx].segments[segIdx].state != .completed {
                tasks[idx].segments[segIdx].state = .pending
                tasks[idx].segments[segIdx].errorMessage = nil
                tasks[idx].segments[segIdx].speedBytesPerSec = 0
            }
        }
        tasks[idx].status = .queued
        persistTasks()
        scheduleNextTasks()
    }

    func pause(taskId: UUID, byBackground: Bool = false) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let currentStatus = tasks[idx].status
        guard currentStatus == .downloading || currentStatus == .probing || currentStatus == .queued else {
            return
        }

        if let probeTask = activeProbes.removeValue(forKey: taskId) {
            probeTask.cancel()
        }
        if let runner = activeRunners.removeValue(forKey: taskId) {
            let finalSegments = runner.stopAndSnapshot()
            tasks[idx].segments = finalSegments
        }

        tasks[idx].status = .paused
        tasks[idx].speedBytesPerSec = 0
        tasks[idx].etaSeconds = nil
        tasks[idx].pausedByBackground = byBackground
        lastSampledBytes.removeValue(forKey: taskId)

        persistTasks()
        updateIdleTimer()
        if !byBackground {
            scheduleNextTasks()
        }
        stopTickerIfIdle()
    }

    func pauseAll() {
        let targets = tasks.filter { $0.canPause }.map(\.id)
        for id in targets {
            pause(taskId: id, byBackground: false)
        }
    }

    func resumeAll() {
        let targets = tasks.filter { $0.canResume }.map(\.id)
        for id in targets {
            startOrResume(taskId: id)
        }
    }

    func restartFromBeginning(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }

        if let probeTask = activeProbes.removeValue(forKey: taskId) {
            probeTask.cancel()
        }
        if let runner = activeRunners.removeValue(forKey: taskId) {
            _ = runner.stopAndSnapshot()
        }

        refreshedOnceTasks.remove(taskId)
        try? FileManager.default.removeItem(at: storage.partialFileURL(for: taskId))

        tasks[idx].resolvedURL = nil
        tasks[idx].resolvedHeaders = [:]
        tasks[idx].savedFileName = nil
        tasks[idx].totalBytes = -1
        tasks[idx].supportsRange = false
        tasks[idx].eTag = nil
        tasks[idx].lastModified = nil
        tasks[idx].errorMessage = nil
        tasks[idx].segments = []
        tasks[idx].speedBytesPerSec = 0
        tasks[idx].etaSeconds = nil
        tasks[idx].completedAt = nil
        tasks[idx].pausedByBackground = false
        tasks[idx].status = .queued
        lastSampledBytes.removeValue(forKey: taskId)

        persistTasks()
        scheduleNextTasks()
    }

    func deleteTask(taskId: UUID, deleteLocalFile: Bool = true) {
        if let probeTask = activeProbes.removeValue(forKey: taskId) {
            probeTask.cancel()
        }
        if let runner = activeRunners.removeValue(forKey: taskId) {
            _ = runner.stopAndSnapshot()
        }
        refreshedOnceTasks.remove(taskId)
        lastSampledBytes.removeValue(forKey: taskId)

        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            let task = tasks[idx]
            try? FileManager.default.removeItem(at: storage.partialFileURL(for: taskId))
            if deleteLocalFile, let saved = task.savedFileName {
                try? FileManager.default.removeItem(at: storage.completedFileURL(for: saved))
            }
            tasks.remove(at: idx)
            persistTasks()
        }

        updateIdleTimer()
        scheduleNextTasks()
        stopTickerIfIdle()
    }

    func renameCompletedFile(taskId: UUID, newName: String) throws {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status == .completed,
              let oldSaved = tasks[idx].savedFileName else {
            return
        }
        let sanitized = ByteFormatter.sanitizeFileName(newName)
        guard sanitized != oldSaved else { return }

        let unique = storage.uniqueCompletedFileName(preferred: sanitized)
        let oldURL = storage.completedFileURL(for: oldSaved)
        let newURL = storage.completedFileURL(for: unique)

        if FileManager.default.fileExists(atPath: oldURL.path) {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        }
        tasks[idx].savedFileName = unique
        tasks[idx].fileName = unique
        persistTasks()
    }

    func clearCompletedTasks(deleteFiles: Bool) {
        let completedIds = tasks.filter { $0.status == .completed }.map(\.id)
        for id in completedIds {
            deleteTask(taskId: id, deleteLocalFile: deleteFiles)
        }
    }

    func clearOrphanPartialFiles() {
        let validPartNames = Set(tasks.map { "\($0.id.uuidString).part" })
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: storage.partialsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items where !validPartNames.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - App Lifecycle (Background & Foreground)

    func appDidEnterBackground() {
        syncActiveSnapshotsToTasks()
        persistTasks()

        #if canImport(UIKit)
        guard activeDownloadCount > 0 else { return }
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "iosdm.activeDownloads") { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleBackgroundTimeExpiring()
                }
            }
        }
        #endif
    }

    func appDidBecomeActive() {
        #if canImport(UIKit)
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        #endif

        if settings.autoResumeOnForeground {
            let backgroundPausedIds = tasks.filter { $0.status == .paused && $0.pausedByBackground }.map(\.id)
            for id in backgroundPausedIds {
                startOrResume(taskId: id)
            }
        }
        updateIdleTimer()
    }

    private func handleBackgroundTimeExpiring() {
        let activeIds = tasks.filter { $0.status.isActive || $0.status == .queued }.map(\.id)
        for id in activeIds {
            pause(taskId: id, byBackground: true)
        }
        persistTasks()
        #if canImport(UIKit)
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        #endif
    }

    // MARK: - Internal Scheduling & Execution

    private func scheduleNextTasks() {
        while activeDownloadCount < settings.maxConcurrentTasks {
            guard let nextIdx = tasks.firstIndex(where: { $0.status == .queued }) else {
                break
            }
            let taskId = tasks[nextIdx].id
            beginTask(taskId: taskId)
        }
        updateIdleTimer()
        if activeDownloadCount > 0 {
            startTickerIfNeeded()
        } else {
            stopTickerIfIdle()
        }
    }

    private func beginTask(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let task = tasks[idx]

        let partURL = storage.partialFileURL(for: taskId)
        let partExists = FileManager.default.fileExists(atPath: partURL.path)
        let canResumeDirectly = task.supportsRange
            && !task.segments.isEmpty
            && task.totalBytes > 0
            && partExists
            && URL(string: task.effectiveURLString) != nil

        if canResumeDirectly {
            launchRunner(for: taskId, truncateToZero: false)
            return
        }

        tasks[idx].status = .probing
        tasks[idx].errorMessage = nil
        persistTasks()

        let urlString = task.originalURL
        let headers = task.customHeaders
        let defaultUA = settings.defaultUserAgent
        let allowCell = settings.allowsCellularAccess
        let proxyConfig = effectiveProxySettings(for: task)
        let fileNameHint = task.fileName == "解析文件名中..." ? nil : task.fileName

        let probeTask = Task { [weak self] in
            do {
                let validURL = try URLProbe.validateURL(urlString)
                let probeResult = try await URLProbe.probe(
                    url: validURL,
                    customHeaders: headers,
                    defaultUserAgent: defaultUA,
                    allowsCellularAccess: allowCell,
                    proxySettings: proxyConfig,
                    expectedFileNameHint: fileNameHint
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.handleProbeSuccess(taskId: taskId, result: probeResult)
                }
            } catch is CancellationError {
                // Handled by pause/delete
            } catch {
                await MainActor.run { [weak self] in
                    self?.handleProbeFailure(taskId: taskId, error: error)
                }
            }
        }
        activeProbes[taskId] = probeTask
    }

    private func handleProbeSuccess(taskId: UUID, result: ProbeResult) {
        activeProbes.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status == .probing else {
            return
        }

        tasks[idx].resolvedURL = result.resolvedURL.absoluteString
        tasks[idx].resolvedHeaders = result.resolvedHeaders
        if let cloudSource = result.cloudSourceURL {
            tasks[idx].cloudSourceURL = cloudSource.absoluteString
        }
        if let provider = result.cloudProvider {
            tasks[idx].cloudProvider = provider
        }
        tasks[idx].totalBytes = result.totalBytes
        tasks[idx].supportsRange = result.supportsRange
        tasks[idx].eTag = result.eTag
        tasks[idx].lastModified = result.lastModified
        tasks[idx].mimeType = result.mimeType

        // Update filename from Content-Disposition/cloud resolver if user didn't supply a custom name
        let currentName = tasks[idx].fileName
        let originalURLFileName = URL(string: tasks[idx].originalURL).flatMap(ByteFormatter.fileNameFromURL)
        if currentName == "解析文件名中..." || currentName == "下载任务" || currentName == originalURLFileName {
            tasks[idx].fileName = result.suggestedFileName
        }

        if result.totalBytes == 0 {
            finalizeEmptyFile(taskId: taskId)
            return
        }

        tasks[idx].segments = TaskDownloadRunner.makeInitialSegments(
            totalBytes: result.totalBytes,
            requestedThreads: tasks[idx].requestedThreadCount,
            supportsRange: result.supportsRange
        )
        persistTasks()

        launchRunner(for: taskId, truncateToZero: !result.supportsRange)
    }

    private func handleProbeFailure(taskId: UUID, error: Error) {
        activeProbes.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status == .probing else {
            return
        }
        if case DownloadProbeError.cancelled = error {
            return
        }
        tasks[idx].status = .failed
        tasks[idx].errorMessage = error.localizedDescription
        tasks[idx].speedBytesPerSec = 0
        tasks[idx].etaSeconds = nil
        persistTasks()
        scheduleNextTasks()
    }

    private func refreshExpiredCloudLinkAndResume(taskId: UUID, reason: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard !refreshedOnceTasks.contains(taskId) else {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = "网盘直链刷新后仍不可用，请检查代理或重新复制链接"
            persistTasks()
            scheduleNextTasks()
            return
        }
        refreshedOnceTasks.insert(taskId)

        let task = tasks[idx]
        let sourceString = task.cloudSourceURL ?? task.originalURL
        let headers = task.customHeaders
        let defaultUA = settings.defaultUserAgent
        let allowCell = settings.allowsCellularAccess
        let proxyConfig = effectiveProxySettings(for: task)
        let savedTotalBytes = task.totalBytes

        tasks[idx].status = .probing
        tasks[idx].errorMessage = reason
        persistTasks()

        let probeTask = Task { [weak self] in
            do {
                let sourceURL = try URLProbe.validateURL(sourceString)
                let probeResult = try await URLProbe.probe(
                    url: sourceURL,
                    customHeaders: headers,
                    defaultUserAgent: defaultUA,
                    allowsCellularAccess: allowCell,
                    proxySettings: proxyConfig,
                    expectedFileNameHint: task.fileName
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self,
                          let currentIdx = self.tasks.firstIndex(where: { $0.id == taskId }),
                          self.tasks[currentIdx].status == .probing else {
                        return
                    }
                    self.activeProbes.removeValue(forKey: taskId)
                    self.tasks[currentIdx].resolvedURL = probeResult.resolvedURL.absoluteString
                    self.tasks[currentIdx].resolvedHeaders = probeResult.resolvedHeaders
                    self.tasks[currentIdx].eTag = probeResult.eTag
                    self.tasks[currentIdx].lastModified = probeResult.lastModified
                    self.tasks[currentIdx].errorMessage = nil

                    // If file size matches and Range is supported, keep exact segment offsets to resume seamlessly!
                    if probeResult.supportsRange && probeResult.totalBytes == savedTotalBytes && savedTotalBytes > 0 {
                        for segIdx in self.tasks[currentIdx].segments.indices where self.tasks[currentIdx].segments[segIdx].state != .completed {
                            self.tasks[currentIdx].segments[segIdx].state = .pending
                            self.tasks[currentIdx].segments[segIdx].errorMessage = nil
                        }
                        self.persistTasks()
                        self.launchRunner(for: taskId, truncateToZero: false)
                    } else {
                        // Remote file size changed or no longer supports Range; start cleanly
                        self.tasks[currentIdx].totalBytes = probeResult.totalBytes
                        self.tasks[currentIdx].supportsRange = probeResult.supportsRange
                        self.tasks[currentIdx].segments = TaskDownloadRunner.makeInitialSegments(
                            totalBytes: probeResult.totalBytes,
                            requestedThreads: self.tasks[currentIdx].requestedThreadCount,
                            supportsRange: probeResult.supportsRange
                        )
                        try? FileManager.default.removeItem(at: self.storage.partialFileURL(for: taskId))
                        self.persistTasks()
                        self.launchRunner(for: taskId, truncateToZero: !probeResult.supportsRange)
                    }
                }
            } catch is CancellationError {
                // Handled by pause/delete
            } catch {
                await MainActor.run { [weak self] in
                    self?.handleProbeFailure(taskId: taskId, error: error)
                }
            }
        }
        activeProbes[taskId] = probeTask
    }

    private func launchRunner(for taskId: UUID, truncateToZero: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let task = tasks[idx]
        guard let downloadURL = URL(string: task.effectiveURLString) else {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = "无效的下载地址"
            persistTasks()
            scheduleNextTasks()
            return
        }

        let partURL = storage.partialFileURL(for: taskId)
        let expectedSize: Int64? = (task.supportsRange && task.totalBytes > 0) ? task.totalBytes : nil

        let writer: FileWriter
        do {
            writer = try FileWriter(url: partURL, expectedSize: expectedSize, truncateToZero: truncateToZero)
        } catch {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = error.localizedDescription
            persistTasks()
            scheduleNextTasks()
            return
        }

        tasks[idx].status = .downloading
        tasks[idx].errorMessage = nil
        lastSampledBytes[taskId] = task.downloadedBytes

        let isCloudRefreshable = task.cloudSourceURL != nil || task.cloudProvider != nil
        let expectsHTML = CloudLinkResolver.isHTMLFileName(task.fileName)

        let runner = TaskDownloadRunner(
            taskId: taskId,
            url: downloadURL,
            segments: task.segments,
            customHeaders: task.mergedHeaders,
            defaultUserAgent: settings.defaultUserAgent,
            allowsCellularAccess: settings.allowsCellularAccess,
            proxySettings: effectiveProxySettings(for: task),
            supportsRange: task.supportsRange,
            eTag: task.eTag,
            lastModified: task.lastModified,
            expectedHTMLFile: expectsHTML,
            isRefreshableCloudLink: isCloudRefreshable,
            fileWriter: writer
        ) { [weak self] completion in
            Task { @MainActor [weak self] in
                self?.handleRunnerCompletion(taskId: taskId, completion: completion)
            }
        }

        activeRunners[taskId] = runner
        runner.start()
        startTickerIfNeeded()
        updateIdleTimer()
    }

    private func handleRunnerCompletion(taskId: UUID, completion: RunnerCompletion) {
        let runner = activeRunners.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }

        if let runner {
            tasks[idx].segments = runner.snapshotSegments()
        }
        tasks[idx].speedBytesPerSec = 0
        tasks[idx].etaSeconds = nil
        lastSampledBytes.removeValue(forKey: taskId)

        switch completion {
        case .completed(let totalWritten):
            refreshedOnceTasks.remove(taskId)
            finalizeCompletedFile(taskId: taskId, totalWritten: totalWritten)

        case .cancelled:
            if tasks[idx].status != .paused {
                tasks[idx].status = .paused
            }
            persistTasks()

        case .requiresLinkRefresh(let reason):
            refreshExpiredCloudLinkAndResume(taskId: taskId, reason: reason)
            return

        case .requiresRestartSingleStream(let reason):
            try? FileManager.default.removeItem(at: storage.partialFileURL(for: taskId))
            tasks[idx].supportsRange = false
            let knownTotal = tasks[idx].totalBytes
            tasks[idx].segments = [
                DownloadSegment(
                    id: 0,
                    startByte: 0,
                    endByte: knownTotal > 0 ? (knownTotal - 1) : -1,
                    downloadedBytes: 0,
                    state: .pending
                )
            ]
            tasks[idx].errorMessage = "\(reason)，已切换为单线程重新下载"
            persistTasks()
            launchRunner(for: taskId, truncateToZero: true)
            return

        case .failed(let message):
            tasks[idx].status = .failed
            tasks[idx].errorMessage = message
            persistTasks()
        }

        scheduleNextTasks()
    }

    private func finalizeCompletedFile(taskId: UUID, totalWritten: Int64) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let partURL = storage.partialFileURL(for: taskId)

        if tasks[idx].totalBytes > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
           let diskSize = attrs[.size] as? Int64,
           diskSize != tasks[idx].totalBytes {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = "文件大小校验不一致（本地 \(diskSize) B，预期 \(tasks[idx].totalBytes) B）"
            persistTasks()
            return
        }

        let reserved = Set(tasks.compactMap { $0.id == taskId ? nil : $0.savedFileName?.lowercased() })
        let uniqueName = storage.uniqueCompletedFileName(preferred: tasks[idx].fileName, reservedNames: reserved)
        let destURL = storage.completedFileURL(for: uniqueName)

        do {
            storage.ensureDirectoriesExist()
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: partURL, to: destURL)
        } catch {
            tasks[idx].status = .failed
            tasks[idx].errorMessage = "保存最终文件失败：\(error.localizedDescription)"
            persistTasks()
            return
        }

        if tasks[idx].totalBytes < 0 {
            tasks[idx].totalBytes = totalWritten
        }
        tasks[idx].fileName = uniqueName
        tasks[idx].savedFileName = uniqueName
        tasks[idx].status = .completed
        tasks[idx].errorMessage = nil
        tasks[idx].completedAt = Date()
        for segIdx in tasks[idx].segments.indices {
            tasks[idx].segments[segIdx].state = .completed
            tasks[idx].segments[segIdx].speedBytesPerSec = 0
        }
        persistTasks()
    }

    private func finalizeEmptyFile(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let reserved = Set(tasks.compactMap { $0.id == taskId ? nil : $0.savedFileName?.lowercased() })
        let uniqueName = storage.uniqueCompletedFileName(preferred: tasks[idx].fileName, reservedNames: reserved)
        let destURL = storage.completedFileURL(for: uniqueName)

        storage.ensureDirectoriesExist()
        FileManager.default.createFile(atPath: destURL.path, contents: Data())

        tasks[idx].fileName = uniqueName
        tasks[idx].savedFileName = uniqueName
        tasks[idx].totalBytes = 0
        tasks[idx].status = .completed
        tasks[idx].completedAt = Date()
        tasks[idx].errorMessage = nil
        persistTasks()
        scheduleNextTasks()
    }

    // MARK: - Low-Overhead UI Snapshot & Speed Ticker

    private func startTickerIfNeeded() {
        guard tickTask == nil else { return }
        lastTickDate = Date()
        lastPersistDate = Date()

        // 0.5s refresh cadence keeps CPU and SwiftUI redraw overhead very low on iPad/iPhone
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { break }
                self.performTick()
            }
        }
    }

    private func stopTickerIfIdle() {
        if activeRunners.isEmpty && activeProbes.isEmpty {
            tickTask?.cancel()
            tickTask = nil
            totalSpeedBytesPerSec = 0
            #if canImport(UIKit)
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
            #endif
        }
    }

    private func performTick() {
        let currentByteSum = syncActiveSnapshotsToTasks()
        let now = Date()
        // Only write tasks.json every 2.0s AND only when bytes actually advanced
        if now.timeIntervalSince(lastPersistDate) >= 2.0 && currentByteSum != lastPersistedByteSum {
            persistTasks()
            lastPersistedByteSum = currentByteSum
            lastPersistDate = now
        }
        stopTickerIfIdle()
    }

    @discardableResult
    private func syncActiveSnapshotsToTasks() -> Int64 {
        let now = Date()
        let dt = max(0.05, now.timeIntervalSince(lastTickDate))
        lastTickDate = now

        var aggregateSpeed: Double = 0
        var aggregateBytes: Int64 = 0

        for (taskId, runner) in activeRunners {
            guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { continue }
            let snapshot = runner.snapshotSegments()
            tasks[idx].segments = snapshot

            let currentDownloaded = snapshot.reduce(0) { $0 + $1.downloadedBytes }
            aggregateBytes += currentDownloaded
            let previousDownloaded = lastSampledBytes[taskId] ?? currentDownloaded
            let delta = max(0, currentDownloaded - previousDownloaded)
            lastSampledBytes[taskId] = currentDownloaded

            let instantSpeed = Double(delta) / dt
            let prevSpeed = tasks[idx].speedBytesPerSec
            let smoothedSpeed = prevSpeed > 0 ? (0.4 * instantSpeed + 0.6 * prevSpeed) : instantSpeed
            tasks[idx].speedBytesPerSec = smoothedSpeed
            aggregateSpeed += smoothedSpeed

            if tasks[idx].totalBytes > 0 && smoothedSpeed > 1 {
                let remaining = max(0, tasks[idx].totalBytes - currentDownloaded)
                tasks[idx].etaSeconds = Double(remaining) / smoothedSpeed
            } else {
                tasks[idx].etaSeconds = nil
            }
        }

        totalSpeedBytesPerSec = aggregateSpeed
        return aggregateBytes
    }

    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwakeWhileDownloading && activeDownloadCount > 0
        #endif
    }

    // MARK: - Persistence

    func persistTasks() {
        storage.ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: storage.tasksMetadataURL, options: [.atomic])
    }

    private func loadTasks() {
        guard let data = try? Data(contentsOf: storage.tasksMetadataURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([DownloadTaskModel].self, from: data) else { return }

        for idx in decoded.indices {
            if decoded[idx].status == .downloading || decoded[idx].status == .probing || decoded[idx].status == .queued {
                decoded[idx].status = .paused
                for segIdx in decoded[idx].segments.indices {
                    if decoded[idx].segments[segIdx].state == .downloading || decoded[idx].segments[segIdx].state == .pending {
                        decoded[idx].segments[segIdx].state = .paused
                    }
                    decoded[idx].segments[segIdx].speedBytesPerSec = 0
                }
            }
            decoded[idx].speedBytesPerSec = 0
            decoded[idx].etaSeconds = nil
        }

        self.tasks = decoded
    }
}
