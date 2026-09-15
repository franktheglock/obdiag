import SwiftUI

/// The vehicle dashboard: connection controls, fault codes and the live sensor
/// grid. This is the heart of the app when hardware is attached.
struct VehicleDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showDeviceScan = false
    @State private var showClearCodes = false
    @State private var showDebugLog = false
    @State private var showVINSheet = false
    @State private var showAllSensors = false
    @State private var selectedDTC: DiagnosticTroubleCode?
    @State private var selectedSensor: SensorKind?
    @State private var hasAutoConnectedDemo = false

    private var obd: OBDSession { env.obd }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    statusCard
                    if obd.isConnected { vinMismatchBanner }
                    DTCSection(
                        onSelect: { selectedDTC = $0 },
                        onScan: { Task { await obd.refreshDTCs() } },
                        onClear: { showClearCodes = true }
                    )
                    sensorsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .screenBackground()
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showDeviceScan = true
                        } label: {
                            Label(obd.isConnected ? "Change adapter" : "Scan for adapter", systemImage: "dot.radiowaves.left.and.right")
                        }
                        if obd.isConnected {
                            Button(role: .destructive) {
                                obd.disconnect()
                                Haptics.warning()
                            } label: {
                                Label("Disconnect", systemImage: "bolt.slash")
                            }
                        }
                        Divider()
                        if obd.isConnected {
                            Button {
                                detectVehicle()
                            } label: {
                                Label("Detect vehicle from VIN", systemImage: "car.badge.gearshape")
                            }
                        }
                        Button {
                            showAllSensors = true
                        } label: {
                            Label("All sensors", systemImage: "list.bullet.rectangle")
                        }
                        Button {
                            showDebugLog = true
                        } label: {
                            Label("Raw OBD log", systemImage: "terminal")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Dashboard options")
                }
            }
            .sheet(isPresented: $showDeviceScan) {
                DeviceScanSheet()
            }
            .sheet(isPresented: $showClearCodes) {
                ClearCodesSheet()
            }
            .sheet(item: $selectedDTC) { code in
                DTCDetailView(code: code)
            }
            .sheet(item: $selectedSensor) { kind in
                SensorDetailView(kind: kind)
            }
            .sheet(isPresented: $showVINSheet) {
                DetectedVINSheet(vin: obd.detectedVIN ?? "")
            }
            .navigationDestination(isPresented: $showDebugLog) {
                DebugLogView()
            }
            .navigationDestination(isPresented: $showAllSensors) {
                AllSensorsView()
            }
        }
        .onAppear {
            guard !obd.isConnected, !obd.isDemo, obd.connectionState == .disconnected else { return }
            if env.settings.demoAdapterEnabled, !hasAutoConnectedDemo {
                hasAutoConnectedDemo = true
                Task { await obd.connectDemo() }
            } else if env.settings.autoReconnect, let preferred = env.settings.preferredAdapterID {
                // Bounded: if the adapter is not around (unplugged, out of
                // range) the scan gives up after a few seconds instead of
                // leaving the button spinning.
                obd.startScan(bounded: true, autoConnectID: preferred)
            }
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                vehicleAvatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(env.garage.selectedVehicle?.displayName ?? "No vehicle selected")
                        .font(.obTitle2)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                    Text(statusSubtitle)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                StatusDot(color: statusColor, pulsing: obd.isConnected)
            }

            if obd.isConnected {
                Text(connectionSummary)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textSecondary)
            }

            connectionControls

            if obd.isDemo {
                demoControls
            }

            if let error = obd.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.amber)
                    Text(error)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .panel()
    }

    private var vehicleAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.accent.opacity(0.15))
                .frame(width: 52, height: 52)
            Image(systemName: env.garage.selectedVehicle?.isDirectConnection == true ? "bolt.horizontal" : "car.fill")
                .font(.title3.weight(.medium))
                .foregroundStyle(Palette.accent)
        }
    }

    /// "Demo · CAN · 14.1 V · 37 sensors"
    private var connectionSummary: String {
        var parts: [String] = []
        if obd.isDemo { parts.append("Demo") }
        if let info = obd.adapterInfo {
            if let protocolName = info.protocolName { parts.append(Self.shortProtocol(protocolName)) }
            if let voltage = info.voltage { parts.append(String(format: "%.1f V", voltage)) }
        }
        if !obd.supportedKinds.isEmpty { parts.append("\(obd.supportedKinds.count) sensors") }
        return parts.joined(separator: " · ")
    }

    /// "ISO 15765-4 (CAN 11/500)" → "CAN 11/500"
    static func shortProtocol(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("can") { return "CAN" }
        if let range = name.range(of: "(") {
            return name[range.lowerBound...].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return name.truncated(to: 10, ellipsis: "")
    }

    private var statusSubtitle: String {
        switch obd.connectionState {
        case .connected:
            if let vehicle = env.garage.selectedVehicle {
                return vehicle.subtitle.isEmpty ? "Connected and streaming live data" : vehicle.subtitle
            }
            return "Connected and streaming live data"
        case .disconnected:
            return "Connect an OBD-II adapter to read live data and fault codes."
        case .scanning:
            return "Searching for nearby Bluetooth adapters…"
        case .connecting(let name), .initializing(let name):
            return "Working with \(name)…"
        case .failed(let message):
            return message
        case .bluetoothUnavailable(let reason):
            return reason
        }
    }

    private var statusColor: Color {
        switch obd.connectionState {
        case .connected: return Palette.success
        case .scanning, .connecting, .initializing: return Palette.amber
        case .failed, .bluetoothUnavailable: return Palette.danger
        case .disconnected: return Palette.textTertiary
        }
    }

    /// Side by side normally; stacked at accessibility text sizes so the
    /// labels never hyphenate.
    private var controlsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    @ViewBuilder
    private var connectionControls: some View {
        if obd.isConnected {
            controlsLayout {
                GlassSecondaryButton(title: "Scan codes", systemImage: "arrow.clockwise") {
                    Task { await obd.refreshDTCs() }
                }
                GlassSecondaryButton(title: "Disconnect", systemImage: "bolt.slash") {
                    Haptics.warning()
                    obd.disconnect()
                }
            }
        } else {
            controlsLayout {
                GlassActionButton(title: "Scan for adapter", systemImage: "dot.radiowaves.left.and.right", isLoading: obd.connectionState.isBusy) {
                    Haptics.tap()
                    showDeviceScan = true
                    obd.startScan()
                }
                GlassSecondaryButton(title: "Demo", systemImage: "play.circle") {
                    Haptics.tap()
                    Task { await obd.connectDemo() }
                }
            }
        }
    }

    private var demoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulated driving scenario")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
            Picker("Scenario", selection: Binding(
                get: { obd.demoScenario },
                set: { obd.demoScenario = $0 }
            )) {
                ForEach(DemoOBDConnection.Scenario.allCases) { scenario in
                    Text(scenario.shortTitle).tag(scenario)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: VIN banner

    @ViewBuilder
    private var vinMismatchBanner: some View {
        if let message = obd.vinMismatchMessage {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "car.badge.gearshape")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vehicle detected")
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    Text(message)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                    HStack(spacing: 8) {
                        Button("Review") {
                            showVINSheet = true
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                        .controlSize(.small)
                        Button("Not now") { obd.dismissVINPrompt() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .panel(tint: Palette.accent.opacity(0.10))
        }
    }

    // MARK: Sensors

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Live sensors", subtitle: sensorSubtitle) {
                if !obd.supportedKinds.isEmpty {
                    Button("All") { showAllSensors = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            if obd.isConnected {
                SensorsGrid(
                    kinds: featuredSensors,
                    onSelect: { selectedSensor = $0 }
                )
            } else {
                connectPrompt
            }
        }
    }

    private var sensorSubtitle: String {
        if !obd.isConnected { return "Connect to see live engine data" }
        if let lastUpdated = obd.lastUpdated {
            return "Updating · last value \(Format.relative(lastUpdated))"
        }
        return "Waiting for the first readings…"
    }

    /// The sensors shown on the dashboard; the full list lives behind "All".
    private var featuredSensors: [SensorKind] {
        let preferred: [SensorKind] = [
            .engineRPM, .vehicleSpeed, .coolantTemperature, .batteryVoltage,
            .engineLoad, .intakeAirTemperature, .shortTermFuelTrimBank1, .longTermFuelTrimBank1,
            .massAirFlow, .throttlePosition, .manifoldAbsolutePressure, .fuelLevel
        ]
        let available = preferred.filter { obd.supportedKinds.contains($0) }
        if available.isEmpty {
            return SensorCatalog.pollingOrder.filter { obd.supportedKinds.contains($0) }.prefix(8).map { $0 }
        }
        return available
    }

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            EmptyStateView(
                systemImage: "cable.connector",
                title: "No adapter connected",
                message: "Plug an OBD-II adapter into the port under your dash, turn the ignition to ON, and connect over Bluetooth. No hardware? Try demo mode.",
                actionTitle: "Scan for adapter",
                action: {
                    showDeviceScan = true
                    obd.startScan()
                }
            )
            Button {
                Haptics.tap()
                Task { await obd.connectDemo() }
            } label: {
                Label("Explore with demo mode", systemImage: "play.circle")
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .panel()
    }

    // MARK: Actions

    private func detectVehicle() {
        if obd.detectedVIN == nil {
            Task {
                await obd.readVIN(force: true)
                if obd.detectedVIN != nil { showVINSheet = true }
            }
        } else {
            showVINSheet = true
        }
    }
}

// MARK: - Shared severity badge

struct SeverityBadge: View {
    let severity: Severity
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: severity.icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(severity.color)
        } else {
            GlassChip(text: severity.title, systemImage: severity.icon, tint: severity.color)
        }
    }
}
