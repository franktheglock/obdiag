import Foundation
import Observation

/// The app's live vehicle session: connection lifecycle, supported-PID
/// discovery, continuous polling, fault codes, VIN detection and the raw debug
/// log. Views observe this object; the AI tools read from it.
@MainActor
@Observable
final class OBDSession {

    enum Mode: Equatable {
        case none
        case real
        case demo

        var isDemo: Bool { self == .demo }
    }

    enum VINReadStatus: Equatable {
        case idle
        case reading
        case found(String)
        case notAvailable
        case failed(String)

        var message: String? {
            switch self {
            case .idle, .found: return nil
            case .reading: return "Reading VIN from the vehicle…"
            case .notAvailable: return "This vehicle did not report a VIN over OBD."
            case .failed(let detail): return detail
            }
        }
    }

    // MARK: Published state

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var adapterInfo: AdapterInfo?
    private(set) var availableAdapters: [DiscoveredAdapter] = []
    private(set) var mode: Mode = .none

    private(set) var readings: [SensorKind: SensorReading] = [:]
    private(set) var supportedKinds: Set<SensorKind> = []
    private(set) var supportedPIDs: Set<UInt8> = []
    private(set) var history: [SensorKind: [Double]] = [:]

    private(set) var dtcs: [DiagnosticTroubleCode] = []
    private(set) var monitorStatus: MonitorStatus?
    private(set) var isScanningDTCs = false
    private(set) var isClearingDTCs = false
    private(set) var lastDTCScan: Date?

    private(set) var detectedVIN: String?
    private(set) var vinStatus: VINReadStatus = .idle
    private var dismissedVIN: String?

    private(set) var log: [OBDLogEntry] = []
    private(set) var lastError: String?
    private(set) var isPolling = false
    var pollingInterval: TimeInterval = 0.35

    // MARK: Dependencies

    private let settings: AppSettings
    private let garage: GarageStore

    private var connection: OBDConnection?
    private var realConnection: RealOBDConnection?
    private var demoConnection: DemoOBDConnection?
    private var pollTask: Task<Void, Never>?
    private var misses: [SensorKind: Int] = [:]
    private var consecutiveTimeouts = 0
    private var lastBoost: Double?

    init(settings: AppSettings, garage: GarageStore) {
        self.settings = settings
        self.garage = garage
    }

    // MARK: Derived values

    var isConnected: Bool { connectionState.isConnected }

    var isDemo: Bool { mode == .demo }

    var vehicleName: String { garage.selectedVehicle?.displayName ?? "Vehicle" }

    var storedCodes: [DiagnosticTroubleCode] { dtcs.filter { $0.status == .stored } }
    var pendingCodes: [DiagnosticTroubleCode] { dtcs.filter { $0.status == .pending } }
    var permanentCodes: [DiagnosticTroubleCode] { dtcs.filter { $0.status == .permanent } }

    var hasFaults: Bool { !dtcs.isEmpty }

    var worstSeverity: Severity? {
        dtcs.map(\.severity).max()
    }

    var readingList: [SensorReading] {
        readings.values
            .filter { $0.isSupported }
            .sorted { lhs, rhs in
                let lhsIndex = SensorCatalog.pollingOrder.firstIndex(of: lhs.kind) ?? Int.max
                let rhsIndex = SensorCatalog.pollingOrder.firstIndex(of: rhs.kind) ?? Int.max
                return lhsIndex < rhsIndex
            }
    }

    func reading(_ kind: SensorKind) -> SensorReading? { readings[kind] }

    func definition(for kind: SensorKind) -> SensorDefinition { SensorCatalog.definition(for: kind) }

    func health(for kind: SensorKind) -> ReadingHealth {
        guard let reading = readings[kind], reading.isValid else { return .inactive }
        return definition(for: kind).health(for: reading.value)
    }

    func historyValues(_ kind: SensorKind) -> [Double] { history[kind] ?? [] }

    var lastUpdated: Date? {
        readings.values.map(\.timestamp).max()
    }

    // MARK: Adapter scanning

    func startScan() {
        guard let real = ensureRealConnection() else { return }
        lastError = nil
        availableAdapters = []
        real.scan()
        connectionState = .scanning
        appendLog(.info, "Scanning for OBD-II adapters…")
    }

    func stopScan() {
        realConnection?.stopScan()
        if !connectionState.isConnected {
            connectionState = .disconnected
        }
    }

    private func ensureRealConnection() -> RealOBDConnection? {
        if let realConnection { return realConnection }
        guard mode != .demo else { return nil }
        let real = RealOBDConnection()
        real.onAdapters = { [weak self] adapters in
            self?.availableAdapters = adapters
        }
        real.onLog = { [weak self] entry in
            self?.append(entry)
        }
        real.onTransportState = { [weak self] state in
            self?.handleTransportState(state)
        }
        real.onDisconnect = { [weak self] error in
            self?.handleUnexpectedDisconnect(error)
        }
        realConnection = real
        return real
    }

    // MARK: Connecting

    func connect(to adapter: DiscoveredAdapter) async {
        guard let real = ensureRealConnection() else { return }
        connectionState = .connecting(adapter.name)
        lastError = nil
        appendLog(.info, "Connecting to \(adapter.name)…")
        do {
            try await real.connect(to: adapter)
            adapterInfo = real.adapterInfo
            connection = real
            mode = .real
            settings.preferredAdapterID = adapter.id
            connectionState = .connected(adapter.name)
            appendLog(.info, "Connected to \(adapter.name) — \(real.adapterInfo?.protocolName ?? "protocol unknown")")
            Haptics.success()
            garage.noteConnection(vehicleID: garage.selectedVehicleID)
            await startSession()
        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            appendLog(.error, error.localizedDescription)
            Haptics.error()
        }
    }

    func connectDemo() async {
        let demo = DemoOBDConnection()
        demo.onDisconnect = { [weak self] _ in
            self?.handleUnexpectedDisconnect(nil)
        }
        demoConnection = demo
        connectionState = .initializing("Demo Adapter")
        appendLog(.info, "Starting demo session (simulated vehicle)")
        do {
            try await demo.connect()
            connection = demo
            mode = .demo
            adapterInfo = AdapterInfo(
                name: demo.displayName,
                deviceDescription: "Simulated ELM327 v1.5",
                identifier: "DEMO-ELM327",
                version: "ELM327 v1.5",
                protocolName: "ISO 15765-4 (CAN 11/500)",
                protocolNumber: "A6",
                voltage: 14.1
            )
            connectionState = .connected(demo.displayName)
            Haptics.success()
            garage.noteConnection(vehicleID: garage.selectedVehicleID)
            await startSession()
        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        stopPolling()
        connection?.disconnect()
        connection = nil
        realConnection = nil
        demoConnection = nil
        mode = .none
        connectionState = .disconnected
        adapterInfo = nil
        appendLog(.info, "Disconnected")
    }

    private func handleUnexpectedDisconnect(_ error: Error?) {
        stopPolling()
        connection = nil
        mode = .none
        consecutiveTimeouts = 0
        if let error {
            lastError = "Adapter disconnected: \(error.localizedDescription)"
            connectionState = .failed("Adapter disconnected")
            appendLog(.error, lastError ?? "")
        } else {
            connectionState = .disconnected
        }
    }

    private func handleTransportState(_ state: OBDTransportState) {
        switch state {
        case .poweredOff:
            connectionState = .bluetoothUnavailable("Bluetooth is turned off")
        case .unauthorized:
            connectionState = .bluetoothUnavailable("Bluetooth permission denied")
        case .scanning:
            if !connectionState.isConnected { connectionState = .scanning }
        case .ready, .unknown, .connecting, .connected, .disconnected:
            break
        }
    }

    // MARK: Session start

    private func startSession() async {
        await discoverSupportedPIDs()
        await readMonitorStatus()
        await refreshDTCs()
        let vehicle = garage.selectedVehicle
        if vehicle?.vin?.isBlank != false {
            _ = await readVIN()
        }
        startPolling()
    }

    // MARK: PID support discovery

    private func discoverSupportedPIDs() async {
        guard let connection else { return }
        var pids: Set<UInt8> = []
        var base: UInt8 = 0x00
        while base <= 0x40 {
            let command = String(format: "01%02X", base)
            guard let response = try? await connection.query(command, timeout: 2.5) else { break }
            let payload = response.payload(mode: 0x01, pid: base)
            let found = SensorCatalog.supportedPIDs(fromBytes: payload, base: base)
            guard !found.isEmpty else { break }
            pids.formUnion(found)
            base += 0x20
        }

        // Pre-CAN vehicles often do not answer the mask query; probe instead.
        if pids.isEmpty {
            appendLog(.info, "No supported-PID bitmap — probing individual sensors")
            for command in SensorCatalog.commands {
                guard Task.isCancelled == false else { return }
                guard let response = try? await connection.query(String(format: "01%02X", command.pid), timeout: 1.2) else { continue }
                if !response.isNoData, !response.payload(mode: 0x01, pid: command.pid).isEmpty {
                    pids.insert(command.pid)
                }
            }
        }

        supportedPIDs = pids
        supportedKinds = Set(SensorCatalog.commands.filter { pids.contains($0.pid) }.map(\.kind))
        if pids.contains(0x0B), pids.contains(0x33) {
            supportedKinds.insert(.boostPressure)
        }
        appendLog(.info, "Supported sensors: \(supportedKinds.count)")
    }

    // MARK: Polling suspension

    private var pollingSuspendDepth = 0
    private var wasPollingBeforeSuspend = false

    /// Suspends the live-data poll so a control operation (code read/clear, VIN)
    /// has the adapter to itself. Nestable, so `clearDTCs` can call
    /// `refreshDTCs` without restarting polling mid-sequence. Polling is only
    /// restarted if it was running when the first suspension happened — during
    /// session startup it has not begun yet.
    private func suspendPolling() {
        pollingSuspendDepth += 1
        if pollingSuspendDepth == 1 {
            wasPollingBeforeSuspend = isPolling
            if isPolling { stopPolling() }
        }
    }

    private func resumePollingIfSuspended() {
        guard pollingSuspendDepth > 0 else { return }
        pollingSuspendDepth -= 1
        if pollingSuspendDepth == 0, wasPollingBeforeSuspend, connection != nil {
            wasPollingBeforeSuspend = false
            startPolling()
        }
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil, connection != nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        if pollingSuspendDepth == 0 { wasPollingBeforeSuspend = false }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let connection else { break }
            let kinds = SensorCatalog.pollingOrder.filter { supportedKinds.contains($0) }
            for kind in kinds {
                guard !Task.isCancelled else { break }
                await poll(kind: kind, connection: connection)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
        }
        isPolling = false
    }

    private func poll(kind: SensorKind, connection: OBDConnection) async {
        guard let command = SensorCatalog.command(for: kind) else { return }
        let commandString = String(format: "01%02X", command.pid)

        let response: OBDResponse
        do {
            response = try await connection.query(commandString, timeout: 1.0)
            consecutiveTimeouts = 0
        } catch {
            // A missing prompt usually means a slow or unsupported PID, or the
            // adapter went away. Count it as a miss (three strikes removes the
            // sensor) and resync so a late reply cannot be read as the answer
            // to the next command.
            consecutiveTimeouts += 1
            registerMiss(kind)
            connection.resync()
            if consecutiveTimeouts >= 3 {
                consecutiveTimeouts = 0
                await recoverBus(on: connection)
            }
            return
        }

        let payload = response.payload(mode: 0x01, pid: command.pid)
        guard !response.isNoData, let value = command.decode(payload) else {
            registerMiss(kind)
            return
        }
        misses[kind] = 0
        store(value: value, for: kind, raw: payload.map { String(format: "%02X", $0) }.joined(separator: " "))
        if kind == .manifoldAbsolutePressure || kind == .barometricPressure {
            updateBoost()
        }
    }

    /// The adapter stopped answering entirely. Close the protocol, re-select
    /// auto and prod the bus so the next poll starts from a known state.
    private func recoverBus(on connection: OBDConnection) async {
        appendLog(.info, "Adapter stopped answering — recovering the bus…")
        _ = try? await connection.query("ATPC", timeout: 2)
        _ = try? await connection.query("ATSP0", timeout: 3)
        _ = try? await connection.query("AT", timeout: 2)
        await discoverSupportedPIDs()
    }

    private func registerMiss(_ kind: SensorKind) {
        let count = (misses[kind] ?? 0) + 1
        misses[kind] = count
        if count >= 3 {
            supportedKinds.remove(kind)
            readings.removeValue(forKey: kind)
            appendLog(.info, "Sensor \(definition(for: kind).shortName) stopped responding — removed from polling")
        }
    }

    private func store(value: Double, for kind: SensorKind, raw: String?) {
        let reading = SensorReading(kind: kind, value: value, rawValue: raw, timestamp: Date(), isSupported: true)
        readings[kind] = reading

        var values = history[kind] ?? []
        values.append(value)
        if values.count > 90 { values.removeFirst(values.count - 90) }
        history[kind] = values
    }

    private func updateBoost() {
        guard let map = readings[.manifoldAbsolutePressure]?.value,
              let baro = readings[.barometricPressure]?.value else { return }
        let boost = map - baro
        store(value: boost, for: .boostPressure, raw: nil)
    }

    // MARK: Fault codes

    func refreshDTCs() async {
        guard let connection else { return }
        suspendPolling()
        defer { resumePollingIfSuspended() }
        isScanningDTCs = true
        defer { isScanningDTCs = false }

        var found: [DiagnosticTroubleCode] = []
        var stored: [String] = []

        for (command, status, header) in [("03", DTCStatus.stored, UInt8(0x43)), ("07", .pending, UInt8(0x47)), ("0A", .permanent, UInt8(0x4A))] {
            guard let response = try? await connection.query(command, timeout: 4) else { continue }
            guard !response.isNoData else { continue }
            let codes = DTCKnowledge.codes(fromPayload: response.payload(header: [header]))
            for code in codes {
                found.append(DTCKnowledge.makeCode(code, status: status))
            }
            if status == .stored { stored = codes }
        }

        // Deduplicate identical code+status pairs.
        var seen: Set<String> = []
        dtcs = found
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.code < rhs.code
            }
        lastDTCScan = Date()
        garage.recordScan(vehicleID: garage.selectedVehicleID, codes: stored)
        appendLog(.info, "Fault scan: \(stored.count) stored, \(dtcs.count - stored.count) pending/permanent")
    }

    func clearDTCs() async -> Bool {
        guard let connection else { return false }
        suspendPolling()
        defer { resumePollingIfSuspended() }
        isClearingDTCs = true
        defer { isClearingDTCs = false }
        appendLog(.info, "Clearing fault codes…")

        var lastAnswer = ""
        for attempt in 1...2 {
            do {
                // Clearing can take a while on some ECUs.
                let response = try await connection.query("04", timeout: 15)
                lastAnswer = response.rawText.trimmed
                if response.allHexBytes.contains(0x44) {
                    garage.recordCodesCleared(vehicleID: garage.selectedVehicleID)
                    // The ECU is busy re-initialising monitors for a moment.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await refreshDTCs()
                    appendLog(.info, "Clear acknowledged; \(storedCodes.count) stored code(s) remain")
                    Haptics.success()
                    return true
                }
                appendLog(.info, "Clear attempt \(attempt) answered: \(lastAnswer.truncated(to: 80))")
            } catch {
                lastAnswer = error.localizedDescription
                appendLog(.error, "Clear attempt \(attempt) failed: \(error.localizedDescription)")
            }

            if attempt == 1 {
                // Adapters sometimes lose bus state after a long polling
                // session; re-select the protocol and try once more.
                _ = try? await connection.query("ATSP0", timeout: 3)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        lastError = "The vehicle did not acknowledge the clear request. Turn the ignition to ON (engine off) and try again."
            + (lastAnswer.isEmpty ? "" : " Adapter said: \(lastAnswer.truncated(to: 80))")
        return false
    }

    // MARK: Monitor status

    func readMonitorStatus() async {
        guard let connection else { return }
        guard let response = try? await connection.query("0101", timeout: 3) else { return }
        let payload = response.payload(mode: 0x01, pid: 0x01)
        monitorStatus = MonitorStatus.decode(payload)
    }

    // MARK: VIN

    @discardableResult
    func readVIN(force: Bool = false) async -> String? {
        if !force, let detectedVIN, !detectedVIN.isBlank { return detectedVIN }
        guard let connection else { return nil }
        suspendPolling()
        defer { resumePollingIfSuspended() }
        vinStatus = .reading
        appendLog(.info, "Requesting VIN (mode 09 PID 02)…")

        for attempt in 1...2 {
            // Wake the bus first: some ECUs ignore 09 02 on a sleeping network.
            _ = try? await connection.query("0100", timeout: 3)
            do {
                let response = try await connection.query("0902", timeout: 12)
                if let vin = VINParser.extract(from: response) {
                    detectedVIN = vin
                    vinStatus = .found(vin)
                    appendLog(.info, "VIN reported: \(vin)")
                    return vin
                }
                appendLog(.info, "VIN attempt \(attempt) returned: \(response.rawText.replacingOccurrences(of: "\n", with: " ").truncated(to: 100))")
            } catch {
                appendLog(.error, "VIN attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }

        vinStatus = .notAvailable
        return nil
    }

    static func parseVIN(_ response: OBDResponse) -> String? {
        VINParser.extract(from: response)
    }

    var vinMismatchMessage: String? {
        guard let detectedVIN, dismissedVIN != detectedVIN else { return nil }
        let current = garage.selectedVehicle
        if current?.vin == detectedVIN { return nil }
        if let current, !current.isDirectConnection {
            return "The connected vehicle reports VIN \(detectedVIN), which doesn't match \(current.displayName)."
        }
        return "The connected vehicle reports VIN \(detectedVIN). Decode it to create this vehicle?"
    }

    func dismissVINPrompt() {
        dismissedVIN = detectedVIN
    }

    // MARK: Demo controls

    var demoScenario: DemoOBDConnection.Scenario {
        get { demoConnection?.scenario ?? .parked }
        set {
            demoConnection?.setScenario(newValue)
            Task { await refreshDTCs() }
        }
    }

    // MARK: Debug log

    func appendLog(_ direction: OBDLogEntry.Direction, _ text: String) {
        append(OBDLogEntry(direction: direction, text: text))
    }

    private func append(_ entry: OBDLogEntry) {
        log.append(entry)
        if log.count > 1_000 { log.removeFirst(log.count - 1_000) }
    }

    func clearLog() { log.removeAll() }

    var logText: String {
        log.map { "[\(Format.timestamp($0.timestamp))] \($0.direction.symbol) \($0.text)" }
            .joined(separator: "\n")
    }
}
