import SwiftUI

enum SettingsRoute: Hashable {
    case provider
    case models
    case search
    case subscription
    case units
    case data
    case about
    case debugLog
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    /// Only used by the `-showSubscription` debug screenshot hook.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                subscriptionSection

                Section("Assistant") {
                    NavigationLink(value: SettingsRoute.provider) {
                        settingsRow(
                            icon: env.settings.provider.icon,
                            tint: Palette.accent,
                            title: "AI provider",
                            detail: providerDetail
                        )
                    }
                    NavigationLink(value: SettingsRoute.models) {
                        settingsRow(
                            icon: env.chat.selectedModel.tier.icon,
                            tint: Palette.purple,
                            title: "Model",
                            detail: env.chat.selectedModel.name
                        )
                    }
                    NavigationLink(value: SettingsRoute.search) {
                        settingsRow(
                            icon: env.settings.searchBackend.icon,
                            tint: Palette.success,
                            title: "Search & tools",
                            detail: env.search.backendLabel
                        )
                    }
                }

                Section("Driving") {
                    HStack {
                        Image(systemName: "ruler")
                            .foregroundStyle(Palette.accent)
                            .frame(width: 26)
                        Picker("Units", selection: Binding(
                            get: { env.settings.unitSystem },
                            set: { env.settings.unitSystem = $0 }
                        )) {
                            ForEach(UnitSystem.allCases) { system in
                                Text(system.title).tag(system)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Adapter") {
                    Toggle(isOn: Binding(
                        get: { env.settings.demoAdapterEnabled },
                        set: { env.settings.demoAdapterEnabled = $0 }
                    )) {
                        settingsRow(
                            icon: "sparkles",
                            tint: Palette.purple,
                            title: "Start in demo mode",
                            detail: "Simulate a connected vehicle"
                        )
                    }
                    Toggle(isOn: Binding(
                        get: { env.settings.autoReconnect },
                        set: { env.settings.autoReconnect = $0 }
                    )) {
                        settingsRow(
                            icon: "arrow.clockwise.circle",
                            tint: Palette.accent,
                            title: "Auto-reconnect",
                            detail: "Reconnect to the last adapter"
                        )
                    }
                    if let preferred = env.settings.preferredAdapterID {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Palette.textTertiary)
                                .frame(width: 26)
                            Text("Last adapter ID")
                                .font(.obCallout)
                            Spacer()
                            Text(String(preferred.prefix(8)) + "…")
                                .font(.obMono(12))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    NavigationLink(value: SettingsRoute.debugLog) {
                        settingsRow(icon: "terminal", tint: Palette.textSecondary, title: "Raw OBD log", detail: "Troubleshooting")
                    }
                }

                Section("Data") {
                    NavigationLink(value: SettingsRoute.data) {
                        settingsRow(icon: "externaldrive", tint: Palette.amber, title: "Storage & reset", detail: nil)
                    }
                }

                Section {
                    NavigationLink(value: SettingsRoute.about) {
                        settingsRow(icon: "info.circle", tint: Palette.textSecondary, title: "About OBDiag", detail: version)
                    }
                } footer: {
                    Text("All vehicle data, conversations and settings stay on this device.")
                        .font(.obCaption)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appBackdrop()
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .provider: ProviderSettingsView()
                case .models: ModelSettingsView()
                case .search: SearchSettingsView()
                case .subscription: SubscriptionDetailView()
                case .units: UnitsDetailView()
                case .data: DataManagementView()
                case .about: AboutView()
                case .debugLog: DebugLogView()
                }
            }
            .onAppear {
                #if DEBUG
                // Screenshot hook, alongside the existing -startSection and
                // -attachDemoImage affordances: opens the subscribe screen
                // without needing to tap through the list.
                if ProcessInfo.processInfo.arguments.contains("-showSubscription"), path.isEmpty {
                    path.append(SettingsRoute.subscription)
                }
                #endif
            }
        }
    }

    // MARK: Subscription card

    /// Sign-in entry point, so an account can be created without going through
    /// the paywall first.
    @ViewBuilder
    private var accountSection: some View {
        switch env.auth.state {
        case .unconfigured:
            EmptyView()
        case .signedIn:
            Section("Account") {
                AccountSummaryView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        case .signedOut:
            Section("Account") {
                AccountRequiredView(
                    reason: "Sign in to use the OBDiag assistant and sync your credits across devices."
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var subscriptionSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.subscription) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Gradients.accent.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(env.subscriptions.plan.title + " plan")
                            .font(.obHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(Format.credits(env.credits.balance)) credits available")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Text("Manage")
                        .font(.obCaption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func settingsRow(icon: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.obCallout)
                    .foregroundStyle(Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var providerDetail: String {
        switch env.settings.provider {
        case .obdiag:
            guard env.auth.isSignedIn else { return "Sign in needed" }
            return "\(env.account.plan.title) · \(Format.credits(env.account.credits)) credits"
        case .demo: return "Demo assistant"
        case .openRouter: return env.settings.openRouterAPIKey.isBlank ? "API key needed" : "Connected"
        case .lmStudio: return env.settings.lmStudioBaseURL
        }
    }

    private var version: String? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}

// MARK: - Units

struct UnitsDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(UnitSystem.allCases) { system in
                    Button {
                        Haptics.selection()
                        env.settings.unitSystem = system
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(system.title)
                                    .font(.obCallout.weight(.semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(system.subtitle)
                                    .font(.obCaption)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            Spacer()
                            if env.settings.unitSystem == system {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
            } footer: {
                Text("Values are stored in metric and converted for display. The assistant answers in your preferred units.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("Units")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data management

struct DataManagementView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showResetOnboarding = false
    @State private var showClearConversations = false
    @State private var showClearGarage = false
    @State private var showResetAll = false

    var body: some View {
        List {
            Section("Storage") {
                statRow("Vehicles", "\(env.garage.vehicles.count)")
                statRow("Conversations", "\(env.conversations.conversations.count)")
                statRow("Messages", "\(env.conversations.conversations.reduce(0) { $0 + $1.messageCount })")
                statRow("Credit ledger entries", "\(env.credits.transactions.count)")
                statRow("On-disk location", "App Support/OBDiag")
            }

            Section("Reset") {
                Button {
                    showResetOnboarding = true
                } label: {
                    Label("Re-run onboarding", systemImage: "arrow.counterclockwise")
                }
                Button {
                    showClearConversations = true
                } label: {
                    Label("Delete all conversations", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                }
                .disabled(env.conversations.conversations.isEmpty)
                Button {
                    showClearGarage = true
                } label: {
                    Label("Delete all vehicles", systemImage: "car.badge.minus")
                }
                .disabled(env.garage.vehicles.isEmpty)
            }

            Section {
                Button(role: .destructive) {
                    showResetAll = true
                } label: {
                    Label("Reset OBDiag completely", systemImage: "trash")
                }
            } footer: {
                Text("Removes vehicles, conversations, cached model data and API keys from this device. Purchases are managed by your Apple ID and can be restored.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("Storage & reset")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Re-run onboarding?", isPresented: $showResetOnboarding, titleVisibility: .visible) {
            Button("Re-run onboarding") {
                env.settings.resetOnboarding()
            }
        } message: {
            Text("Your vehicles and conversations are kept.")
        }
        .confirmationDialog("Delete all conversations?", isPresented: $showClearConversations, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                env.conversations.deleteAll()
            }
        }
        .confirmationDialog("Delete all vehicles?", isPresented: $showClearGarage, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                env.garage.replaceAll(with: [])
            }
        } message: {
            Text("Conversations stay on the device but are no longer attached to a vehicle.")
        }
        .confirmationDialog("Reset everything?", isPresented: $showResetAll, titleVisibility: .visible) {
            Button("Reset everything", role: .destructive) {
                env.settings.resetEverything()
                env.garage.replaceAll(with: [])
                env.conversations.deleteAll()
                env.credits.reset()
                env.search.clearCache()
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.obCallout)
            Spacer()
            Text(value)
                .font(.obMono(13, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
