import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth

/// Sign in with Apple backed by Firebase Auth.
///
/// The Firebase uid becomes the RevenueCat `appUserID`, which is what lets a
/// purchase webhook be matched to the right account.
@MainActor
@Observable
final class BackendAuth: NSObject {
    enum State: Equatable {
        /// No `GoogleService-Info.plist`, so the managed backend is unavailable.
        case unconfigured
        case signedOut
        case signedIn(uid: String)
    }

    private(set) var state: State = .unconfigured
    private(set) var isSigningIn = false
    private(set) var lastError: String?

    /// Called whenever the signed-in user changes, with the new uid (`nil` when
    /// signed out). Lets RevenueCat's `appUserID` track the Firebase uid, which
    /// is what lets a purchase webhook be matched to an account.
    var onUserChanged: ((String?) -> Void)?

    private var currentNonce: String?

    override init() {
        super.init()
        guard BackendConfig.isFirebaseConfigured else {
            state = .unconfigured
            return
        }

        state = Auth.auth().currentUser.map { .signedIn(uid: $0.uid) } ?? .signedOut

        // The listener is intentionally never removed: this object lives for the
        // lifetime of the app, and deinit can't touch main-actor state.
        _ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                self.state = user.map { .signedIn(uid: $0.uid) } ?? .signedOut
                self.onUserChanged?(user?.uid)
            }
        }
    }

    var uid: String? {
        if case .signedIn(let uid) = state { return uid }
        return nil
    }

    var isSignedIn: Bool { uid != nil }

    /// A fresh Firebase ID token. `getIDToken()` refreshes automatically when
    /// the cached token is close to expiry.
    func idToken() async throws -> String {
        guard let user = Auth.auth().currentUser else { throw BackendError.notSignedIn }
        do {
            return try await user.getIDToken()
        } catch {
            throw BackendError.function(
                code: "unauthenticated",
                message: "Your session expired. Please sign in again."
            )
        }
    }

    // MARK: Sign in / out

    /// Configures the Sign in with Apple request.
    ///
    /// Call from `SignInWithAppleButton`'s `onRequest`. The nonce is generated
    /// here and its SHA-256 goes to Apple; the raw value is held until
    /// completion, where Firebase needs it to verify the returned token.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Completes sign-in from `SignInWithAppleButton`'s `onCompletion`.
    ///
    /// Returns whether the user is now signed in. A cancellation is not an
    /// error and is not surfaced.
    @discardableResult
    func complete(_ result: Result<ASAuthorization, Error>) async -> Bool {
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return false
            }
            lastError = error.localizedDescription
            return false

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                lastError = "Apple did not return an identity token. Please try again."
                return false
            }
            currentNonce = nil

            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: identityToken,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            do {
                try await Auth.auth().signIn(with: firebaseCredential)
                return true
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        state = .signedOut
    }

    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else { throw BackendError.notSignedIn }
        // Client-side deletion only removes the auth identity; server-side data
        // removal is handled by a dedicated callable in a later release.
        try await user.delete()
        state = .signedOut
    }

    // MARK: Nonce helpers

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else {
                // Fall back to the system RNG rather than shipping a weak nonce.
                result.append(characters.randomElement() ?? "x")
                remaining -= 1
                continue
            }
            if random < characters.count {
                result.append(characters[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
