import SwiftUI

// MARK: - Surfaces
//
// Content sits on soft cards that match Apple's grouped surfaces. Liquid Glass
// is reserved for the navigation layer — toolbar controls, floating buttons and
// the tab bar — exactly as the Human Interface Guidelines describe.

/// A content card: system grouped surface, continuous corners, hairline
/// separator. No borders-for-decoration, no chrome.
struct Panel<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var tint: Color? = nil
    var interactive: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.grouped)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.12))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.stroke.opacity(0.5), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// Wraps any view in a content card.
    func panel(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        Panel(cornerRadius: cornerRadius, tint: tint, interactive: interactive) { self }
    }
}

/// Compact status pill: tinted capsule, sentence case, platform caption size.
struct GlassChip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = Palette.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Circular glass icon button sized for a comfortable 44pt target.
struct GlassIconButton: View {
    var systemImage: String
    var tint: Color = Palette.textPrimary
    var size: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(systemImage)
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
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
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
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
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
                .font(.system(size: 48, weight: .light))
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

    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing {
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
