import SwiftUI

@main
struct iosdmApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(downloadManager)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        downloadManager.appDidEnterBackground()
                    case .active:
                        downloadManager.appDidBecomeActive()
                    case .inactive:
                        downloadManager.persistTasks()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
