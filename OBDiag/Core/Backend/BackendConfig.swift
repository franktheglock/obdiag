import Foundation

/// Static backend configuration.
///
/// No keys or deployment identifiers live in this file. Everything that varies
/// per environment is read from gitignored files that are bundled at build time:
///
///   - `GoogleService-Info.plist` — Firebase's iOS config, and the single source
///     of truth for the project id. Generate your own with
///     `firebase apps:sdkconfig IOS <APP_ID>`; see `docs/SETUP.md`.
///   - `Secrets.plist` — the RevenueCat public SDK key. Copy
///     `Secrets.example.plist` and fill it in.
///
/// Both are absent on a fresh clone, and the app degrades rather than failing:
/// it falls back to the demo assistant and the local providers.
///
/// An iOS app has no runtime `.env` — a Swift `let` is compiled into the binary,
/// so a committed constant would ship the value. A bundled, gitignored file is
/// the equivalent, and it keeps a clone from pointing at someone else's backend.
enum BackendConfig {

    // MARK: Environment files

    /// Reads a plist out of the app bundle, or nil when it isn't there.
    private static func bundledPlist(named name: String) -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }

    private static let firebaseConfig = bundledPlist(named: "GoogleService-Info")
    private static let secrets = bundledPlist(named: "Secrets")

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Firebase

    /// Firebase project id, taken from `GoogleService-Info.plist` so there is one
    /// source of truth and the id stays out of the repository. Empty means the
    /// managed backend is unavailable.
    static let projectID = string(firebaseConfig?["PROJECT_ID"])

    /// Region the callable functions are deployed to. Not an identifier, so it
    /// stays in source. Must match `REGION` in `server/functions/src/config.ts`.
    static let region = "us-central1"

    /// Callable function names. Keep in sync with `server/functions/src/index.ts`.
    enum Function {
        static let chat = "chat"
        static let listModels = "listModels"
        static let accountSummary = "getAccountSummary"
        static let syncEntitlements = "syncEntitlements"
        static let ledger = "getLedger"
    }

    /// `https://<region>-<projectID>.cloudfunctions.net/<name>`, matching the URL
    /// scheme the Firebase SDK uses for callable functions. Nil when no project
    /// id is available, which surfaces as `.notConfigured` rather than a bad URL.
    static func callableURL(_ name: String) -> URL? {
        guard !projectID.isBlank else { return nil }
        return URL(string: "https://\(region)-\(projectID).cloudfunctions.net/\(name)")
    }

    /// True when `GoogleService-Info.plist` is bundled, which Firebase Auth and
    /// App Check both require.
    static var isFirebaseConfigured: Bool { !projectID.isBlank }

    // MARK: RevenueCat

    /// RevenueCat public SDK key.
    ///
    /// Public by design — it identifies the app rather than authenticating a
    /// user — but kept out of the repository so a clone doesn't point at someone
    /// else's RevenueCat project.
    ///
    /// Debug prefers the **Test Store** key, RevenueCat's fake store, so the
    /// whole purchase → webhook → credits path can be exercised without App
    /// Store Connect. Release uses the App Store key. Either falls back to the
    /// other if only one is supplied.
    static var revenueCatAPIKey: String {
        #if DEBUG
        let preferred = string(secrets?["RevenueCatTestAPIKey"])
        return preferred.isEmpty ? string(secrets?["RevenueCatAppStoreAPIKey"]) : preferred
        #else
        let preferred = string(secrets?["RevenueCatAppStoreAPIKey"])
        return preferred.isEmpty ? string(secrets?["RevenueCatTestAPIKey"]) : preferred
        #endif
    }

    /// True once a RevenueCat key has been supplied.
    static var isStoreConfigured: Bool { !revenueCatAPIKey.isBlank }
}
