import Foundation

struct VehicleMake: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
}

/// Decoded VIN information, normalized from the NHTSA vPIC response.
struct DecodedVehicle: Codable, Hashable, Sendable {
    var vin: String
    var year: Int?
    var make: String?
    var model: String?
    var series: String?
    var trimName: String?
    var engineDescription: String?
    var displacementLiters: Double?
    var cylinders: Int?
    var fuelType: String?
    var bodyClass: String?
    var driveType: String?
    var vehicleType: String?
    var plantCountry: String?
    var errors: [String] = []

    var isValid: Bool { (make?.isBlank == false) || (model?.isBlank == false) }

    var summary: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let make, !make.isBlank { parts.append(make) }
        if let model, !model.isBlank { parts.append(model) }
        return parts.joined(separator: " ")
    }
}

/// Looks up vehicles through the free NHTSA vPIC API, with a bundled offline
/// fallback so the flow still works without a connection.
actor VehicleCatalogClient {
    private var cachedMakes: [VehicleMake]?
    private var modelCache: [String: [String]] = [:]

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Makes

    func makes() async -> [VehicleMake] {
        if let cachedMakes { return cachedMakes }
        if let remote = try? await fetchMakes(), !remote.isEmpty {
            cachedMakes = remote
            return remote
        }
        let fallback = Self.offlineMakes
        cachedMakes = fallback
        return fallback
    }

    private func fetchMakes() async throws -> [VehicleMake] {
        let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/GetMakesForVehicleType/car?format=json")!
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["Results"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        var seen: Set<String> = []
        var makes: [VehicleMake] = []
        for item in results {
            guard let name = (item["MakeName"] as? String)?.trimmed, !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let id = (item["MakeId"] as? Int) ?? Int((item["MakeId"] as? String) ?? "0") ?? 0
            makes.append(VehicleMake(id: id, name: name))
        }
        return makes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Models

    func models(make: String, year: Int?) async -> [String] {
        let key = "\(make.lowercased())|\(year.map(String.init) ?? "any")"
        if let cached = modelCache[key] { return cached }

        if let remote = try? await fetchModels(make: make, year: year), !remote.isEmpty {
            modelCache[key] = remote
            return remote
        }
        let fallback = Self.offlineModels[make.lowercased()] ?? []
        modelCache[key] = fallback
        return fallback
    }

    private func fetchModels(make: String, year: Int?) async throws -> [String] {
        let encodedMake = make.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? make
        let path: String
        if let year {
            path = "https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/\(encodedMake)/modelyear/\(year)?format=json"
        } else {
            path = "https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMake/\(encodedMake)?format=json"
        }
        guard let url = URL(string: path) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["Results"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let names = results.compactMap { ($0["Model_Name"] as? String)?.trimmed }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: VIN decode

    func decode(vin: String) async throws -> DecodedVehicle {
        let cleaned = vin.uppercased().trimmed
        guard cleaned.count == 17 else { throw VehicleCatalogError.invalidVIN }
        let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/\(cleaned)?format=json")!
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (root["Results"] as? [[String: Any]])?.first else {
            throw VehicleCatalogError.decodeFailed("Unexpected response")
        }

        func string(_ key: String) -> String? {
            guard let value = result[key] as? String else { return nil }
            let cleaned = value.trimmed
            return cleaned.isEmpty || cleaned == "0" ? nil : cleaned
        }

        var decoded = DecodedVehicle(
            vin: cleaned,
            year: Int(string("ModelYear") ?? ""),
            make: string("Make"),
            model: string("Model"),
            series: string("Series"),
            trimName: string("Trim"),
            engineDescription: Self.engineDescription(from: result),
            displacementLiters: Double(string("DisplacementL") ?? ""),
            cylinders: Int(string("EngineCylinders") ?? ""),
            fuelType: string("FuelTypePrimary"),
            bodyClass: string("BodyClass"),
            driveType: string("DriveType"),
            vehicleType: string("VehicleType"),
            plantCountry: string("PlantCountry")
        )

        if let errorText = string("ErrorText") {
            decoded.errors = errorText
                .split(separator: ",")
                .map { $0.trimmed }
                .filter { !$0.isEmpty && !$0.lowercased().contains("0 - vpic") }
        }
        return decoded
    }

    private static func engineDescription(from result: [String: Any]) -> String? {
        var parts: [String] = []
        if let model = (result["EngineModel"] as? String)?.trimmed, !model.isEmpty {
            parts.append(model)
        }
        if let displacement = (result["DisplacementL"] as? String)?.trimmed,
           let liters = Double(displacement), liters > 0 {
            parts.append(String(format: "%.1fL", liters))
        }
        if let cylinders = (result["EngineCylinders"] as? String)?.trimmed, !cylinders.isEmpty, cylinders != "0" {
            parts.append("\(cylinders)-cyl")
        }
        if let fuel = (result["FuelTypePrimary"] as? String)?.trimmed, !fuel.isEmpty, fuel != "0" {
            parts.append(fuel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Offline fallback data

    static let offlineMakes: [VehicleMake] = [
        "Acura", "Audi", "BMW", "Buick", "Cadillac", "Chevrolet", "Chrysler", "Dodge",
        "Ford", "Genesis", "GMC", "Honda", "Hyundai", "Infiniti", "Jeep", "Kia",
        "Land Rover", "Lexus", "Lincoln", "Mazda", "Mercedes-Benz", "Mini", "Mitsubishi",
        "Nissan", "Porsche", "Ram", "Subaru", "Tesla", "Toyota", "Volkswagen", "Volvo"
    ].enumerated().map { VehicleMake(id: $0.offset, name: $0.element) }

    static let offlineModels: [String: [String]] = [
        "toyota": ["Camry", "Corolla", "RAV4", "Tacoma", "Tundra", "Highlander", "4Runner", "Prius", "Sienna", "Sequoia", "Land Cruiser"],
        "honda": ["Civic", "Accord", "CR-V", "Pilot", "Odyssey", "HR-V", "Ridgeline", "Passport", "Fit"],
        "ford": ["F-150", "Escape", "Explorer", "Mustang", "Edge", "Ranger", "Bronco", "Expedition", "Fusion", "Focus"],
        "chevrolet": ["Silverado 1500", "Equinox", "Malibu", "Traverse", "Tahoe", "Suburban", "Colorado", "Camaro", "Blazer", "Impala"],
        "nissan": ["Altima", "Rogue", "Sentra", "Pathfinder", "Frontier", "Murano", "Titan", "Versa", "370Z"],
        "jeep": ["Wrangler", "Grand Cherokee", "Cherokee", "Compass", "Renegade", "Gladiator", "Wagoneer"],
        "hyundai": ["Elantra", "Sonata", "Tucson", "Santa Fe", "Kona", "Palisade", "Accent", "Ioniq"],
        "kia": ["Soul", "Sorento", "Sportage", "Forte", "Telluride", "Optima", "Seltos", "Carnival"],
        "subaru": ["Outback", "Forester", "Crosstrek", "Impreza", "Ascent", "Legacy", "WRX", "BRZ"],
        "bmw": ["3 Series", "5 Series", "X3", "X5", "X1", "7 Series", "M3", "M5", "X7"],
        "mercedes-benz": ["C-Class", "E-Class", "GLC", "GLE", "S-Class", "GLA", "GLB", "Sprinter"],
        "volkswagen": ["Jetta", "Golf", "Tiguan", "Passat", "Atlas", "GTI", "ID.4", "Taos"],
        "audi": ["A4", "Q5", "A6", "Q7", "A3", "Q3", "e-tron", "SQ5"],
        "mazda": ["Mazda3", "CX-5", "Mazda6", "CX-9", "MX-5 Miata", "CX-30", "CX-50"],
        "dodge": ["Charger", "Challenger", "Durango", "Journey", "Grand Caravan", "Hornet"],
        "ram": ["1500", "2500", "3500", "ProMaster", "ProMaster City"],
        "gmc": ["Sierra 1500", "Terrain", "Acadia", "Yukon", "Canyon", "Yukon XL"],
        "tesla": ["Model 3", "Model Y", "Model S", "Model X", "Cybertruck"],
        "lexus": ["RX 350", "ES 350", "NX 300", "GX 460", "IS 300", "LX 570", "UX 250h"],
        "chrysler": ["300", "Pacifica", "Voyager"],
        "buick": ["Encore", "Enclave", "Envision"],
        "cadillac": ["Escalade", "XT5", "CT5", "XT4", "CT4"],
        "acura": ["MDX", "RDX", "TLX", "Integra", "ILX"],
        "infiniti": ["Q50", "QX60", "QX80", "Q60", "QX50"],
        "lincoln": ["Navigator", "Aviator", "Nautilus", "Corsair"],
        "porsche": ["911", "Cayenne", "Macan", "Panamera", "Taycan", "718 Cayman"],
        "land rover": ["Range Rover", "Discovery", "Defender", "Range Rover Sport", "Evoque"],
        "mini": ["Cooper", "Countryman", "Clubman", "Convertible"],
        "mitsubishi": ["Outlander", "Eclipse Cross", "Mirage", "Outlander Sport"],
        "volvo": ["XC90", "XC60", "XC40", "S60", "V60"],
        "genesis": ["G70", "G80", "GV70", "GV80"]
    ]
}

enum VehicleCatalogError: LocalizedError {
    case invalidVIN
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVIN: return "A VIN must be exactly 17 characters (no I, O or Q)."
        case .decodeFailed(let detail): return "Could not decode that VIN: \(detail)"
        }
    }
}
