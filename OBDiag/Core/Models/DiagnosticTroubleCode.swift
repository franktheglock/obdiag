import SwiftUI

/// How serious a fault is, driving both copy and color.
enum Severity: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case info
    case low
    case moderate
    case high
    case critical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Info"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .info: return Palette.textSecondary
        case .low: return Palette.success
        case .moderate: return Palette.amber
        case .high: return Color(hex: 0xFF8A3D)
        case .critical: return Palette.danger
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .low: return "checkmark.circle.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.octagon.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .moderate: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// OBD-II mode 03/07/0A code categories.
enum DTCStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case stored
    case pending
    case permanent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stored: return "Stored"
        case .pending: return "Pending"
        case .permanent: return "Permanent"
        }
    }

    var explanation: String {
        switch self {
        case .stored: return "Confirmed by the ECU and saved in memory. The check-engine light is usually on."
        case .pending: return "Detected once, awaiting a second drive cycle before it is confirmed."
        case .permanent: return "Emissions-related code that cannot be cleared with a scan tool; it clears itself after the ECU re-tests."
        }
    }

    var color: Color {
        switch self {
        case .stored: return Palette.danger
        case .pending: return Palette.amber
        case .permanent: return Palette.purple
        }
    }
}

/// First letter of a DTC identifies the vehicle system.
enum DTCSystem: String, Codable, CaseIterable, Sendable {
    case powertrain = "P"
    case body = "B"
    case chassis = "C"
    case network = "U"
    case unknown = "?"

    var title: String {
        switch self {
        case .powertrain: return "Powertrain"
        case .body: return "Body"
        case .chassis: return "Chassis"
        case .network: return "Network"
        case .unknown: return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .powertrain: return "engine.combustion"
        case .body: return "car.side"
        case .chassis: return "steeringwheel"
        case .network: return "cable.connector"
        case .unknown: return "questionmark.circle"
        }
    }

    static func from(code: String) -> DTCSystem {
        guard let first = code.uppercased().first else { return .unknown }
        return DTCSystem(rawValue: String(first)) ?? .unknown
    }
}

/// A single fault code with everything the UI and the AI need.
struct DiagnosticTroubleCode: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(code)-\(status.rawValue)" }
    var code: String
    var status: DTCStatus
    var title: String
    var detail: String
    var severity: Severity
    var possibleCauses: [String]
    var symptoms: [String]
    var recommendedActions: [String]
    var isManufacturerSpecific: Bool
    var freezeFrame: [FreezeFrameItem]

    var system: DTCSystem { DTCSystem.from(code: code) }

    static func placeholder(code: String, status: DTCStatus = .stored) -> DiagnosticTroubleCode {
        let system = DTCSystem.from(code: code)
        return DiagnosticTroubleCode(
            code: code.uppercased(),
            status: status,
            title: "\(system.title) code \(code.uppercased())",
            detail: "No description in the on-device library. Ask the AI assistant to explain this code for your specific vehicle.",
            severity: .moderate,
            possibleCauses: [],
            symptoms: [],
            recommendedActions: ["Ask the AI assistant about this code"],
            isManufacturerSpecific: code.uppercased().hasPrefix("P1") || code.uppercased().hasPrefix("Po"),
            freezeFrame: []
        )
    }
}

/// A snapshot frame captured by the ECU when the fault was stored.
struct FreezeFrameItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var value: String
}
