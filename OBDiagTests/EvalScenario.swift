import Foundation
@testable import OBDiag

/// One evaluation scenario: a scripted vehicle state, prompt and a set of
/// expectations that deterministic graders can check.
struct EvalScenario: Codable, Identifiable {
    var id: String
    var category: String
    var title: String
    var vehicle: VehicleFixture
    var obd: OBDFixture
    var history: [TurnFixture] = []
    var prompt: String
    /// Attach a synthetic "CHECK ENGINE" photo to the prompt.
    var attachImage: Bool = false
    /// Answer used if the assistant asks a clarifying question.
    var autoAnswer: String?
    /// Canned search results, matched on keywords in the query.
    var searchFixtures: [SearchFixture] = []
    /// Extra text considered "known" by the grounding grader (e.g. a TSB the
    /// fixture would have returned).
    var groundingExtras: [String] = []
    var expect: Expectations
    var timeout: TimeInterval = 180

    // MARK: Nested fixtures

    struct VehicleFixture: Codable {
        var year: Int?
        var make: String
        var model: String
        var trim: String?
        var engine: String?
        var vin: String?
        var lastKnownCodes: [String] = []

        func vehicle() -> Vehicle {
            Vehicle(
                nickname: "",
                year: year,
                make: make,
                model: model,
                trim: trim,
                vin: vin,
                engineDescription: engine,
                fuelType: "Gasoline"
            )
        }
    }

    struct OBDFixture: Codable {
        var connected: Bool = true
        var adapterName: String = "Fixture Adapter"
        var readings: [String: Double] = [:]
        var codes: [CodeFixture] = []
        var monitor: MonitorFixture?
        var vin: String?
    }

    struct CodeFixture: Codable {
        var code: String
        var status: String
    }

    struct MonitorFixture: Codable {
        var milOn: Bool = false
        var dtcCount: Int = 0
        var misfireComplete: Bool = true
        var fuelComplete: Bool = true
        var componentsComplete: Bool = true
    }

    struct TurnFixture: Codable {
        var user: String
        var assistant: String
    }

    struct SearchFixture: Codable {
        /// Scopes this fixture answers: nil = any.
        var scope: String?
        /// Query keywords that trigger this fixture (any match).
        var matchAny: [String]
        var results: [ResultFixture]
    }

    struct ResultFixture: Codable {
        var title: String
        var url: String
        var snippet: String
    }

    struct Expectations: Codable {
        var mustCallTools: [String] = []
        var mustNotCallTools: [String] = []
        var mustMention: [String] = []
        /// Passes if any one of these appears (for "either/or" phrasings).
        var mustMentionAny: [String] = []
        var mustNotMention: [String] = []
        var requireSections: [String] = []
        var requireCitation: Bool = false
        var requireAbstention: Bool = false
        var forbidAbstention: Bool = false
        var expectAskUser: Bool = false
        var expectImageAwareness: Bool = false
        var safetyCritical: Bool = false
        /// When false, invented specs are tolerated (rarely useful).
        var requireGrounding: Bool = true
        var maxCharacters: Int?
        var notes: String?
    }
}

// MARK: - Candidate models

/// A model under evaluation, with the pricing we would pay for it.
struct EvalModel: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var tier: String
    /// USD per 1M tokens.
    var inputPrice: Double
    var outputPrice: Double
    var supportsImages: Bool = true
    var supportsReasoning: Bool = true

    var asAIModel: AIModel {
        AIModel(
            id: id,
            name: name,
            provider: String(id.split(separator: "/").first ?? "Eval"),
            contextLength: 1_000_000,
            promptPricePerToken: inputPrice / 1_000_000,
            completionPricePerToken: outputPrice / 1_000_000,
            supportsTools: true,
            supportsReasoning: supportsReasoning,
            supportsImages: supportsImages,
            isFree: false,
            isRecommended: false,
            description: nil
        )
    }

    var priceLabel: String {
        String(format: "$%.2f/$%.2f per M", inputPrice, outputPrice)
    }
}

enum EvalCatalogue {
    /// The tier models we ship plus the nearest alternatives — handy for
    /// deciding whether a swap actually improves groundedness.
    static let candidates: [EvalModel] = [
        EvalModel(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", tier: "flash",
                  inputPrice: 0.15, outputPrice: 0.60),
        EvalModel(id: "openai/gpt-5.6-luna", name: "GPT-5.6 Luna", tier: "flash",
                  inputPrice: 0.20, outputPrice: 1.20),
        EvalModel(id: "meta/muse-spark-1.3", name: "Muse Spark 1.3", tier: "plus",
                  inputPrice: 1.25, outputPrice: 4.25),
        EvalModel(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash", tier: "plus",
                  inputPrice: 0.75, outputPrice: 3.75),
        EvalModel(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", tier: "max",
                  inputPrice: 2.00, outputPrice: 10.00),
        EvalModel(id: "anthropic/claude-opus-5", name: "Claude Opus 5", tier: "max",
                  inputPrice: 5.00, outputPrice: 25.00)
    ]

    static func model(withID id: String) -> EvalModel? {
        candidates.first { $0.id == id }
    }
}

// MARK: - Loading

enum EvalScenarioLibrary {
    static func loadAll() throws -> [EvalScenario] {
        guard let url = Bundle(for: EvalBundleToken.self).url(forResource: "EvalScenarios", withExtension: "json") else {
            throw EvalError.scenariosNotFound
        }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(Document.self, from: data)
        return document.scenarios
    }

    static func load(ids: [String]) throws -> [EvalScenario] {
        let all = try loadAll()
        guard !ids.isEmpty else { return all }
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }

    private struct Document: Codable {
        var version: Int
        var scenarios: [EvalScenario]
    }
}

enum EvalError: LocalizedError {
    case scenariosNotFound
    case missingAPIKey
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .scenariosNotFound: return "EvalScenarios.json is missing from the test bundle."
        case .missingAPIKey: return "No OpenRouter key. Add one at .eval/openrouter-key or set OBDIAG_EVAL_KEY."
        case .timedOut(let scenario): return "Scenario \(scenario) exceeded its time budget."
        }
    }
}

/// Used only to locate the test bundle.
final class EvalBundleToken {}

// MARK: - Lenient decoding
//
// Scenario JSON only spells out the fields it cares about; everything with a
// default is optional at the key level.

extension EvalScenario {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        vehicle = try c.decode(VehicleFixture.self, forKey: .vehicle)
        obd = try c.decodeIfPresent(OBDFixture.self, forKey: .obd) ?? OBDFixture()
        history = try c.decodeIfPresent([TurnFixture].self, forKey: .history) ?? []
        prompt = try c.decode(String.self, forKey: .prompt)
        attachImage = try c.decodeIfPresent(Bool.self, forKey: .attachImage) ?? false
        autoAnswer = try c.decodeIfPresent(String.self, forKey: .autoAnswer)
        searchFixtures = try c.decodeIfPresent([SearchFixture].self, forKey: .searchFixtures) ?? []
        groundingExtras = try c.decodeIfPresent([String].self, forKey: .groundingExtras) ?? []
        expect = try c.decodeIfPresent(Expectations.self, forKey: .expect) ?? Expectations()
        timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 180
    }
}

extension EvalScenario.VehicleFixture {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        make = try c.decode(String.self, forKey: .make)
        model = try c.decode(String.self, forKey: .model)
        trim = try c.decodeIfPresent(String.self, forKey: .trim)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        vin = try c.decodeIfPresent(String.self, forKey: .vin)
        lastKnownCodes = try c.decodeIfPresent([String].self, forKey: .lastKnownCodes) ?? []
    }
}

extension EvalScenario.OBDFixture {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? true
        adapterName = try c.decodeIfPresent(String.self, forKey: .adapterName) ?? "Fixture Adapter"
        readings = try c.decodeIfPresent([String: Double].self, forKey: .readings) ?? [:]
        codes = try c.decodeIfPresent([EvalScenario.CodeFixture].self, forKey: .codes) ?? []
        monitor = try c.decodeIfPresent(EvalScenario.MonitorFixture.self, forKey: .monitor)
        vin = try c.decodeIfPresent(String.self, forKey: .vin)
    }
}

extension EvalScenario.MonitorFixture {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        milOn = try c.decodeIfPresent(Bool.self, forKey: .milOn) ?? false
        dtcCount = try c.decodeIfPresent(Int.self, forKey: .dtcCount) ?? 0
        misfireComplete = try c.decodeIfPresent(Bool.self, forKey: .misfireComplete) ?? true
        fuelComplete = try c.decodeIfPresent(Bool.self, forKey: .fuelComplete) ?? true
        componentsComplete = try c.decodeIfPresent(Bool.self, forKey: .componentsComplete) ?? true
    }
}

extension EvalScenario.SearchFixture {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        matchAny = try c.decodeIfPresent([String].self, forKey: .matchAny) ?? []
        results = try c.decodeIfPresent([EvalScenario.ResultFixture].self, forKey: .results) ?? []
    }
}

extension EvalScenario.Expectations {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mustCallTools = try c.decodeIfPresent([String].self, forKey: .mustCallTools) ?? []
        mustNotCallTools = try c.decodeIfPresent([String].self, forKey: .mustNotCallTools) ?? []
        mustMention = try c.decodeIfPresent([String].self, forKey: .mustMention) ?? []
        mustMentionAny = try c.decodeIfPresent([String].self, forKey: .mustMentionAny) ?? []
        mustNotMention = try c.decodeIfPresent([String].self, forKey: .mustNotMention) ?? []
        requireSections = try c.decodeIfPresent([String].self, forKey: .requireSections) ?? []
        requireCitation = try c.decodeIfPresent(Bool.self, forKey: .requireCitation) ?? false
        requireAbstention = try c.decodeIfPresent(Bool.self, forKey: .requireAbstention) ?? false
        forbidAbstention = try c.decodeIfPresent(Bool.self, forKey: .forbidAbstention) ?? false
        expectAskUser = try c.decodeIfPresent(Bool.self, forKey: .expectAskUser) ?? false
        expectImageAwareness = try c.decodeIfPresent(Bool.self, forKey: .expectImageAwareness) ?? false
        safetyCritical = try c.decodeIfPresent(Bool.self, forKey: .safetyCritical) ?? false
        requireGrounding = try c.decodeIfPresent(Bool.self, forKey: .requireGrounding) ?? true
        maxCharacters = try c.decodeIfPresent(Int.self, forKey: .maxCharacters)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

extension EvalModel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tier = try c.decode(String.self, forKey: .tier)
        inputPrice = try c.decode(Double.self, forKey: .inputPrice)
        outputPrice = try c.decode(Double.self, forKey: .outputPrice)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? true
        supportsReasoning = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? true
    }
}
