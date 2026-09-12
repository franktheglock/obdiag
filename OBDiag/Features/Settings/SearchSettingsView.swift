import SwiftUI

/// Search backend and tool configuration. Explains the trade-offs between the
/// OpenRouter server tool and the on-device DuckDuckGo / TinyFish backends.
struct SearchSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var tinyFishKeyField = ""

    var body: some View {
        List {
            Section {
                ForEach(SearchBackendKind.allCases) { backend in
                    backendRow(backend)
                }
            } header: {
                Text("Web search backend")
            } footer: {
                Text("Video and parts searches always use the on-device backends because they need domain filtering. OpenRouter's server-side search is only available with an OpenRouter key.")
            }

            if env.settings.searchBackend == .tinyFish {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Palette.accent)
                            .frame(width: 24)
                        SecureField("TinyFish API key", text: $tinyFishKeyField)
                            .font(.obMono(13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save") {
                            env.settings.tinyFishAPIKey = tinyFishKeyField.trimmed
                            Haptics.success()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(tinyFishKeyField.trimmed == env.settings.tinyFishAPIKey)
                    }
                    Link(destination: URL(string: "https://agent.tinyfish.ai/api-keys")!) {
                        HStack {
                            Image(systemName: "arrow.up.right.square").foregroundStyle(Palette.accent)
                            Text("Get a TinyFish key (free tier)")
                                .font(.obCallout)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                } header: {
                    Text("TinyFish key")
                } footer: {
                    Text("TinyFish returns structured, geo-targeted results and is free at any balance. Without a key OBDiag falls back to DuckDuckGo.")
                }
            }

            Section("Search region") {
                HStack {
                    Text("Country code")
                        .font(.obCallout)
                    Spacer()
                    TextField("US", text: Binding(
                        get: { env.settings.regionCode },
                        set: { env.settings.regionCode = String($0.uppercased().prefix(2)) }
                    ))
                    .font(.obMono(14))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                }
                HStack {
                    Text("Language code")
                        .font(.obCallout)
                    Spacer()
                    TextField("en", text: Binding(
                        get: { env.settings.languageCode },
                        set: { env.settings.languageCode = String($0.lowercased().prefix(2)) }
                    ))
                    .font(.obMono(14))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                }
            }

            Section {
                toolToggle("Web search", detail: "Facts, recalls, TSBs, specs and procedures", isOn: Binding(
                    get: { env.settings.webSearchEnabled },
                    set: { env.settings.webSearchEnabled = $0 }
                ))
                toolToggle("Video search", detail: "DIY repair walkthroughs from YouTube and Vimeo", isOn: Binding(
                    get: { env.settings.videoSearchEnabled },
                    set: { env.settings.videoSearchEnabled = $0 }
                ))
                toolToggle("Parts & tools search", detail: "Current listings and prices from major retailers", isOn: Binding(
                    get: { env.settings.partsSearchEnabled },
                    set: { env.settings.partsSearchEnabled = $0 }
                ))
                toolToggle("Read pages", detail: "Pull details from repair guides, forums and listings", isOn: Binding(
                    get: { env.settings.urlReadingEnabled },
                    set: { env.settings.urlReadingEnabled = $0 }
                ))
                toolToggle("Ask clarifying questions", detail: "Let the assistant ask you multiple-choice questions", isOn: Binding(
                    get: { env.settings.askUserEnabled },
                    set: { env.settings.askUserEnabled = $0 }
                ))
            } header: {
                Text("Tools")
            } footer: {
                Text("Disabling a tool removes it from the model's tool list entirely, which saves tokens.")
            }

            Section {
                HStack {
                    Text("Active backend")
                        .font(.obCallout)
                    Spacer()
                    Text(env.search.backendLabel)
                        .font(.obCallout.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                if let error = env.search.lastError {
                    Text(error)
                        .font(.obCaption)
                        .foregroundStyle(Palette.amber)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("Search & tools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tinyFishKeyField = env.settings.tinyFishAPIKey
        }
    }

    private func backendRow(_ backend: SearchBackendKind) -> some View {
        Button {
            Haptics.selection()
            env.settings.searchBackend = backend
        } label: {
            HStack(spacing: 13) {
                Image(systemName: backend.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(env.settings.searchBackend == backend ? Palette.accent : Palette.textSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.title)
                        .font(.obCallout.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(backend.subtitle)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if env.settings.searchBackend == backend {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func toolToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.obCallout)
                Text(detail)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .tint(Palette.accent)
    }
}

// MARK: - Model settings

struct ModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: env.chat.selectedModel.tier.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(env.chat.selectedModel.name)
                            .font(.obHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("\(env.chat.selectedModel.provider) · \(env.chat.selectedModel.contextLabel) · \(env.chat.selectedModel.priceLabel)")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.vertical, 3)
            } header: {
                Text("Current model")
            }

            ForEach(ModelTier.allCases, id: \.rawValue) { tier in
                let models = env.settings.availableModels.filter { $0.tier == tier }
                if !models.isEmpty {
                    Section {
                        ForEach(models) { model in
                            Button {
                                guard tierIsAvailable(tier) else {
                                    env.requestedSection = .settings
                                    return
                                }
                                Haptics.selection()
                                env.settings.selectedModelID = model.id
                                env.chat.modelOverride = nil
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(model.name)
                                                .font(.obCallout.weight(.semibold))
                                                .foregroundStyle(Palette.textPrimary)
                                            if model.supportsImages {
                                                Image(systemName: "eye.fill")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(Palette.accent)
                                                    .accessibilityLabel("Can view images")
                                            }
                                            if model.isRecommended {
                                                Text("recommended").font(.obMicro).foregroundStyle(Palette.success)
                                            }
                                        }
                                        Text("\(model.contextLabel) · \(model.priceLabel)")
                                            .font(.obMicro)
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    Spacer(minLength: 4)
                                    if !tierIsAvailable(tier) {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(Palette.amber)
                                    } else if env.settings.selectedModelID == model.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Palette.accent)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(tier.title) — \(tier.subtitle)")
                            Spacer()
                            if !tierIsAvailable(tier) {
                                Text("\(tierRequiredPlan(tier).title)+")
                                    .foregroundStyle(Palette.amber)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh from provider", systemImage: "arrow.clockwise")
                }
            } footer: {
                if env.settings.cachedModels.isEmpty {
                    Text("Showing the built-in recommended list. Add a provider key and refresh to load every available model.")
                } else {
                    Text("\(env.settings.cachedModels.count) models loaded from your provider.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tierIsAvailable(_ tier: ModelTier) -> Bool {
        tier <= env.subscriptions.plan.modelTierLimit
    }

    private func tierRequiredPlan(_ tier: ModelTier) -> PlanTier {
        switch tier {
        case .flash: return .free
        case .plus: return .plus
        case .max: return .pro
        }
    }

    private func refresh() async {
        switch env.settings.provider {
        case .openRouter:
            guard !env.settings.openRouterAPIKey.isBlank else { return }
            if let client = try? RemoteChatClient(kind: .openRouter, apiKey: env.settings.openRouterAPIKey, baseURLString: ""),
               let models = try? await client.fetchModels(), !models.isEmpty {
                env.settings.cachedModels = models
                env.settings.lastCatalogRefresh = Date()
            }
        case .lmStudio:
            if let client = try? RemoteChatClient(kind: .lmStudio, apiKey: "", baseURLString: env.settings.lmStudioBaseURL),
               let models = try? await client.fetchModels(), !models.isEmpty {
                env.settings.cachedModels = models
                env.settings.lmStudioModelID = models[0].id
            }
        case .demo:
            break
        }
    }
}
