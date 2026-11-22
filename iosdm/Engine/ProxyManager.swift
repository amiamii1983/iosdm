import Foundation
import CFNetwork
import Network
import Darwin

enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case manual
    case direct

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .manual: return "手动设置"
        case .direct: return "直接连接"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "自动代理"
        case .manual: return "手动代理"
        case .direct: return "直连"
        }
    }

    var descriptionText: String {
        switch self {
        case .auto:
            return "自动跟随系统与已开启的代理软件（如 Shadowrocket、Surge、Quantumult X、Loon、Clash 等），国内直连、国外加速，互不影响。"
        case .manual:
            return "手动填写代理地址与端口；开启国内直连分流后，不影响中国和国外网络的下载速度。"
        case .direct:
            return "不走代理直接下载，适合纯国内或局域网链接。"
        }
    }
}

enum ManualProxyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case socks5

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .http: return "HTTP / HTTPS"
        case .socks5: return "SOCKS5"
        }
    }
}

struct ProxySettingsData: Codable, Equatable, Sendable {
    var mode: ProxyMode = .auto
    var manualType: ManualProxyType = .http
    var host: String = "127.0.0.1"
    var port: Int = 1082
    var username: String = ""
    var password: String = ""
    var bypassChinaDomains: Bool = true
    var customBypassRules: String = ""

    var isManualConfigValid: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty && (1...65535).contains(port)
    }
}

struct DetectedSystemProxyInfo: Equatable, Sendable {
    let hasActiveVPNTunnel: Bool
    let vpnInterfaces: [String]
    let httpProxyHost: String?
    let httpProxyPort: Int?
    let httpsProxyHost: String?
    let httpsProxyPort: Int?
    let socksProxyHost: String?
    let socksProxyPort: Int?
    let pacURL: String?

    var hasAnyProxyOrVPN: Bool {
        hasActiveVPNTunnel || httpProxyHost != nil || httpsProxyHost != nil || socksProxyHost != nil || pacURL != nil
    }

    var primaryProxyHost: String? {
        httpProxyHost ?? httpsProxyHost ?? socksProxyHost
    }

    var primaryProxyPort: Int? {
        if httpProxyHost != nil { return httpProxyPort }
        if httpsProxyHost != nil { return httpsProxyPort }
        if socksProxyHost != nil { return socksProxyPort }
        return nil
    }

    var primaryProxyType: ManualProxyType {
        if httpProxyHost != nil || httpsProxyHost != nil {
            return .http
        }
        return .socks5
    }

    var summaryTitle: String {
        if hasAnyProxyOrVPN {
            return "已检测到系统 / VPN 代理"
        }
        return "当前为直连网络"
    }

    var detailLines: [String] {
        var lines: [String] = []
        if let h = httpProxyHost, let p = httpProxyPort {
            lines.append("系统代理地址：\(h):\(p)")
        } else if let h = httpsProxyHost, let p = httpsProxyPort {
            lines.append("系统代理地址：\(h):\(p)")
        } else if let h = socksProxyHost, let p = socksProxyPort {
            lines.append("系统代理地址：\(h):\(p)")
        }
        if hasActiveVPNTunnel {
            lines.append("已开启 VPN 分流，自动模式可直接生效。")
        } else if lines.isEmpty {
            lines.append("未检测到代理软件运行，将使用普通网络直接下载。")
        }
        return lines
    }
}

struct ProxyTestResult: Equatable, Sendable {
    let success: Bool
    let message: String
    let latencyMs: Int?
}

enum ProxyManager {
    private static let chinaAndLocalBypassSuffixes: [String] = [
        "localhost",
        "local",
        "cn",
        "qq.com",
        "gtimg.com",
        "qpic.cn",
        "weixin.qq.com",
        "baidu.com",
        "bdstatic.com",
        "bcebos.com",
        "baidupcs.com",
        "aliyun.com",
        "aliyuncs.com",
        "alicdn.com",
        "alipan.com",
        "aliyundrive.com",
        "taobao.com",
        "tmall.com",
        "163.com",
        "126.net",
        "netease.com",
        "bilibili.com",
        "bilivideo.com",
        "hdslb.com",
        "jd.com",
        "360buyimg.com",
        "zhihu.com",
        "weibo.com",
        "douyin.com",
        "bytedance.com",
        "byteimg.com",
        "toutiao.com",
        "xiaomi.com",
        "mi.com",
        "huawei.com",
        "myqcloud.com",
        "qcloud.com",
        "qiniucdn.com",
        "upyun.com",
        "gitee.com",
        "csdn.net",
        "quark.cn",
        "123pan.com",
        "iqiyi.com",
        "youku.com",
        "apple.com",
        "icloud.com",
        "mzstatic.com"
    ]

    /// Inspects current iOS/iPadOS system proxy dictionary and active VPN utun interfaces (e.g. Shadowrocket).
    /// Called only on demand (zero background polling).
    static func detectSystemProxy() -> DetectedSystemProxyInfo {
        var httpHost: String?
        var httpPort: Int?
        var httpsHost: String?
        var httpsPort: Int?
        var socksHost: String?
        var socksPort: Int?
        var pacURL: String?

        if let rawDict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            extractProxies(
                from: rawDict,
                httpHost: &httpHost,
                httpPort: &httpPort,
                httpsHost: &httpsHost,
                httpsPort: &httpsPort,
                socksHost: &socksHost,
                socksPort: &socksPort,
                pacURL: &pacURL
            )

            if let scoped = rawDict["__SCOPED__"] as? [String: Any] {
                for (iface, value) in scoped {
                    guard let subDict = value as? [String: Any] else { continue }
                    let lower = iface.lowercased()
                    let isTunnel = lower.hasPrefix("utun") || lower.hasPrefix("tap") || lower.hasPrefix("tun") || lower.hasPrefix("ppp") || lower.hasPrefix("ipsec")
                    if isTunnel || (httpHost == nil && httpsHost == nil && socksHost == nil) {
                        extractProxies(
                            from: subDict,
                            httpHost: &httpHost,
                            httpPort: &httpPort,
                            httpsHost: &httpsHost,
                            httpsPort: &httpsPort,
                            socksHost: &socksHost,
                            socksPort: &socksPort,
                            pacURL: &pacURL
                        )
                    }
                }
            }
        }

        let tunnels = activeVPNTunnelInterfaces()
        return DetectedSystemProxyInfo(
            hasActiveVPNTunnel: !tunnels.isEmpty,
            vpnInterfaces: tunnels,
            httpProxyHost: httpHost,
            httpProxyPort: httpPort,
            httpsProxyHost: httpsHost,
            httpsProxyPort: httpsPort,
            socksProxyHost: socksHost,
            socksProxyPort: socksPort,
            pacURL: pacURL
        )
    }

    static func shouldBypassManualProxy(for url: URL, settings: ProxySettingsData) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        if isLocalOrPrivateHost(host) {
            return true
        }

        if settings.bypassChinaDomains {
            for suffix in chinaAndLocalBypassSuffixes {
                if host == suffix || host.hasSuffix(".\(suffix)") {
                    return true
                }
            }
        }

        let customTokens = parseCustomBypassRules(settings.customBypassRules)
        for rule in customTokens {
            if matchesBypassRule(host: host, rule: rule) {
                return true
            }
        }

        return false
    }

    static func applyProxy(
        to config: URLSessionConfiguration,
        targetURL: URL,
        settings: ProxySettingsData
    ) {
        switch settings.mode {
        case .auto:
            // Do not override system proxy / TUN route so Shadowrocket & iOS split rules work natively
            break

        case .direct:
            config.connectionProxyDictionary = [:]

        case .manual:
            guard settings.isManualConfigValid else { return }
            if shouldBypassManualProxy(for: targetURL, settings: settings) {
                config.connectionProxyDictionary = [:]
                return
            }

            let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = settings.port
            let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = settings.password

            if #available(iOS 17.0, macOS 14.0, *),
               let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
                var proxyConfig: ProxyConfiguration
                switch settings.manualType {
                case .http:
                    proxyConfig = ProxyConfiguration(httpCONNECTProxy: endpoint)
                case .socks5:
                    proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
                }
                if !user.isEmpty {
                    proxyConfig.applyCredential(username: user, password: pass)
                }
                proxyConfig.excludedDomains = excludedDomainsForManualProxy(settings: settings)
                config.proxyConfigurations = [proxyConfig]
            } else {
                var dict: [AnyHashable: Any] = [:]
                switch settings.manualType {
                case .http:
                    dict["HTTPEnable"] = 1
                    dict["HTTPProxy"] = host
                    dict["HTTPPort"] = port
                    dict["HTTPSEnable"] = 1
                    dict["HTTPSProxy"] = host
                    dict["HTTPSPort"] = port
                    if !user.isEmpty {
                        dict["HTTPUser"] = user
                        dict["HTTPPassword"] = pass
                    }
                case .socks5:
                    dict["SOCKSEnable"] = 1
                    dict["SOCKSProxy"] = host
                    dict["SOCKSPort"] = port
                    if !user.isEmpty {
                        dict["SOCKSUser"] = user
                        dict["SOCKSPassword"] = pass
                    }
                }
                dict["ExceptionsList"] = excludedDomainsForManualProxy(settings: settings)
                config.connectionProxyDictionary = dict
            }
        }
    }

    static func testConnectivity(
        settings: ProxySettingsData,
        testURLString: String = "https://cp.cloudflare.com/generate_204"
    ) async -> ProxyTestResult {
        guard let url = URL(string: testURLString) else {
            return ProxyTestResult(success: false, message: "无效的测试地址", latencyMs: nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        applyProxy(to: config, targetURL: url, settings: settings)

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await session.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                return ProxyTestResult(success: true, message: "连接正常（HTTP \(http.statusCode)）", latencyMs: ms)
            }
            return ProxyTestResult(success: false, message: "收到异常响应", latencyMs: ms)
        } catch {
            return ProxyTestResult(success: false, message: "连接失败：\(error.localizedDescription)", latencyMs: nil)
        }
    }

    // MARK: - Private Helpers

    private static func extractProxies(
        from dict: [String: Any],
        httpHost: inout String?,
        httpPort: inout Int?,
        httpsHost: inout String?,
        httpsPort: inout Int?,
        socksHost: inout String?,
        socksPort: inout Int?,
        pacURL: inout String?
    ) {
        if boolFlag(dict["HTTPEnable"]),
           let host = nonEmptyString(dict["HTTPProxy"]),
           let port = intValue(dict["HTTPPort"]), port > 0 {
            httpHost = host
            httpPort = port
        }
        if boolFlag(dict["HTTPSEnable"]),
           let host = nonEmptyString(dict["HTTPSProxy"]),
           let port = intValue(dict["HTTPSPort"]), port > 0 {
            httpsHost = host
            httpsPort = port
        }
        if boolFlag(dict["SOCKSEnable"]),
           let host = nonEmptyString(dict["SOCKSProxy"]),
           let port = intValue(dict["SOCKSPort"]), port > 0 {
            socksHost = host
            socksPort = port
        }
        if boolFlag(dict["ProxyAutoConfigEnable"]),
           let urlStr = nonEmptyString(dict["ProxyAutoConfigURLString"]) {
            pacURL = urlStr
        }
    }

    private static func boolFlag(_ value: Any?) -> Bool {
        if let num = value as? NSNumber { return num.intValue != 0 }
        if let b = value as? Bool { return b }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String { return Int(str) }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func activeVPNTunnelInterfaces() -> [String] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        var found: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let iface = current.pointee
            let flags = Int32(iface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUp, let namePtr = iface.ifa_name, let addrPtr = iface.ifa_addr {
                let name = String(cString: namePtr)
                let lower = name.lowercased()
                let isTunnelName = lower.hasPrefix("utun") || lower.hasPrefix("ipsec") || lower.hasPrefix("ppp")
                if isTunnelName && addrPtr.pointee.sa_family == UInt8(AF_INET) {
                    found.insert(name)
                }
            }
            cursor = iface.ifa_next
        }
        return found.sorted()
    }

    private static func excludedDomainsForManualProxy(settings: ProxySettingsData) -> [String] {
        var list = ["localhost", "127.0.0.1", "*.local"]
        if settings.bypassChinaDomains {
            for suffix in chinaAndLocalBypassSuffixes where suffix != "localhost" && suffix != "local" {
                list.append(suffix)
                list.append("*.\(suffix)")
            }
        }
        for rule in parseCustomBypassRules(settings.customBypassRules) {
            list.append(rule)
        }
        return list
    }

    private static func parseCustomBypassRules(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",;\n\r "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func matchesBypassRule(host: String, rule: String) -> Bool {
        if rule.hasPrefix("*.") {
            let suffix = String(rule.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        if rule.hasPrefix(".") {
            let suffix = String(rule.dropFirst())
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        if rule.hasSuffix("*") {
            let prefix = String(rule.dropLast())
            return host.hasPrefix(prefix)
        }
        return host == rule || host.hasSuffix(".\(rule)")
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
