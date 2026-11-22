import Foundation

enum RunnerCompletion: Sendable {
    case completed(totalBytesWritten: Int64)
    case cancelled
    case requiresRestartSingleStream(reason: String)
    case requiresLinkRefresh(reason: String)
    case failed(String)
}

final class TaskDownloadRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxRetriesPerSegment = 5
    static let minimumBytesPerSegment: Int64 = 512 * 1024 // 512 KB to avoid wasteful tiny connections

    private let taskId: UUID
    private let url: URL
    private let customHeaders: [String: String]
    private let defaultUserAgent: String
    private let allowsCellularAccess: Bool
    private let proxySettings: ProxySettingsData
    private let supportsRange: Bool
    private let eTag: String?
    private let lastModified: String?
    private let expectedHTMLFile: Bool
    private let isRefreshableCloudLink: Bool
    private let fileWriter: FileWriter
    private let onCompletion: @Sendable (RunnerCompletion) -> Void

    private let lock = NSLock()
    private var segments: [DownloadSegment]
    private var activeDataTasks: [Int: URLSessionDataTask] = [:] // segmentId -> task
    private var taskToSegment: [Int: Int] = [:] // taskIdentifier -> segmentId
    private var retryCounts: [Int: Int] = [:]
    private var pendingRetryWorkItems: [Int: DispatchWorkItem] = [:]
    private var segmentFatalErrors: [Int: String] = [:]
    private var segmentSpeedSamples: [Int: (bytes: Int64, timestamp: TimeInterval)] = [:]
    private var isStopped = false
    private var didReportCompletion = false

    private var session: URLSession!
    private let delegateQueue: OperationQueue
    private let retryQueue = DispatchQueue(label: "com.iosdm.runner.retry", qos: .utility)

    init(
        taskId: UUID,
        url: URL,
        segments: [DownloadSegment],
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData = ProxySettingsData(),
        supportsRange: Bool,
        eTag: String?,
        lastModified: String?,
        expectedHTMLFile: Bool = false,
        isRefreshableCloudLink: Bool = false,
        fileWriter: FileWriter,
        onCompletion: @escaping @Sendable (RunnerCompletion) -> Void
    ) {
        self.taskId = taskId
        self.url = url
        self.segments = segments
        self.customHeaders = customHeaders
        self.defaultUserAgent = defaultUserAgent
        self.allowsCellularAccess = allowsCellularAccess
        self.proxySettings = proxySettings
        self.supportsRange = supportsRange
        self.eTag = eTag
        self.lastModified = lastModified
        self.expectedHTMLFile = expectedHTMLFile
        self.isRefreshableCloudLink = isRefreshableCloudLink
        self.fileWriter = fileWriter
        self.onCompletion = onCompletion

        // Low-overhead utility queue keeps CPU & battery usage minimal on iPad/iPhone
        let queue = OperationQueue()
        queue.name = "com.iosdm.runner.\(taskId.uuidString)"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        self.delegateQueue = queue

        super.init()

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = max(8, segments.count + 1)
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 24 // 24 hours
        config.waitsForConnectivity = false
        ProxyManager.applyProxy(to: config, targetURL: url, settings: proxySettings)

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    static func makeInitialSegments(totalBytes: Int64, requestedThreads: Int, supportsRange: Bool) -> [DownloadSegment] {
        guard supportsRange, totalBytes > 0 else {
            let endByte: Int64 = totalBytes > 0 ? (totalBytes - 1) : -1
            return [
                DownloadSegment(id: 0, startByte: 0, endByte: endByte, downloadedBytes: 0, state: .pending)
            ]
        }

        let maxUsefulThreads = Int(max(1, totalBytes / minimumBytesPerSegment))
        let count = max(1, min(requestedThreads, maxUsefulThreads))
        let baseChunk = totalBytes / Int64(count)
        let remainder = totalBytes % Int64(count)

        var result: [DownloadSegment] = []
        result.reserveCapacity(count)
        var cursor: Int64 = 0
        for index in 0..<count {
            let size = baseChunk + (Int64(index) < remainder ? 1 : 0)
            let end = cursor + size - 1
            result.append(
                DownloadSegment(
                    id: index,
                    startByte: cursor,
                    endByte: end,
                    downloadedBytes: 0,
                    state: .pending
                )
            )
            cursor = end + 1
        }
        return result
    }

    func start() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        let segmentIdsToLaunch = segments.indices.compactMap { idx -> Int? in
            if segments[idx].state == .completed || segments[idx].isRangeComplete {
                segments[idx].state = .completed
                segments[idx].speedBytesPerSec = 0
                return nil
            }
            segments[idx].errorMessage = nil
            return segments[idx].id
        }
        let allDone = segments.allSatisfy { $0.state == .completed }
        lock.unlock()

        if allDone {
            finishWith(.completed(totalBytesWritten: totalDownloadedBytes()))
            return
        }

        for segId in segmentIdsToLaunch {
            launchSegment(segId)
        }
    }

    func snapshotSegments() -> [DownloadSegment] {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }

        var copy = segments
        for idx in copy.indices {
            let segId = copy[idx].id
            if copy[idx].state == .downloading {
                let currentBytes = copy[idx].downloadedBytes
                if let sample = segmentSpeedSamples[segId] {
                    let dt = now - sample.timestamp
                    if dt >= 0.3 {
                        let delta = max(0, currentBytes - sample.bytes)
                        let instant = Double(delta) / dt
                        let prev = copy[idx].speedBytesPerSec
                        let smoothed = prev > 0 ? (0.45 * instant + 0.55 * prev) : instant
                        copy[idx].speedBytesPerSec = smoothed
                        segments[idx].speedBytesPerSec = smoothed
                        segmentSpeedSamples[segId] = (currentBytes, now)
                    }
                } else {
                    segmentSpeedSamples[segId] = (currentBytes, now)
                }
            } else {
                copy[idx].speedBytesPerSec = 0
                segments[idx].speedBytesPerSec = 0
            }
        }
        return copy
    }

    func stopAndSnapshot() -> [DownloadSegment] {
        lock.lock()
        isStopped = true
        didReportCompletion = true
        let tasksToCancel = Array(activeDataTasks.values)
        activeDataTasks.removeAll()
        taskToSegment.removeAll()
        let retriesToCancel = Array(pendingRetryWorkItems.values)
        pendingRetryWorkItems.removeAll()
        for idx in segments.indices where segments[idx].state == .downloading || segments[idx].state == .pending {
            segments[idx].state = .paused
            segments[idx].speedBytesPerSec = 0
        }
        lock.unlock()

        for item in retriesToCancel {
            item.cancel()
        }
        for task in tasksToCancel {
            task.cancel()
        }
        session.invalidateAndCancel()
        fileWriter.syncAndClose()

        lock.lock()
        let finalSnapshot = segments
        lock.unlock()
        return finalSnapshot
    }

    private func totalDownloadedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.downloadedBytes }
    }

    private func launchSegment(_ segmentId: Int) {
        lock.lock()
        guard !isStopped,
              let idx = segments.firstIndex(where: { $0.id == segmentId }) else {
            lock.unlock()
            return
        }
        if segments[idx].isRangeComplete {
            segments[idx].state = .completed
            segments[idx].speedBytesPerSec = 0
            lock.unlock()
            evaluateOverallState()
            return
        }

        let seg = segments[idx]
        segments[idx].state = .downloading
        segments[idx].errorMessage = nil
        segmentFatalErrors.removeValue(forKey: segmentId)
        segmentSpeedSamples[segmentId] = (seg.downloadedBytes, Date().timeIntervalSinceReferenceDate)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        var hasUserAgent = false
        for (key, value) in customHeaders {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            if trimmedKey.caseInsensitiveCompare("User-Agent") == .orderedSame {
                hasUserAgent = true
            }
            if trimmedKey.caseInsensitiveCompare("Range") == .orderedSame ||
               trimmedKey.caseInsensitiveCompare("If-Range") == .orderedSame {
                continue
            }
            request.setValue(value, forHTTPHeaderField: trimmedKey)
        }
        if !hasUserAgent && !defaultUserAgent.isEmpty {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        if supportsRange && seg.hasKnownLength {
            request.setValue("bytes=\(seg.currentOffset)-\(seg.endByte)", forHTTPHeaderField: "Range")
            if let eTag, !eTag.isEmpty, !eTag.hasPrefix("W/") {
                request.setValue(eTag, forHTTPHeaderField: "If-Range")
            } else if let lastModified, !lastModified.isEmpty {
                request.setValue(lastModified, forHTTPHeaderField: "If-Range")
            }
        }

        let dataTask = session.dataTask(with: request)
        activeDataTasks[segmentId] = dataTask
        taskToSegment[dataTask.taskIdentifier] = segmentId
        lock.unlock()

        dataTask.resume()
    }

    private func scheduleRetry(for segmentId: Int, reason: String) {
        lock.lock()
        guard !isStopped,
              let idx = segments.firstIndex(where: { $0.id == segmentId }) else {
            lock.unlock()
            return
        }
        let nextAttempt = (retryCounts[segmentId] ?? 0) + 1
        guard nextAttempt <= Self.maxRetriesPerSegment else {
            segments[idx].state = .failed
            segments[idx].speedBytesPerSec = 0
            segments[idx].errorMessage = reason
            lock.unlock()
            evaluateOverallState()
            return
        }

        retryCounts[segmentId] = nextAttempt
        segments[idx].state = .pending
        segments[idx].speedBytesPerSec = 0
        segments[idx].errorMessage = "正在重试 (\(nextAttempt)/\(Self.maxRetriesPerSegment))..."

        let shouldResetSingleStream = !supportsRange
        if shouldResetSingleStream {
            segments[idx].downloadedBytes = 0
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingRetryWorkItems.removeValue(forKey: segmentId)
            let stopped = self.isStopped
            self.lock.unlock()
            guard !stopped else { return }

            if shouldResetSingleStream {
                try? self.fileWriter.truncate(to: 0)
            }
            self.launchSegment(segmentId)
        }
        pendingRetryWorkItems[segmentId] = workItem
        lock.unlock()

        let delay = min(5.0, 0.7 * Double(nextAttempt))
        retryQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateOverallState() {
        lock.lock()
        guard !isStopped, !didReportCompletion else {
            lock.unlock()
            return
        }
        let allCompleted = segments.allSatisfy { $0.state == .completed }
        let anyInFlight = !activeDataTasks.isEmpty || !pendingRetryWorkItems.isEmpty
        let firstError = segments.first(where: { $0.state == .failed })?.errorMessage
        let total = segments.reduce(0) { $0 + $1.downloadedBytes }
        lock.unlock()

        if allCompleted {
            finishWith(.completed(totalBytesWritten: total))
        } else if !anyInFlight, let firstError {
            finishWith(.failed(firstError))
        }
    }

    private func finishWith(_ result: RunnerCompletion) {
        lock.lock()
        guard !didReportCompletion else {
            lock.unlock()
            return
        }
        didReportCompletion = true
        isStopped = true
        let tasksToCancel = Array(activeDataTasks.values)
        activeDataTasks.removeAll()
        taskToSegment.removeAll()
        let retries = Array(pendingRetryWorkItems.values)
        pendingRetryWorkItems.removeAll()
        lock.unlock()

        for item in retries {
            item.cancel()
        }
        for task in tasksToCancel {
            task.cancel()
        }
        session.invalidateAndCancel()
        fileWriter.syncAndClose()

        onCompletion(result)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let segId = taskToSegment[task.taskIdentifier]
        let segment = segId.flatMap { id in segments.first(where: { $0.id == id }) }
        lock.unlock()

        var redirected = request
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if supportsRange, let seg = segment, seg.hasKnownLength {
            redirected.setValue("bytes=\(seg.currentOffset)-\(seg.endByte)", forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard !isStopped,
              let segId = taskToSegment[dataTask.taskIdentifier],
              let idx = segments.firstIndex(where: { $0.id == segId }) else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let seg = segments[idx]
        let segmentCount = segments.count
        lock.unlock()

        guard let http = response as? HTTPURLResponse else {
            recordFatalSegmentError(segId, message: "无效的服务器响应")
            completionHandler(.cancel)
            return
        }

        let code = http.statusCode

        // Guard against expired cloud links redirecting back to an HTML webpage mid-resume
        if !expectedHTMLFile && Self.isHTMLResponse(http) {
            completionHandler(.cancel)
            if isRefreshableCloudLink {
                finishWith(.requiresLinkRefresh(reason: "网盘临时直链已过期，正在重新解析有效地址..."))
            } else {
                finishWith(.failed(CloudResolverError.htmlPageInsteadOfFile(provider: nil).localizedDescription))
            }
            return
        }

        if (code == 403 || code == 410) && isRefreshableCloudLink {
            completionHandler(.cancel)
            finishWith(.requiresLinkRefresh(reason: "网盘直链访问令牌已过期 (HTTP \(code))，正在重新获取..."))
            return
        }

        if supportsRange && seg.hasKnownLength {
            if code == 206 {
                if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
                   let startOffset = Self.parseContentRangeStart(rangeHeader),
                   startOffset != seg.currentOffset {
                    completionHandler(.cancel)
                    finishWith(.requiresRestartSingleStream(reason: "服务器返回的分片偏移量不匹配，需重新下载"))
                    return
                }
                completionHandler(.allow)
                return
            }

            if code == 200 {
                if segmentCount == 1 && seg.startByte == 0 && seg.downloadedBytes == 0 {
                    completionHandler(.allow)
                    return
                }
                completionHandler(.cancel)
                finishWith(.requiresRestartSingleStream(reason: "远程文件已变更或服务器不支持当前断点续传"))
                return
            }

            if code == 416 && seg.isRangeComplete {
                completionHandler(.cancel)
                return
            }

            let statusText = HTTPURLResponse.localizedString(forStatusCode: code)
            if Self.isRetryableHTTPStatus(code) {
                recordRetryableSegmentError(segId, message: "HTTP \(code) (\(statusText))")
            } else {
                recordFatalSegmentError(segId, message: "服务器返回 HTTP \(code) (\(statusText))")
            }
            completionHandler(.cancel)
            return
        } else {
            guard (200...299).contains(code) else {
                let statusText = HTTPURLResponse.localizedString(forStatusCode: code)
                if Self.isRetryableHTTPStatus(code) {
                    recordRetryableSegmentError(segId, message: "HTTP \(code) (\(statusText))")
                } else {
                    recordFatalSegmentError(segId, message: "服务器返回 HTTP \(code) (\(statusText))")
                }
                completionHandler(.cancel)
                return
            }
            if !seg.hasKnownLength && http.expectedContentLength > 0 {
                lock.lock()
                if let currentIdx = segments.firstIndex(where: { $0.id == segId }) {
                    segments[currentIdx].endByte = http.expectedContentLength - 1
                }
                lock.unlock()
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard !isStopped,
              let segId = taskToSegment[dataTask.taskIdentifier],
              let idx = segments.firstIndex(where: { $0.id == segId }) else {
            lock.unlock()
            return
        }
        let seg = segments[idx]
        let writeOffset = seg.currentOffset
        let hasKnownLength = seg.hasKnownLength
        let remaining = seg.remainingBytes
        lock.unlock()

        let bytesToWrite: Int
        if hasKnownLength {
            guard remaining > 0 else {
                dataTask.cancel()
                return
            }
            bytesToWrite = min(data.count, Int(remaining))
        } else {
            bytesToWrite = data.count
        }

        let payload = (bytesToWrite == data.count) ? data : data.prefix(bytesToWrite)

        do {
            try fileWriter.write(payload, at: writeOffset)
        } catch {
            if case FileWriterError.closed = error {
                return
            }
            finishWith(.failed(error.localizedDescription))
            return
        }

        lock.lock()
        if let currentIdx = segments.firstIndex(where: { $0.id == segId }) {
            segments[currentIdx].downloadedBytes += Int64(bytesToWrite)
            retryCounts[segId] = 0
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let segId = taskToSegment.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        activeDataTasks.removeValue(forKey: segId)

        if isStopped {
            lock.unlock()
            return
        }

        guard let idx = segments.firstIndex(where: { $0.id == segId }) else {
            lock.unlock()
            return
        }

        let fatalMessage = segmentFatalErrors.removeValue(forKey: segId)
        let seg = segments[idx]

        if let fatalMessage {
            segments[idx].state = .failed
            segments[idx].speedBytesPerSec = 0
            segments[idx].errorMessage = fatalMessage
            lock.unlock()
            evaluateOverallState()
            return
        }

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled && seg.isRangeComplete {
                segments[idx].state = .completed
                segments[idx].speedBytesPerSec = 0
                segments[idx].errorMessage = nil
                lock.unlock()
                evaluateOverallState()
                return
            }

            let hasRetryableHTTPMessage = segments[idx].errorMessage != nil
            let pendingRetryReason = segments[idx].errorMessage ?? error.localizedDescription
            lock.unlock()

            if Self.isRetryableError(nsError) || hasRetryableHTTPMessage {
                scheduleRetry(for: segId, reason: pendingRetryReason)
            } else {
                lock.lock()
                if let currentIdx = segments.firstIndex(where: { $0.id == segId }) {
                    segments[currentIdx].state = .failed
                    segments[currentIdx].speedBytesPerSec = 0
                    segments[currentIdx].errorMessage = error.localizedDescription
                }
                lock.unlock()
                evaluateOverallState()
            }
            return
        }

        if seg.hasKnownLength && !seg.isRangeComplete {
            lock.unlock()
            scheduleRetry(for: segId, reason: "连接提前断开，已自动续传重试")
            return
        }

        segments[idx].state = .completed
        segments[idx].speedBytesPerSec = 0
        segments[idx].errorMessage = nil
        lock.unlock()
        evaluateOverallState()
    }

    private func recordFatalSegmentError(_ segmentId: Int, message: String) {
        lock.lock()
        segmentFatalErrors[segmentId] = message
        lock.unlock()
    }

    private func recordRetryableSegmentError(_ segmentId: Int, message: String) {
        lock.lock()
        if let idx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[idx].errorMessage = message
        }
        lock.unlock()
    }

    private static func isHTMLResponse(_ response: HTTPURLResponse) -> Bool {
        if let mime = response.mimeType?.lowercased(), mime.contains("text/html") || mime.contains("application/xhtml") {
            return true
        }
        if let ct = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ct.contains("text/html") || ct.contains("application/xhtml") {
            return true
        }
        return false
    }

    private static func parseContentRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst(6)
        guard let dashIndex = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[..<dashIndex].trimmingCharacters(in: .whitespaces))
    }

    private static func isRetryableHTTPStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }

    private static func isRetryableError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }
}
