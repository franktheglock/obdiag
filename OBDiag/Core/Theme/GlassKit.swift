import SwiftUI

// MARK: - Surfaces
//
// Content sits on soft cards that match Apple's grouped surfaces. Liquid Glass
// is reserved for the navigation layer — toolbar controls, floating buttons and
// the tab bar — exactly as the Human Interface Guidelines describe.

/// A content card: the system grouped surface with continuous corners, like
/// an inset-grouped cell. No border, no shadow, one radius everywhere. The card
/// adds no inset of its own; callers pad their content (14–16pt for text,
/// `.vertical` only for row lists so dividers run edge to edge).
/// The one card radius, shared by every `Panel`.
let panelCornerRadius: CGFloat = 20

struct Panel<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .fill(Palette.grouped)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                                .fill(tint.opacity(0.12))
                        }
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
    }
}

extension View {
    /// Wraps any view in a content card.
    func panel(tint: Color? = nil) -> some View {
        Panel(tint: tint) { self }
    }
}

/// Compact metadata tag, like the tags in the App Store: a quiet system-fill
/// capsule with secondary text. Colour appears only on the icon, and only when
/// it means something (severity, status).
struct GlassChip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = Palette.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// Primary action, using the platform's prominent glass button style.
struct GlassActionButton: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = Palette.accent
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Secondary action, using the platform's glass button style.
struct GlassSecondaryButton: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = Palette.textPrimary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

/// Section heading with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 2)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Standard empty-state presentation, centred like ContentUnavailableView.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle.weight(.light))
                .imageScale(.large)
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 2)

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            if let actionTitle, let action {
                GlassActionButton(title: actionTitle, action: action)
                    .frame(maxWidth: 260)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Small severity dot used in dense lists.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing, !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.45), lineWidth: 1.5)
                        .scaleEffect(animate ? 2.6 : 1)
                        .opacity(animate ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: animate)
                }
            }
            .onAppear { animate = pulsing }
    }
}

/// Text-input surface for the content layer: the same grouped fill and
/// hairline as `Panel`, without the card padding. Inputs live in the content,
/// not the navigation layer, so they are not glass.
struct InputSurface: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.stroke.opacity(0.5), lineWidth: 0.5)
            }
    }
}

extension View {
    func inputSurface(cornerRadius: CGFloat = 14) -> some View { modifier(InputSurface(cornerRadius: cornerRadius)) }
}

/// Keyboard-safe scroll behaviour helper for chat and forms.
struct ScrollDismissesKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    func dismissKeyboardOnScroll() -> some View { modifier(ScrollDismissesKeyboard()) }
}

/// Sheet root that guarantees OBDiag's backdrop reaches every edge of the
/// sheet — including under the home indicator — so no system material strip
/// shows at the bottom.
struct SheetNavigationStack<Content: View>: View {
    enum Backdrop {
        case appBackground
        case solid(Color)
    }

    var backdrop: Backdrop = .appBackground
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack { content }
            .presentationBackground {
                switch backdrop {
                case .appBackground:
                    AppBackground()
                case .solid(let color):
                    color.ignoresSafeArea()
                }
            }
    }
}
