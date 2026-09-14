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

    private var currentNonce: String?
    private var signInContinuation: CheckedContinuation<Void, Error>?
    private weak var presentationAnchor: ASPresentationAnchor?

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

    func signInWithApple(anchor: ASPresentationAnchor? = nil) async throws {
        guard BackendConfig.isFirebaseConfigured else { throw BackendError.notConfigured }
        guard !isSigningIn else { return }

        isSigningIn = true
        lastError = nil
        presentationAnchor = anchor
        defer { isSigningIn = false }

        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
            controller.performRequests()
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

    private func finishSignIn(_ result: Result<Void, Error>) {
        let continuation = signInContinuation
        signInContinuation = nil
        currentNonce = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            lastError = error.localizedDescription
            continuation?.resume(throwing: error)
        }
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

// MARK: - Authorization callbacks

extension BackendAuth: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            finishSignIn(.failure(BackendError.malformedResponse("Apple returned no identity token.")))
            return
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        Task {
            do {
                try await Auth.auth().signIn(with: firebaseCredential)
                finishSignIn(.success(()))
            } catch {
                finishSignIn(.failure(error))
            }
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        // A user cancellation is not an error worth surfacing.
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finishSignIn(.failure(CancellationError()))
            return
        }
        finishSignIn(.failure(error))
    }
}

extension BackendAuth: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let presentationAnchor { return presentationAnchor }
        // Fall back to the key window; Sign in with Apple requires an anchor.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
