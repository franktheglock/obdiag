import Foundation

/// A vehicle in the user's garage. Everything in OBDiag is scoped to one of these.
struct Vehicle: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var nickname: String = ""
    var year: Int?
    var make: String
    var model: String
    var trim: String?
    var vin: String?
    var engineDescription: String?
    var fuelType: String?
    var bodyClass: String?
    var driveType: String?
    var notes: String = ""
    var isDirectConnection: Bool = false
    var createdAt: Date = Date()
    var lastConnectedAt: Date?
    var lastKnownCodes: [String] = []
    var lastScanAt: Date?

    /// A generic vehicle used when the user skips setup ("Direct OBD Connection").
    static let directConnection = Vehicle(
        nickname: "Direct OBD Connection",
        make: "Unknown Vehicle",
        model: "Live adapter",
        isDirectConnection: true
    )

    var displayName: String {
        if !nickname.trimmed.isEmpty { return nickname }
        if isDirectConnection { return "Direct OBD Connection" }
        return composedName
    }

    var composedName: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if !make.isBlank { parts.append(make) }
        if !model.isBlank { parts.append(model) }
        return parts.joined(separator: " ")
    }

    var fullName: String {
        var parts = [composedName]
        if let trim, !trim.isBlank { parts.append(trim) }
        return parts.joined(separator: " • ")
    }

    var subtitle: String {
        var parts: [String] = []
        if let engineDescription, !engineDescription.isBlank { parts.append(engineDescription) }
        if let fuelType, !fuelType.isBlank { parts.append(fuelType) }
        if isDirectConnection { parts.append("Adapter reported") }
        return parts.joined(separator: " • ")
    }

    var hasFaults: Bool { !lastKnownCodes.isEmpty }

    var initials: String {
        let source = isDirectConnection ? "OBD" : composedName
        let words = source.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Validate loosely; real validation happens server-side on decode.
    static func isPlausibleVIN(_ candidate: String) -> Bool {
        let vin = candidate.uppercased().trimmed
        guard vin.count == 17 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        return vin.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
