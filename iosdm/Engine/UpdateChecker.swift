import Foundation

struct RemoteVersionManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int?
    let notes: String?
    let releaseURL: String?
    let universalIPAURL: String?
    let iPhoneIPAURL: String?
}

enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(latestVersion: String, notes: String, releaseURL: URL, directIPAURL: URL?)
    case failed(String)
}

enum UpdateChecker {
    static let repoReleasesLatestURL = "https://github.com/amiamii1983/iosdm/releases/latest"
    static let manifestDownloadURL = "https://github.com/amiamii1983/iosdm/releases/latest/download/version.json"

    static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// Manual on-demand update check (zero background polling).
    /// Reads Release CDN version.json first to avoid GitHub API 60/hr IP rate limits,
    /// falling back to parsing the releases/latest redirect tag.
    static func checkForUpdates(
        currentVersion: String = currentAppVersion,
        isPad: Bool = false,
        proxySettings: ProxySettingsData = ProxySettingsData()
    ) async -> UpdateCheckOutcome {
        // 1. Try lightweight version.json hosted as a GitHub Release asset (CDN-backed)
        if let manifestURL = URL(string: manifestDownloadURL),
           let manifest = await fetchManifest(url: manifestURL, proxySettings: proxySettings) {
            return evaluate(manifest: manifest, currentVersion: currentVersion, isPad: isPad)
        }

        // 2. Fallback: inspect redirect of /releases/latest -> /releases/tag/vX.Y.Z
        if let latestURL = URL(string: repoReleasesLatestURL),
           let tagVersion = await fetchLatestTagViaRedirect(url: latestURL, proxySettings: proxySettings) {
            let fallbackReleaseURL = URL(string: "https://github.com/amiamii1983/iosdm/releases/tag/\(tagVersion)") ?? latestURL
            let ipaName = isPad ? "iosdm.ipa" : "iosdm-iPhone.ipa"
            let directIPA = URL(string: "https://github.com/amiamii1983/iosdm/releases/download/\(tagVersion)/\(ipaName)")
            let manifest = RemoteVersionManifest(
                version: normalizeVersion(tagVersion),
                build: nil,
                notes: "已在 GitHub 发布新版本 \(tagVersion)。",
                releaseURL: fallbackReleaseURL.absoluteString,
                universalIPAURL: "https://github.com/amiamii1983/iosdm/releases/download/\(tagVersion)/iosdm.ipa",
                iPhoneIPAURL: "https://github.com/amiamii1983/iosdm/releases/download/\(tagVersion)/iosdm-iPhone.ipa"
            )
            if compareVersions(currentVersion, manifest.version) == .orderedAscending {
                return .updateAvailable(
                    latestVersion: manifest.version,
                    notes: manifest.notes ?? "",
                    releaseURL: fallbackReleaseURL,
                    directIPAURL: directIPA
                )
            } else {
                return .upToDate(currentVersion: normalizeVersion(currentVersion))
            }
        }

        return .failed("无法连接到 GitHub 检查更新，请检查网络或代理设置后重试。")
    }

    static func evaluate(
        manifest: RemoteVersionManifest,
        currentVersion: String,
        isPad: Bool
    ) -> UpdateCheckOutcome {
        let normalizedCurrent = normalizeVersion(currentVersion)
        let normalizedLatest = normalizeVersion(manifest.version)

        if compareVersions(normalizedCurrent, normalizedLatest) == .orderedAscending {
            let releaseURL = URL(string: manifest.releaseURL ?? repoReleasesLatestURL)
                ?? URL(string: repoReleasesLatestURL)!
            let preferredIPAStr = isPad
                ? (manifest.universalIPAURL ?? manifest.iPhoneIPAURL)
                : (manifest.iPhoneIPAURL ?? manifest.universalIPAURL)
            let directIPA = preferredIPAStr.flatMap(URL.init(string:))
            return .updateAvailable(
                latestVersion: normalizedLatest,
                notes: manifest.notes ?? "修复已知问题并优化下载体验。",
                releaseURL: releaseURL,
                directIPAURL: directIPA
            )
        }
        return .upToDate(currentVersion: normalizedCurrent)
    }

    static func normalizeVersion(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("v") {
            cleaned.removeFirst()
        }
        return cleaned
    }

    /// Compares semantic version strings such as "1.0" vs "1.0.1" vs "1.2".
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = normalizeVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = normalizeVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)
        for i in 0..<count {
            let l = i < leftParts.count ? leftParts[i] : 0
            let r = i < rightParts.count ? rightParts[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func fetchManifest(
        url: URL,
        proxySettings: ProxySettingsData
    ) async -> RemoteVersionManifest? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        ProxyManager.applyProxy(to: config, targetURL: url, settings: proxySettings)

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(RemoteVersionManifest.self, from: data)
    }

    private static func fetchLatestTagViaRedirect(
        url: URL,
        proxySettings: ProxySettingsData
    ) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        ProxyManager.applyProxy(to: config, targetURL: url, settings: proxySettings)

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await session.data(for: request),
              let finalURL = (response as? HTTPURLResponse)?.url else {
            return nil
        }
        let components = finalURL.pathComponents
        if let tagIndex = components.firstIndex(of: "tag"), components.indices.contains(tagIndex + 1) {
            return components[tagIndex + 1]
        }
        return nil
    }
}
