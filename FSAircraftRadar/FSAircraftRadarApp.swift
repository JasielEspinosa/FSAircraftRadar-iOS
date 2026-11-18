import SwiftUI

@main
struct FSAircraftRadarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.settings.themeMode.colorScheme)
        }
    }
}
