import SwiftUI

/// OBDiag's visual language follows Apple's platform conventions: semantic
/// system colors, SF typography, soft materials and generous spacing. Color is
/// used for meaning — amber for warnings, red for faults, green for healthy —
/// not as decoration.
enum Palette {
    // Surfaces (resolve to the standard dark equivalents)
    static let base = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let elevated = Color(uiColor: .tertiarySystemBackground)
    static let grouped = Color(uiColor: .secondarySystemGroupedBackground)
    static let stroke = Color(uiColor: .separator)
    static let strokeStrong = Color(uiColor: .opaqueSeparator)

    // Text
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // System signal colors
    static let accent = Color(uiColor: .systemBlue)
    static let amber = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let success = Color(uiColor: .systemGreen)
    static let purple = Color(uiColor: .systemPurple)
    static let info = Color(uiColor: .systemGray)

    // Data viz
    static let chartLine = Color(uiColor: .systemBlue)
    static let chartFill = Color(uiColor: .systemBlue).opacity(0.12)
}

enum Gradients {
    static let accent = LinearGradient(
        colors: [Color(uiColor: .systemBlue), Color(uiColor: .systemIndigo)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let warning = LinearGradient(
        colors: [Color(uiColor: .systemOrange), Color(uiColor: .systemYellow)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let danger = LinearGradient(
        colors: [Color(uiColor: .systemRed), Color(uiColor: .systemPink)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Typography
//
// SF Pro throughout, mapped to the platform text styles so Dynamic Type works.
// Numbers use tabular figures; only raw protocol data is truly monospaced.

extension Font {
    static let obDisplay = Font.system(size: 32, weight: .bold)
    static let obLargeTitle = Font.system(size: 32, weight: .bold)
    static let obTitle = Font.system(size: 24, weight: .semibold)
    static let obTitle2 = Font.system(size: 20, weight: .semibold)
    static let obHeadline = Font.system(size: 17, weight: .semibold)
    static let obBody = Font.system(size: 17, weight: .regular)
    static let obCallout = Font.system(size: 16, weight: .regular)
    static let obCaption = Font.system(size: 13, weight: .regular)
    static let obMicro = Font.system(size: 12, weight: .medium)
    static let obLabel = Font.system(size: 12, weight: .medium)

    /// Tabular figures so live values never jitter as they update.
    static func obMono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// True monospace, reserved for raw adapter logs and protocol payloads.
    static func obMonoFull(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Small secondary label treatment used above readouts and in section heads.
    func obLabelStyle(_ color: Color = Palette.textSecondary) -> some View {
        font(.obLabel)
            .foregroundStyle(color)
    }
}

// MARK: - Background

/// A quiet dark backdrop: system background with two very soft color blooms,
/// like the ambience in Weather or Fitness. No grid, no texture — the content
/// is the interface.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Palette.base

            RadialGradient(
                colors: [Palette.accent.opacity(0.14), .clear],
                center: .init(x: 0.12, y: -0.08), startRadius: 0, endRadius: 640
            )
            RadialGradient(
                colors: [Palette.purple.opacity(0.07), .clear],
                center: .init(x: 0.95, y: 0.10), startRadius: 0, endRadius: 520
            )
            RadialGradient(
                colors: [Palette.amber.opacity(0.05), .clear],
                center: .init(x: 0.85, y: 0.95), startRadius: 0, endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

/// Sheet content helper: keeps scroll/list backgrounds transparent so the
/// sheet's own backdrop shows through exactly once — no seams.
struct TransparentSheetContent: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
    }
}

extension View {
    func transparentSheetContent() -> some View { modifier(TransparentSheetContent()) }
}

/// Soft fade behind floating bottom controls (composer, action bars).
struct BottomFade: ViewModifier {
    var intensity: Double = 0.9

    func body(content: Content) -> some View {
        content.background {
            LinearGradient(
                colors: [Palette.base.opacity(0), Palette.base.opacity(intensity)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

extension View {
    func bottomFade(intensity: Double = 0.9) -> some View { modifier(BottomFade(intensity: intensity)) }
}

/// Standard screen chrome: background + scroll styling hook.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { AppBackground().ignoresSafeArea() }
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }

    /// App backdrop for list-based screens. Full-bleed, so it reaches under the
    /// floating tab bar with no seam.
    func appBackdrop() -> some View {
        background { AppBackground().ignoresSafeArea() }
    }
}
