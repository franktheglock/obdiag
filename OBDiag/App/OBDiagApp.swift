import SwiftUI
import FirebaseCore
import FirebaseAppCheck
import FirebaseAuth
import RevenueCat

@main
struct OBDiagApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Order matters here, and this is why `environment` has no default value.
        //
        // A stored-property initialiser (`@State private var environment =
        // AppEnvironment()`) runs *before* this initialiser body, and
        // AppEnvironment builds BackendAuth, whose initialiser reads
        // `Auth.auth()`. That requires the default FirebaseApp to exist, so
        // configuring Firebase in the body afterwards crashed on launch as soon
        // as `GoogleService-Info.plist` was added.
        Self.configureFirebase()
        Self.configureRevenueCat()
        _environment = State(initialValue: AppEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }

    /// When `GoogleService-Info.plist` isn't bundled the app still runs, but the
    /// managed assistant is unavailable and it falls back to the local providers.
    private static func configureFirebase() {
        guard BackendConfig.isFirebaseConfigured else {
            #if DEBUG
            print("[OBDiag] GoogleService-Info.plist missing — managed backend disabled. Falling back to the demo/local providers.")
            #endif
            return
        }
        guard FirebaseApp.app() == nil else { return }

        // App Check attests that requests come from a genuine build of this app.
        // The `chat` callable enforces it, so this must be registered before the
        // first assistant request.
        #if DEBUG
        // The debug provider prints a token to the console; register it in the
        // Firebase console under App Check → Apps → Manage debug tokens.
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(OBDiagAppCheckProviderFactory())
        #endif

        FirebaseApp.configure()
    }

    /// RevenueCat must be configured once, before anything reads `Purchases.shared`.
    /// With no public SDK key the store is simply unavailable and the app runs on
    /// the free plan.
    private static func configureRevenueCat() {
        guard BackendConfig.isStoreConfigured, !Purchases.isConfigured else { return }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        // Pass the restored Firebase uid when there is one, so a returning
        // subscriber is identified immediately instead of being aliased up from
        // a fresh anonymous user.
        Purchases.configure(
            withAPIKey: BackendConfig.revenueCatAPIKey,
            appUserID: Auth.auth().currentUser?.uid
        )
    }
}
