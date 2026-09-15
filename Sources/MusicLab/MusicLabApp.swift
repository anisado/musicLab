import SwiftUI

@main
struct MusicLabApp: App {
    @StateObject private var store = Store()
    @StateObject private var model = MusicViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}
