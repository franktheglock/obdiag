import Foundation

/// Live BLE connection: owns the transport + ELM327 client and exposes a clean
/// `OBDConnection` surface to the session.
@MainActor
final class RealOBDConnection: OBDConnection {
    let transport: BLEOBDTransport
    let client: ELM327Client

    private(set) var adapterInfo: AdapterInfo?
    var onDisconnect: ((Error?) -> Void)?

    /// UI hooks.
    var onLog: ((OBDLogEntry) -> Void)?
    var onAdapters: (([DiscoveredAdapter]) -> Void)?
    var onTransportState: ((OBDTransportState) -> Void)?

    var displayName: String { adapterInfo?.name ?? "OBD adapter" }

    init() {
        let transport = BLEOBDTransport()
        self.transport = transport
        self.client = ELM327Client(transport: transport)

        transport.onDiscovered = { [weak self] adapters in
            self?.onAdapters?(adapters)
        }
        transport.onStateChange = { [weak self] state in
            self?.onTransportState?(state)
        }
        transport.onDisconnected = { [weak self] error in
            self?.onDisconnect?(error)
        }
        client.onLog = { [weak self] entry in
            self?.onLog?(entry)
        }
    }

    func scan() { transport.startScan() }
    func stopScan() { transport.stopScan() }

    func connect(to adapter: DiscoveredAdapter) async throws {
        try await transport.connect(to: adapter)
        adapterInfo = try await client.initializeAdapter(name: adapter.name)
    }

    func connect() async throws {
        // Only used by the protocol; real connections are made to a specific device.
        throw BLEError.notFound
    }

    func query(_ command: String, timeout: TimeInterval) async throws -> OBDResponse {
        try await client.query(command, timeout: timeout)
    }

    func resync() {
        client.resync()
    }

    func disconnect() {
        client.cancelAll()
        transport.disconnect()
    }
}
