import SwiftUI

/// About, privacy and data-source acknowledgements.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var env

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 13) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Gradients.accent.opacity(0.2))
                                .frame(width: 56, height: 56)
                            Image(systemName: "bolt.car.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("OBDiag")
                                .font(.obTitle2)
                                .foregroundStyle(Palette.textPrimary)
                            Text("AI vehicle diagnostics for iPhone and iPad")
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Text("Plug in a Bluetooth OBD-II adapter and OBDiag reads live engine data and fault codes, then explains what's wrong and what to do about it — in plain language, with sources.")
                        .font(.obCallout)
                        .foregroundStyle(Palette.textSecondary)
                    HStack {
                        Text("Version")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textTertiary)
                        Spacer()
                        Text(version)
                            .font(.obMono(12))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Privacy") {
                aboutRow(icon: "lock.shield.fill", tint: Palette.success,
                         title: "On-device by default",
                         detail: "Vehicles, conversations, settings and the credit ledger are stored locally. OBDiag runs no server.")
                aboutRow(icon: "key.fill", tint: Palette.accent,
                         title: "Keys in the Keychain",
                         detail: "API keys are kept in the iOS Keychain and sent only to the provider you choose.")
                aboutRow(icon: "antenna.radiowaves.left.and.right", tint: Palette.amber,
                         title: "Explicit network use",
                         detail: "Traffic to the AI provider, search backends and the NHTSA database happens only when those features are used.")
            }

            Section("Data sources") {
                linkRow("NHTSA vPIC vehicle database", url: "https://vpic.nhtsa.dot.gov/api/")
                linkRow("OpenRouter model catalog", url: "https://openrouter.ai/docs")
                linkRow("DuckDuckGo search (on-device parsing)", url: "https://duckduckgo.com")
                linkRow("TinyFish Search API", url: "https://docs.tinyfish.ai/search-api")
                Text("Fault-code descriptions in the offline library are written for OBDiag and follow SAE J2012 conventions.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }

            Section("Safety") {
                Text("OBDiag is a diagnostic aid, not a substitute for a qualified mechanic. Always follow the manufacturer's procedures, use jack stands, and stop driving if you suspect a safety-critical fault (brakes, steering, fuel, overheating or airbags).")
                    .font(.obCallout)
                    .foregroundStyle(Palette.textSecondary)
            }

            Section {
                Button {
                    env.requestedSection = .settings
                } label: {
                    Text("Back to settings")
                        .font(.obCallout)
                }
                .hidden()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func aboutRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func linkRow(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                    .font(.obCallout)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}
