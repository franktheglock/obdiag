import Foundation

/// Capability/cost tiers shown to users. "Flash / Plus / Max" is the
/// simplified language; the underlying model ID is always available in detail
/// views for power users.
enum ModelTier: Int, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case flash = 0
    case plus = 1
    case max = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .flash: return "Flash"
        case .plus: return "Plus"
        case .max: return "Max"
        }
    }

    var subtitle: String {
        switch self {
        case .flash: return "Fastest, lowest cost"
        case .plus: return "Balanced everyday diagnosis"
        case .max: return "Deepest reasoning"
        }
    }

    var icon: String {
        switch self {
        case .flash: return "bolt.fill"
        case .plus: return "bolt.badge.automatic.fill"
        case .max: return "brain.head.profile.fill"
        }
    }

    static func < (lhs: ModelTier, rhs: ModelTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A model available to the assistant, normalized across providers.
struct AIModel: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var provider: String
    var contextLength: Int
    var promptPricePerToken: Double
    var completionPricePerToken: Double
    var supportsTools: Bool
    var supportsReasoning: Bool
    var supportsImages: Bool
    var isFree: Bool
    var isRecommended: Bool
    var description: String?

    /// Tiers are derived from input price per million tokens, which is the
    /// best proxy users have for "what will this cost me":
    /// Flash < $1/M · Plus $1–5/M · Max > $5/M. Free models are always Flash.
    var tier: ModelTier {
        if isFree || promptPricePerToken == 0 { return .flash }
        let promptPerMillion = promptPricePerToken * 1_000_000
        if promptPerMillion < 1 { return .flash }
        if promptPerMillion <= 5 { return .plus }
        return .max
    }

    var tierIsEstimated: Bool { !isFree && promptPricePerToken == 0 }

    var priceLabel: String {
        if isFree { return "Free" }
        let perMillion = (promptPricePerToken + completionPricePerToken) / 2 * 1_000_000
        if perMillion == 0 { return "—" }
        if perMillion < 1 { return String(format: "$%.3f/M tokens", perMillion) }
        return String(format: "$%.2f/M tokens", perMillion)
    }

    var contextLabel: String {
        if contextLength >= 1_000_000 { return "\(contextLength / 1_000_000)M context" }
        if contextLength >= 1_000 { return "\(contextLength / 1_000)K context" }
        return "\(contextLength) context"
    }

    func estimatedCost(for usage: TokenUsage) -> Double {
        Double(usage.promptTokens) * promptPricePerToken
            + Double(usage.completionTokens) * completionPricePerToken
    }

    /// Default model offered to new users.
    static let defaultModelID = "google/gemini-3.8-flash"

    /// Curated fallback catalog used before the live catalog loads (or when
    /// there is no API key yet). IDs and prices verified against OpenRouter's
    /// public model list, September 2026.
    static let fallbackCatalog: [AIModel] = [
        // MARK: Flash — fast and cheap
        AIModel(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash", provider: "Google",
                contextLength: 1_048_576, promptPricePerToken: 0.75e-6, completionPricePerToken: 3.75e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: true, description: "Fast, current-generation generalist with vision and strong tool use. The default for everyday diagnosis."),
        AIModel(id: "openai/gpt-5.6-luna", name: "GPT-5.6 Luna", provider: "OpenAI",
                contextLength: 1_048_576, promptPricePerToken: 0.20e-6, completionPricePerToken: 1.20e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: true, description: "OpenAI's value tier — excellent price/performance with vision."),
        AIModel(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", provider: "DeepSeek",
                contextLength: 1_048_576, promptPricePerToken: 0.15e-6, completionPricePerToken: 0.60e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Very cheap, vision-capable, million-token context."),
        AIModel(id: "x-ai/grok-4.3", name: "Grok 4.3", provider: "xAI",
                contextLength: 1_000_000, promptPricePerToken: 1.25e-6, completionPricePerToken: 2.50e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Fast frontier model with live knowledge and vision."),

        // MARK: Plus — balanced everyday power
        AIModel(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", provider: "Anthropic",
                contextLength: 1_000_000, promptPricePerToken: 2.00e-6, completionPricePerToken: 10.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: true, description: "Careful, well-cited reasoning — a strong default for real diagnostic work."),
        AIModel(id: "x-ai/grok-4.6", name: "Grok 4.6", provider: "xAI",
                contextLength: 500_000, promptPricePerToken: 2.00e-6, completionPricePerToken: 6.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Frontier reasoning at a mid-tier price."),
        AIModel(id: "openai/gpt-5.6-sol", name: "GPT-5.6 Sol", provider: "OpenAI",
                contextLength: 1_048_576, promptPricePerToken: 2.00e-6, completionPricePerToken: 10.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "OpenAI's mid tier with strong tool calling."),
        AIModel(id: "google/gemini-3.5-flash", name: "Gemini 3.5 Flash", provider: "Google",
                contextLength: 1_048_576, promptPricePerToken: 1.50e-6, completionPricePerToken: 9.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Previous-generation Flash with a proven track record."),
        AIModel(id: "qwen/qwen3.8-max-0902", name: "Qwen 3.8 Max", provider: "Qwen",
                contextLength: 1_000_000, promptPricePerToken: 2.00e-6, completionPricePerToken: 6.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Strong open-weight family flagship with vision."),
        AIModel(id: "moonshotai/kimi-k3", name: "Kimi K3", provider: "Moonshot",
                contextLength: 1_048_576, promptPricePerToken: 2.30e-6, completionPricePerToken: 11.55e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Long-context agentic model with good tool use."),
        AIModel(id: "z-ai/glm-5.3", name: "GLM-5.3", provider: "Z.ai",
                contextLength: 1_310_720, promptPricePerToken: 1.40e-6, completionPricePerToken: 4.40e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: false, isFree: false,
                isRecommended: false, description: "High-value frontier model with a huge context window."),

        // MARK: Max — frontier reasoning
        AIModel(id: "anthropic/claude-opus-5", name: "Claude Opus 5", provider: "Anthropic",
                contextLength: 1_000_000, promptPricePerToken: 5.00e-6, completionPricePerToken: 25.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: true, description: "Anthropic's frontier model for the hardest, most ambiguous faults."),
        AIModel(id: "openai/gpt-6-astra", name: "GPT-6 Astra", provider: "OpenAI",
                contextLength: 1_050_000, promptPricePerToken: 10.00e-6, completionPricePerToken: 50.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "OpenAI's flagship — deepest reasoning, highest cost."),
        AIModel(id: "anthropic/claude-fable-5.1", name: "Claude Fable 5.1", provider: "Anthropic",
                contextLength: 1_000_000, promptPricePerToken: 10.00e-6, completionPricePerToken: 50.00e-6,
                supportsTools: true, supportsReasoning: true, supportsImages: true, isFree: false,
                isRecommended: false, description: "Anthropic's newest frontier tier (limited availability)."),

        // MARK: Free
        AIModel(id: "google/gemma-4-31b-it:free", name: "Gemma 4 31B (free)", provider: "Google",
                contextLength: 262_144, promptPricePerToken: 0, completionPricePerToken: 0,
                supportsTools: true, supportsReasoning: false, supportsImages: true, isFree: true,
                isRecommended: false, description: "No-cost vision option for straightforward questions."),
        AIModel(id: "thinkingmachines/inkling:free", name: "Inkling (free)", provider: "Thinking Machines",
                contextLength: 1_048_576, promptPricePerToken: 0, completionPricePerToken: 0,
                supportsTools: true, supportsReasoning: false, supportsImages: true, isFree: true,
                isRecommended: false, description: "Free million-token-context model with vision.")
    ]
}

/// Local and remote provider choices for the assistant.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Managed service: the key lives on the server and usage is metered in
    /// credits. This is the default, and the only provider most users need.
    case obdiag
    /// Bring-your-own-key. Kept for power users who'd rather pay OpenRouter
    /// directly than subscribe.
    case openRouter
    case lmStudio
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .obdiag: return "OBDiag AI"
        case .openRouter: return "OpenRouter (your key)"
        case .lmStudio: return "LM Studio (local)"
        case .demo: return "Demo assistant"
        }
    }

    var subtitle: String {
        switch self {
        case .obdiag: return "Included with your plan. No API key needed."
        case .openRouter: return "Use your own OpenRouter key — you pay them directly."
        case .lmStudio: return "Run a model on your Mac or PC — nothing leaves your network."
        case .demo: return "Scripted answers so you can explore without any setup."
        }
    }

    var icon: String {
        switch self {
        case .obdiag: return "bolt.badge.automatic.fill"
        case .openRouter: return "cloud.fill"
        case .lmStudio: return "desktopcomputer"
        case .demo: return "sparkles"
        }
    }
}
