import Foundation

struct ProbeResult: Sendable {
    let resolvedURL: URL
    let suggestedFileName: String
    let totalBytes: Int64 // -1 if unknown
    let supportsRange: Bool
    let eTag: String?
    let lastModified: String?
    let mimeType: String?
    let resolvedHeaders: [String: String]
    let cloudSourceURL: URL?
    let cloudProvider: String?
}

enum DownloadProbeError: LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case nonHTTPResponse
    case httpStatus(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的下载链接"
        case .unsupportedScheme(let scheme):
            return "仅支持 http:// 与 https:// 协议（当前为 \(scheme)）"
        case .nonHTTPResponse:
            return "服务器未返回有效的 HTTP 响应"
        case .httpStatus(let code, let text):
            return "服务器返回错误 HTTP \(code) (\(text))"
        case .cancelled:
            return "已取消连接"
        }
    }
}

enum URLProbe {
    static func validateURL(_ rawString: String) throws -> URL {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DownloadProbeError.invalidURL
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw DownloadProbeError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw DownloadProbeError.unsupportedScheme(scheme)
        }
        return url
    }

    static func probe(
        url: URL,
        customHeaders: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData = ProxySettingsData(),
        expectedFileNameHint: String? = nil
    ) async throws -> ProbeResult {
        var workingURL = url
        var mergedExtraHeaders: [String: String] = [:]
        var preferredFileName: String? = nil
        var cloudSourceURL: URL? = nil
        var cloudProvider: String? = CloudLinkResolver.providerName(for: url)

        // Step 1: Pre-resolve known overseas cloud share pages (MediaFire / Google Drive / Dropbox / Pixeldrain / Gofile / OneDrive / GitHub)
        if let preResolved = try await CloudLinkResolver.preResolveIfNeeded(
            url: url,
            customHeaders: customHeaders,
            defaultUserAgent: defaultUserAgent,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        ) {
            workingURL = preResolved.downloadURL
            mergedExtraHeaders = preResolved.extraHeaders
            preferredFileName = preResolved.suggestedFileName
            cloudSourceURL = preResolved.refreshableSourceURL
            cloudProvider = preResolved.providerName
        }

        let effectiveHeaders = combineHeaders(extra: mergedExtraHeaders, custom: customHeaders)

        // Step 2: Probe direct URL; if an expired MediaFire direct link returns 403/404/410, recover from its share page automatically
        let firstOutcome: SingleProbeOutcome
        do {
            firstOutcome = try await probeDirectURL(
                url: workingURL,
                headers: effectiveHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
        } catch DownloadProbeError.httpStatus(let code, _)
            where (code == 403 || code == 404 || code == 410)
            && CloudLinkResolver.isMediaFireDirectHost(workingURL.host?.lowercased() ?? "") {
            if let recovered = try await CloudLinkResolver.recoverFromHTMLResponse(
                originalURL: url,
                resolvedURL: workingURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            ) {
                workingURL = recovered.downloadURL
                mergedExtraHeaders = recovered.extraHeaders
                preferredFileName = recovered.suggestedFileName ?? preferredFileName
                cloudSourceURL = recovered.refreshableSourceURL
                cloudProvider = recovered.providerName
                let refreshedHeaders = combineHeaders(extra: mergedExtraHeaders, custom: customHeaders)
                firstOutcome = try await probeDirectURL(
                    url: workingURL,
                    headers: refreshedHeaders,
                    defaultUserAgent: defaultUserAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    proxySettings: proxySettings
                )
            } else {
                throw DownloadProbeError.httpStatus(code, HTTPURLResponse.localizedString(forStatusCode: code))
            }
        }

        // Step 3: Guard against HTML landing page trap (e.g., expired download1475.mediafire.com redirecting to /file 324KB HTML!)
        let userExplicitlyWantsHTML = isUserExpectingHTML(originalURL: url, hint: expectedFileNameHint)
        var finalOutcome = firstOutcome

        if isHTMLResponse(finalOutcome.response) && !userExplicitlyWantsHTML {
            if let recovered = try await CloudLinkResolver.recoverFromHTMLResponse(
                originalURL: url,
                resolvedURL: finalOutcome.finalURL,
                customHeaders: customHeaders,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            ) {
                workingURL = recovered.downloadURL
                mergedExtraHeaders = recovered.extraHeaders
                preferredFileName = recovered.suggestedFileName ?? preferredFileName
                cloudSourceURL = recovered.refreshableSourceURL
                cloudProvider = recovered.providerName
                let refreshedHeaders = combineHeaders(extra: mergedExtraHeaders, custom: customHeaders)
                finalOutcome = try await probeDirectURL(
                    url: workingURL,
                    headers: refreshedHeaders,
                    defaultUserAgent: defaultUserAgent,
                    allowsCellularAccess: allowsCellularAccess,
                    proxySettings: proxySettings
                )
            }

            if isHTMLResponse(finalOutcome.response) {
                let provider = cloudProvider ?? CloudLinkResolver.providerName(for: finalOutcome.finalURL)
                throw CloudResolverError.htmlPageInsteadOfFile(provider: provider)
            }
        }

        // Record cookies returned on direct endpoint redirects if any
        if !finalOutcome.cookieHeader.isEmpty {
            let existing = mergedExtraHeaders["Cookie"]
            mergedExtraHeaders["Cookie"] = existing.map { "\($0); \(finalOutcome.cookieHeader)" } ?? finalOutcome.cookieHeader
        }

        return buildProbeResult(
            originalURL: url,
            finalURL: finalOutcome.finalURL,
            response: finalOutcome.response,
            totalBytes: finalOutcome.totalBytes,
            supportsRange: finalOutcome.supportsRange,
            preferredFileName: preferredFileName,
            resolvedHeaders: mergedExtraHeaders,
            cloudSourceURL: cloudSourceURL,
            cloudProvider: cloudProvider
        )
    }

    private struct SingleProbeOutcome: Sendable {
        let response: HTTPURLResponse
        let finalURL: URL
        let totalBytes: Int64
        let supportsRange: Bool
        let cookieHeader: String
    }

    private static func probeDirectURL(
        url: URL,
        headers: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> SingleProbeOutcome {
        // First probe with GET + Range: bytes=0-0 (most compatible across CDNs & servers that block HEAD)
        let rangeOutcome = try await executeSingleProbe(
            url: url,
            method: "GET",
            includeRangeZero: true,
            headers: headers,
            defaultUserAgent: defaultUserAgent,
            allowsCellularAccess: allowsCellularAccess,
            proxySettings: proxySettings
        )

        let status = rangeOutcome.response.statusCode

        if status == 206 {
            let totalBytes = parseTotalSizeFromContentRange(rangeOutcome.response)
            let supportsRange = totalBytes > 0
            return SingleProbeOutcome(
                response: rangeOutcome.response,
                finalURL: rangeOutcome.finalURL,
                totalBytes: totalBytes,
                supportsRange: supportsRange,
                cookieHeader: rangeOutcome.cookieHeader
            )
        }

        if status == 200 {
            let totalBytes = parseContentLength(rangeOutcome.response)
            return SingleProbeOutcome(
                response: rangeOutcome.response,
                finalURL: rangeOutcome.finalURL,
                totalBytes: totalBytes,
                supportsRange: false,
                cookieHeader: rangeOutcome.cookieHeader
            )
        }

        if status == 416 {
            if let totalFromRange = parseTotalSizeFromContentRangeNullable(rangeOutcome.response),
               totalFromRange == 0 {
                return SingleProbeOutcome(
                    response: rangeOutcome.response,
                    finalURL: rangeOutcome.finalURL,
                    totalBytes: 0,
                    supportsRange: false,
                    cookieHeader: rangeOutcome.cookieHeader
                )
            }
            let headOutcome = try await executeSingleProbe(
                url: url,
                method: "HEAD",
                includeRangeZero: false,
                headers: headers,
                defaultUserAgent: defaultUserAgent,
                allowsCellularAccess: allowsCellularAccess,
                proxySettings: proxySettings
            )
            let headStatus = headOutcome.response.statusCode
            guard (200...299).contains(headStatus) else {
                throw DownloadProbeError.httpStatus(headStatus, HTTPURLResponse.localizedString(forStatusCode: headStatus))
            }
            let totalBytes = parseContentLength(headOutcome.response)
            let acceptRanges = headOutcome.response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
            let supportsRange = totalBytes > 0 && acceptRanges.contains("bytes")
            return SingleProbeOutcome(
                response: headOutcome.response,
                finalURL: headOutcome.finalURL,
                totalBytes: totalBytes,
                supportsRange: supportsRange,
                cookieHeader: headOutcome.cookieHeader
            )
        }

        throw DownloadProbeError.httpStatus(status, HTTPURLResponse.localizedString(forStatusCode: status))
    }

    private struct RawProbeOutcome: Sendable {
        let response: HTTPURLResponse
        let finalURL: URL
        let cookieHeader: String
    }

    private static func executeSingleProbe(
        url: URL,
        method: String,
        includeRangeZero: Bool,
        headers: [String: String],
        defaultUserAgent: String,
        allowsCellularAccess: Bool,
        proxySettings: ProxySettingsData
    ) async throws -> RawProbeOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 25
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if includeRangeZero {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }

        var hasUserAgent = false
        for (key, value) in headers {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            if trimmedKey.caseInsensitiveCompare("User-Agent") == .orderedSame {
                hasUserAgent = true
            }
            if trimmedKey.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            request.setValue(value, forHTTPHeaderField: trimmedKey)
        }
        if !hasUserAgent && !defaultUserAgent.isEmpty {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.allowsCellularAccess = allowsCellularAccess
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 50
        ProxyManager.applyProxy(to: config, targetURL: url, settings: proxySettings)

        let delegate = ProbeSessionDelegate(originalURL: url, preserveRangeZero: includeRangeZero)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let dataTask = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation: continuation, session: session, task: dataTask)
                dataTask.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private static func buildProbeResult(
        originalURL: URL,
        finalURL: URL,
        response: HTTPURLResponse,
        totalBytes: Int64,
        supportsRange: Bool,
        preferredFileName: String?,
        resolvedHeaders: [String: String],
        cloudSourceURL: URL?,
        cloudProvider: String?
    ) -> ProbeResult {
        var suggested: String?
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            suggested = ByteFormatter.fileNameFromContentDisposition(disposition)
        }
        if suggested == nil, let preferredFileName, !preferredFileName.isEmpty {
            suggested = preferredFileName
        }
        if suggested == nil {
            let candidate = ByteFormatter.fileNameFromURL(finalURL)
            if candidate?.lowercased() != "file" && candidate?.lowercased() != "download" {
                suggested = candidate
            }
        }
        if suggested == nil {
            let candidate = ByteFormatter.fileNameFromURL(originalURL)
            if candidate?.lowercased() != "file" && candidate?.lowercased() != "download" {
                suggested = candidate
            }
        }
        if suggested == nil, let respName = response.suggestedFilename, !respName.isEmpty, respName != "Unknown" {
            suggested = ByteFormatter.sanitizeFileName(respName)
        }
        let finalFileName = suggested ?? ByteFormatter.sanitizeFileName("")

        let eTag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        let mimeType = response.mimeType

        return ProbeResult(
            resolvedURL: finalURL,
            suggestedFileName: finalFileName,
            totalBytes: totalBytes,
            supportsRange: supportsRange,
            eTag: eTag,
            lastModified: lastModified,
            mimeType: mimeType,
            resolvedHeaders: resolvedHeaders,
            cloudSourceURL: cloudSourceURL,
            cloudProvider: cloudProvider
        )
    }

    private static func isHTMLResponse(_ response: HTTPURLResponse) -> Bool {
        if let mime = response.mimeType?.lowercased(), mime.contains("text/html") || mime.contains("application/xhtml") {
            return true
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") || contentType.contains("application/xhtml") {
            return true
        }
        return false
    }

    private static func isUserExpectingHTML(originalURL: URL, hint: String?) -> Bool {
        if let hint, CloudLinkResolver.isHTMLFileName(hint) {
            return true
        }
        return CloudLinkResolver.isHTMLFileName(originalURL.lastPathComponent)
    }

    private static func combineHeaders(extra: [String: String], custom: [String: String]) -> [String: String] {
        var combined = extra
        for (k, v) in custom {
            combined[k] = v
        }
        return combined
    }

    private static func parseContentLength(_ response: HTTPURLResponse) -> Int64 {
        if let raw = response.value(forHTTPHeaderField: "Content-Length")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = Int64(raw), parsed >= 0 {
            return parsed
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : -1
    }

    private static func parseTotalSizeFromContentRange(_ response: HTTPURLResponse) -> Int64 {
        parseTotalSizeFromContentRangeNullable(response) ?? -1
    }

    private static func parseTotalSizeFromContentRangeNullable(_ response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        let parts = contentRange.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let totalPart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if totalPart == "*" { return nil }
        return Int64(totalPart)
    }

    private final class ProbeSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RawProbeOutcome, Error>?
        private weak var session: URLSession?
        private weak var task: URLSessionDataTask?
        private var finalURL: URL
        private let preserveRangeZero: Bool
        private var didFinish = false

        init(originalURL: URL, preserveRangeZero: Bool) {
            self.finalURL = originalURL
            self.preserveRangeZero = preserveRangeZero
            super.init()
        }

        func start(
            continuation: CheckedContinuation<RawProbeOutcome, Error>,
            session: URLSession,
            task: URLSessionDataTask
        ) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
            self.session = session
            self.task = task
        }

        func cancel() {
            lock.lock()
            let cont = continuation
            let sess = session
            let t = task
            continuation = nil
            didFinish = true
            lock.unlock()

            t?.cancel()
            sess?.invalidateAndCancel()
            cont?.resume(throwing: DownloadProbeError.cancelled)
        }

        private func finish(with result: Result<RawProbeOutcome, Error>) {
            lock.lock()
            guard !didFinish, let cont = continuation else {
                lock.unlock()
                return
            }
            didFinish = true
            continuation = nil
            let sess = session
            lock.unlock()

            sess?.invalidateAndCancel()
            switch result {
            case .success(let outcome):
                cont.resume(returning: outcome)
            case .failure(let error):
                cont.resume(throwing: error)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            if let newURL = redirected.url {
                lock.lock()
                finalURL = newURL
                lock.unlock()
            }
            if preserveRangeZero {
                redirected.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            }
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            completionHandler(redirected)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            completionHandler(.cancel)

            guard let httpResponse = response as? HTTPURLResponse else {
                finish(with: .failure(DownloadProbeError.nonHTTPResponse))
                return
            }

            let cookies = session.configuration.httpCookieStorage?.cookies ?? []
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

            lock.lock()
            let resolved = httpResponse.url ?? finalURL
            lock.unlock()

            finish(with: .success(RawProbeOutcome(response: httpResponse, finalURL: resolved, cookieHeader: cookieHeader)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(with: .failure(error))
            } else {
                finish(with: .failure(DownloadProbeError.nonHTTPResponse))
            }
        }
    }
}
