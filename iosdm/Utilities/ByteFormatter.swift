import Foundation

enum ByteFormatter {
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "未知大小" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        } else if value >= 100 {
            return String(format: "%.1f %@", value, units[unitIndex])
        } else {
            return String(format: "%.2f %@", value, units[unitIndex])
        }
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite && bytesPerSecond > 0 else {
            return "0 B/s"
        }
        return "\(formatBytes(Int64(bytesPerSecond)))/s"
    }

    static func formatETA(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 359_999 else {
            return "--:--"
        }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    static func sanitizeFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip path separators and control characters
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0").union(.controlCharacters)
        name = name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            return "download_\(formatter.string(from: Date()))"
        }
        // Keep filename reasonable for APFS/iOS limits (255 bytes)
        if name.utf8.count > 200 {
            let ns = name as NSString
            let ext = ns.pathExtension
            let stem = ext.isEmpty ? name : ns.deletingPathExtension
            let clippedStem = String(stem.prefix(80))
            name = ext.isEmpty ? clippedStem : "\(clippedStem).\(ext)"
        }
        return name
    }

    static func fileNameFromContentDisposition(_ header: String) -> String? {
        // 1. RFC 5987: filename*=UTF-8''percent-encoded-name
        if let regex = try? NSRegularExpression(
            pattern: #"filename\*\s*=\s*(?:[^']*)'[^']*'([^;\r\n]+)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(header.startIndex..., in: header)
            if let match = regex.firstMatch(in: header, range: range),
               let valueRange = Range(match.range(at: 1), in: header) {
                let encoded = String(header[valueRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let decoded = encoded.removingPercentEncoding ?? encoded
                if !decoded.isEmpty {
                    return sanitizeFileName(decoded)
                }
            }
        }

        // 2. Quoted filename="..."
        if let regex = try? NSRegularExpression(
            pattern: #"filename\s*=\s*"([^"]+)""#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(header.startIndex..., in: header)
            if let match = regex.firstMatch(in: header, range: range),
               let valueRange = Range(match.range(at: 1), in: header) {
                let value = String(header[valueRange])
                let decoded = value.removingPercentEncoding ?? value
                if !decoded.isEmpty {
                    return sanitizeFileName(decoded)
                }
            }
        }

        // 3. Unquoted filename=foo.zip
        if let regex = try? NSRegularExpression(
            pattern: #"filename\s*=\s*([^;\r\n]+)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(header.startIndex..., in: header)
            if let match = regex.firstMatch(in: header, range: range),
               let valueRange = Range(match.range(at: 1), in: header) {
                let value = String(header[valueRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let decoded = value.removingPercentEncoding ?? value
                if !decoded.isEmpty {
                    return sanitizeFileName(decoded)
                }
            }
        }

        return nil
    }

    static func fileNameFromURL(_ url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        let decoded = last.removingPercentEncoding ?? last
        let cleaned = sanitizeFileName(decoded)
        return cleaned.isEmpty ? nil : cleaned
    }
}
