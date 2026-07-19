import SwiftUI

@main
struct LetsLapseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 680)
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            switch model.stage {
            case .home:
                HomeView()
            case .configure:
                BlendOptionsView()
            case .processing:
                ProcessingView()
            case .done:
                ResultView()
            }
        }
    }
}
