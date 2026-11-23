import Foundation

enum RunnerCompletion: Sendable {
    case completed(totalBytesWritten: Int64)
    case cancelled
    case requiresRestartSingleStream(reason: String)
    case requiresLinkRefresh(reason: String)
    case failed(String)
}

final class TaskDownloadRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxRetriesPerSegment = 8
    static let minimumBytesPerSegment: Int64 = 512 * 1024       // 512 KB initial split floor
    static let minimumStealRemainingBytes: Int64 = 1024 * 1024  // 1 MB minimum remaining to split
    static let writeBufferThreshold: Int = 256 * 1024           // 256 KB write buffer per segment
    static let writeBufferMaxAgeSeconds: TimeInterval = 0.4     // Also flush every 0.4s for smooth slow-link progress
    static let stallTimeoutSeconds: TimeInterval = 12.0         // Reconnect stalled TCP stream after 12s idle
    static let watchdogIntervalSeconds: TimeInterval = 3.0
    static let maxTotalDynamicSegments = 24

    private struct SegmentConnection {
        let token: UUID
        let session: URLSession
        let task: URLSessionDataTask
    }

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
    private let targetConcurrency: Int
    private let fileWriter: FileWriter
    private let onCompletion: @Sendable (RunnerCompletion) -> Void

    private let lock = NSLock()
    private var segments: [DownloadSegment]
    private var nextSegmentId: Int
    private var activeConnections: [Int: SegmentConnection] = [:]     // segmentId -> independent session & task
    private var sessionToSegment: [ObjectIdentifier: (segmentId: Int, token: UUID)] = [:]
    private var segmentBuffers: [Int: Data] = [:]                     // per-segment 256KB write buffer
    private var segmentFlushingBytes: [Int: Int64] = [:]              // bytes currently in-flight inside pwrite
    private var segmentLastFlushTime: [Int: TimeInterval] = [:]       // last flush timestamp per segment
    private var segmentFlushLocks: [Int: NSLock] = [:]                // serializes pwrite flush per segment
    private var segmentLastActivity: [Int: TimeInterval] = [:]
    private var retryCounts: [Int: Int] = [:]
    private var pendingRetryWorkItems: [Int: DispatchWorkItem] = [:]
    private var segmentFatalErrors: [Int: String] = [:]
    private var segmentSpeedSamples: [Int: (bytes: Int64, timestamp: TimeInterval)] = [:]
    private var isStopped = false
    private var didReportCompletion = false

    private var watchdogTimer: DispatchSourceTimer?
    private let retryQueue = DispatchQueue(label: "com.iosdm.runner.control", qos: .userInitiated)

    init(
        taskId: UUID,
        url: URL,
        segments: [DownloadSegment],
        requestedThreadCount: Int? = nil,
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
        self.nextSegmentId = (segments.map(\.id).max() ?? -1) + 1
        self.targetConcurrency = max(1, min(8, requestedThreadCount ?? segments.count))
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
        super.init()
    }

    deinit {
        cancelWatchdog()
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

        startWatchdog()
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
            let effectiveDownloaded = accountedBytesLocked(for: copy[idx])
            if copy[idx].state == .downloading {
                if let sample = segmentSpeedSamples[segId] {
                    let dt = now - sample.timestamp
                    if dt >= 0.4 {
                        let delta = max(0, effectiveDownloaded - sample.bytes)
                        let instant = Double(delta) / dt
                        let prev = copy[idx].speedBytesPerSec
                        let smoothed = prev > 0 ? (0.35 * instant + 0.65 * prev) : instant
                        copy[idx].speedBytesPerSec = smoothed
                        segments[idx].speedBytesPerSec = smoothed
                        segmentSpeedSamples[segId] = (effectiveDownloaded, now)
                    }
                } else {
                    segmentSpeedSamples[segId] = (effectiveDownloaded, now)
                }
            } else {
                copy[idx].speedBytesPerSec = 0
                segments[idx].speedBytesPerSec = 0
            }
        }
        return copy
    }

    func stopAndSnapshot() -> [DownloadSegment] {
        cancelWatchdog()

        lock.lock()
        isStopped = true
        didReportCompletion = true
        let connectionsToStop = Array(activeConnections.values)
        activeConnections.removeAll()
        sessionToSegment.removeAll()
        let retriesToCancel = Array(pendingRetryWorkItems.values)
        pendingRetryWorkItems.removeAll()
        let allSegmentIds = segments.map(\.id)
        for idx in segments.indices where segments[idx].state == .downloading || segments[idx].state == .pending {
            segments[idx].state = .paused
            segments[idx].speedBytesPerSec = 0
        }
        lock.unlock()

        for item in retriesToCancel {
            item.cancel()
        }
        for conn in connectionsToStop {
            conn.task.cancel()
            conn.session.invalidateAndCancel()
        }

        // Flush all remaining per-segment write buffers safely before closing file
        for segId in allSegmentIds {
            _ = flushSegmentBuffer(segId, allowWhenStopped: true)
        }
        fileWriter.syncAndClose()

        lock.lock()
        let finalSnapshot = segments
        lock.unlock()
        return finalSnapshot
    }

    // MARK: - Independent Session & Segment Launch

    private func makeIndependentSession(for segmentId: Int) -> URLSession {
        let queue = OperationQueue()
        queue.name = "com.iosdm.seg.\(taskId.uuidString).\(segmentId)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        // Each segment uses its own ephemeral URLSession so HTTP/2 does NOT coalesce
        // all threads onto one TCP socket (critical for Cloudflare / high-RTT / lossy links).
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.waitsForConnectivity = false
        ProxyManager.applyProxy(to: config, targetURL: url, settings: proxySettings)

        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    private func launchSegment(_ segmentId: Int) {
        // Ensure any leftover buffered bytes are flushed before reading currentOffset
        _ = flushSegmentBuffer(segmentId, allowWhenStopped: false)

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
            handleSegmentFinishedWork(segmentId)
            return
        }

        // Tear down any previous connection for this segment
        let oldConn = activeConnections.removeValue(forKey: segmentId)
        if let oldConn {
            sessionToSegment.removeValue(forKey: ObjectIdentifier(oldConn.session))
        }

        let seg = segments[idx]
        let now = Date().timeIntervalSinceReferenceDate
        segments[idx].state = .downloading
        segments[idx].errorMessage = nil
        segmentFatalErrors.removeValue(forKey: segmentId)
        segmentLastActivity[segmentId] = now
        segmentLastFlushTime[segmentId] = now
        segmentSpeedSamples[segmentId] = (seg.downloadedBytes, now)
        if segmentFlushLocks[segmentId] == nil {
            segmentFlushLocks[segmentId] = NSLock()
        }
        if segmentBuffers[segmentId] == nil {
            var buf = Data()
            buf.reserveCapacity(Self.writeBufferThreshold)
            segmentBuffers[segmentId] = buf
        }

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

        let token = UUID()
        let segSession = makeIndependentSession(for: segmentId)
        let dataTask = segSession.dataTask(with: request)
        let conn = SegmentConnection(token: token, session: segSession, task: dataTask)
        activeConnections[segmentId] = conn
        sessionToSegment[ObjectIdentifier(segSession)] = (segmentId, token)
        lock.unlock()

        if let oldConn {
            oldConn.task.cancel()
            oldConn.session.invalidateAndCancel()
        }

        dataTask.resume()
    }

    // MARK: - Dynamic Work Stealing

    private func handleSegmentFinishedWork(_ completedSegmentId: Int) {
        if let stolenSegmentId = tryStealWork() {
            launchSegment(stolenSegmentId)
        } else {
            evaluateOverallState()
        }
    }

    /// Splits the largest remaining active segment in half so fast finished threads help eliminate slow tail segments.
    private func tryStealWork() -> Int? {
        guard supportsRange else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard !isStopped,
              segments.count < Self.maxTotalDynamicSegments else {
            return nil
        }

        let currentActive = activeConnections.count + pendingRetryWorkItems.count
        guard currentActive < targetConcurrency else {
            return nil
        }

        var bestIndex: Int?
        var bestRemaining: Int64 = 0

        for idx in segments.indices {
            let seg = segments[idx]
            guard seg.hasKnownLength,
                  seg.state == .downloading || seg.state == .pending else {
                continue
            }
            let accounted = accountedBytesLocked(for: seg)
            let remaining = seg.totalBytes - accounted
            if remaining >= Self.minimumStealRemainingBytes && remaining > bestRemaining {
                bestRemaining = remaining
                bestIndex = idx
            }
        }

        guard let victimIdx = bestIndex else { return nil }

        let oldEnd = segments[victimIdx].endByte
        let stealSize = bestRemaining / 2
        let newVictimEnd = oldEnd - stealSize
        let newStart = newVictimEnd + 1
        let victimAccountedEnd = segments[victimIdx].startByte
            + accountedBytesLocked(for: segments[victimIdx])
            - 1

        guard newVictimEnd > victimAccountedEnd, newStart <= oldEnd else {
            return nil
        }

        segments[victimIdx].endByte = newVictimEnd
        let newId = nextSegmentId
        nextSegmentId += 1
        segments.append(
            DownloadSegment(
                id: newId,
                startByte: newStart,
                endByte: oldEnd,
                downloadedBytes: 0,
                state: .pending
            )
        )
        return newId
    }

    // MARK: - Stall Watchdog (Reconnects Hung / Stalled Streams)

    private func startWatchdog() {
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: retryQueue)
        timer.schedule(
            deadline: .now() + Self.watchdogIntervalSeconds,
            repeating: Self.watchdogIntervalSeconds,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.checkStalledConnections()
        }
        lock.lock()
        watchdogTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func cancelWatchdog() {
        lock.lock()
        let timer = watchdogTimer
        watchdogTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func checkStalledConnections() {
        let now = Date().timeIntervalSinceReferenceDate
        var stalled: [(segmentId: Int, conn: SegmentConnection)] = []

        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        for (segId, conn) in activeConnections {
            guard let lastTime = segmentLastActivity[segId],
                  now - lastTime >= Self.stallTimeoutSeconds else {
                continue
            }
            activeConnections.removeValue(forKey: segId)
            sessionToSegment.removeValue(forKey: ObjectIdentifier(conn.session))
            stalled.append((segId, conn))
        }
        lock.unlock()

        for item in stalled {
            item.conn.task.cancel()
            item.conn.session.invalidateAndCancel()
            if !flushSegmentBuffer(item.segmentId, allowWhenStopped: false) {
                return
            }
            scheduleRetry(for: item.segmentId, reason: "连接卡顿，自动切换新连接续传")
        }
    }

    // MARK: - Buffered Disk Flush

    private func accountedBytesLocked(for seg: DownloadSegment) -> Int64 {
        seg.downloadedBytes
            + Int64(segmentBuffers[seg.id]?.count ?? 0)
            + (segmentFlushingBytes[seg.id] ?? 0)
    }

    @discardableResult
    private func flushSegmentBuffer(_ segmentId: Int, allowWhenStopped: Bool) -> Bool {
        lock.lock()
        let flushLock = segmentFlushLocks[segmentId]
        lock.unlock()
        guard let flushLock else { return true }

        flushLock.lock()
        defer { flushLock.unlock() }

        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        guard (allowWhenStopped || !isStopped),
              let idx = segments.firstIndex(where: { $0.id == segmentId }),
              let pending = segmentBuffers[segmentId],
              !pending.isEmpty else {
            lock.unlock()
            return true
        }
        let writeOffset = segments[idx].currentOffset
        let dataToWrite = pending
        let writeCount = Int64(dataToWrite.count)
        segmentBuffers[segmentId]?.removeAll(keepingCapacity: !allowWhenStopped)
        segmentFlushingBytes[segmentId, default: 0] += writeCount
        segmentLastFlushTime[segmentId] = now
        lock.unlock()

        do {
            try fileWriter.write(dataToWrite, at: writeOffset)
        } catch {
            lock.lock()
            segmentFlushingBytes[segmentId] = max(0, (segmentFlushingBytes[segmentId] ?? 0) - writeCount)
            lock.unlock()
            if case FileWriterError.closed = error {
                return false
            }
            finishWith(.failed(error.localizedDescription))
            return false
        }

        lock.lock()
        segmentFlushingBytes[segmentId] = max(0, (segmentFlushingBytes[segmentId] ?? 0) - writeCount)
        if let currentIdx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[currentIdx].downloadedBytes += writeCount
        }
        lock.unlock()
        return true
    }

    // MARK: - Retry & Completion Management

    private func scheduleRetry(for segmentId: Int, reason: String) {
        lock.lock()
        guard !isStopped,
              let idx = segments.firstIndex(where: { $0.id == segmentId }) else {
            lock.unlock()
            return
        }
        if segments[idx].isRangeComplete {
            segments[idx].state = .completed
            segments[idx].speedBytesPerSec = 0
            segments[idx].errorMessage = nil
            lock.unlock()
            handleSegmentFinishedWork(segmentId)
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
        segments[idx].errorMessage = "正在重连 (\(nextAttempt)/\(Self.maxRetriesPerSegment))..."

        let shouldResetSingleStream = !supportsRange
        if shouldResetSingleStream {
            segments[idx].downloadedBytes = 0
            segmentBuffers[segmentId]?.removeAll(keepingCapacity: false)
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

        let delay = min(4.0, 0.5 * Double(nextAttempt))
        retryQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateOverallState() {
        lock.lock()
        guard !isStopped, !didReportCompletion else {
            lock.unlock()
            return
        }
        let allCompleted = segments.allSatisfy { $0.state == .completed }
        let anyInFlight = !activeConnections.isEmpty || !pendingRetryWorkItems.isEmpty
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
        cancelWatchdog()

        lock.lock()
        guard !didReportCompletion else {
            lock.unlock()
            return
        }
        didReportCompletion = true
        isStopped = true
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        sessionToSegment.removeAll()
        let retries = Array(pendingRetryWorkItems.values)
        pendingRetryWorkItems.removeAll()
        let segIds = segments.map(\.id)
        lock.unlock()

        for item in retries {
            item.cancel()
        }
        for conn in conns {
            conn.task.cancel()
            conn.session.invalidateAndCancel()
        }
        for segId in segIds {
            _ = flushSegmentBuffer(segId, allowWhenStopped: true)
        }
        fileWriter.syncAndClose()

        onCompletion(result)
    }

    private func totalDownloadedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.downloadedBytes }
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
        let entry = sessionToSegment[ObjectIdentifier(session)]
        let seg = entry.flatMap { info in segments.first(where: { $0.id == info.segmentId }) }
        lock.unlock()

        var redirected = request
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if supportsRange, let seg, seg.hasKnownLength {
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
              let info = sessionToSegment[ObjectIdentifier(session)],
              activeConnections[info.segmentId]?.token == info.token,
              let idx = segments.firstIndex(where: { $0.id == info.segmentId }) else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let segId = info.segmentId
        let seg = segments[idx]
        let segmentCount = segments.count
        segmentLastActivity[segId] = Date().timeIntervalSinceReferenceDate
        lock.unlock()

        guard let http = response as? HTTPURLResponse else {
            recordFatalSegmentError(segId, message: "无效的服务器响应")
            completionHandler(.cancel)
            return
        }

        let code = http.statusCode

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

        var shouldFlush = false
        var hitSegmentEnd = false
        var targetSegId: Int = -1

        lock.lock()
        guard !isStopped,
              let info = sessionToSegment[ObjectIdentifier(session)],
              activeConnections[info.segmentId]?.token == info.token,
              let idx = segments.firstIndex(where: { $0.id == info.segmentId }) else {
            lock.unlock()
            return
        }

        targetSegId = info.segmentId
        let now = Date().timeIntervalSinceReferenceDate
        let seg = segments[idx]
        let bufferedCount = Int64(segmentBuffers[targetSegId]?.count ?? 0)
        let accounted = accountedBytesLocked(for: seg)
        let lastFlush = segmentLastFlushTime[targetSegId] ?? now

        if seg.hasKnownLength {
            let remaining = seg.totalBytes - accounted
            if remaining <= 0 {
                hitSegmentEnd = true
                shouldFlush = bufferedCount > 0
                lock.unlock()
                if shouldFlush {
                    _ = flushSegmentBuffer(targetSegId, allowWhenStopped: false)
                }
                dataTask.cancel()
                return
            }
            let take = min(data.count, Int(remaining))
            if take == data.count {
                segmentBuffers[targetSegId, default: Data()].append(data)
            } else {
                segmentBuffers[targetSegId, default: Data()].append(data.prefix(take))
            }
            let newBuffered = Int64(segmentBuffers[targetSegId]?.count ?? 0)
            let newAccounted = seg.downloadedBytes + newBuffered + (segmentFlushingBytes[targetSegId] ?? 0)
            if newAccounted >= seg.totalBytes {
                hitSegmentEnd = true
                shouldFlush = true
            } else if newBuffered >= Int64(Self.writeBufferThreshold)
                        || (newBuffered > 0 && now - lastFlush >= Self.writeBufferMaxAgeSeconds) {
                shouldFlush = true
            }
        } else {
            segmentBuffers[targetSegId, default: Data()].append(data)
            let newBuffered = segmentBuffers[targetSegId]?.count ?? 0
            if newBuffered >= Self.writeBufferThreshold
                || (newBuffered > 0 && now - lastFlush >= Self.writeBufferMaxAgeSeconds) {
                shouldFlush = true
            }
        }

        segmentLastActivity[targetSegId] = now
        retryCounts[targetSegId] = 0
        lock.unlock()

        if shouldFlush {
            guard flushSegmentBuffer(targetSegId, allowWhenStopped: false) else { return }
        }
        if hitSegmentEnd {
            // If this segment's endByte was shrunk by dynamic work stealing, cancel the tail cleanly now
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sessionKey = ObjectIdentifier(session)

        lock.lock()
        guard let info = sessionToSegment.removeValue(forKey: sessionKey) else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        let segId = info.segmentId
        let isCurrentConnection = (activeConnections[segId]?.token == info.token)
        if isCurrentConnection {
            activeConnections.removeValue(forKey: segId)
        }
        let stopped = isStopped
        lock.unlock()

        // Always invalidate this segment's ephemeral session immediately to prevent leaks
        session.invalidateAndCancel()

        if stopped || !isCurrentConnection {
            return
        }

        // Flush any remaining buffered bytes before inspecting completion state
        guard flushSegmentBuffer(segId, allowWhenStopped: false) else { return }

        lock.lock()
        guard !isStopped,
              let idx = segments.firstIndex(where: { $0.id == segId }) else {
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
                handleSegmentFinishedWork(segId)
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
        handleSegmentFinishedWork(segId)
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
             NSURLErrorDataNotAllowed,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
