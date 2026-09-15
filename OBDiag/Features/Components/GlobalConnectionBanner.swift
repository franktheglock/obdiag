import SwiftUI

/// Global connection status toast. Appears briefly when the adapter state
/// changes — connecting, live, or failed — and taps through to the dashboard.
/// It stays out of the way otherwise, since the dashboard and garage cards show
/// persistent status.
struct GlobalConnectionBanner: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var section: AppSection

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    private var state: ConnectionState { env.obd.connectionState }

    var body: some View {
        Group {
            if isVisible, let presentation = presentation {
                Button {
                    Haptics.tap()
                    dismiss()
                    section = .dashboard
                } label: {
                    HStack(spacing: 8) {
                        icon(for: presentation)
                        Text(presentation.title)
                            .font(.obCaption)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.obMicro)
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(presentation.tint.opacity(0.16)).interactive(), in: .capsule)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("OBD connection: \(presentation.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 46)
        .animation(.smooth(duration: 0.3), value: isVisible)
        .onChange(of: state) { _, newState in
            guard env.settings.onboardingComplete else { return }
            switch newState {
            case .disconnected:
                dismiss()
            case .scanning:
                break
            case .connected, .failed, .bluetoothUnavailable:
                present(autoHideAfter: newState.isConnected || !newState.isBusy ? 5 : nil)
            case .connecting, .initializing:
                present(autoHideAfter: nil)
            }
        }
    }

    private struct Presentation {
        var title: String
        var detail: String?
        var tint: Color
        var isBusy: Bool
        var symbol: String
    }

    private var presentation: Presentation? {
        switch state {
        case .connected:
            let detail: String?
            if env.obd.hasFaults {
                detail = "\(env.obd.dtcs.count) fault\(env.obd.dtcs.count == 1 ? "" : "s") found"
            } else if let vehicle = env.garage.selectedVehicle?.displayName, !vehicle.isEmpty {
                detail = vehicle
            } else {
                detail = nil
            }
            return Presentation(
                title: env.obd.isDemo ? "Demo vehicle live" : "Adapter live",
                detail: detail,
                tint: env.obd.isDemo ? Palette.accent : Palette.success,
                isBusy: false,
                symbol: "bolt.fill"
            )
        case .connecting(let name):
            return Presentation(title: "Connecting to \(name)", detail: nil, tint: Palette.amber, isBusy: true, symbol: "bolt.horizontal")
        case .initializing(let name):
            return Presentation(title: "Initializing \(name)", detail: nil, tint: Palette.amber, isBusy: true, symbol: "bolt.horizontal")
        case .scanning:
            return Presentation(title: "Scanning for adapters", detail: nil, tint: Palette.accent, isBusy: true, symbol: "dot.radiowaves.left.and.right")
        case .failed(let message):
            return Presentation(title: message, detail: "Tap for details", tint: Palette.danger, isBusy: false, symbol: "exclamationmark.triangle.fill")
        case .bluetoothUnavailable(let reason):
            return Presentation(title: reason, detail: "Tap for details", tint: Palette.danger, isBusy: false, symbol: "bluetooth.slash")
        case .disconnected:
            return nil
        }
    }

    @ViewBuilder
    private func icon(for presentation: Presentation) -> some View {
        if presentation.isBusy {
            ProgressView()
                .controlSize(.mini)
                .tint(presentation.tint)
        } else {
            Image(systemName: presentation.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(presentation.tint)
        }
    }

    private func present(autoHideAfter seconds: TimeInterval?) {
        hideTask?.cancel()
        isVisible = true
        guard let seconds else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
    }
}
