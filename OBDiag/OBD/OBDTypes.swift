import Foundation

// MARK: - Adapter discovery & connection state

/// A Bluetooth device that looks like an OBD-II adapter.
struct DiscoveredAdapter: Identifiable, Hashable, Sendable {
    var id: String              // peripheral identifier
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var isLikelyOBD: Bool

    var signalIcon: String {
        switch rssi {
        case (-50)...: return "wifi"
        case (-70)..<(-50): return "wifi.exclamationmark"
        default: return "wifi.slash"
        }
    }
}

/// High-level connection lifecycle shown across the app.
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case bluetoothUnavailable(String)
    case scanning
    case connecting(String)
    case initializing(String)
    case connected(String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .initializing: return true
        default: return false
        }
    }

    var adapterName: String? {
        switch self {
        case .connecting(let name), .initializing(let name), .connected(let name): return name
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .disconnected: return "Not connected"
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return "Scanning…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .initializing(let name): return "Initializing \(name)…"
        case .connected(let name): return "Connected to \(name)"
        case .failed(let message): return message
        }
    }

    var shortLabel: String {
        switch self {
        case .disconnected: return "Offline"
        case .bluetoothUnavailable: return "Bluetooth off"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .initializing: return "Initializing"
        case .connected: return "Live"
        case .failed: return "Error"
        }
    }
}

enum OBDTransportState: Equatable, Sendable {
    case unknown
    case poweredOff
    case unauthorized
    case ready
    case scanning
    case connecting
    case connected
    case disconnected
}

/// Info read from the adapter itself (AT commands).
struct AdapterInfo: Equatable, Sendable {
    var name: String
    var deviceDescription: String?     // AT@1
    var identifier: String?            // ATI
    var version: String?               // "ELM327 v1.5"
    var protocolName: String?          // ATDP
    var protocolNumber: String?        // ATRV-based (ATDPN)
    var voltage: Double?               // ATRV
}

// MARK: - Low-level response

/// A decoded ELM327 exchange: the command, every response line, and cached
/// hex payloads with header bytes stripped where possible.
struct OBDResponse: Sendable {
    var command: String
    var lines: [String]
    var duration: TimeInterval
    var isNoData: Bool
    var isError: Bool

    private var parsedHex: [[UInt8]]

    init(command: String, lines: [String], duration: TimeInterval = 0) {
        self.command = command
        self.lines = lines
        self.duration = duration
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let joined = cleaned.joined(separator: " ").uppercased()
        self.isNoData = joined.contains("NO DATA") || joined.contains("NODATA") || joined.contains("CAN ERROR") || joined.contains("BUS INIT")
        self.isError = joined.contains("?") || joined.contains("ERROR") || joined.contains("UNABLE TO CONNECT")
        self.parsedHex = cleaned.compactMap { Self.hexBytes(in: $0) }
    }

    var rawText: String { lines.joined(separator: "\n") }

    /// All hex bytes across every response line, concatenated.
    var allHexBytes: [UInt8] { parsedHex.flatMap { $0 } }

    /// Bytes that follow a response header such as `41 0C` (mode 01 pid 0C).
    /// Searches every line so CAN headers and ISO-TP frame bytes are ignored.
    func payload(mode: UInt8, pid: UInt8) -> [UInt8] {
        payload(header: [mode | 0x40, pid])
    }

    func payload(header: [UInt8]) -> [UInt8] {
        for line in parsedHex {
            if let index = Self.firstIndex(of: header, in: line) {
                return Array(line[(index + header.count)...])
            }
        }
        return []
    }

    /// First line that looks like human-readable text (for AT commands).
    var firstTextLine: String? {
        lines.first { !$0.trimmed.isEmpty && !$0.trimmed.hasPrefix(">") }
    }

    private static func hexBytes(in line: String) -> [UInt8]? {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.count % 2 == 0 else { return nil }
        let hexCharacters = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard compact.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else { return nil }
        var bytes: [UInt8] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) {
            if Array(bytes[start..<(start + pattern.count)]) == pattern { return start }
        }
        return nil
    }
}

// MARK: - Debug log

struct OBDLogEntry: Identifiable, Sendable {
    enum Direction: String, Sendable {
        case sent
        case received
        case info
        case error

        var symbol: String {
            switch self {
            case .sent: return "→"
            case .received: return "←"
            case .info: return "•"
            case .error: return "!"
            }
        }
    }

    var id = UUID()
    var timestamp = Date()
    var direction: Direction
    var text: String
    var duration: TimeInterval?
}

// MARK: - Errors

enum OBDError: LocalizedError {
    case notConnected
    case initializationFailed(String)
    case noData(String)
    case timeout(String)
    case adapterError(String)
    case vehicleNotResponding
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "No OBD adapter connected."
        case .initializationFailed(let detail): return "Adapter initialization failed: \(detail)"
        case .noData(let command): return "No data returned for \(command)."
        case .timeout(let command): return "Timed out waiting for \(command)."
        case .adapterError(let detail): return "Adapter reported: \(detail)"
        case .vehicleNotResponding: return "The adapter is connected but the vehicle is not responding. Turn the ignition to ON."
        case .unsupported(let feature): return "\(feature) is not supported by this vehicle."
        }
    }
}

/// Abstraction so the demo simulator and real BLE hardware share one code path.
@MainActor
protocol OBDConnection: AnyObject {
    var displayName: String { get }
    func connect() async throws
    func disconnect()
    func query(_ command: String, timeout: TimeInterval) async throws -> OBDResponse
    var onDisconnect: ((Error?) -> Void)? { get set }
}

/// A raw byte pipe to an adapter. The BLE transport implements this; tests and
/// previews can substitute anything that speaks text lines.
@MainActor
protocol OBDTransport: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onStateChange: ((OBDTransportState) -> Void)? { get set }
    var onDisconnected: ((Error?) -> Void)? { get set }
    var onDiscovered: (([DiscoveredAdapter]) -> Void)? { get set }

    func startScan()
    func stopScan()
    func connect(to adapter: DiscoveredAdapter) async throws
    func disconnect()
    func send(_ text: String)
}

extension OBDConnection {
    func query(_ command: String) async throws -> OBDResponse {
        try await query(command, timeout: 3)
    }
}
