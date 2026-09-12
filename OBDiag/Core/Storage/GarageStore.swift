import Foundation
import Observation

/// The user's garage. Selecting a vehicle scopes the dashboard and chat.
@MainActor
@Observable
final class GarageStore {
    private(set) var vehicles: [Vehicle] = []
    var selectedVehicleID: UUID? {
        didSet { UserDefaults.standard.set(selectedVehicleID?.uuidString, forKey: Self.selectionKey) }
    }

    private static let fileName = "garage.json"
    private static let selectionKey = "obdiag.selectedVehicleID"

    init() {
        if let stored = FileStore.load([Vehicle].self, from: Self.fileName) {
            vehicles = stored
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey), let id = UUID(uuidString: raw) {
            selectedVehicleID = vehicles.contains(where: { $0.id == id }) ? id : vehicles.first?.id
        } else {
            selectedVehicleID = vehicles.first?.id
        }
    }

    var selectedVehicle: Vehicle? {
        guard let selectedVehicleID else { return nil }
        return vehicles.first { $0.id == selectedVehicleID }
    }

    var hasVehicles: Bool { !vehicles.isEmpty }

    var totalFaultCount: Int {
        vehicles.reduce(0) { $0 + $1.lastKnownCodes.count }
    }

    func vehicle(withID id: UUID?) -> Vehicle? {
        guard let id else { return nil }
        return vehicles.first { $0.id == id }
    }

    @discardableResult
    func add(_ vehicle: Vehicle, select: Bool = true) -> Vehicle {
        var copy = vehicle
        if copy.nickname.isBlank && copy.isDirectConnection { copy.nickname = "" }
        vehicles.append(copy)
        if select { selectedVehicleID = copy.id }
        persist()
        return copy
    }

    func update(_ vehicle: Vehicle) {
        guard let index = vehicles.firstIndex(where: { $0.id == vehicle.id }) else { return }
        vehicles[index] = vehicle
        persist()
    }

    func remove(_ id: UUID) {
        vehicles.removeAll { $0.id == id }
        if selectedVehicleID == id {
            selectedVehicleID = vehicles.first?.id
        }
        persist()
    }

    func select(_ id: UUID?) {
        selectedVehicleID = id
    }

    /// Called after every scan so the garage reflects the latest fault state.
    func recordScan(vehicleID: UUID?, codes: [String], at date: Date = Date()) {
        guard let vehicleID, let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        vehicles[index].lastKnownCodes = codes
        vehicles[index].lastScanAt = date
        vehicles[index].lastConnectedAt = date
        persist()
    }

    func recordCodesCleared(vehicleID: UUID?) {
        guard let vehicleID, let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        vehicles[index].lastKnownCodes = []
        vehicles[index].lastScanAt = Date()
        persist()
    }

    func noteConnection(vehicleID: UUID?, at date: Date = Date()) {
        guard let vehicleID, let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        vehicles[index].lastConnectedAt = date
        persist()
    }

    /// Applies decoded VIN data to an existing vehicle.
    func applyDecodedVIN(_ decoded: DecodedVehicle, to vehicleID: UUID) {
        guard let index = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        vehicles[index].vin = decoded.vin
        if let year = decoded.year { vehicles[index].year = year }
        if let make = decoded.make, !make.isBlank { vehicles[index].make = make }
        if let model = decoded.model, !model.isBlank { vehicles[index].model = model }
        if let trim = decoded.trimName, !trim.isBlank { vehicles[index].trim = trim }
        if let engine = decoded.engineDescription, !engine.isBlank { vehicles[index].engineDescription = engine }
        if let fuel = decoded.fuelType, !fuel.isBlank { vehicles[index].fuelType = fuel }
        persist()
    }

    func replaceAll(with vehicles: [Vehicle]) {
        self.vehicles = vehicles
        selectedVehicleID = vehicles.first?.id
        persist()
    }

    func persist() {
        FileStore.save(vehicles, to: Self.fileName)
    }
}
