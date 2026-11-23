import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let supportedThreadCounts = [1, 4, 8, 16]
    static let standardUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let defaults: UserDefaults

    let defaultUserAgent: String = AppSettings.standardUserAgent

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

    @Published var proxySettings: ProxySettingsData {
        didSet { persistProxySettings() }
    }

    private enum Keys {
        static let defaultThreadCount = "iosdm.defaultThreadCount"
        static let threadDefaultMigratedV2 = "iosdm.threadDefaultMigratedV2"
        static let maxConcurrentTasks = "iosdm.maxConcurrentTasks"
        static let allowsCellularAccess = "iosdm.allowsCellularAccess"
        static let keepScreenAwake = "iosdm.keepScreenAwake"
        static let autoResumeOnForeground = "iosdm.autoResumeOnForeground"
        static let proxySettings = "iosdm.proxySettings"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedThreads = defaults.integer(forKey: Keys.defaultThreadCount)
        let migratedV2 = defaults.bool(forKey: Keys.threadDefaultMigratedV2)
        if !migratedV2 {
            defaults.set(true, forKey: Keys.threadDefaultMigratedV2)
            if savedThreads == 0 || savedThreads == 4 {
                self.defaultThreadCount = 8
                defaults.set(8, forKey: Keys.defaultThreadCount)
            } else {
                self.defaultThreadCount = Self.supportedThreadCounts.contains(savedThreads) ? savedThreads : 8
            }
        } else {
            self.defaultThreadCount = Self.supportedThreadCounts.contains(savedThreads) ? savedThreads : 8
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
