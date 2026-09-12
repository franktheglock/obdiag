import SwiftUI

/// AI provider configuration: demo, OpenRouter (cloud) or LM Studio (local).
struct ProviderSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var openRouterKeyField = ""
    @State private var showKey = false
    @State private var lmStudioURLField = ""
    @State private var lmStudioModelField = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isRefreshingModels = false

    var body: some View {
        List {
            Section {
                ForEach(AIProviderKind.allCases) { provider in
                    providerRow(provider)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Requests go directly from this device to the provider you choose. OBDiag has no server and stores keys in the iOS Keychain.")
            }

            switch env.settings.provider {
            case .openRouter: openRouterSection
            case .lmStudio: lmStudioSection
            case .demo:
                Section {
                    Text("The demo assistant writes deterministic answers using your real fault codes, live data and vehicle profile. It never leaves the device and uses no credits.")
                        .font(.obCallout)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Section("Response") {
                Toggle(isOn: Binding(
                    get: { env.settings.showReasoning },
                    set: { env.settings.showReasoning = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show model thinking")
                            .font(.obCallout)
                        Text("Display the reasoning stream while the model works.")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .tint(Palette.accent)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .appBackdrop()
        .navigationTitle("AI provider")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            openRouterKeyField = env.settings.openRouterAPIKey
            lmStudioURLField = env.settings.lmStudioBaseURL
            lmStudioModelField = env.settings.lmStudioModelID
        }
    }

    // MARK: Provider rows

    private func providerRow(_ provider: AIProviderKind) -> some View {
        Button {
            Haptics.selection()
            env.settings.provider = provider
        } label: {
            HStack(spacing: 13) {
                Image(systemName: provider.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(env.settings.provider == provider ? Palette.accent : Palette.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.obCallout.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(provider.subtitle)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if env.settings.provider == provider {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.vertical, 3)
        }
    }

    // MARK: OpenRouter

    @ViewBuilder
    private var openRouterSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                if showKey {
                    TextField("sk-or-…", text: $openRouterKeyField)
                        .font(.obMono(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-or-…", text: $openRouterKeyField)
                        .font(.obMono(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button("Save key") {
                    env.settings.openRouterAPIKey = openRouterKeyField.trimmed
                    Haptics.success()
                    Task { await refreshModels() }
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .disabled(openRouterKeyField.trimmed == env.settings.openRouterAPIKey)

                Button("Clear") {
                    openRouterKeyField = ""
                    env.settings.openRouterAPIKey = ""
                    env.settings.cachedModels = []
                }
                .buttonStyle(.glass)
                .tint(Palette.danger)
                .disabled(env.settings.openRouterAPIKey.isBlank && openRouterKeyField.isBlank)
            }

            Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Palette.accent)
                    Text("Create a key at openrouter.ai/keys")
                        .font(.obCallout)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await refreshModels() }
                } label: {
                    HStack(spacing: 7) {
                        if isRefreshingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh model catalog")
                            .font(.obCallout)
                    }
                }
                .buttonStyle(.glass)
                .disabled(env.settings.openRouterAPIKey.isBlank || isRefreshingModels)

                Spacer()
                if let date = env.settings.lastCatalogRefresh {
                    Text("Updated \(Format.relative(date))")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        } header: {
            Text("OpenRouter API key")
        } footer: {
            Text("One key gives access to models from OpenAI, Anthropic, Google, xAI, DeepSeek and more. Pay-as-you-go billing stays on your OpenRouter account.")
        }
    }

    private func refreshModels() async {
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        guard !env.settings.openRouterAPIKey.isBlank else { return }
        do {
            let client = try RemoteChatClient(kind: .openRouter, apiKey: env.settings.openRouterAPIKey, baseURLString: "")
            let models = try await client.fetchModels()
            if !models.isEmpty {
                env.settings.cachedModels = models
                env.settings.lastCatalogRefresh = Date()
                if !models.contains(where: { $0.id == env.settings.selectedModelID }),
                   let replacement = models.first(where: { $0.tier == env.subscriptions.plan.modelTierLimit }) ?? models.first {
                    env.settings.selectedModelID = replacement.id
                }
            }
        } catch {
            testResult = error.localizedDescription
        }
    }

    // MARK: LM Studio

    @ViewBuilder
    private var lmStudioSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
                TextField("http://localhost:1234/v1", text: $lmStudioURLField)
                    .font(.obMono(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Model identifier")
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
                TextField("local-model", text: $lmStudioModelField)
                    .font(.obMono(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HStack(spacing: 10) {
                Button {
                    saveLMSettings()
                    Task { await testLMStudio() }
                } label: {
                    HStack(spacing: 7) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("Save & test connection")
                            .font(.obCallout)
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .disabled(isTesting)
            }
            if let testResult {
                Text(testResult)
                    .font(.obCaption)
                    .foregroundStyle(testResult.hasPrefix("Connected") ? Palette.success : Palette.amber)
            }
        } header: {
            Text("LM Studio")
        } footer: {
            Text("In LM Studio, load a tool-capable model and start the local server. On iPhone, use your Mac's IP address (e.g. http://192.168.1.20:1234/v1) and enable Local Network access when prompted.")
        }
    }

    private func saveLMSettings() {
        env.settings.lmStudioBaseURL = lmStudioURLField.trimmed
        env.settings.lmStudioModelID = lmStudioModelField.trimmed.isEmpty ? "local-model" : lmStudioModelField.trimmed
    }

    private func testLMStudio() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            let client = try RemoteChatClient(kind: .lmStudio, apiKey: "", baseURLString: env.settings.lmStudioBaseURL)
            let models = try await client.fetchModels()
            if models.isEmpty {
                testResult = "Connected, but the server reported no loaded models."
            } else {
                env.settings.cachedModels = models
                if !models.contains(where: { $0.id == env.settings.lmStudioModelID }) {
                    env.settings.lmStudioModelID = models[0].id
                }
                testResult = "Connected — \(models.count) model\(models.count == 1 ? "" : "s") available."
                Haptics.success()
            }
        } catch {
            testResult = "Could not reach LM Studio: \(error.localizedDescription)"
        }
    }
}
