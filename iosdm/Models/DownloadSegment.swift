import Foundation

enum SegmentState: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case completed
    case failed

    var displayTitle: String {
        switch self {
        case .pending: return "等待"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
}

struct DownloadSegment: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let startByte: Int64
    var endByte: Int64 // -1 means unknown length single-stream download
    var downloadedBytes: Int64
    var state: SegmentState
    var errorMessage: String?

    // Transient runtime field (not persisted)
    var speedBytesPerSec: Double = 0

    enum CodingKeys: String, CodingKey {
        case id
        case startByte
        case endByte
        case downloadedBytes
        case state
        case errorMessage
    }

    init(
        id: Int,
        startByte: Int64,
        endByte: Int64,
        downloadedBytes: Int64 = 0,
        state: SegmentState = .pending,
        errorMessage: String? = nil,
        speedBytesPerSec: Double = 0
    ) {
        self.id = id
        self.startByte = startByte
        self.endByte = endByte
        self.downloadedBytes = downloadedBytes
        self.state = state
        self.errorMessage = errorMessage
        self.speedBytesPerSec = speedBytesPerSec
    }

    var hasKnownLength: Bool {
        endByte >= startByte
    }

    var totalBytes: Int64 {
        hasKnownLength ? (endByte - startByte + 1) : -1
    }

    var currentOffset: Int64 {
        startByte + downloadedBytes
    }

    var remainingBytes: Int64 {
        guard hasKnownLength else { return -1 }
        return max(0, totalBytes - downloadedBytes)
    }

    var isRangeComplete: Bool {
        hasKnownLength && downloadedBytes >= totalBytes
    }

    var progress: Double {
        if state == .completed { return 1.0 }
        guard hasKnownLength, totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }
}
