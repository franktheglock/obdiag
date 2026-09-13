import Foundation

/// Serializes ELM327 exchanges over any `OBDTransport`: one command in flight,
/// responses completed by the `>` prompt, timeouts enforced, everything logged.
@MainActor
final class ELM327Client {
    private let transport: OBDTransport
    private var pendingText = ""

    private struct Request {
        let id: Int
        let command: String
        let timeout: TimeInterval
        let continuation: CheckedContinuation<OBDResponse, Error>
    }

    private var queue: [Request] = []
    private var active: Request?
    private var activeBuffer: [String] = []
    private var activeStartedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private var nextID = 0

    /// Every exchange, for the debug log.
    var onLog: ((OBDLogEntry) -> Void)?

    init(transport: OBDTransport) {
        self.transport = transport
        self.transport.onLine = { [weak self] text in
            self?.ingest(text)
        }
    }

    var isIdle: Bool { active == nil && queue.isEmpty }

    // MARK: Public API

    func query(_ command: String, timeout: TimeInterval = 3) async throws -> OBDResponse {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Request(id: id, command: command, timeout: timeout, continuation: continuation))
            pump()
        }
    }

    /// Clears any half-received response and nudges the adapter back to a
    /// prompt. A timed-out request can leave the adapter mid-message, and the
    /// late reply would otherwise be attributed to the next command.
    func resync() {
        pendingText = ""
        activeBuffer = []
        transport.send("\r")
        log(.info, "resync")
    }

    /// Fire-and-forget AT command; used for tidy-up during disconnect.
    func sendWithoutWaiting(_ command: String) {
        transport.send(command + "\r")
        log(.sent, command)
    }

    func cancelAll() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let active {
            active.continuation.resume(throwing: OBDError.notConnected)
            self.active = nil
        }
        for request in queue { request.continuation.resume(throwing: OBDError.notConnected) }
        queue.removeAll()
        activeBuffer.removeAll()
        pendingText = ""
    }

    // MARK: Queue

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request
        activeBuffer = []
        activeStartedAt = Date()
        log(.sent, request.command)
        transport.send(request.command + "\r")

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(request.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.failActive(with: .timeout(request.command))
        }
    }

    private func finishActive() {
        guard let request = active else {
            // Stray prompt (e.g. leftover from ATZ) — ignore.
            pendingText = ""
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        let duration = activeStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        var lines = activeBuffer
        if lines.isEmpty, !pendingText.trimmed.isEmpty, pendingText.trimmed != ">" {
            lines.append(pendingText.trimmed)
        }
        pendingText = ""
        active = nil
        activeBuffer = []

        let response = OBDResponse(command: request.command, lines: lines, duration: duration)
        if response.isError, request.command.hasPrefix("AT") == false {
            log(.error, "\(request.command) → \(response.rawText.truncated(to: 160))")
        } else {
            log(.received, "\(request.command) → \(response.rawText.truncated(to: 160))", duration: duration)
        }
        request.continuation.resume(returning: response)
        pump()
    }

    private func failActive(with error: OBDError) {
        guard let request = active else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        active = nil
        activeBuffer = []
        pendingText = ""
        log(.error, "\(request.command) → \(error.localizedDescription)")
        request.continuation.resume(throwing: error)
        pump()
    }

    // MARK: Ingest

    private func ingest(_ text: String) {
        pendingText += text
        while !pendingText.isEmpty {
            guard let separatorIndex = pendingText.firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == ">" }) else {
                break
            }
            let separator = pendingText[separatorIndex]
            let line = String(pendingText[pendingText.startIndex..<separatorIndex]).trimmed
            pendingText = String(pendingText[pendingText.index(after: separatorIndex)...])

            if separator == ">" {
                if !line.isEmpty { activeBuffer.append(line) }
                finishActive()
                continue
            }
            if !line.isEmpty, line != ">" {
                activeBuffer.append(line)
            }
        }
    }

    private func log(_ direction: OBDLogEntry.Direction, _ text: String, duration: TimeInterval? = nil) {
        onLog?(OBDLogEntry(direction: direction, text: text, duration: duration))
    }
}

// MARK: - Initialization sequence

extension ELM327Client {
    /// Runs the standard handshake and returns the adapter identity.
    func initializeAdapter(name: String) async throws -> AdapterInfo {
        var info = AdapterInfo(name: name)

        // Reset. Some clones take a moment; a timeout here is not fatal.
        if let reset = try? await query("ATZ", timeout: 5) {
            info.version = reset.firstTextLine
        }
        _ = try? await query("ATE0")          // echo off
        _ = try? await query("ATL0")          // line feeds off
        _ = try? await query("ATS0")          // spaces off
        _ = try? await query("ATH0")          // headers off
        _ = try? await query("ATSP0")         // auto protocol
        _ = try? await query("ATAT1")         // adaptive timing (ATAT2 is only for J1850/ISO9141)
        _ = try? await query("ATST 32")       // 200 ms response window; some ECUs are slow

        if let identifier = try? await query("ATI"), let line = identifier.firstTextLine {
            info.identifier = line
        }
        if let description = try? await query("AT@1"), let line = description.firstTextLine {
            info.deviceDescription = line
        }
        if let protocolName = try? await query("ATDP"), let line = protocolName.firstTextLine {
            info.protocolName = line
        }
        if let protocolNumber = try? await query("ATDPN"), let line = protocolNumber.firstTextLine {
            info.protocolNumber = line
        }
        if let voltage = try? await query("ATRV"), let line = voltage.firstTextLine {
            let numeric = line.replacingOccurrences(of: "V", with: "").trimmed
            info.voltage = Double(numeric)
        }

        // Probe the bus; a NO DATA response still means the adapter is alive.
        let probe = try? await query("0100")
        if probe?.isNoData == true {
            throw OBDError.vehicleNotResponding
        }
        return info
    }
}
