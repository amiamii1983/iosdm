import Foundation

struct ResolvedCloudLink: Sendable {
    let downloadURL: URL
    let suggestedFileName: String?
    let extraHeaders: [String: String]
    let providerName: String
    let refreshableSourceURL: URL
}

enum CloudResolverError: LocalizedError {
    case challengeRequired(provider: String)
    case htmlPageInsteadOfFile(provider: String?)
    case directLinkNotFound(provider: String)
    case apiError(provider: String, message: String)

    var errorDescription: String? {
        switch self {
        case .challengeRequired(let provider):
            return "\(provider) 页面触发了人机验证或访问限制，请先在浏览器完成验证后再复制最新下载链接。"
        case .htmlPageInsteadOfFile(let provider):
            if let provider {
                return "\(provider) 返回了网页内容而非真实文件（链接可能已失效、需要密码或登录），iosdm 已拦截，避免下载错误网页文件。"
            }
            return "服务器返回了网页内容而非目标文件（链接可能已过期、需登录或跳转至网页），iosdm 已拦截，避免误下载。"
        case .directLinkNotFound(let provider):
            return "未能从 \(provider) 页面解析到有效直链（文件可能已删除、加密或页面结构已更新）。"
        case .apiError(let provider, let message):
            return "\(provider) 解析失败：\(message)"
        }
    }
}

enum CloudLinkResolver {

    // MARK: - Provider Detection

    static func providerName(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("mediafire.com") { return "MediaFire" }
        if host.contains("drive.google.com") || host.contains("drive.usercontent.google.com") { return "Google Drive" }
        if host.contains("dropbox.com") || host.contains("dropboxusercontent.com") { return "Dropbox" }
        if host.contains("pixeldrain.com") { return "Pixeldrain" }
        if host.contains("gofile.io") { return "Gofile" }
        if host.contains("1drv.ms") || host.contains("onedrive.live.com") { return "OneDrive" }
        if host == "github.com" { return "GitHub" }
        return nil
    }

    static func isKnownCloudSharePage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()

        if host.contains("mediafire.com") {
            // Direct mediafire hosts look like download1475.mediafire.com; share pages are www.mediafire.com/file/...
            if isMediaFireDirectHost(host) { return false }
            return path.contains("/file/") || path.contains("/download/") || url.query != nil
        }
        if host == "drive.google.com" {
            return path.contains("/file/d/") || path.hasPrefix("/open") || path.hasPrefix("/uc")
        }
        if host.contains("dropbox.com") && !host.contains("dropboxusercontent.com") {
            return true
        }
        if host.contains("pixeldrain.com") && path.hasPrefix("/u/") {
            return true
        }
        if host.contains("gofile.io") && path.hasPrefix("/d/") {
            return true
        }
        if host == "1drv.ms" || host.contains("onedrive.live.com") {
            return true
        }
        if host == "github.com" && path.contains("/blob/") {
            return true
        }
        return false
    }

    /// Resolves known overseas cloud share URLs BEFORE probing.
    /// Returns nil when the URL should be probed directly first.
    static func preResolveIfNeeded(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink? {
        guard isKnownCloudSharePage(url), let host = url.host?.lowercased() else {
            return nil
        }

        if host.contains("mediafire.com") {
            return try await resolveMediaFireLandingPage(
                pageURL: url,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        if host == "drive.google.com" {
            return try await resolveGoogleDrive(
                url: url,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        if host.contains("dropbox.com") {
            return resolveDropbox(url: url)
        }

        if host.contains("pixeldrain.com") {
            return resolvePixeldrain(url: url)
        }

        if host.contains("gofile.io") {
            return try await resolveGofile(
                url: url,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        if host == "1drv.ms" || host.contains("onedrive.live.com") {
            return try await resolveOneDrive(
                url: url,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        if host == "github.com" && url.path.contains("/blob/") {
            return resolveGitHubBlob(url: url)
        }

        return nil
    }

    /// Called when probing a direct URL (for example an expired download1475.mediafire.com link or Google Drive uc link)
    /// unexpectedly received an HTML landing page instead of the target binary file.
    static func recoverFromHTMLResponse(
        originalURL: URL,
        resolvedURL: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink? {
        let origHost = originalURL.host?.lowercased() ?? ""
        let resolvedHost = resolvedURL.host?.lowercased() ?? ""

        // 1. MediaFire: either redirected to www.mediafire.com/file/... OR expired downloadXXXX.mediafire.com
        if resolvedHost.contains("mediafire.com") || origHost.contains("mediafire.com") {
            let landingURL = mediaFireLandingURL(from: resolvedURL)
                ?? mediaFireLandingURL(from: originalURL)
                ?? resolvedURL
            return try await resolveMediaFireLandingPage(
                pageURL: landingURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        // 2. Google Drive virus-scan warning / confirmation page
        if resolvedHost.contains("drive.google.com") || resolvedHost.contains("drive.usercontent.google.com") || origHost.contains("drive.google.com") {
            return try await resolveGoogleDriveHTML(
                pageURL: resolvedURL,
                sourceURL: originalURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        // 3. Dropbox web preview page
        if resolvedHost.contains("dropbox.com") && !resolvedHost.contains("dropboxusercontent.com") {
            return resolveDropbox(url: resolvedURL)
        }

        // 4. Pixeldrain web page
        if resolvedHost.contains("pixeldrain.com") && resolvedURL.path.lowercased().hasPrefix("/u/") {
            return resolvePixeldrain(url: resolvedURL)
        }

        // 5. Gofile web page
        if resolvedHost.contains("gofile.io") && resolvedURL.path.lowercased().hasPrefix("/d/") {
            return try await resolveGofile(
                url: resolvedURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        // 6. OneDrive
        if resolvedHost.contains("onedrive.live.com") || resolvedHost == "1drv.ms" {
            return try await resolveOneDrive(
                url: resolvedURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        return nil
    }

    // MARK: - MediaFire

    static func isMediaFireDirectHost(_ host: String) -> Bool {
        host.hasPrefix("download") && host.hasSuffix(".mediafire.com")
    }

    /// Reconstructs https://www.mediafire.com/file/<quickkey>/<filename>/file from an expired direct link
    /// e.g. https://download1475.mediafire.com/<token>/<quickkey>/<filename>
    static func mediaFireLandingURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("mediafire.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }

        if !isMediaFireDirectHost(host) {
            if parts.first?.lowercased() == "file" || parts.first?.lowercased() == "download" {
                return url
            }
            if let query = url.query, !query.isEmpty, !query.contains("=") {
                return URL(string: "https://www.mediafire.com/file/\(query)/file")
            }
            return url
        }

        // Direct link structure: /<token>/<quickkey>/<filename>
        if parts.count >= 3 {
            let quickKey = parts[1]
            let fileName = parts[2]
            let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            return URL(string: "https://www.mediafire.com/file/\(quickKey)/\(encodedName)/file")
        } else if parts.count == 2 {
            let quickKey = parts[1]
            return URL(string: "https://www.mediafire.com/file/\(quickKey)/file")
        }
        return nil
    }

    static func extractMediaFireDirectURL(from html: String) -> URL? {
        // 1. Preferred: data-scrambled-url="<base64>" on downloadButton
        if let scrambled = firstRegexCapture(
            pattern: #"data-scrambled-url\s*=\s*["']([A-Za-z0-9+/=_-]+)["']"#,
            in: html
        ), let decoded = decodeBase64URLString(scrambled),
           let candidate = URL(string: decoded),
           let scheme = candidate.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return candidate
        }

        // 2. Direct href on id="downloadButton" (either attribute order)
        let buttonPatterns = [
            #"<a[^>]*id\s*=\s*["']downloadButton["'][^>]*href\s*=\s*["'](https?://[^"']+)["']"#,
            #"<a[^>]*href\s*=\s*["'](https?://[^"']+)["'][^>]*id\s*=\s*["']downloadButton["']"#,
            #"aria-label\s*=\s*["']Download file["'][^>]*href\s*=\s*["'](https?://[^"']+)["']"#
        ]
        for pattern in buttonPatterns {
            if let raw = firstRegexCapture(pattern: pattern, in: html) {
                let unescaped = unescapeHTMLAttribute(raw)
                if let url = URL(string: unescaped),
                   !(url.host?.lowercased() == "www.mediafire.com" && url.path.hasSuffix("/file")) {
                    return url
                }
            }
        }

        // 3. Fallback: embedded downloadXXXX.mediafire.com URL in HTML/JS
        if let raw = firstRegexCapture(
            pattern: #"(https?://download\d*\.mediafire\.com/[^"'\s<>\\]+)"#,
            in: html
        ) {
            let unescaped = unescapeHTMLAttribute(raw)
            if let url = URL(string: unescaped) {
                return url
            }
        }

        return nil
    }

    static func extractMediaFireFileName(landingURL: URL, directURL: URL) -> String? {
        // Prefer real filename from direct URL lastPathComponent
        let directName = directURL.lastPathComponent
        if !directName.isEmpty && directName != "/" && directName.lowercased() != "file" {
            return ByteFormatter.sanitizeFileName(directName.removingPercentEncoding ?? directName)
        }
        // Fallback: /file/<quickkey>/<filename>/file
        let parts = landingURL.pathComponents.filter { $0 != "/" }
        if parts.count >= 3 && parts[0].lowercased() == "file" {
            let candidate = parts[2]
            if candidate.lowercased() != "file" {
                return ByteFormatter.sanitizeFileName(candidate.removingPercentEncoding ?? candidate)
            }
        }
        return nil
    }

    private static func resolveMediaFireLandingPage(
        pageURL: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink {
        let fetched = try await fetchTextPage(
            url: pageURL,
            customHeaders: customHeaders,
            defaultUserAgent: defaultUserAgent,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )

        if let directURL = extractMediaFireDirectURL(from: fetched.html) {
            var extraHeaders: [String: String] = [
                "Referer": fetched.finalURL.absoluteString
            ]
            if !fetched.cookieHeader.isEmpty {
                extraHeaders["Cookie"] = mergeCookieHeaders(
                    existing: customHeaders["Cookie"],
                    additional: fetched.cookieHeader
                )
            }
            let fileName = extractMediaFireFileName(landingURL: fetched.finalURL, directURL: directURL)
            return ResolvedCloudLink(
                downloadURL: directURL,
                suggestedFileName: fileName,
                extraHeaders: extraHeaders,
                providerName: "MediaFire",
                refreshableSourceURL: fetched.finalURL
            )
        }

        if containsChallengeMarkers(fetched.html) {
            throw CloudResolverError.challengeRequired(provider: "MediaFire")
        }
        throw CloudResolverError.directLinkNotFound(provider: "MediaFire")
    }

    // MARK: - Google Drive

    static func extractGoogleDriveFileID(from url: URL) -> String? {
        let parts = url.pathComponents
        if let dIndex = parts.firstIndex(of: "d"), parts.indices.contains(dIndex + 1) {
            let candidate = parts[dIndex + 1]
            if !candidate.isEmpty { return candidate }
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idValue = components.queryItems?.first(where: { $0.name == "id" })?.value,
           !idValue.isEmpty {
            return idValue
        }
        return nil
    }

    static func extractGoogleDriveConfirmURL(from html: String, fallbackBase: URL) -> URL? {
        // Modern Google Drive warning page uses <form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
        if let formRange = html.range(of: #"<form[^>]*id\s*=\s*["']download-form["'][^>]*>[\s\S]*?</form>"#, options: [.regularExpression, .caseInsensitive]) {
            let formHTML = String(html[formRange])
            let actionRaw = firstRegexCapture(pattern: #"action\s*=\s*["']([^"']+)["']"#, in: formHTML) ?? fallbackBase.absoluteString
            let actionStr = unescapeHTMLAttribute(actionRaw)

            guard var components = URLComponents(string: actionStr) else { return nil }
            var items = components.queryItems ?? []

            if let inputRegex = try? NSRegularExpression(
                pattern: #"<input[^>]*type\s*=\s*["']hidden["'][^>]*>"#,
                options: [.caseInsensitive]
            ) {
                let nsRange = NSRange(formHTML.startIndex..., in: formHTML)
                for match in inputRegex.matches(in: formHTML, range: nsRange) {
                    guard let range = Range(match.range, in: formHTML) else { continue }
                    let tag = String(formHTML[range])
                    if let name = firstRegexCapture(pattern: #"name\s*=\s*["']([^"']+)["']"#, in: tag),
                       let value = firstRegexCapture(pattern: #"value\s*=\s*["']([^"']*)["']"#, in: tag) {
                        items.removeAll(where: { $0.name == name })
                        items.append(URLQueryItem(name: name, value: unescapeHTMLAttribute(value)))
                    }
                }
            }
            components.queryItems = items
            return components.url
        }

        // Legacy fallback: confirm token link
        if let rawHref = firstRegexCapture(
            pattern: #"href\s*=\s*["']([^"']*export=download[^"']*confirm=[^"']+)["']"#,
            in: html
        ) {
            let unescaped = unescapeHTMLAttribute(rawHref)
            if unescaped.hasPrefix("http") {
                return URL(string: unescaped)
            }
            return URL(string: unescaped, relativeTo: fallbackBase)?.absoluteURL
        }

        return nil
    }

    private static func resolveGoogleDrive(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink? {
        guard let fileId = extractGoogleDriveFileID(from: url) else {
            return nil
        }
        guard let directURL = URL(string: "https://drive.usercontent.google.com/download?id=\(fileId)&export=download&confirm=t") else {
            return nil
        }
        return ResolvedCloudLink(
            downloadURL: directURL,
            suggestedFileName: nil,
            extraHeaders: [:],
            providerName: "Google Drive",
            refreshableSourceURL: url
        )
    }

    private static func resolveGoogleDriveHTML(
        pageURL: URL,
        sourceURL: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink {
        let fetched = try await fetchTextPage(
            url: pageURL,
            customHeaders: customHeaders,
            defaultUserAgent: defaultUserAgent,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )

        if let confirmURL = extractGoogleDriveConfirmURL(from: fetched.html, fallbackBase: fetched.finalURL) {
            var extraHeaders: [String: String] = ["Referer": fetched.finalURL.absoluteString]
            if !fetched.cookieHeader.isEmpty {
                extraHeaders["Cookie"] = mergeCookieHeaders(
                    existing: customHeaders["Cookie"],
                    additional: fetched.cookieHeader
                )
            }
            return ResolvedCloudLink(
                downloadURL: confirmURL,
                suggestedFileName: nil,
                extraHeaders: extraHeaders,
                providerName: "Google Drive",
                refreshableSourceURL: sourceURL
            )
        }

        if containsChallengeMarkers(fetched.html) {
            throw CloudResolverError.challengeRequired(provider: "Google Drive")
        }
        throw CloudResolverError.htmlPageInsteadOfFile(provider: "Google Drive")
    }

    // MARK: - Dropbox

    static func resolveDropbox(url: URL) -> ResolvedCloudLink? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name.lowercased() == "dl" || $0.name.lowercased() == "raw" })
        items.append(URLQueryItem(name: "dl", value: "1"))
        components.queryItems = items
        guard let direct = components.url else { return nil }
        return ResolvedCloudLink(
            downloadURL: direct,
            suggestedFileName: ByteFormatter.fileNameFromURL(direct),
            extraHeaders: [:],
            providerName: "Dropbox",
            refreshableSourceURL: url
        )
    }

    // MARK: - Pixeldrain

    static func resolvePixeldrain(url: URL) -> ResolvedCloudLink? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "u" else { return nil }
        let fileId = parts[1]
        guard let direct = URL(string: "https://pixeldrain.com/api/file/\(fileId)?download") else {
            return nil
        }
        return ResolvedCloudLink(
            downloadURL: direct,
            suggestedFileName: nil,
            extraHeaders: [:],
            providerName: "Pixeldrain",
            refreshableSourceURL: url
        )
    }

    // MARK: - GitHub Blob -> Raw

    static func resolveGitHubBlob(url: URL) -> ResolvedCloudLink? {
        let parts = url.pathComponents.filter { $0 != "/" }
        // /<owner>/<repo>/blob/<branch>/<path...>
        guard parts.count >= 5, parts[2] == "blob" else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        let rest = parts.dropFirst(3).joined(separator: "/")
        guard let rawURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(rest)") else {
            return nil
        }
        return ResolvedCloudLink(
            downloadURL: rawURL,
            suggestedFileName: ByteFormatter.fileNameFromURL(rawURL),
            extraHeaders: [:],
            providerName: "GitHub",
            refreshableSourceURL: url
        )
    }

    // MARK: - OneDrive / 1drv.ms

    private static func resolveOneDrive(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink? {
        var resolved = url
        if url.host?.lowercased() == "1drv.ms" {
            resolved = try await followRedirectsOnly(
                url: url,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        }

        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.path.lowercased().contains("/redir") {
            components.path = components.path.replacingOccurrences(of: "/redir", with: "/download")
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name.lowercased() == "download" }) {
            items.append(URLQueryItem(name: "download", value: "1"))
        }
        components.queryItems = items
        guard let direct = components.url else { return nil }
        return ResolvedCloudLink(
            downloadURL: direct,
            suggestedFileName: nil,
            extraHeaders: [:],
            providerName: "OneDrive",
            refreshableSourceURL: url
        )
    }

    // MARK: - Gofile

    private static func resolveGofile(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> ResolvedCloudLink {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "d" else {
            throw CloudResolverError.directLinkNotFound(provider: "Gofile")
        }
        let contentId = parts[1]

        let session = makeResolverSession(
            targetURL: URL(string: "https://api.gofile.io")!,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )
        defer { session.invalidateAndCancel() }

        // 1. Obtain guest token
        var accountReq = URLRequest(url: URL(string: "https://api.gofile.io/accounts")!)
        accountReq.httpMethod = "POST"
        accountReq.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let (accData, _) = try await session.data(for: accountReq)
        guard let accJSON = try? JSONSerialization.jsonObject(with: accData) as? [String: Any],
              let accInner = accJSON["data"] as? [String: Any],
              let token = accInner["token"] as? String, !token.isEmpty else {
            throw CloudResolverError.apiError(provider: "Gofile", message: "无法获取访客令牌")
        }

        // 2. Query content details
        guard let contentURL = URL(string: "https://api.gofile.io/contents/\(contentId)?wt=4fd6sg89d7s6") else {
            throw CloudResolverError.directLinkNotFound(provider: "Gofile")
        }
        var contentReq = URLRequest(url: contentURL)
        contentReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        contentReq.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (contentData, _) = try await session.data(for: contentReq)
        guard let root = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let status = root["status"] as? String, status == "ok",
              let dataDict = root["data"] as? [String: Any],
              let children = dataDict["children"] as? [String: Any] else {
            throw CloudResolverError.apiError(provider: "Gofile", message: "文件不存在、需密码或接口已变化")
        }

        for value in children.values {
            guard let item = value as? [String: Any],
                  let linkStr = item["link"] as? String,
                  let directURL = URL(string: linkStr) else {
                continue
            }
            let fileName = item["name"] as? String
            let cookieVal = mergeCookieHeaders(existing: customHeaders["Cookie"], additional: "accountToken=\(token)")
            return ResolvedCloudLink(
                downloadURL: directURL,
                suggestedFileName: fileName.map(ByteFormatter.sanitizeFileName),
                extraHeaders: [
                    "Cookie": cookieVal,
                    "Referer": "https://gofile.io/"
                ],
                providerName: "Gofile",
                refreshableSourceURL: url
            )
        }

        throw CloudResolverError.directLinkNotFound(provider: "Gofile")
    }

    // MARK: - Network & HTML Helpers

    private struct FetchedPage {
        let html: String
        let finalURL: URL
        let cookieHeader: String
    }

    private static func makeResolverSession(
        targetURL: URL,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.allowsCellularAccess = allowsCellularAccess
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        ProxyManager.applyProxy(to: config, targetURL: targetURL, settings: proxySettings)
        return URLSession(configuration: config)
    }

    private static func fetchTextPage(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> FetchedPage {
        let session = makeResolverSession(
            targetURL: url,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        var hasUA = false
        for (k, v) in customHeaders {
            let trimmed = k.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.caseInsensitiveCompare("User-Agent") == .orderedSame { hasUA = true }
            if trimmed.caseInsensitiveCompare("Range") == .orderedSame { continue }
            request.setValue(v, forHTTPHeaderField: trimmed)
        }
        if !hasUA && !defaultUserAgent.isEmpty {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        let (data, response) = try await session.data(for: request)
        let finalURL = (response as? HTTPURLResponse)?.url ?? url

        // Collect all cookies gathered across redirects
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return FetchedPage(html: html, finalURL: finalURL, cookieHeader: cookieHeader)
    }

    private static func followRedirectsOnly(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> URL {
        let session = makeResolverSession(
            targetURL: url,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.url ?? url
    }

    static func containsChallengeMarkers(_ html: String) -> Bool {
        let lower = html.lowercased()
        let markers = [
            "cf-challenge",
            "challenge-platform",
            "just a moment...",
            "g-recaptcha",
            "h-captcha",
            "cf-turnstile"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func isHTMLFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    private static func decodeBase64URLString(_ input: String) -> String? {
        var padded = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func unescapeHTMLAttribute(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeCookieHeaders(existing: String?, additional: String) -> String {
        let cleanExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanExisting.isEmpty { return additional }
        if additional.isEmpty { return cleanExisting }
        return "\(cleanExisting); \(additional)"
    }
}
