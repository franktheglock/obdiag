import Foundation

/// Shared, locale-aware formatters. Live-data formatters use tabular digits
/// so values don't jitter as they update.
enum Format {
    static let groupedDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    static func number(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func integer(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    static func currency(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = .current
        return f.string(from: amount as NSNumber) ?? "$\(number(amount, decimals: 2))"
    }

    static func credits(_ value: Int) -> String {
        NumberFormatter.localizedString(from: value as NSNumber, number: .decimal)
    }

    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if abs(interval) < 5 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    static func chatTimestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 1S2A3B4C5D → "1S2-A3B-4C5-D"? No — VINs stay whole, but partial VINs get grouped.
    static func vin(_ vin: String) -> String {
        vin.uppercased().trimmed
    }

    /// Normalizes user-entered year ("'18", "2018", "18") to a four-digit year.
    static func normalizeYear(_ input: String) -> Int? {
        let digits = input.filter(\.isNumber)
        guard let number = Int(digits) else { return nil }
        switch number {
        case 1900...2999: return number
        case 0...99: return number >= 30 ? 1900 + number : 2000 + number
        default: return nil
        }
    }
}

extension Int {
    var formattedWithGrouping: String { Format.credits(self) }
}
