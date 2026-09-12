import Foundation

/// Global unit preference. All stored values are metric/SI; conversion happens
/// only at the display layer.
enum UnitSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case imperial
    case metric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imperial: return "Imperial"
        case .metric: return "Metric"
        }
    }

    var subtitle: String {
        switch self {
        case .imperial: return "°F, mph, PSI, gallons"
        case .metric: return "°C, km/h, kPa, liters"
        }
    }

    var temperatureSymbol: String { self == .imperial ? "°F" : "°C" }
    var speedSymbol: String { self == .imperial ? "mph" : "km/h" }
    var distanceSymbol: String { self == .imperial ? "mi" : "km" }
    var pressureSymbol: String { self == .imperial ? "psi" : "kPa" }
    var volumeSymbol: String { self == .imperial ? "gal" : "L" }
    var airFlowSymbol: String { self == .imperial ? "lb/min" : "g/s" }
    var economySymbol: String { self == .imperial ? "mpg" : "L/100km" }
}

/// Physical quantity kinds used by the sensor catalog.
enum MeasureKind: String, Codable, Sendable {
    case temperatureCelsius
    case speedKPH
    case distanceKM
    case pressureKPA
    case volumeLiters
    case airFlowGramsPerSecond
    case percent
    case ratio
    case voltage
    case rpm
    case angleDegrees
    case count
    case durationSeconds
    case frequencyHz
    case fuelEconomy
    case lambda
    case text

    var unitSymbol: String {
        switch self {
        case .temperatureCelsius: return "°C"
        case .speedKPH: return "km/h"
        case .distanceKM: return "km"
        case .pressureKPA: return "kPa"
        case .volumeLiters: return "L"
        case .airFlowGramsPerSecond: return "g/s"
        case .percent: return "%"
        case .ratio: return ":1"
        case .voltage: return "V"
        case .rpm: return "rpm"
        case .angleDegrees: return "°"
        case .count: return ""
        case .durationSeconds: return "s"
        case .frequencyHz: return "Hz"
        case .fuelEconomy: return "L/100km"
        case .lambda: return "λ"
        case .text: return ""
        }
    }
}

/// Converts and formats a stored (metric) value for the active unit system.
struct UnitConverter {
    let system: UnitSystem

    func value(_ value: Double, kind: MeasureKind) -> Double {
        switch (system, kind) {
        case (.imperial, .temperatureCelsius): return value * 9 / 5 + 32
        case (.imperial, .speedKPH): return value * 0.621371
        case (.imperial, .distanceKM): return value * 0.621371
        case (.imperial, .pressureKPA): return value * 0.145038
        case (.imperial, .volumeLiters): return value * 0.264172
        case (.imperial, .airFlowGramsPerSecond): return value * 0.132277
        case (.imperial, .fuelEconomy):
            // L/100km → mpg
            return value <= 0 ? 0 : 235.215 / value
        default: return value
        }
    }

    func symbol(for kind: MeasureKind) -> String {
        switch (system, kind) {
        case (.imperial, .temperatureCelsius): return "°F"
        case (.imperial, .speedKPH): return "mph"
        case (.imperial, .distanceKM): return "mi"
        case (.imperial, .pressureKPA): return "psi"
        case (.imperial, .volumeLiters): return "gal"
        case (.imperial, .airFlowGramsPerSecond): return "lb/min"
        case (.imperial, .fuelEconomy): return "mpg"
        default: return kind.unitSymbol
        }
    }

    /// Decimal places appropriate for a kind and magnitude.
    func decimals(for kind: MeasureKind, value: Double) -> Int {
        switch kind {
        case .voltage, .lambda: return 2
        case .rpm, .count, .durationSeconds: return 0
        case .percent, .ratio, .angleDegrees, .frequencyHz, .airFlowGramsPerSecond: return 1
        default: return abs(value) >= 100 ? 0 : 1
        }
    }

    func formatted(_ value: Double, kind: MeasureKind) -> String {
        let converted = self.value(value, kind: kind)
        return Format.number(converted, decimals: decimals(for: kind, value: converted))
    }

    func formattedWithUnit(_ value: Double, kind: MeasureKind) -> String {
        let symbol = symbol(for: kind)
        let text = formatted(value, kind: kind)
        return symbol.isEmpty ? text : "\(text) \(symbol)"
    }
}
