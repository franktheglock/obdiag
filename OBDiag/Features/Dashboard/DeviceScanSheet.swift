import SwiftUI

/// Bluetooth scan sheet: nearby BLE OBD-II adapters, connection state and demo
/// entry point.
struct DeviceScanSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var connectingID: String?
    @State private var errorMessage: String?

    private var likely: [DiscoveredAdapter] { env.obd.availableAdapters.filter(\.isLikelyOBD) }
    private var others: [DiscoveredAdapter] { env.obd.availableAdapters.filter { !$0.isLikelyOBD } }

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if env.obd.connectionState.isConnected {
                        connectedCard
                    } else {
                        scanningState
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
                            Text(errorMessage)
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .panel()
                    }

                    if !likely.isEmpty {
                        adapterSection("OBD-II adapters", adapters: likely)
                    }
                    if !others.isEmpty {
                        adapterSection("Other Bluetooth devices", adapters: others)
                    }

                    footer
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle("Connect adapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !env.obd.isConnected else { return }
            env.obd.startScan()
        }
        .onDisappear {
            env.obd.stopScan()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if env.obd.connectionState.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Palette.accent)
                }
                Text(env.obd.connectionState.label)
                    .font(.obHeadline)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button {
                    env.obd.startScan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Text("OBDiag works with Bluetooth LE adapters (iPhone does not support Bluetooth Classic SPP adapters). Vgate iCar Pro BLE, Veepeak BLE and OBDLink MX+ are known-good.")
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var scanningState: some View {
        Group {
            if env.obd.availableAdapters.isEmpty {
                HStack(spacing: 12) {
                    if env.obd.connectionState == .scanning {
                        ProgressView().controlSize(.small).tint(Palette.accent)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.obd.connectionState == .scanning ? "Looking for adapters…" : "No adapters found")
                            .font(.obCallout)
                            .foregroundStyle(Palette.textPrimary)
                        Text(env.obd.connectionState == .scanning
                             ? "Make sure the ignition is ON and the adapter's LED is blinking."
                             : "Check that it is plugged in, then scan again.")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .panel()
            }
        }
    }

    private var connectedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Palette.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(env.obd.adapterInfo?.name ?? "Adapter")
                    .font(.obHeadline)
                    .foregroundStyle(Palette.textPrimary)
                if let info = env.obd.adapterInfo {
                    Text([info.version, info.protocolName].compactMap { $0 }.joined(separator: " · "))
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button("Disconnect") {
                env.obd.disconnect()
                dismiss()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .tint(Palette.danger)
        }
        .padding(14)
        .panel(tint: Palette.success.opacity(0.10))
    }

    private func adapterSection(_ title: String, adapters: [DiscoveredAdapter]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.obCaption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(adapters.enumerated()), id: \.element.id) { index, adapter in
                    adapterRow(adapter)
                    if index < adapters.count - 1 {
                        Divider().overlay(Palette.stroke)
                    }
                }
            }
            .padding(.vertical, 4)
            .panel()
        }
    }

    private func adapterRow(_ adapter: DiscoveredAdapter) -> some View {
        Button {
            connect(adapter)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: adapter.isLikelyOBD ? "bolt.horizontal.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.body)
                    .foregroundStyle(adapter.isLikelyOBD ? Palette.accent : Palette.textTertiary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(adapter.name)
                        .font(.obCallout.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(adapter.advertisedServices.isEmpty
                         ? "No advertised services"
                         : adapter.advertisedServices.joined(separator: ", "))
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if connectingID == adapter.id || (env.obd.connectionState.isBusy && env.obd.connectionState.adapterName == adapter.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(adapter.rssi) dBm")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            GlassSecondaryButton(title: "Explore with demo vehicle", systemImage: "play.circle") {
                Haptics.tap()
                Task {
                    await env.obd.connectDemo()
                    dismiss()
                }
            }
            .tint(Palette.accent)

            Text("Demo mode simulates a full ELM327 adapter and a vehicle, so you can try every feature without hardware.")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func connect(_ adapter: DiscoveredAdapter) {
        connectingID = adapter.id
        errorMessage = nil
        Haptics.tap()
        Task {
            await env.obd.connect(to: adapter)
            connectingID = nil
            if env.obd.connectionState.isConnected {
                dismiss()
            } else if let error = env.obd.lastError {
                errorMessage = error
            }
        }
    }
}
