import SwiftUI

/// Raw ELM327 exchange log for troubleshooting adapters and protocols.
struct DebugLogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var autoScroll = true
    @State private var filter: LogFilter = .all

    enum LogFilter: String, CaseIterable, Identifiable {
        case all, sent, received, errors
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .sent: return "Sent"
            case .received: return "Received"
            case .errors: return "Errors"
            }
        }
    }

    private var entries: [OBDLogEntry] {
        switch filter {
        case .all: return env.obd.log
        case .sent: return env.obd.log.filter { $0.direction == .sent }
        case .received: return env.obd.log.filter { $0.direction == .received }
        case .errors: return env.obd.log.filter { $0.direction == .error || $0.direction == .info }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        EmptyStateView(
                            systemImage: "terminal",
                            title: "Nothing logged yet",
                            message: "Connect an adapter and OBDiag will record every command and response here."
                        )
                        .padding(.top, 60)
                    }
                    ForEach(entries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: entries.count) { _, _ in
                guard autoScroll, let last = entries.last else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color(hex: 0x05070A).ignoresSafeArea())
        .navigationTitle("Raw OBD log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(isOn: $autoScroll) {
                    Image(systemName: autoScroll ? "arrow.down.to.line.compact" : "pause")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Auto scroll")

                ShareLink(item: env.obd.logText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share log")

                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(LogFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        env.obd.clearLog()
                    } label: {
                        Label("Clear log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}

struct LogRow: View {
    let entry: OBDLogEntry

    private var color: Color {
        switch entry.direction {
        case .sent: return Palette.accent
        case .received: return Palette.success
        case .info: return Palette.textSecondary
        case .error: return Palette.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Format.timestamp(entry.timestamp))
                .font(.obMono(10, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 78, alignment: .leading)
            Text(entry.direction.symbol)
                .font(.obMono(11, weight: .bold))
                .foregroundStyle(color)
            Text(entry.text)
                .font(.obMono(11, weight: .regular))
                .foregroundStyle(entry.direction == .received ? Palette.textPrimary : Palette.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let duration = entry.duration {
                Text(String(format: "%.0f ms", duration * 1000))
                    .font(.obMono(9, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
