import SwiftUI

@main
struct LetsLapseWatchApp: App {
    @StateObject private var remote = WatchCaptureRemote()

    var body: some Scene {
        WindowGroup {
            WatchControlView()
                .environmentObject(remote)
        }
    }
}
