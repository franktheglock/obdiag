import SwiftUI
import FirebaseCore
import FirebaseAppCheck

@main
struct OBDiagApp: App {
    @State private var environment = AppEnvironment()

    init() {
        configureFirebase()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }

    /// Firebase must be configured before any Auth or App Check call. When
    /// `GoogleService-Info.plist` isn't bundled the app still runs, but the
    /// managed assistant is unavailable and the app falls back to the local
    /// providers.
    private func configureFirebase() {
        guard BackendConfig.isFirebaseConfigured else {
            #if DEBUG
            print("[OBDiag] GoogleService-Info.plist missing — managed backend disabled. Falling back to the demo/local providers.")
            #endif
            return
        }
        guard FirebaseApp.app() == nil else { return }

        // App Check attests that requests come from a genuine build of this app.
        // The `chat` callable enforces App Check, so this must be registered
        // before the first assistant request.
        #if DEBUG
        // The debug provider prints a token to the console; register it in the
        // Firebase console under App Check → Apps → Manage debug tokens.
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(OBDiagAppCheckProviderFactory())
        #endif

        FirebaseApp.configure()
    }
}
