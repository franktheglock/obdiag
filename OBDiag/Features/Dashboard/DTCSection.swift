import SwiftUI

/// Fault-code section shown on the dashboard, with scan and clear actions.
struct DTCSection: View {
    @Environment(AppEnvironment.self) private var env
    var onSelect: (DiagnosticTroubleCode) -> Void
    var onScan: () -> Void
    var onClear: () -> Void

    private var obd: OBDSession { env.obd }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Fault codes", subtitle: subtitle) {
                Button {
                    Haptics.tap()
                    onScan()
                } label: {
                    if obd.isScanningDTCs {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!obd.isConnected || obd.isScanningDTCs)
                .accessibilityLabel("Scan fault codes")
            }

            if !obd.dtcs.isEmpty {
                summaryChips
                VStack(spacing: 0) {
                    ForEach(Array(obd.dtcs.enumerated()), id: \.element.id) { index, code in
                        DTCRow(code: code) { onSelect(code) }
                        if index < obd.dtcs.count - 1 {
                            Divider().overlay(Palette.stroke)
                        }
                    }
                }
                .padding(.vertical, 4)
                .panel(cornerRadius: 14)

                HStack(spacing: 10) {
                    GlassSecondaryButton(title: "Clear codes", systemImage: "trash") {
                        onClear()
                    }
                    .tint(Palette.danger)
                }
            } else if obd.isConnected {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No fault codes")
                            .font(.obHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        Text(obd.lastDTCScan.map { "Checked \(Format.relative($0))" } ?? "The ECU reports no stored, pending or permanent codes.")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .panel(cornerRadius: 14, tint: Palette.success.opacity(0.10))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.amber)
                    Text("Connect an adapter to read fault codes. Last known codes for this vehicle stay visible in the garage.")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .panel(cornerRadius: 14)
            }
        }
    }

    private var subtitle: String {
        if obd.isScanningDTCs { return "Scanning all code types…" }
        if !obd.isConnected { return "Not connected" }
        if obd.dtcs.isEmpty { return "All clear" }
        return "\(obd.storedCodes.count) stored · \(obd.pendingCodes.count) pending · \(obd.permanentCodes.count) permanent"
    }

    private var summaryChips: some View {
        HStack(spacing: 8) {
            if let worst = obd.worstSeverity {
                GlassChip(text: worst.title, systemImage: worst.icon, tint: worst.color)
            }
            GlassChip(text: "\(obd.dtcs.count) total", systemImage: "number", tint: Palette.textSecondary)
            Spacer()
        }
    }
}

struct DTCRow: View {
    let code: DiagnosticTroubleCode
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(code.code)
                    .font(.obMono(16, weight: .bold))
                    .foregroundStyle(code.severity.color)
                    .frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(code.title)
                        .font(.obCallout)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(code.status.title)
                            .font(.obMicro)
                            .foregroundStyle(code.status.color)
                        if code.isManufacturerSpecific {
                            Text("· manufacturer")
                                .font(.obMicro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(code.code), \(code.title), \(code.severity.title), \(code.status.title)")
    }
}

// MARK: - Detail

struct DTCDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let code: DiagnosticTroubleCode

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    if !code.detail.isEmpty {
                        section("What it means", body: code.detail)
                    }
                    if !code.possibleCauses.isEmpty {
                        list("Likely causes", items: code.possibleCauses, icon: "wrench.and.screwdriver")
                    }
                    if !code.symptoms.isEmpty {
                        list("Symptoms you may notice", items: code.symptoms, icon: "ear")
                    }
                    if !code.recommendedActions.isEmpty {
                        list("Diagnostic steps", items: code.recommendedActions, icon: "checklist")
                    }
                    if !code.freezeFrame.isEmpty {
                        freezeFrame
                    }
                    askAssistantCard
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle(code.code)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(code.title)
                .font(.obTitle2)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: 8) {
                SeverityBadge(severity: code.severity)
                GlassChip(text: code.status.title, systemImage: "flag", tint: code.status.color)
                GlassChip(text: code.system.title, systemImage: code.system.icon, tint: Palette.textSecondary)
            }
            Text(code.status.explanation)
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 14)
    }

    private func section(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.obHeadline).foregroundStyle(Palette.textPrimary)
            Text(body)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 14)
    }

    private func list(_ title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(Palette.accent.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(item)
                        .font(.obCallout)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 14)
    }

    private var freezeFrame: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Freeze frame (at the moment of the fault)", systemImage: "snowflake")
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            ForEach(code.freezeFrame) { item in
                HStack {
                    Text(item.name)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                    Text(item.value)
                        .font(.obMono(13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
        }
        .padding(14)
        .panel(cornerRadius: 14)
    }

    private var askAssistantCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Get a vehicle-specific plan", systemImage: "sparkles")
                .font(.obHeadline)
                .foregroundStyle(Palette.textPrimary)
            Text("The assistant can combine this code with your live readings, find the factory diagnostic procedure and point to parts and videos.")
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
            GlassActionButton(title: "Ask about \(code.code)", systemImage: "bubble.left.and.text.bubble.right") {
                env.pendingChatPrompt = """
                Explain \(code.code) (\(code.title)) for my \(env.garage.selectedVehicle?.composedName ?? "vehicle"). \
                What should I check first, what parts might I need, and is it safe to keep driving?
                """
                env.requestedSection = .chat
                dismiss()
            }
        }
        .padding(14)
        .panel(cornerRadius: 14, tint: Palette.accent.opacity(0.10))
    }
}

// MARK: - Clear codes

struct ClearCodesSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var understood = false
    @State private var isClearing = false
    @State private var resultMessage: String?
    @State private var didSucceed = false

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Before you clear", systemImage: "exclamationmark.triangle.fill")
                            .font(.obHeadline)
                            .foregroundStyle(Palette.amber)
                        bullet("Stored and pending codes are erased. The check-engine light should turn off if no fault is currently active.")
                        bullet("Permanent codes (emissions-related) cannot be cleared with a scan tool — they clear themselves once the ECU re-tests the system.")
                        bullet("Emissions readiness monitors reset. You will need to complete a full drive cycle before an inspection.")
                        bullet("If the underlying fault is still present, the code will return. Clearing is a reset, not a repair.")
                    }
                    .padding(14)
                    .panel(cornerRadius: 14)

                    if let resultMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: didSucceed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(didSucceed ? Palette.success : Palette.danger)
                            Text(resultMessage)
                                .font(.obCallout)
                                .foregroundStyle(Palette.textSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .panel(cornerRadius: 14, tint: (didSucceed ? Palette.success : Palette.danger).opacity(0.10))
                    }

                    Toggle(isOn: $understood) {
                        Text("I understand the codes will be erased and monitors reset.")
                            .font(.obCallout)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .tint(Palette.accent)
                    .padding(14)
                    .panel(cornerRadius: 14)

                    GlassActionButton(
                        title: didSucceed ? "Done" : "Clear fault codes",
                        systemImage: didSucceed ? "checkmark" : "trash",
                        tint: Palette.danger,
                        isEnabled: understood || didSucceed,
                        isLoading: isClearing
                    ) {
                        if didSucceed {
                            dismiss()
                        } else {
                            clear()
                        }
                    }

                    Text("Not legal advice: clearing codes to pass an emissions test without repairing the fault is prohibited in many regions.")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle("Clear fault codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Palette.amber.opacity(0.8)).frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func clear() {
        isClearing = true
        Task {
            let success = await env.obd.clearDTCs()
            didSucceed = success
            resultMessage = success
                ? "Codes cleared. The ECU acknowledged the request. Drive normally — if the fault is still present, the code will return."
                : (env.obd.lastError ?? "The vehicle did not acknowledge the clear request.")
            isClearing = false
        }
    }
}
