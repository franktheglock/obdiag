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
        payloads(header: header).first ?? []
    }

    /// Every line that carries this header. A CAN vehicle can have several
    /// modules answer the same request (engine, transmission, ABS …), and each
    /// one reports its own codes — taking only the first line hides faults.
    func payloads(header: [UInt8]) -> [[UInt8]] {
        parsedHex.compactMap { line in
            guard let index = Self.firstIndex(of: header, in: line) else { return nil }
            return Array(line[(index + header.count)...])
        }
    }

    /// First line that looks like human-readable text (for AT commands).
    var firstTextLine: String? {
        lines.first { !$0.trimmed.isEmpty && !$0.trimmed.hasPrefix(">") }
    }

    /// Parses one adapter line into bytes.
    ///
    /// Adapters format payloads inconsistently: ISO-TP responses may be split
    /// across lines prefixed with a frame index (`0: 49 02 01 …`), the first
    /// frame may carry an odd-length length token (`014`), and CAN headers may
    /// be present. Non-hex lines (`NO DATA`, `SEARCHING…`, `BUS INIT: ERROR`)
    /// return nil so they are ignored.
    static func hexBytes(in line: String) -> [UInt8]? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return nil }

        var bytes: [UInt8] = []
        var sawHex = false

        for rawToken in tokens {
            var token = rawToken
            // ISO-TP frame index, either separated ("0: 49 02 …") or glued to
            // the payload when spaces are off ("0:490201334336").
            if let colon = token.firstIndex(of: ":") {
                let prefix = token[token.startIndex..<colon]
                if !prefix.isEmpty, prefix.allSatisfy(\.isNumber) {
                    token = token[token.index(after: colon)...]
                }
            }
            if token.isEmpty { continue }
            guard token.allSatisfy({ $0.isHexDigit }) else { return nil }
            sawHex = true
            // Odd-length token is a length/PCI byte pair, e.g. "014" → 01 04.
            if token.count % 2 == 1 { token = "0" + token }

            var index = token.startIndex
            while index < token.endIndex {
                let next = token.index(index, offsetBy: 2)
                guard let byte = UInt8(token[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
        }
        return sawHex ? bytes : nil
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
    /// Drops any half-received response and resynchronises the adapter.
    func resync()
    var onDisconnect: ((Error?) -> Void)? { get set }
}

extension OBDConnection {
    func resync() {}
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

// MARK: - VIN extraction

/// Pulls the 17-character VIN out of a mode 09 PID 02 response.
///
/// Real adapters return this in several shapes — one assembled line, one line
/// per ISO-TP frame with a `0:`/`1:` index, frames with the `49 02` header
/// repeated, or raw CAN frames with a header and PCI byte. Parsing is therefore
/// structural (per line) rather than "everything after the first header".
enum VINParser {
    static func extract(from response: OBDResponse) -> String? {
        extract(fromLines: response.lines)
    }

    static func extract(fromLines lines: [String]) -> String? {
        var payload: [UInt8] = []
        var inSequence = false

        for line in lines {
            guard let bytes = OBDResponse.hexBytes(in: line), !bytes.isEmpty else { continue }

            if let header = firstIndex(of: [0x49, 0x02], in: bytes) {
                inSequence = true
                var rest = Array(bytes[(header + 2)...])
                // The byte after the header is the item/frame count or index.
                if let first = rest.first, first <= 0x0F { rest.removeFirst() }
                payload.append(contentsOf: rest)
            } else if inSequence {
                // Continuation frame. ISO-TP consecutive frames carry seven data
                // bytes, so drop any CAN header + PCI byte by keeping the tail.
                let rest = bytes.count > 7 ? Array(bytes.suffix(7)) : bytes
                payload.append(contentsOf: rest)
            }
        }

        guard inSequence else { return nil }

        let characters: [Character] = payload.compactMap { byte in
            guard byte >= 0x20, byte < 0x7F else { return nil }
            let character = Character(UnicodeScalar(byte))
            guard character.isLetter || character.isNumber else { return nil }
            // I, O and Q never appear in a VIN — they are usually header or
            // padding bytes that survived the conversion.
            guard !"IOQ".contains(character) else { return nil }
            return character
        }

        let vin = String(characters.prefix(17)).uppercased()
        return Vehicle.isPlausibleVIN(vin) ? vin : nil
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count)
        where Array(bytes[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }
}
