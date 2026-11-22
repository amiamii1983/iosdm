import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let supportedThreadCounts = [1, 2, 4, 8]
    // Clean standard Safari User-Agent without custom app suffixes that trigger overseas cloud-drive blocks
    static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let defaults: UserDefaults

    @Published var defaultThreadCount: Int {
        didSet { defaults.set(defaultThreadCount, forKey: Keys.defaultThreadCount) }
    }

    @Published var maxConcurrentTasks: Int {
        didSet { defaults.set(maxConcurrentTasks, forKey: Keys.maxConcurrentTasks) }
    }

    @Published var allowsCellularAccess: Bool {
        didSet { defaults.set(allowsCellularAccess, forKey: Keys.allowsCellularAccess) }
    }

    @Published var keepScreenAwakeWhileDownloading: Bool {
        didSet { defaults.set(keepScreenAwakeWhileDownloading, forKey: Keys.keepScreenAwake) }
    }

    @Published var autoResumeOnForeground: Bool {
        didSet { defaults.set(autoResumeOnForeground, forKey: Keys.autoResumeOnForeground) }
    }

    @Published var defaultUserAgent: String {
        didSet { defaults.set(defaultUserAgent, forKey: Keys.defaultUserAgent) }
    }

    @Published var proxySettings: ProxySettingsData {
        didSet { persistProxySettings() }
    }

    private enum Keys {
        static let defaultThreadCount = "iosdm.defaultThreadCount"
        static let maxConcurrentTasks = "iosdm.maxConcurrentTasks"
        static let allowsCellularAccess = "iosdm.allowsCellularAccess"
        static let keepScreenAwake = "iosdm.keepScreenAwake"
        static let autoResumeOnForeground = "iosdm.autoResumeOnForeground"
        static let defaultUserAgent = "iosdm.defaultUserAgent"
        static let proxySettings = "iosdm.proxySettings"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedThreads = defaults.integer(forKey: Keys.defaultThreadCount)
        if Self.supportedThreadCounts.contains(savedThreads) {
            self.defaultThreadCount = savedThreads
        } else {
            self.defaultThreadCount = 4
        }

        let savedConcurrent = defaults.integer(forKey: Keys.maxConcurrentTasks)
        self.maxConcurrentTasks = (1...4).contains(savedConcurrent) ? savedConcurrent : 2

        if defaults.object(forKey: Keys.allowsCellularAccess) == nil {
            self.allowsCellularAccess = true
        } else {
            self.allowsCellularAccess = defaults.bool(forKey: Keys.allowsCellularAccess)
        }

        if defaults.object(forKey: Keys.keepScreenAwake) == nil {
            self.keepScreenAwakeWhileDownloading = true
        } else {
            self.keepScreenAwakeWhileDownloading = defaults.bool(forKey: Keys.keepScreenAwake)
        }

        if defaults.object(forKey: Keys.autoResumeOnForeground) == nil {
            self.autoResumeOnForeground = true
        } else {
            self.autoResumeOnForeground = defaults.bool(forKey: Keys.autoResumeOnForeground)
        }

        // Auto-migrate legacy UA containing "iosdm/" so upgrading on iPad fixes cloud-drive compatibility immediately
        if let savedUA = defaults.string(forKey: Keys.defaultUserAgent),
           !savedUA.isEmpty,
           !savedUA.contains("iosdm/") {
            self.defaultUserAgent = savedUA
        } else {
            self.defaultUserAgent = Self.fallbackUserAgent
            defaults.set(Self.fallbackUserAgent, forKey: Keys.defaultUserAgent)
        }

        if let rawProxy = defaults.data(forKey: Keys.proxySettings),
           let decoded = try? JSONDecoder().decode(ProxySettingsData.self, from: rawProxy) {
            self.proxySettings = decoded
        } else {
            self.proxySettings = ProxySettingsData()
        }
    }

    private func persistProxySettings() {
        if let data = try? JSONEncoder().encode(proxySettings) {
            defaults.set(data, forKey: Keys.proxySettings)
        }
    }
}
