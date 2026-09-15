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
// Every `ob*` font is a text style with a weight, never a fixed point size, so
// the whole app follows the user's text size setting. Numbers use tabular
// figures via `.obMono`, which scales its base size with `@ScaledMetric`.

extension Font {
    static let obDisplay = Font.largeTitle.weight(.bold)
    static let obLargeTitle = Font.largeTitle.weight(.bold)
    static let obTitle = Font.title2.weight(.semibold)
    static let obTitle2 = Font.title3.weight(.semibold)
    static let obHeadline = Font.headline
    static let obBody = Font.body
    static let obCallout = Font.callout
    static let obCaption = Font.footnote
    static let obMicro = Font.caption.weight(.medium)
    static let obLabel = Font.caption.weight(.medium)
}

/// A system font at a designed point size that still scales with Dynamic Type.
/// The size is treated as the value at the default (Large) text size and
/// scaled relative to the closest text style, so a 44pt hero readout grows and
/// shrinks in step with the body text around it.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let tabularDigits: Bool

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, tabularDigits: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(closestTo: size))
        self.weight = weight
        self.design = design
        self.tabularDigits = tabularDigits
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: weight, design: design)
        content.font(tabularDigits ? font.monospacedDigit() : font)
    }

    /// Default (Large) point sizes of the iOS text styles, used to pick which
    /// style's scaling curve a custom size should follow.
    private static func textStyle(closestTo size: CGFloat) -> Font.TextStyle {
        switch size {
        case 34...: return .largeTitle
        case 28..<34: return .title
        case 22..<28: return .title2
        case 20..<22: return .title3
        case 17..<20: return .body
        case 16..<17: return .callout
        case 15..<16: return .subheadline
        case 13..<15: return .footnote
        case 12..<13: return .caption
        default: return .caption2
        }
    }
}

extension View {
    /// Tabular figures at a scaled size, so live values never jitter as they
    /// update and still respect Dynamic Type.
    func obMono(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: .default, tabularDigits: true))
    }

    /// True monospace at a scaled size, reserved for raw adapter logs and
    /// protocol payloads.
    func obMonoFull(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: .monospaced, tabularDigits: false))
    }
}

// MARK: - Background

/// The app backdrop: the plain system background. Colour lives in content
/// (readings, severity, the accent on actions), not in the canvas behind it.
struct AppBackground: View {
    var body: some View {
        Palette.base.ignoresSafeArea()
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
