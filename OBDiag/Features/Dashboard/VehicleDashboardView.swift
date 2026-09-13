import SwiftUI

/// The vehicle dashboard: connection controls, fault codes and the live sensor
/// grid. This is the heart of the app when hardware is attached.
struct VehicleDashboardView: View {
    @Environment(AppEnvironment.self) private var env

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
                    if obd.isConnected { footerActions }
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
                        Button {
                            showDebugLog = true
                        } label: {
                            Label("Raw OBD log", systemImage: "terminal")
                        }
                        Button {
                            showAllSensors = true
                        } label: {
                            Label("All sensors", systemImage: "list.bullet.rectangle")
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
                        .lineLimit(1)
                    Text(statusSubtitle)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                StatusDot(color: statusColor, pulsing: obd.isConnected)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    GlassChip(text: obd.connectionState.shortLabel, systemImage: obd.isConnected ? "bolt.fill" : "bolt.slash",
                              tint: statusColor)
                    if let info = obd.adapterInfo {
                        if let protocolName = info.protocolName {
                            GlassChip(text: Self.shortProtocol(protocolName), systemImage: "cable.connector",
                                      tint: Palette.textSecondary)
                        }
                        if let voltage = info.voltage {
                            GlassChip(text: String(format: "%.1f V", voltage), systemImage: "car.battery", tint: Palette.textSecondary)
                        }
                    }
                    if !obd.supportedKinds.isEmpty {
                        GlassChip(text: "\(obd.supportedKinds.count) sensors", systemImage: "gauge.with.dots.needle.67percent", tint: Palette.textSecondary)
                    }
                    if obd.isDemo {
                        GlassChip(text: "Simulated", systemImage: "sparkles", tint: Palette.purple)
                    }
                }
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
        .panel(cornerRadius: 24)
    }

    private var vehicleAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.accent.opacity(0.15))
                .frame(width: 52, height: 52)
            Image(systemName: env.garage.selectedVehicle?.isDirectConnection == true ? "bolt.horizontal" : "car.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Palette.accent)
        }
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
        case .connected: return obd.isDemo ? Palette.purple : Palette.success
        case .scanning, .connecting, .initializing: return Palette.amber
        case .failed, .bluetoothUnavailable: return Palette.danger
        case .disconnected: return Palette.textTertiary
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        if obd.isConnected {
            HStack(spacing: 10) {
                GlassSecondaryButton(title: "Scan codes", systemImage: "arrow.clockwise") {
                    Task { await obd.refreshDTCs() }
                }
                GlassSecondaryButton(title: "Disconnect", systemImage: "bolt.slash") {
                    Haptics.warning()
                    obd.disconnect()
                }
            }
        } else {
            HStack(spacing: 10) {
                GlassActionButton(title: "Scan for adapter", systemImage: "dot.radiowaves.left.and.right", isLoading: obd.connectionState.isBusy) {
                    Haptics.tap()
                    showDeviceScan = true
                    obd.startScan()
                }
                GlassSecondaryButton(title: "Demo", systemImage: "sparkles") {
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
                    .font(.system(size: 20))
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
            .panel(cornerRadius: 14, tint: Palette.accent.opacity(0.10))
        }
    }

    // MARK: Sensors

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Live sensors", subtitle: sensorSubtitle) {
                if !obd.supportedKinds.isEmpty {
                    Button("All") { showAllSensors = true }
                        .font(.obCaption)
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
                Label("Explore with demo mode", systemImage: "sparkles")
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.purple)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .panel(cornerRadius: 14)
    }

    // MARK: Footer

    private var footerActions: some View {
        VStack(spacing: 10) {
            GlassSecondaryButton(title: "Automated vehicle detection", systemImage: "car.badge.gearshape") {
                if obd.detectedVIN == nil {
                    Task {
                        await obd.readVIN(force: true)
                        if obd.detectedVIN != nil { showVINSheet = true }
                    }
                } else {
                    showVINSheet = true
                }
            }
            Button {
                showDebugLog = true
            } label: {
                Label("Raw OBD debug log", systemImage: "terminal")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

// MARK: - Shared severity badge

struct SeverityBadge: View {
    let severity: Severity
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: severity.icon)
                .font(.system(size: compact ? 10 : 11, weight: .bold))
            if !compact {
                Text(severity.title)
                    .font(.obMicro)
            }
        }
        .foregroundStyle(severity.color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 3 : 5)
        .glassEffect(.regular.tint(severity.color.opacity(0.15)), in: .capsule)
    }
}
