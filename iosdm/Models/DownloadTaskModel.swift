import Foundation

enum DownloadTaskStatus: String, Codable, Sendable {
    case queued
    case probing
    case downloading
    case paused
    case completed
    case failed

    var displayTitle: String {
        switch self {
        case .queued: return "排队中"
        case .probing: return "解析中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }

    var isActive: Bool {
        self == .probing || self == .downloading
    }
}

struct DownloadTaskModel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var originalURL: String
    var resolvedURL: String?
    var cloudSourceURL: String?
    var cloudProvider: String?
    var fileName: String
    var savedFileName: String?
    var requestedThreadCount: Int
    var customHeaders: [String: String]
    var resolvedHeaders: [String: String]
    var proxyModeOverride: ProxyMode?
    var totalBytes: Int64 // -1 if unknown
    var supportsRange: Bool
    var eTag: String?
    var lastModified: String?
    var mimeType: String?
    var status: DownloadTaskStatus
    var errorMessage: String?
    var segments: [DownloadSegment]
    var createdAt: Date
    var completedAt: Date?

    // Transient runtime fields (not persisted)
    var speedBytesPerSec: Double = 0
    var etaSeconds: Double? = nil
    var pausedByBackground: Bool = false
    var adaptiveConcurrencyLimit: Int = 0
    var isAdaptiveThrottled: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case originalURL
        case resolvedURL
        case cloudSourceURL
        case cloudProvider
        case fileName
        case savedFileName
        case requestedThreadCount
        case customHeaders
        case resolvedHeaders
        case proxyModeOverride
        case totalBytes
        case supportsRange
        case eTag
        case lastModified
        case mimeType
        case status
        case errorMessage
        case segments
        case createdAt
        case completedAt
    }

    init(
        id: UUID = UUID(),
        originalURL: String,
        resolvedURL: String? = nil,
        cloudSourceURL: String? = nil,
        cloudProvider: String? = nil,
        fileName: String,
        savedFileName: String? = nil,
        requestedThreadCount: Int = 8,
        customHeaders: [String: String] = [:],
        resolvedHeaders: [String: String] = [:],
        proxyModeOverride: ProxyMode? = nil,
        totalBytes: Int64 = -1,
        supportsRange: Bool = false,
        eTag: String? = nil,
        lastModified: String? = nil,
        mimeType: String? = nil,
        status: DownloadTaskStatus = .queued,
        errorMessage: String? = nil,
        segments: [DownloadSegment] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.originalURL = originalURL
        self.resolvedURL = resolvedURL
        self.cloudSourceURL = cloudSourceURL
        self.cloudProvider = cloudProvider
        self.fileName = fileName
        self.savedFileName = savedFileName
        self.requestedThreadCount = max(1, min(16, requestedThreadCount))
        self.customHeaders = customHeaders
        self.resolvedHeaders = resolvedHeaders
        self.proxyModeOverride = proxyModeOverride
        self.totalBytes = totalBytes
        self.supportsRange = supportsRange
        self.eTag = eTag
        self.lastModified = lastModified
        self.mimeType = mimeType
        self.status = status
        self.errorMessage = errorMessage
        self.segments = segments
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalURL = try c.decode(String.self, forKey: .originalURL)
        resolvedURL = try c.decodeIfPresent(String.self, forKey: .resolvedURL)
        cloudSourceURL = try c.decodeIfPresent(String.self, forKey: .cloudSourceURL)
        cloudProvider = try c.decodeIfPresent(String.self, forKey: .cloudProvider)
        fileName = try c.decode(String.self, forKey: .fileName)
        savedFileName = try c.decodeIfPresent(String.self, forKey: .savedFileName)
        requestedThreadCount = max(1, min(16, try c.decodeIfPresent(Int.self, forKey: .requestedThreadCount) ?? 8))
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        resolvedHeaders = try c.decodeIfPresent([String: String].self, forKey: .resolvedHeaders) ?? [:]
        proxyModeOverride = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyModeOverride)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? -1
        supportsRange = try c.decodeIfPresent(Bool.self, forKey: .supportsRange) ?? false
        eTag = try c.decodeIfPresent(String.self, forKey: .eTag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        status = try c.decodeIfPresent(DownloadTaskStatus.self, forKey: .status) ?? .paused
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        segments = try c.decodeIfPresent([DownloadSegment].self, forKey: .segments) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    var effectiveURLString: String {
        resolvedURL ?? originalURL
    }

    var mergedHeaders: [String: String] {
        var combined = resolvedHeaders
        for (k, v) in customHeaders {
            combined[k] = v
        }
        return combined
    }

    var downloadedBytes: Int64 {
        if status == .completed && totalBytes >= 0 {
            return totalBytes
        }
        return segments.reduce(0) { $0 + $1.downloadedBytes }
    }

    var progress: Double {
        if status == .completed { return 1.0 }
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var activeSegmentCount: Int {
        segments.filter { $0.state == .downloading }.count
    }

    var canPause: Bool {
        status == .downloading || status == .probing || status == .queued
    }

    var canResume: Bool {
        status == .paused || status == .failed
    }

    var isResumableDisplayText: String {
        if status == .queued || (status == .probing && segments.isEmpty) {
            return "待检测"
        }
        return supportsRange ? "可断点续传" : "不支持续传"
    }
}
