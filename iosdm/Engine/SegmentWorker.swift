import Foundation

enum RunnerCompletion: Sendable {
    case completed(totalBytesWritten: Int64)
    case cancelled
    case requiresRestartSingleStream(reason: String)
    case requiresLinkRefresh(reason: String)
    case failed(String)
}

struct RunnerRuntimeStatus: Sendable {
    let activeConcurrencyLimit: Int
    let targetConcurrency: Int
    let isAdaptiveThrottled: Bool
}

final class TaskDownloadRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxRetriesPerSegment = 10
    static let maxThreadCount = 16
    static let minimumBytesPerSegment: Int64 = 512 * 1024        // 512 KB initial split floor
    static let minimumStealRemainingBytes: Int64 = 256 * 1024    // 256 KB aggressive tail work-stealing floor
    static let writeBufferThreshold: Int = 512 * 1024            // 512 KB zero-copy swap write buffer
    static let writeBufferMaxAgeSeconds: TimeInterval = 0.4      // Smooth progress flush on slow links
    static let maxQueuedWriteBytesPerSegment: Int64 = 4 * 1024 * 1024
    static let stallTimeoutSeconds: TimeInterval = 10.0          // Dead-stall reconnect threshold
    static let slowThreadMinAgeSeconds: TimeInterval = 8.0       // Min lifetime before evaluating slow replacement
    static let slowThreadCooldownSeconds: TimeInterval = 12.0
    static let watchdogIntervalSeconds: TimeInterval = 3.0
    static let rampIntervalSeconds: TimeInterval = 0.25          // Smooth staggered connection ramp-up
    static let dropWindowSeconds: TimeInterval = 15.0            // Rolling window for server -1005 / 429 detection
    static let recoveryProbeIntervalSeconds: TimeInterval = 20.0 // Gentle concurrency recovery after 20s zero drops
    static let maxTotalDynamicSegments = 64

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
    private let maxTargetConcurrency: Int
    private let fileWriter: FileWriter
    private let onCompletion: @Sendable (RunnerCompletion) -> Void

    private let lock = NSLock()
    private var segments: [DownloadSegment]
    private var nextSegmentId: Int

    // Adaptive concurrency state (protected by `lock`)
    private var adaptiveConcurrencyLimit: Int
    private var isAdaptiveThrottled = false
    private var recentDropTimestamps: [TimeInterval] = []
    private var lastDropAt: TimeInterval = 0
    private var lastStepDownAt: TimeInterval = 0
    private var rampScheduled = false

    // Active connections & per-segment runtime state (protected by `lock`)
    private var activeConnections: [Int: SegmentConnection] = [:]
    private var claimingSegmentIds: Set<Int> = []
    private var sessionToSegment: [ObjectIdentifier: (segmentId: Int, token: UUID)] = [:]
    private var segmentBuffers: [Int: Data] = [:]
    private var segmentQueuedWriteBytes: [Int: Int64] = [:]
    private var segmentLastFlushTime: [Int: TimeInterval] = [:]
    private var segmentLastActivity: [Int: TimeInterval] = [:]
    private var segmentConnectedAt: [Int: TimeInterval] = [:]
    private var segmentLastSlowReplaceAt: [Int: TimeInterval] = [:]
    private var retryCounts: [Int: Int] = [:]
    private var pendingRetryWorkItems: [Int: DispatchWorkItem] = [:]
    private var segmentFatalErrors: [Int: String] = [:]
    private var segmentSpeedSamples: [Int: (bytes: Int64, timestamp: TimeInterval)] = [:]
    private var isStopped = false
    private var didReportCompletion = false

    private var watchdogTimer: DispatchSourceTimer?
    private let controlQueue = DispatchQueue(label: "com.iosdm.runner.control", qos: .userInitiated)
    private let diskIOQueues: [DispatchQueue]
    private let diskWriteGroup = DispatchGroup()

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
        let target = supportsRange ? max(1, min(Self.maxThreadCount, requestedThreadCount ?? segments.count)) : 1
        self.maxTargetConcurrency = target
        self.adaptiveConcurrencyLimit = target
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
        self.diskIOQueues = (0..<4).map { idx in
            DispatchQueue(label: "com.iosdm.diskio.\(taskId.uuidString).\(idx)", qos: .utility)
        }
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

        let clampedThreads = max(1, min(Self.maxThreadCount, requestedThreads))
        let maxUsefulThreads = Int(max(1, totalBytes / minimumBytesPerSegment))
        let count = max(1, min(clampedThreads, maxUsefulThreads))
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

    func runtimeStatus() -> RunnerRuntimeStatus {
        lock.lock()
        defer { lock.unlock() }
        return RunnerRuntimeStatus(
            activeConcurrencyLimit: adaptiveConcurrencyLimit,
            targetConcurrency: maxTargetConcurrency,
            isAdaptiveThrottled: isAdaptiveThrottled
        )
    }

    func start() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        var initialPending: [Int] = []
        for idx in segments.indices {
            if segments[idx].state == .completed || segments[idx].isRangeComplete {
                segments[idx].state = .completed
                segments[idx].speedBytesPerSec = 0
            } else {
                segments[idx].state = .pending
                segments[idx].errorMessage = nil
                initialPending.append(segments[idx].id)
            }
        }
        let allDone = segments.allSatisfy { $0.state == .completed }
        let immediateBurst = min(2, min(adaptiveConcurrencyLimit, initialPending.count))
        let firstBatch = Array(initialPending.prefix(immediateBurst))
        for segId in firstBatch {
            claimingSegmentIds.insert(segId)
        }
        let hasMoreToRamp = initialPending.count > immediateBurst
        lock.unlock()

        if allDone {
            finishWith(.completed(totalBytesWritten: totalDownloadedBytes()))
            return
        }

        startWatchdog()

        // Launch initial 2 connections immediately for instant startup, then ramp smoothly every 250ms
        for segId in firstBatch {
            launchSegment(segId)
        }
        if hasMoreToRamp {
            scheduleNextRampStep()
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
        claimingSegmentIds.removeAll()
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

        // Flush all memory buffers and wait for all async disk writes to complete before closing fd
        for segId in allSegmentIds {
            _ = flushSegmentBuffer(segId, wait: true, allowWhenStopped: true)
        }
        diskWriteGroup.wait()
        fileWriter.syncAndClose()

        lock.lock()
        let finalSnapshot = segments
        lock.unlock()
        return finalSnapshot
    }

    // MARK: - Smooth Staggered Ramp & Adaptive Scheduler

    private func scheduleNextRampStep() {
        lock.lock()
        guard !isStopped, !rampScheduled else {
            lock.unlock()
            return
        }
        rampScheduled = true
        lock.unlock()

        controlQueue.asyncAfter(deadline: .now() + Self.rampIntervalSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.rampScheduled = false
            let stopped = self.isStopped
            self.lock.unlock()
            guard !stopped else { return }

            if let nextSegId = self.claimNextLaunchableSegment(allowSteal: false) {
                self.launchSegment(nextSegId)
                // Keep ramping until we hit adaptiveConcurrencyLimit or run out of pending segments
                if self.hasMorePendingCapacity() {
                    self.scheduleNextRampStep()
                }
            }
        }
    }

    private func hasMorePendingCapacity() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        let inFlight = activeConnections.count + pendingRetryWorkItems.count + claimingSegmentIds.count
        guard inFlight < adaptiveConcurrencyLimit else { return false }
        return segments.contains { seg in
            seg.state == .pending
                && !seg.isRangeComplete
                && activeConnections[seg.id] == nil
                && pendingRetryWorkItems[seg.id] == nil
                && !claimingSegmentIds.contains(seg.id)
        }
    }

    private func dispatchPendingOrStealWork() {
        while let nextSegId = claimNextLaunchableSegment(allowSteal: true) {
            launchSegment(nextSegId)
        }
        evaluateOverallState()
    }

    private func claimNextLaunchableSegment(allowSteal: Bool) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard !isStopped else { return nil }
        let inFlight = activeConnections.count + pendingRetryWorkItems.count + claimingSegmentIds.count
        guard inFlight < adaptiveConcurrencyLimit else { return nil }

        // 1. Prefer any unfinished .pending segment not currently scheduled for retry
        if let pendingIdx = segments.firstIndex(where: { seg in
            seg.state == .pending
                && !seg.isRangeComplete
                && activeConnections[seg.id] == nil
                && pendingRetryWorkItems[seg.id] == nil
                && !claimingSegmentIds.contains(seg.id)
        }) {
            let segId = segments[pendingIdx].id
            segments[pendingIdx].state = .downloading
            claimingSegmentIds.insert(segId)
            return segId
        }

        // 2. Otherwise dynamically steal half of the largest remaining active segment (down to 256 KB)
        guard allowSteal, supportsRange, segments.count < Self.maxTotalDynamicSegments else {
            return nil
        }

        var bestIndex: Int?
        var bestRemaining: Int64 = 0

        for idx in segments.indices {
            let seg = segments[idx]
            guard seg.hasKnownLength,
                  seg.state == .downloading,
                  activeConnections[seg.id] != nil else {
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
                state: .downloading
            )
        )
        claimingSegmentIds.insert(newId)
        return newId
    }

    /// Detects server anti-flood / connection-limit resets (-1005, 429, 503) and lowers concurrency to keep surviving streams full speed.
    private func recordConnectionDrop(isRateLimit: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }

        lastDropAt = now
        recentDropTimestamps.append(now)
        recentDropTimestamps.removeAll { now - $0 > Self.dropWindowSeconds }

        guard supportsRange, maxTargetConcurrency > 1 else { return }

        let floorLimit = isRateLimit ? 1 : 2
        let shouldStepDown = isRateLimit || recentDropTimestamps.count >= 2
        if shouldStepDown && adaptiveConcurrencyLimit > floorLimit {
            let reduced = max(floorLimit, adaptiveConcurrencyLimit / 2)
            adaptiveConcurrencyLimit = reduced
            isAdaptiveThrottled = reduced < maxTargetConcurrency
            lastStepDownAt = now
            recentDropTimestamps.removeAll()
        }
    }

    // MARK: - Safari-Tuned Independent Session & Segment Launch

    private func makeIndependentSession(for segmentId: Int) -> URLSession {
        let queue = OperationQueue()
        queue.name = "com.iosdm.seg.\(taskId.uuidString).\(segmentId)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        // Independent ephemeral session per active thread avoids HTTP/2 single-socket coalescing
        // while enabling iOS high-priority responsiveData socket tuning and HTTP/3 QUIC racing.
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = allowsCellularAccess
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.networkServiceType = .responsiveData
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
        // Ensure all queued async writes for this segment finish so currentOffset is exact
        _ = flushSegmentBuffer(segmentId, wait: true, allowWhenStopped: false)

        lock.lock()
        claimingSegmentIds.remove(segmentId)
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
            dispatchPendingOrStealWork()
            return
        }

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
        segmentConnectedAt[segmentId] = now
        segmentLastFlushTime[segmentId] = now
        segmentSpeedSamples[segmentId] = (seg.downloadedBytes, now)
        if segmentBuffers[segmentId] == nil {
            var buf = Data()
            buf.reserveCapacity(Self.writeBufferThreshold)
            segmentBuffers[segmentId] = buf
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.networkServiceType = .responsiveData
        if #available(iOS 15.0, macOS 12.0, *) {
            request.assumesHTTP3Capable = true
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

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
            // Attach If-Range when resuming partially written bytes to guarantee remote file consistency
            if seg.downloadedBytes > 0 {
                if let eTag, !eTag.isEmpty, !eTag.hasPrefix("W/") {
                    request.setValue(eTag, forHTTPHeaderField: "If-Range")
                } else if let lastModified, !lastModified.isEmpty {
                    request.setValue(lastModified, forHTTPHeaderField: "If-Range")
                }
            }
        }

        let token = UUID()
        let segSession = makeIndependentSession(for: segmentId)
        let dataTask = segSession.dataTask(with: request)
        dataTask.priority = URLSessionTask.highPriority
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

    // MARK: - Watchdog (Dead Stall + Zombie Slow-Thread Replacement + Gentle Concurrency Recovery)

    private func startWatchdog() {
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(
            deadline: .now() + Self.watchdogIntervalSeconds,
            repeating: Self.watchdogIntervalSeconds,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.runWatchdogTick()
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

    private func runWatchdogTick() {
        let now = Date().timeIntervalSinceReferenceDate
        var stalled: [(segmentId: Int, conn: SegmentConnection)] = []
        var slowToReplace: (segmentId: Int, conn: SegmentConnection)? = nil
        var shouldDispatchMore = false

        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }

        // 1. Detect completely stalled connections (idle >= 10s)
        for (segId, conn) in activeConnections {
            guard let lastTime = segmentLastActivity[segId],
                  now - lastTime >= Self.stallTimeoutSeconds else {
                continue
            }
            activeConnections.removeValue(forKey: segId)
            sessionToSegment.removeValue(forKey: ObjectIdentifier(conn.session))
            stalled.append((segId, conn))
        }

        // 2. Detect zombie slow threads when multiple connections are healthy and not in anti-RST cooldown
        let inAntiThrottleCooldown = (now - lastStepDownAt < 15.0) || (now - lastDropAt < 15.0)
        if stalled.isEmpty && !inAntiThrottleCooldown && activeConnections.count >= 2 {
            var matureSpeeds: [(segId: Int, speed: Double, remaining: Int64)] = []
            for seg in segments where activeConnections[seg.id] != nil && seg.state == .downloading {
                guard let connectedAt = segmentConnectedAt[seg.id],
                      now - connectedAt >= Self.slowThreadMinAgeSeconds else {
                    continue
                }
                let remaining = seg.hasKnownLength ? max(0, seg.totalBytes - accountedBytesLocked(for: seg)) : Int64.max
                matureSpeeds.append((seg.id, seg.speedBytesPerSec, remaining))
            }

            if matureSpeeds.count >= 2 {
                let sorted = matureSpeeds.map(\.speed).sorted()
                let medianOrHigh = sorted[sorted.count / 2]
                if medianOrHigh >= 400_000 { // Only replace when peers are healthy (>= 400 KB/s)
                    let slowThreshold = max(80_000.0, medianOrHigh * 0.15)
                    if let slowest = matureSpeeds.min(by: { $0.speed < $1.speed }),
                       slowest.speed < slowThreshold,
                       slowest.remaining >= 512 * 1024,
                       now - (segmentLastSlowReplaceAt[slowest.segId] ?? 0) >= Self.slowThreadCooldownSeconds,
                       let conn = activeConnections.removeValue(forKey: slowest.segId) {
                        sessionToSegment.removeValue(forKey: ObjectIdentifier(conn.session))
                        segmentLastSlowReplaceAt[slowest.segId] = now
                        slowToReplace = (slowest.segId, conn)
                    }
                }
            }
        }

        // 3. Gentle concurrency recovery probe (+1) after 20s of zero drops
        if supportsRange && adaptiveConcurrencyLimit < maxTargetConcurrency {
            let quietSinceDrop = now - lastDropAt >= Self.recoveryProbeIntervalSeconds
            let quietSinceStep = now - lastStepDownAt >= Self.recoveryProbeIntervalSeconds
            if quietSinceDrop && quietSinceStep {
                let totalRemaining = segments.reduce(Int64(0)) { acc, seg in
                    guard seg.hasKnownLength, seg.state != .completed else { return acc }
                    return acc + max(0, seg.totalBytes - accountedBytesLocked(for: seg))
                }
                if totalRemaining > 4 * 1024 * 1024 {
                    adaptiveConcurrencyLimit += 1
                    isAdaptiveThrottled = adaptiveConcurrencyLimit < maxTargetConcurrency
                    lastStepDownAt = now
                    shouldDispatchMore = true
                }
            }
        }

        // 4. Also check if we have spare capacity for queued pending segments
        if activeConnections.count + pendingRetryWorkItems.count < adaptiveConcurrencyLimit {
            let hasPending = segments.contains { seg in
                seg.state == .pending && !seg.isRangeComplete && activeConnections[seg.id] == nil && pendingRetryWorkItems[seg.id] == nil
            }
            if hasPending {
                shouldDispatchMore = true
            }
        }
        lock.unlock()

        for item in stalled {
            item.conn.task.cancel()
            item.conn.session.invalidateAndCancel()
            if !flushSegmentBuffer(item.segmentId, wait: true, allowWhenStopped: false) {
                return
            }
            recordConnectionDrop(isRateLimit: false)
            handleSegmentDropOrRetry(segmentId: item.segmentId, reason: "连接卡顿，自动切换新连接续传", hadProgress: true)
        }

        if let slow = slowToReplace {
            slow.conn.task.cancel()
            slow.conn.session.invalidateAndCancel()
            if flushSegmentBuffer(slow.segmentId, wait: true, allowWhenStopped: false) {
                launchSegment(slow.segmentId)
            }
        }

        if shouldDispatchMore {
            dispatchPendingOrStealWork()
        }
    }

    // MARK: - Zero-Copy Swap & Asynchronous Disk I/O Queue

    private func accountedBytesLocked(for seg: DownloadSegment) -> Int64 {
        seg.downloadedBytes
            + (segmentQueuedWriteBytes[seg.id] ?? 0)
            + Int64(segmentBuffers[seg.id]?.count ?? 0)
    }

    @discardableResult
    private func flushSegmentBuffer(_ segmentId: Int, wait: Bool, allowWhenStopped: Bool) -> Bool {
        let ioQueue = diskIOQueues[abs(segmentId) % diskIOQueues.count]
        let now = Date().timeIntervalSinceReferenceDate

        var dataToWrite: Data? = nil
        var writeOffset: Int64 = 0
        var shouldBackpressure = false

        lock.lock()
        if (allowWhenStopped || !isStopped),
           let idx = segments.firstIndex(where: { $0.id == segmentId }),
           let popped = segmentBuffers.removeValue(forKey: segmentId),
           !popped.isEmpty {
            let queued = segmentQueuedWriteBytes[segmentId] ?? 0
            writeOffset = segments[idx].startByte + segments[idx].downloadedBytes + queued
            let writeCount = Int64(popped.count)
            segmentQueuedWriteBytes[segmentId] = queued + writeCount
            segmentLastFlushTime[segmentId] = now
            shouldBackpressure = (queued + writeCount) >= Self.maxQueuedWriteBytesPerSegment
            dataToWrite = popped

            if !allowWhenStopped {
                var fresh = Data()
                fresh.reserveCapacity(Self.writeBufferThreshold)
                segmentBuffers[segmentId] = fresh
            }
        }
        lock.unlock()

        if wait {
            var writeSuccess = true
            ioQueue.sync {
                if let payload = dataToWrite {
                    writeSuccess = self.performDiskWrite(payload, at: writeOffset, for: segmentId, isSyncCall: true)
                }
            }
            return writeSuccess
        }

        guard let payload = dataToWrite else { return true }

        diskWriteGroup.enter()
        ioQueue.async { [weak self] in
            defer { self?.diskWriteGroup.leave() }
            guard let self else { return }
            _ = self.performDiskWrite(payload, at: writeOffset, for: segmentId, isSyncCall: false)
        }

        // Apply gentle backpressure if disk queue grows beyond 4 MB for this segment
        if shouldBackpressure {
            ioQueue.sync {}
        }
        return true
    }

    private func performDiskWrite(_ payload: Data, at writeOffset: Int64, for segmentId: Int, isSyncCall: Bool) -> Bool {
        let writeCount = Int64(payload.count)
        do {
            try fileWriter.write(payload, at: writeOffset)
        } catch {
            lock.lock()
            segmentQueuedWriteBytes[segmentId] = max(0, (segmentQueuedWriteBytes[segmentId] ?? 0) - writeCount)
            lock.unlock()
            if case FileWriterError.closed = error {
                return false
            }
            let msg = error.localizedDescription
            if isSyncCall {
                finishWith(.failed(msg))
            } else {
                // Dispatch off ioQueue so finishWith's diskWriteGroup.wait() can never deadlock
                controlQueue.async { [weak self] in
                    self?.finishWith(.failed(msg))
                }
            }
            return false
        }

        lock.lock()
        segmentQueuedWriteBytes[segmentId] = max(0, (segmentQueuedWriteBytes[segmentId] ?? 0) - writeCount)
        if let currentIdx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[currentIdx].downloadedBytes += writeCount
        }
        lock.unlock()
        return true
    }

    // MARK: - Adaptive Drop Handling, Retry & Completion

    private func handleSegmentDropOrRetry(segmentId: Int, reason: String, hadProgress: Bool) {
        lock.lock()
        claimingSegmentIds.remove(segmentId)
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
            dispatchPendingOrStealWork()
            return
        }

        // If adaptive concurrency already stepped down and surviving connections fill the quota,
        // keep this segment queued as .pending so surviving fast threads pick it up without triggering another RST!
        let currentInFlight = activeConnections.count + pendingRetryWorkItems.count + claimingSegmentIds.count
        if supportsRange && currentInFlight >= adaptiveConcurrencyLimit && activeConnections.count > 0 {
            segments[idx].state = .pending
            segments[idx].speedBytesPerSec = 0
            segments[idx].errorMessage = nil
            lock.unlock()
            return
        }

        let nextAttempt = hadProgress ? 1 : ((retryCounts[segmentId] ?? 0) + 1)
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
            let overQuota = self.supportsRange
                && (self.activeConnections.count >= self.adaptiveConcurrencyLimit)
                && !self.activeConnections.isEmpty
            if overQuota, let curIdx = self.segments.firstIndex(where: { $0.id == segmentId }) {
                self.segments[curIdx].state = .pending
                self.segments[curIdx].errorMessage = nil
            }
            self.lock.unlock()
            guard !stopped, !overQuota else { return }

            if shouldResetSingleStream {
                try? self.fileWriter.truncate(to: 0)
            }
            self.launchSegment(segmentId)
        }
        pendingRetryWorkItems[segmentId] = workItem
        lock.unlock()

        let delay = hadProgress ? 0.3 : min(4.0, 0.5 * Double(nextAttempt))
        controlQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateOverallState() {
        lock.lock()
        guard !isStopped, !didReportCompletion else {
            lock.unlock()
            return
        }
        let allCompleted = segments.allSatisfy { $0.state == .completed }
        let anyInFlight = !activeConnections.isEmpty || !pendingRetryWorkItems.isEmpty || !claimingSegmentIds.isEmpty
        let hasPendingUnfinished = segments.contains { $0.state == .pending && !$0.isRangeComplete }
        let firstError = segments.first(where: { $0.state == .failed })?.errorMessage
        let total = segments.reduce(0) { $0 + $1.downloadedBytes }
        lock.unlock()

        if allCompleted {
            finishWith(.completed(totalBytesWritten: total))
        } else if !anyInFlight && hasPendingUnfinished {
            dispatchPendingOrStealWork()
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
        claimingSegmentIds.removeAll()
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
            _ = flushSegmentBuffer(segId, wait: true, allowWhenStopped: true)
        }
        diskWriteGroup.wait()
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
        redirected.networkServiceType = .responsiveData
        if #available(iOS 15.0, macOS 12.0, *) {
            redirected.assumesHTTP3Capable = true
        }
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
                if code == 429 || code == 503 {
                    recordConnectionDrop(isRateLimit: true)
                }
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
                    _ = flushSegmentBuffer(targetSegId, wait: true, allowWhenStopped: false)
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
            let newAccounted = seg.downloadedBytes + (segmentQueuedWriteBytes[targetSegId] ?? 0) + newBuffered
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
            guard flushSegmentBuffer(targetSegId, wait: hitSegmentEnd, allowWhenStopped: false) else { return }
        }
        if hitSegmentEnd {
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
        let hadProgress = (retryCounts[segId] ?? 0) == 0 && task.countOfBytesReceived > 0
        lock.unlock()

        session.invalidateAndCancel()

        if stopped || !isCurrentConnection {
            return
        }

        // Wait for all queued async writes of this segment to flush cleanly before evaluating completion
        guard flushSegmentBuffer(segId, wait: true, allowWhenStopped: false) else { return }

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
                dispatchPendingOrStealWork()
                return
            }

            let hasRetryableHTTPMessage = segments[idx].errorMessage != nil
            let pendingRetryReason = segments[idx].errorMessage ?? error.localizedDescription
            lock.unlock()

            if Self.isRetryableError(nsError) || hasRetryableHTTPMessage {
                let isConnectionDrop = (nsError.domain == NSURLErrorDomain && (
                    nsError.code == NSURLErrorNetworkConnectionLost
                    || nsError.code == NSURLErrorTimedOut
                    || nsError.code == NSURLErrorCannotConnectToHost
                ))
                if isConnectionDrop {
                    recordConnectionDrop(isRateLimit: false)
                }
                handleSegmentDropOrRetry(segmentId: segId, reason: pendingRetryReason, hadProgress: hadProgress)
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
            recordConnectionDrop(isRateLimit: false)
            handleSegmentDropOrRetry(segmentId: segId, reason: "连接提前断开，已自动续传重试", hadProgress: hadProgress)
            return
        }

        segments[idx].state = .completed
        segments[idx].speedBytesPerSec = 0
        segments[idx].errorMessage = nil
        lock.unlock()
        dispatchPendingOrStealWork()
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
