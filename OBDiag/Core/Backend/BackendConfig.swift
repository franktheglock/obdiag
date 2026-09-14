import Foundation

/// Static backend configuration.
///
/// These values must match the deployed Firebase project:
///   - `projectID` ↔ `server/.firebaserc`
///   - `region`    ↔ `REGION` in `server/functions/src/config.ts`
enum BackendConfig {
    /// Firebase project id that hosts the functions.
    static let projectID = "obdiag-app"
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

    /// RevenueCat public SDK key. Set `RevenueCat-API-Key` in Info.plist, or
    /// override here for a development build.
    static var revenueCatAPIKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String) ?? ""
    }
}
