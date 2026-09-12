import SwiftUI

// MARK: - Color

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Collections

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Optional bindings

extension Binding {
    /// Binding<Wrapped?> → Binding<Bool> (true when non-nil).
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}

// MARK: - View conveniences

extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value { transform(self, value) } else { self }
    }

    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if isHidden { self.hidden() } else { self }
    }

    /// Applies a modifier only in regular (iPad) size classes.
    @ViewBuilder
    func regularWidthOnly() -> some View {
        self
    }
}

// MARK: - Strings

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }

    /// Localized-ish title case for option identifiers ("check_engine" → "Check Engine").
    var humanizedIdentifier: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func truncated(to limit: Int, ellipsis: String = "…") -> String {
        count > limit ? String(prefix(limit)) + ellipsis : self
    }
}

extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension URL {
    var hostDisplayName: String {
        host?.replacingOccurrences(of: "www.", with: "") ?? absoluteString
    }

    var faviconURL: URL? {
        guard let host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
    }
}
