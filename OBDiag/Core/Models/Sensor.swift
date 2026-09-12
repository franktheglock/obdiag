import SwiftUI

/// Every live value OBDiag understands. Metadata (formulas, ranges, icons)
/// lives in `SensorCatalog`.
enum SensorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Engine
    case engineRPM
    case vehicleSpeed
    case engineLoad
    case absoluteLoad
    case throttlePosition
    case timingAdvance
    case runtimeSinceStart
    case engineOilTemperature

    // Temperature
    case coolantTemperature
    case intakeAirTemperature
    case ambientAirTemperature
    case catalystTempBank1Sensor1
    case catalystTempBank1Sensor2
    case catalystTempBank2Sensor1
    case catalystTempBank2Sensor2

    // Air & fuel
    case manifoldAbsolutePressure
    case boostPressure
    case massAirFlow
    case fuelPressure
    case fuelRailGaugePressure
    case fuelLevel
    case barometricPressure
    case commandedEquivalenceRatio
    case ethanolFuelPercent
    case fuelType

    // Fuel trims
    case shortTermFuelTrimBank1
    case longTermFuelTrimBank1
    case shortTermFuelTrimBank2
    case longTermFuelTrimBank2

    // O2 sensors
    case o2Bank1Sensor1
    case o2Bank1Sensor2
    case o2Bank2Sensor1
    case o2Bank2Sensor2

    // Emissions & electrical
    case commandedEGR
    case egrError
    case evapPurge
    case batteryVoltage

    // Counters
    case distanceWithMILOn
    case distanceSinceCodesCleared
    case timeSinceCodesCleared
    case warmupsSinceCodesCleared

    var id: String { rawValue }
}

enum SensorGroup: String, CaseIterable, Identifiable, Sendable {
    case engine
    case temperatures
    case airFuel
    case fuelTrims
    case o2Sensors
    case electrical
    case emissions
    case counters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engine: return "Engine"
        case .temperatures: return "Temperatures"
        case .airFuel: return "Air & Fuel"
        case .fuelTrims: return "Fuel Trims"
        case .o2Sensors: return "O₂ Sensors"
        case .electrical: return "Electrical"
        case .emissions: return "Emissions"
        case .counters: return "Counters"
        }
    }

    var icon: String {
        switch self {
        case .engine: return "engine.combustion"
        case .temperatures: return "thermometer.medium"
        case .airFuel: return "wind"
        case .fuelTrims: return "dial.medium"
        case .o2Sensors: return "aqi.medium"
        case .electrical: return "bolt"
        case .emissions: return "leaf"
        case .counters: return "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

/// A single decoded reading from the adapter (or the demo simulator).
struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    var kind: SensorKind
    var value: Double
    var rawValue: String?
    var timestamp: Date
    var isSupported: Bool

    var id: SensorKind { kind }

    static func unsupported(_ kind: SensorKind) -> SensorReading {
        SensorReading(kind: kind, value: .nan, rawValue: nil, timestamp: Date(), isSupported: false)
    }

    var isValid: Bool { isSupported && !value.isNaN }
}

/// Health assessment for a reading, used for color coding.
enum ReadingHealth: Sendable {
    case normal
    case caution
    case warning
    case critical
    case inactive

    var color: Color {
        switch self {
        case .normal: return Palette.success
        case .caution: return Palette.amber
        case .warning: return Color(hex: 0xFF8A3D)
        case .critical: return Palette.danger
        case .inactive: return Palette.textTertiary
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .caution: return "Watch"
        case .warning: return "High"
        case .critical: return "Critical"
        case .inactive: return "Unavailable"
        }
    }
}

/// Static metadata for a sensor: name, units, healthy ranges, grouping.
struct SensorDefinition: Identifiable, Sendable {
    var kind: SensorKind
    var name: String
    var shortName: String
    var measure: MeasureKind
    var group: SensorGroup
    var icon: String
    var minimum: Double
    var maximum: Double
    var cautionBelow: Double?
    var cautionAbove: Double?
    var criticalBelow: Double?
    var criticalAbove: Double?
    var gaugeSegments: Int = 5

    var id: SensorKind { kind }

    /// Evaluates a raw (metric) value against the configured thresholds.
    func health(for value: Double) -> ReadingHealth {
        if let criticalBelow, value < criticalBelow { return .critical }
        if let criticalAbove, value > criticalAbove { return .critical }
        if let cautionBelow, value < cautionBelow { return .warning }
        if let cautionAbove, value > cautionAbove { return .warning }
        return .normal
    }

    /// 0…1 position on the gauge track.
    func fraction(for value: Double) -> Double {
        guard maximum > minimum else { return 0 }
        return min(max((value - minimum) / (maximum - minimum), 0), 1)
    }
}
