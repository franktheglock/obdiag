import SwiftUI
import AuthenticationServices

/// Sign in with Apple.
///
/// Uses Apple's own `SignInWithAppleButton` rather than a custom control: the
/// sign-in affordance is one of the few places the guidelines require the
/// system-provided button, and it also removes the need to source a presentation
/// anchor by hand.
struct AppleSignInButton: View {
    @Environment(AppEnvironment.self) private var env
    var onSignedIn: (() -> Void)?

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            env.auth.prepare(request)
        } onCompletion: { result in
            Task {
                if await env.auth.complete(result) {
                    onSignedIn?()
                }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(env.auth.isSigningIn)
    }
}

/// Explains why an account is needed and offers the sign-in button.
///
/// Purchases are gated on this: credits are granted server-side against a
/// Firebase uid, so an anonymous purchase would have nowhere to land. RevenueCat
/// can alias an anonymous user, but the server parks those credits instead of
/// granting them, so requiring an account up front avoids the whole situation.
struct AccountRequiredView: View {
    @Environment(AppEnvironment.self) private var env
    var reason: String
    var onSignedIn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                Text("Sign in to continue")
                    .font(.obHeadline)
                    .foregroundStyle(Palette.textPrimary)
            }

            Text(reason)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)

            AppleSignInButton(onSignedIn: onSignedIn)

            if let error = env.auth.lastError {
                Text(error)
                    .font(.obCaption)
                    .foregroundStyle(Palette.danger)
            }

            Text("Your plan and credits follow your account, so they survive reinstalling the app.")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(16)
        .panel()
    }
}

/// Signed-in account summary with a sign-out control.
struct AccountSummaryView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill.badge.checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in")
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    Text(env.account.plan.title + " plan · " + Format.credits(env.account.credits) + " credits")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }

            GlassSecondaryButton(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                env.auth.signOut()
            }
        }
        .padding(16)
        .panel()
    }
}
