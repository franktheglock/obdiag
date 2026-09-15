import Foundation

/// A full vehicle simulation that speaks the same ELM327 text protocol as real
/// hardware. Every parsing and polling code path in the app is exercised by
/// demo mode — nothing is faked at a higher level.
@MainActor
final class DemoOBDConnection: OBDConnection {
    enum Scenario: String, CaseIterable, Identifiable {
        case parked
        case cityDrive
        case highway
        case misfire

        var id: String { rawValue }

        var title: String {
            switch self {
            case .parked: return "Parked idle"
            case .cityDrive: return "City drive"
            case .highway: return "Highway cruise"
            case .misfire: return "Misfire (faulty)"
            }
        }

        var shortTitle: String {
            switch self {
            case .parked: return "Parked"
            case .cityDrive: return "City"
            case .highway: return "Highway"
            case .misfire: return "Faulty"
            }
        }

        var icon: String {
            switch self {
            case .parked: return "parkingsign.circle"
            case .cityDrive: return "building.2"
            case .highway: return "road.lanes"
            case .misfire: return "exclamationmark.engine"
            }
        }
    }

    let displayName = "Demo Adapter (simulated)"
    var onDisconnect: ((Error?) -> Void)?

    private(set) var scenario: Scenario = .parked
    private var simulator = DemoVehicleSimulator()
    private var startedAt = Date()

    // MARK: OBDConnection

    func connect() async throws {
        startedAt = Date()
        simulator = DemoVehicleSimulator()
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func disconnect() {
        onDisconnect?(nil)
    }

    func query(_ command: String, timeout: TimeInterval) async throws -> OBDResponse {
        let start = Date()
        // Simulate adapter latency so streaming UI states are exercised.
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.02...0.06) * 1_000_000_000))
        simulator.advance()
        let lines = respond(to: command.uppercased(), since: start)
        return OBDResponse(command: command, lines: lines, duration: Date().timeIntervalSince(start))
    }

    func setScenario(_ scenario: Scenario) {
        self.scenario = scenario
        simulator.setScenario(scenario)
    }

    // MARK: Simulation

    private func respond(to command: String, since start: Date) -> [String] {
        let clean = command.replacingOccurrences(of: " ", with: "")

        // AT commands
        if clean.hasPrefix("AT") {
            switch clean {
            case "ATZ", "ATI": return ["ELM327 v1.5"]
            case "AT@1": return ["OBDII to RS232 Interpreter"]
            case "ATDP": return ["ISO 15765-4 (CAN 11/500)"]
            case "ATDPN": return ["A6"]
            case "ATRV": return [String(format: "%.1fV", simulator.batteryVoltage)]
            default: return ["OK"]
            }
        }

        // Mode 01
        if clean.hasPrefix("01") {
            let pidString = String(clean.dropFirst(2).prefix(2))
            guard let pid = UInt8(pidString, radix: 16) else { return ["NO DATA"] }
            if let bytes = simulator.bytes(for: pid) {
                return ["41" + pidString + bytes.map { String(format: "%02X", $0) }.joined()]
            }
            return ["NO DATA"]
        }

        // Stored / pending / permanent DTCs
        if clean.hasPrefix("03") {
            let payload = simulator.dtcBytes(for: .stored)
            return ["43" + payload.map { String(format: "%02X", $0) }.joined()]
        }
        if clean.hasPrefix("07") {
            let payload = simulator.dtcBytes(for: .pending)
            return ["47" + payload.map { String(format: "%02X", $0) }.joined()]
        }
        if clean.hasPrefix("0A") {
            let payload = simulator.dtcBytes(for: .permanent)
            return ["4A" + payload.map { String(format: "%02X", $0) }.joined()]
        }
        if clean.hasPrefix("04") {
            simulator.clearCodes()
            return ["44"]
        }

        // VIN and calibration
        if clean.hasPrefix("0902") {
            let bytes = Array(simulator.vin.utf8)
            var lines: [String] = []
            var index = 0
            var frame = 1
            while index < bytes.count {
                let end = min(index + 7, bytes.count)
                let chunk = bytes[index..<end]
                lines.append("49 02 \(String(format: "%02X", frame)) " + chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
                index = end
                frame += 1
            }
            return lines
        }
        if clean.hasPrefix("0904") {
            return ["49 04 01 44 45 4D 4F 2D 43 41 4C"]
        }
        if clean.hasPrefix("090A") {
            return ["49 0A 01 44 45 4D 4F 2D 45 43 4D"]
        }

        return ["NO DATA"]
    }
}

/// Physical-ish model of a vehicle used by demo mode.
struct DemoVehicleSimulator {
    var scenario: DemoOBDConnection.Scenario = .parked
    private var engineOn = true
    private var startDate = Date()
    private var lastTick = Date()
    private var warmup = 0.0
    private var phase = 0.0
    private var shiftPhase = 0.0

    // Live values
    private(set) var rpm = 820.0
    private(set) var speed = 0.0
    private(set) var coolant = 18.0
    private(set) var intakeAir = 22.0
    private(set) var throttle = 13.0
    private(set) var engineLoad = 19.0
    private(set) var maf = 3.6
    private(set) var map = 34.0
    private(set) var baro = 99.0
    private(set) var stft = 2.0
    private(set) var ltft = 3.0
    private(set) var o2Upstream = 0.45
    private(set) var o2Downstream = 0.62
    private(set) var batteryVoltage = 14.12
    private(set) var fuelLevel = 63.0
    private(set) var fuelRail = 4200.0
    private(set) var timing = 12.0
    private(set) var ethanol = 10.0

    var vin: String { "1HGCM82633A004352" }

    private(set) var storedCodes: [String] = ["P0420", "P0171"]
    private(set) var pendingCodes: [String] = ["P0171"]
    private(set) var permanentCodes: [String] = []

    mutating func advance() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 2)
        lastTick = now
        phase += dt
        shiftPhase += dt
        warmup = min(1, warmup + dt / 90)

        switch scenario {
        case .parked:
            rpm += ((780 + sin(phase * 1.7) * 18 + Double.random(in: -12...12)) - rpm) * 0.3
            speed = max(0, speed - dt * 6)
            throttle = 13 + sin(phase * 0.8) * 0.8
            engineLoad = 18 + sin(phase * 0.6) * 2
        case .cityDrive:
            let cycle = (sin(shiftPhase * 0.09) + 1) / 2
            speed = max(0, min(52, cycle * 55 + Double.random(in: -1.5...1.5)))
            let targetRPM = 900 + speed * 24 + sin(phase * 2) * 60
            rpm += (targetRPM - rpm) * 0.18
            throttle = 12 + cycle * 26 + Double.random(in: -2...2)
            engineLoad = 22 + cycle * 38
        case .highway:
            speed += ((112 + sin(phase * 0.05) * 4) - speed) * 0.06
            rpm += ((2350 + sin(phase * 0.4) * 90) - rpm) * 0.1
            throttle = 24 + sin(phase * 0.3) * 3
            engineLoad = 48 + sin(phase * 0.25) * 8
        case .misfire:
            rpm += ((760 + sin(phase * 3.5) * 120 + Double.random(in: -70...70)) - rpm) * 0.5
            speed = max(0, speed - dt * 8)
            throttle = 15 + sin(phase * 1.2) * 2
            engineLoad = 24 + sin(phase * 1.1) * 6
        }

        coolant = 18 + warmup * 74 + sin(phase * 0.2) * 0.6
        intakeAir = 22 + warmup * 12 + sin(phase * 0.13) * 1.2
        let loadFraction = engineLoad / 100
        maf = 3.1 + loadFraction * 42 + Double.random(in: -0.25...0.25)
        map = baro * (0.32 + loadFraction * 0.62) + Double.random(in: -1.5...1.5)
        timing = 8 + (1 - loadFraction) * 18 + sin(phase * 1.3) * 2
        batteryVoltage = 14.12 + sin(phase * 0.07) * 0.05 + Double.random(in: -0.02...0.02)

        // Fuel trims drift lean when the simulated fault is present.
        let leanBias = scenario == .misfire ? 12.0 : 0.0
        stft = 1.5 + leanBias * 0.6 + sin(phase * 0.9) * 2.5
        ltft = 2.5 + leanBias * 0.4 + sin(phase * 0.05) * 1.5

        // Upstream O₂ oscillates around stoichiometry; downstream stays calm.
        o2Upstream = 0.45 + sin(phase * 4.2) * 0.38 + Double.random(in: -0.05...0.05)
        o2Downstream = 0.6 + sin(phase * 0.4) * 0.06
        fuelLevel = max(8, fuelLevel - dt * 0.002)
    }

    func bytes(for pid: UInt8) -> [UInt8]? {
        switch pid {
        case 0x00, 0x20, 0x40, 0x60:
            return supportedMask(base: pid)
        case 0x01:
            return [0x82, 0x07, 0x00, 0x00]
        case 0x03:
            return [0x02, 0x00]
        case 0x04:
            return [UInt8(clamping: Int(engineLoad * 255 / 100))]
        case 0x05:
            return [UInt8(clamping: Int(coolant + 40))]
        case 0x06:
            return [encodeTrim(stft)]
        case 0x07:
            return [encodeTrim(ltft)]
        case 0x0A:
            return [UInt8(clamping: Int(430 / 3))]
        case 0x0B:
            return [UInt8(clamping: Int(map))]
        case 0x0C:
            let rpmValue = Int(rpm * 4)
            return [UInt8(rpmValue >> 8), UInt8(rpmValue & 0xFF)]
        case 0x0D:
            return [UInt8(clamping: Int(speed))]
        case 0x0E:
            return [UInt8(clamping: Int((timing + 64) * 2))]
        case 0x0F:
            return [UInt8(clamping: Int(intakeAir + 40))]
        case 0x10:
            let mafValue = Int(maf * 100)
            return [UInt8(mafValue >> 8), UInt8(mafValue & 0xFF)]
        case 0x11:
            return [UInt8(clamping: Int(throttle * 255 / 100))]
        case 0x14:
            return [UInt8(clamping: Int(o2Upstream * 200)), 0xFF]
        case 0x15:
            return [UInt8(clamping: Int(o2Downstream * 200)), 0x80]
        case 0x1F:
            let runtime = Int(Date().timeIntervalSince(startDate))
            return [UInt8(runtime >> 8), UInt8(runtime & 0xFF)]
        case 0x21:
            let km = storedCodes.isEmpty ? 0 : 118
            return [UInt8(km >> 8), UInt8(km & 0xFF)]
        case 0x23:
            let rail = Int(fuelRail / 10)
            return [UInt8(rail >> 8), UInt8(rail & 0xFF)]
        case 0x2C:
            return [0]
        case 0x2D:
            return [128]
        case 0x2E:
            return [24]
        case 0x2F:
            return [UInt8(clamping: Int(fuelLevel * 255 / 100))]
        case 0x30:
            return [42]
        case 0x31:
            let km = 1480
            return [UInt8(km >> 8), UInt8(km & 0xFF)]
        case 0x33:
            return [UInt8(clamping: Int(baro))]
        case 0x3C, 0x3D, 0x3E, 0x3F:
            let temp = 320 + warmup * 380 + (pid == 0x3C ? 120 : 0)
            let value = Int((temp + 40) * 10)
            return [UInt8(value >> 8), UInt8(value & 0xFF)]
        case 0x42:
            let volts = Int(batteryVoltage * 1000)
            return [UInt8(volts >> 8), UInt8(volts & 0xFF)]
        case 0x43:
            let load = Int(engineLoad * 255 / 100)
            return [UInt8(load >> 8), UInt8(load & 0xFF)]
        case 0x44:
            let ratio = Int(1.0 * 32768)
            return [UInt8(ratio >> 8), UInt8(ratio & 0xFF)]
        case 0x46:
            return [UInt8(clamping: Int(intakeAir + 40))]
        case 0x4E:
            let minutes = 1760
            return [UInt8(minutes >> 8), UInt8(minutes & 0xFF)]
        case 0x51:
            return [0x01]
        case 0x52:
            return [UInt8(clamping: Int(ethanol * 255 / 100))]
        case 0x5C:
            return [UInt8(clamping: Int(coolant + 8 + 40))]
        default:
            return nil
        }
    }

    /// Encodes fuel trim percent into the 0–255 PID format.
    private func encodeTrim(_ percent: Double) -> UInt8 {
        UInt8(clamping: Int((percent + 100) * 1.28))
    }

    private func supportedMask(base: UInt8) -> [UInt8] {
        var mask: [UInt8] = [0, 0, 0, 0]
        let supported = Set(Self.supportedPIDs)
        for offset in 0..<32 {
            let pid = base + UInt8(offset + 1)
            guard supported.contains(pid) else { continue }
            mask[offset / 8] |= 0x80 >> UInt8(offset % 8)
        }
        return mask
    }

    static let supportedPIDs: [UInt8] = [
        0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x14, 0x15, 0x1F, 0x21, 0x23, 0x2C, 0x2D, 0x2E, 0x2F, 0x30,
        0x31, 0x33, 0x3C, 0x3D, 0x3E, 0x3F, 0x42, 0x43, 0x44, 0x46, 0x4E, 0x51,
        0x52, 0x5C
    ]

    mutating func dtcBytes(for status: DTCStatus) -> [UInt8] {
        switch status {
        case .stored: return Self.encode(storedCodes)
        case .pending: return Self.encode(pendingCodes)
        case .permanent: return Self.encode(permanentCodes)
        }
    }

    mutating func clearCodes() {
        storedCodes = []
        pendingCodes = []
        // Permanent codes only clear after the ECU re-tests the system.
    }

    static func encode(_ codes: [String]) -> [UInt8] {
        DTCCodec.encode(codes)
    }

    mutating func setScenario(_ scenario: DemoOBDConnection.Scenario) {
        self.scenario = scenario
        switch scenario {
        case .misfire:
            storedCodes = ["P0301", "P0420", "P0171"]
            pendingCodes = ["P0301"]
        default:
            storedCodes = ["P0420", "P0171"]
            pendingCodes = ["P0171"]
        }
    }
}
