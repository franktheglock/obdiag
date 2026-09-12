import Foundation
import CoreBluetooth
import Observation

/// CoreBluetooth transport for BLE OBD-II adapters (Vgate iCar Pro, Veepeak,
/// OBDLink MX+, Kiwi 3 and the many ELM327 BLE clones).
///
/// Most adapters expose one of a handful of service/characteristic pairs, so
/// discovery tries known UUIDs first and falls back to "any notify + any write"
/// characteristic on the device.
@MainActor
final class BLEOBDTransport: NSObject, OBDTransport {

    // MARK: Protocol callbacks
    var onLine: ((String) -> Void)?
    var onStateChange: ((OBDTransportState) -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onDiscovered: (([DiscoveredAdapter]) -> Void)?

    // MARK: Known adapter signatures
    static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFE5"),
        CBUUID(string: "FF00"),
        CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    ]

    static let preferredNotifyUUIDs: [CBUUID] = [
        CBUUID(string: "FFF1"), CBUUID(string: "FFE1"), CBUUID(string: "FFF2"),
        CBUUID(string: "FFE2"), CBUUID(string: "FFF4")
    ]

    static let preferredWriteUUIDs: [CBUUID] = [
        CBUUID(string: "FFF2"), CBUUID(string: "FFE1"), CBUUID(string: "FFF1"),
        CBUUID(string: "FFE2"), CBUUID(string: "FFF4")
    ]

    static let nameFragments = [
        "obd", "elm", "vgate", "veepeak", "konnwei", "icar", "obdlink", "mx+",
        "kiwi", "vlink", "v-link", "obdii", "obd2", "scan", "autophix", "topdon"
    ]

    // MARK: State
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var discovered: [String: DiscoveredAdapter] = [:]
    private var peripheralsByID: [String: CBPeripheral] = [:]

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoveryContinuation: CheckedContinuation<Void, Error>?
    private var pendingServiceDiscoveries = 0
    private var isScanning = false
    private var wantsScan = false
    private var wantsConnection: DiscoveredAdapter?
    private var writeQueue: [Data] = []

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    var isBluetoothReady: Bool { central.state == .poweredOn }

    // MARK: Scanning

    func startScan() {
        guard central.state == .poweredOn else {
            wantsScan = true
            reportState()
            return
        }
        guard !isScanning else { return }
        discovered.removeAll()
        peripheralsByID.removeAll()
        onDiscovered?([])
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        onStateChange?(.scanning)
    }

    func stopScan() {
        wantsScan = false
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        if peripheral == nil { onStateChange?(.ready) }
    }

    // MARK: Connecting

    func connect(to adapter: DiscoveredAdapter) async throws {
        if !isBluetoothReady { wantsConnection = adapter }
        guard let target = peripheralsByID[adapter.id] ?? nil else {
            throw BLEError.notFound
        }
        stopScan()
        wantsConnection = nil
        peripheral = target
        target.delegate = self
        onStateChange?(.connecting)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            central.connect(target, options: nil)
        }

        do {
            try await discoverServices(on: target)
        } catch {
            central.cancelPeripheralConnection(target)
            throw error
        }
        onStateChange?(.connected)
    }

    private func discoverServices(on peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            discoveryContinuation = continuation
            pendingServiceDiscoveries = 0
            writeCharacteristic = nil
            notifyCharacteristic = nil
            peripheral.discoverServices(Self.knownServiceUUIDs)
        }
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        resetConnection()
        onStateChange?(.disconnected)
    }

    private func resetConnection() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeQueue.removeAll()
    }

    // MARK: Sending

    func send(_ text: String) {
        guard let peripheral, let characteristic = writeCharacteristic,
              let data = text.data(using: .ascii) else { return }

        let maxLength = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse

        var offset = 0
        while offset < data.count {
            let end = min(offset + maxLength, data.count)
            let chunk = data.subdata(in: offset..<end)
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                writeQueue.append(chunk)
            } else {
                peripheral.writeValue(chunk, for: characteristic, type: type)
            }
            offset = end
        }
    }

    // MARK: State reporting

    private func reportState() {
        switch central.state {
        case .poweredOn: onStateChange?(.ready)
        case .poweredOff: onStateChange?(.poweredOff)
        case .unauthorized: onStateChange?(.unauthorized)
        case .unsupported: onStateChange?(.poweredOff)
        case .resetting, .unknown: onStateChange?(.unknown)
        @unknown default: onStateChange?(.unknown)
        }
    }

    private func makeAdapter(from peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) -> DiscoveredAdapter {
        let advertisedName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "Unknown device"
        let serviceUUIDs = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let lowercaseName = name.lowercased()
        let nameMatch = Self.nameFragments.contains { lowercaseName.contains($0) }
        let serviceMatch = serviceUUIDs.contains { uuid in
            Self.knownServiceUUIDs.contains { $0.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }
        }
        return DiscoveredAdapter(
            id: peripheral.identifier.uuidString,
            name: name,
            rssi: rssi.intValue,
            advertisedServices: serviceUUIDs,
            isLikelyOBD: nameMatch || serviceMatch
        )
    }

    private func publishDiscovered() {
        let sorted = discovered.values.sorted { lhs, rhs in
            if lhs.isLikelyOBD != rhs.isLikelyOBD { return lhs.isLikelyOBD }
            return lhs.rssi > rhs.rssi
        }
        onDiscovered?(sorted)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEOBDTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            reportState()
            if central.state == .poweredOn {
                if wantsScan { startScan() }
                if let adapter = wantsConnection, connectContinuation == nil, peripheral == nil {
                    wantsConnection = nil
                    Task { try? await self.connect(to: adapter) }
                }
            } else {
                failConnect(with: BLEError.bluetoothUnavailable)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let adapter = makeAdapter(from: peripheral, advertisement: advertisementData, rssi: RSSI)
            peripheralsByID[adapter.id] = peripheral
            discovered[adapter.id] = adapter
            publishDiscovered()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectContinuation?.resume()
            connectContinuation = nil
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            failConnect(with: BLEError.connectionFailed(error?.localizedDescription ?? "unknown error"))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            resetConnection()
            onStateChange?(.disconnected)
            onDisconnected?(error)
        }
    }

    private func failConnect(with error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        discoveryContinuation?.resume(throwing: error)
        discoveryContinuation = nil
        resetConnection()
        onStateChange?(.disconnected)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEOBDTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                discoveryContinuation?.resume(throwing: BLEError.connectionFailed(error.localizedDescription))
                discoveryContinuation = nil
                return
            }
            let services = peripheral.services ?? []
            if services.isEmpty {
                // Fall back to discovering everything the device offers.
                peripheral.discoverServices(nil)
                return
            }
            pendingServiceDiscoveries = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            pendingServiceDiscoveries -= 1
            for characteristic in service.characteristics ?? [] {
                let notify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
                let write = characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)

                if notify, shouldPrefer(characteristic, over: notifyCharacteristic, preferred: Self.preferredNotifyUUIDs) {
                    notifyCharacteristic = characteristic
                }
                if write, shouldPrefer(characteristic, over: writeCharacteristic, preferred: Self.preferredWriteUUIDs) {
                    writeCharacteristic = characteristic
                }
            }

            if let notifyCharacteristic, notifyCharacteristic.isNotifying == false {
                peripheral.setNotifyValue(true, for: notifyCharacteristic)
            }

            if pendingServiceDiscoveries <= 0 {
                if writeCharacteristic != nil {
                    discoveryContinuation?.resume()
                } else {
                    discoveryContinuation?.resume(throwing: BLEError.noWritableCharacteristic)
                }
                discoveryContinuation = nil
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value else { return }
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                onLine?(text)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let characteristic = writeCharacteristic else { return }
            while peripheral.canSendWriteWithoutResponse, !writeQueue.isEmpty {
                let chunk = writeQueue.removeFirst()
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            }
        }
    }

    private func shouldPrefer(
        _ candidate: CBCharacteristic,
        over existing: CBCharacteristic?,
        preferred: [CBUUID]
    ) -> Bool {
        guard let existing else { return true }
        let candidateRank = preferred.firstIndex(of: candidate.uuid) ?? preferred.count
        let existingRank = preferred.firstIndex(of: existing.uuid) ?? preferred.count
        return candidateRank < existingRank
    }
}

// MARK: - Errors

enum BLEError: LocalizedError {
    case bluetoothUnavailable
    case notFound
    case connectionFailed(String)
    case noWritableCharacteristic

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is not available. Turn it on in Settings."
        case .notFound:
            return "That adapter is no longer nearby. Scan again."
        case .connectionFailed(let detail):
            return "Could not connect: \(detail)"
        case .noWritableCharacteristic:
            return "Connected, but this device doesn't expose the expected OBD characteristics."
        }
    }
}
