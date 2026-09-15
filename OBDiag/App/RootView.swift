import SwiftUI

/// Top-level sections. On iPhone these are tabs; on iPad they populate the
/// navigation split view sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case garage
    case dashboard
    case chat
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .garage: return "Garage"
        case .dashboard: return "Live"
        case .chat: return "Assistant"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .garage: return "car.2.fill"
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .chat: return "bubble.left.and.text.bubble.right.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Root gate: onboarding → adaptive shell. Also hosts the global connection
/// banner so adapter state is visible anywhere in the app.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var section: AppSection = .garage

    var body: some View {
        Group {
            if env.settings.onboardingComplete {
                if sizeClass == .regular {
                    RegularRootView(section: $section)
                } else {
                    CompactRootView(section: $section)
                }
            } else {
                OnboardingFlow()
            }
        }
        .overlay(alignment: .top) {
            GlobalConnectionBanner(section: $section)
        }
        .animation(.smooth(duration: 0.35), value: env.settings.onboardingComplete)
        .onChange(of: env.requestedSection) { _, requested in
            if let requested {
                section = requested
                env.requestedSection = nil
            }
        }
        .onAppear {
            if let requested = env.requestedSection {
                section = requested
                env.requestedSection = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                env.settings.flush()
                env.garage.persist()
                env.conversations.persist()
                env.credits.persist()
            }
        }
    }
}

// MARK: - iPhone

struct CompactRootView: View {
    @Binding var section: AppSection
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView(selection: $section) {
                Tab(AppSection.garage.title, systemImage: AppSection.garage.icon, value: AppSection.garage) {
                    GarageView()
                }
                Tab(AppSection.dashboard.title, systemImage: AppSection.dashboard.icon, value: AppSection.dashboard) {
                    VehicleDashboardView()
                }
                Tab(AppSection.chat.title, systemImage: AppSection.chat.icon, value: AppSection.chat) {
                    AIChatView()
                }
                Tab(AppSection.settings.title, systemImage: AppSection.settings.icon, value: AppSection.settings) {
                    SettingsView()
                }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - iPad

struct RegularRootView: View {
    @Binding var section: AppSection
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppSection?>(
                get: { section },
                set: { if let value = $0 { section = value } }
            )) {
                Section {
                    ForEach(AppSection.allCases) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
                if let vehicle = env.garage.selectedVehicle {
                    Section("Current vehicle") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.displayName)
                                .font(.obCallout.weight(.semibold))
                            Text(vehicle.subtitle.isEmpty ? "Tap Garage to change" : vehicle.subtitle)
                                .font(.obCaption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("OBDiag")
            .scrollContentBackground(.hidden)
        } detail: {
            NavigationStack {
                switch section {
                case .garage: GarageView()
                case .dashboard: VehicleDashboardView()
                case .chat: AIChatView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
