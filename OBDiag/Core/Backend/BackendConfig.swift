import Foundation

/// Static backend configuration.
///
/// These values must match the deployed Firebase project:
///   - `projectID` ↔ `server/.firebaserc`
///   - `region`    ↔ `REGION` in `server/functions/src/config.ts`
enum BackendConfig {
    /// Firebase project id that hosts the functions.
    static let projectID = "YOUR_FIREBASE_PROJECT_ID"
    /// Region the callable functions are deployed to.
    static let region = "us-central1"

    /// Callable function names. Keep in sync with `server/functions/src/index.ts`.
    enum Function {
        static let chat = "chat"
        static let listModels = "listModels"
        static let accountSummary = "getAccountSummary"
        static let syncEntitlements = "syncEntitlements"
    }

    /// `https://<region>-<projectID>.cloudfunctions.net/<name>`, matching the
    /// URL scheme the Firebase SDK uses for callable functions.
    static func callableURL(_ name: String) -> URL? {
        URL(string: "https://\(region)-\(projectID).cloudfunctions.net/\(name)")
    }

    /// True when `GoogleService-Info.plist` is bundled, which Firebase Auth and
    /// App Check both require. The app stays usable (demo/local providers) when
    /// it is absent, so a checkout without backend credentials still builds.
    static var isFirebaseConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    /// RevenueCat public SDK key, `appl_…`.
    ///
    /// Not a secret: it identifies the app rather than authenticating a user, and
    /// is designed to ship inside the binary. Set it here.
    ///
    /// Deliberately *not* read from Info.plist. `INFOPLIST_KEY_<name>` build
    /// settings only populate Apple's own Info.plist keys — a custom key is
    /// silently dropped from the generated plist even when the setting is
    /// defined, which fails late and confusingly (an empty key reaching
    /// `Purchases.configure`).
    static let revenueCatAPIKey = ""

    /// True once `revenueCatAPIKey` has been filled in.
    static var isStoreConfigured: Bool { !revenueCatAPIKey.isBlank }
}
