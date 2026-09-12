import SwiftUI

@main
struct OBDiagApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}
