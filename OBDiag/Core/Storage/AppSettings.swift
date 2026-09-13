import Foundation
import Observation

/// User preferences. Non-secret values live in UserDefaults; API keys live in
/// the Keychain. Every mutation persists immediately — the dataset is tiny.
@MainActor
@Observable
final class AppSettings {
    // MARK: Onboarding
    var onboardingComplete: Bool = false { didSet { scheduleSave() } }
    var onboardingAnswers = OnboardingAnswers() { didSet { scheduleSave() } }

    // MARK: Units & locale
    var unitSystem: UnitSystem = .imperial { didSet { scheduleSave() } }
    var regionCode: String = "US" { didSet { scheduleSave() } }
    var languageCode: String = "en" { didSet { scheduleSave() } }

    // MARK: Assistant
    var provider: AIProviderKind = .demo { didSet { scheduleSave() } }
    var selectedModelID: String = AIModel.defaultModelID { didSet { scheduleSave() } }
    var lmStudioBaseURL: String = "http://localhost:1234/v1" { didSet { scheduleSave() } }
    var lmStudioModelID: String = "local-model" { didSet { scheduleSave() } }
    var cachedModels: [AIModel] = [] { didSet { scheduleSave() } }
    var lastCatalogRefresh: Date? { didSet { scheduleSave() } }
    var showReasoning: Bool = true { didSet { scheduleSave() } }

    // MARK: Tools
    var searchBackend: SearchBackendKind = .automatic { didSet { scheduleSave() } }
    var webSearchEnabled = true { didSet { scheduleSave() } }
    var videoSearchEnabled = true { didSet { scheduleSave() } }
    var partsSearchEnabled = true { didSet { scheduleSave() } }
    var urlReadingEnabled = true { didSet { scheduleSave() } }
    var askUserEnabled = true { didSet { scheduleSave() } }

    // MARK: Hardware
    var demoAdapterEnabled = false { didSet { scheduleSave() } }
    var autoReconnect = true { didSet { scheduleSave() } }
    var preferredAdapterID: String? { didSet { scheduleSave() } }

    // MARK: Feel
    var hapticsEnabled = true { didSet { scheduleSave(); Haptics.isEnabled = hapticsEnabled } }

    // MARK: Secrets (Keychain-backed)
    var openRouterAPIKey: String = "" {
        didSet {
            Keychain.set(openRouterAPIKey, for: .openRouterAPIKey)
        }
    }
    var tinyFishAPIKey: String = "" {
        didSet { Keychain.set(tinyFishAPIKey, for: .tinyFishAPIKey) }
    }

    /// Available models: live catalog when present, curated fallback otherwise.
    var availableModels: [AIModel] {
        cachedModels.isEmpty ? AIModel.fallbackCatalog : cachedModels
    }

    var selectedModel: AIModel {
        availableModels.first(where: { $0.id == selectedModelID })
            ?? availableModels.first(where: { $0.tier == .flash })
            ?? AIModel.fallbackCatalog[0]
    }

    func model(withID id: String) -> AIModel? {
        availableModels.first(where: { $0.id == id })
    }

    // MARK: Init
    private static let defaultsKey = "obdiag.settings.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let snapshot = try? JSONDecoder.settings.decode(Snapshot.self, from: data) {
            apply(snapshot)
        }
        openRouterAPIKey = Keychain.get(.openRouterAPIKey) ?? ""
        tinyFishAPIKey = Keychain.get(.tinyFishAPIKey) ?? ""
        Haptics.isEnabled = hapticsEnabled
        isLoaded = true
    }

    // MARK: Persistence
    private func apply(_ snapshot: Snapshot) {
        onboardingComplete = snapshot.onboardingComplete
        onboardingAnswers = snapshot.onboardingAnswers
        unitSystem = snapshot.unitSystem
        regionCode = snapshot.regionCode
        languageCode = snapshot.languageCode
        provider = snapshot.provider
        selectedModelID = snapshot.selectedModelID
        lmStudioBaseURL = snapshot.lmStudioBaseURL
        lmStudioModelID = snapshot.lmStudioModelID
        cachedModels = snapshot.cachedModels
        lastCatalogRefresh = snapshot.lastCatalogRefresh
        showReasoning = snapshot.showReasoning
        searchBackend = snapshot.searchBackend
        webSearchEnabled = snapshot.webSearchEnabled
        videoSearchEnabled = snapshot.videoSearchEnabled
        partsSearchEnabled = snapshot.partsSearchEnabled
        urlReadingEnabled = snapshot.urlReadingEnabled
        askUserEnabled = snapshot.askUserEnabled
        demoAdapterEnabled = snapshot.demoAdapterEnabled
        autoReconnect = snapshot.autoReconnect
        preferredAdapterID = snapshot.preferredAdapterID
        hapticsEnabled = snapshot.hapticsEnabled
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        let snapshot = Snapshot(from: self)
        guard let data = try? JSONEncoder.settings.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Forces a write; used on app background.
    func flush() { saveNow() }

    struct Snapshot: Codable {
        var onboardingComplete = false
        var onboardingAnswers = OnboardingAnswers()
        var unitSystem: UnitSystem = .imperial
        var regionCode = "US"
        var languageCode = "en"
        var provider: AIProviderKind = .demo
        var selectedModelID = AIModel.defaultModelID
        var lmStudioBaseURL = "http://localhost:1234/v1"
        var lmStudioModelID = "local-model"
        var cachedModels: [AIModel] = []
        var lastCatalogRefresh: Date?
        var showReasoning = true
        var searchBackend: SearchBackendKind = .automatic
        var webSearchEnabled = true
        var videoSearchEnabled = true
        var partsSearchEnabled = true
        var urlReadingEnabled = true
        var askUserEnabled = true
        var demoAdapterEnabled = false
        var autoReconnect = true
        var preferredAdapterID: String?
        var hapticsEnabled = true

        init() {}

        @MainActor
        init(from settings: AppSettings) {
            onboardingComplete = settings.onboardingComplete
            onboardingAnswers = settings.onboardingAnswers
            unitSystem = settings.unitSystem
            regionCode = settings.regionCode
            languageCode = settings.languageCode
            provider = settings.provider
            selectedModelID = settings.selectedModelID
            lmStudioBaseURL = settings.lmStudioBaseURL
            lmStudioModelID = settings.lmStudioModelID
            cachedModels = settings.cachedModels
            lastCatalogRefresh = settings.lastCatalogRefresh
            showReasoning = settings.showReasoning
            searchBackend = settings.searchBackend
            webSearchEnabled = settings.webSearchEnabled
            videoSearchEnabled = settings.videoSearchEnabled
            partsSearchEnabled = settings.partsSearchEnabled
            urlReadingEnabled = settings.urlReadingEnabled
            askUserEnabled = settings.askUserEnabled
            demoAdapterEnabled = settings.demoAdapterEnabled
            autoReconnect = settings.autoReconnect
            preferredAdapterID = settings.preferredAdapterID
            hapticsEnabled = settings.hapticsEnabled
        }
    }

    // MARK: Reset helpers
    func completeOnboarding(with answers: OnboardingAnswers) {
        onboardingAnswers = answers
        onboardingComplete = true
    }

    func resetOnboarding() {
        onboardingComplete = false
        onboardingAnswers = OnboardingAnswers()
    }

    func resetEverything() {
        FileStore.deleteAll()
        Keychain.delete(.openRouterAPIKey)
        Keychain.delete(.tinyFishAPIKey)
        Keychain.delete(.lmStudioAPIKey)
        defaults.removeObject(forKey: Self.defaultsKey)
        onboardingComplete = false
        onboardingAnswers = OnboardingAnswers()
        unitSystem = .imperial
        provider = .demo
        selectedModelID = AIModel.defaultModelID
        cachedModels = []
        showReasoning = true
        searchBackend = .automatic
        webSearchEnabled = true
        videoSearchEnabled = true
        partsSearchEnabled = true
        urlReadingEnabled = true
        askUserEnabled = true
        demoAdapterEnabled = false
        autoReconnect = true
        preferredAdapterID = nil
        hapticsEnabled = true
        openRouterAPIKey = ""
        tinyFishAPIKey = ""
        saveNow()
    }
}

private extension JSONEncoder {
    static let settings: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let settings: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
