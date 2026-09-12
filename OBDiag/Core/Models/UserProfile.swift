import Foundation

// MARK: - Credits, plans & entitlements

enum PlanTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case plus
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        }
    }

    /// Highest model tier this plan may use.
    var modelTierLimit: ModelTier {
        switch self {
        case .free: return .flash
        case .plus: return .plus
        case .pro: return .max
        }
    }

    /// Credits granted at the start of each billing month.
    var monthlyCredits: Int {
        switch self {
        case .free: return 150
        case .plus: return 2_500
        case .pro: return 8_000
        }
    }

    /// Spending multiplier — lower plans burn credits faster.
    var creditMultiplier: Double {
        switch self {
        case .free: return 1.5
        case .plus: return 1.2
        case .pro: return 1.0
        }
    }

    var features: [String] {
        switch self {
        case .free:
            return [
                "Live sensor dashboard & fault codes",
                "150 AI credits every month",
                "Flash-tier models",
                "Web, video & parts search",
                "Unlimited local conversations"
            ]
        case .plus:
            return [
                "Everything in Free",
                "2,500 AI credits every month",
                "Plus-tier models with deeper reasoning",
                "Priority streaming",
                "Conversation history across vehicles"
            ]
        case .pro:
            return [
                "Everything in Plus",
                "8,000 AI credits every month",
                "Max-tier frontier models",
                "Lowest credit burn rate",
                "Early access to new tools"
            ]
        }
    }
}

enum CreditReason: String, Codable, Sendable {
    case welcome
    case monthlyGrant
    case purchase
    case chat
    case adjustment

    var title: String {
        switch self {
        case .welcome: return "Welcome bonus"
        case .monthlyGrant: return "Monthly allowance"
        case .purchase: return "Credit pack"
        case .chat: return "AI usage"
        case .adjustment: return "Adjustment"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "gift.fill"
        case .monthlyGrant: return "calendar.badge.plus"
        case .purchase: return "bag.fill"
        case .chat: return "sparkles"
        case .adjustment: return "wrench.and.screwdriver.fill"
        }
    }
}

struct CreditTransaction: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    /// Negative for spend, positive for grants.
    var amount: Int
    var reason: CreditReason
    var note: String
    var balanceAfter: Int
    var modelID: String?
}

/// Converts model usage into credits.
///
///   credits = ceil( usd_cost ÷ $0.001 × plan_multiplier ), minimum 1
///   usd_cost = reported provider cost, or
///              prompt_tokens × input_price + completion_tokens × output_price
///
/// Plan multipliers: Free ×1.5, Plus ×1.2, Pro ×1.0. Local and demo models are
/// free. Prices come from the live model catalog the app fetches from the
/// provider, so a credit always tracks real model cost.
enum CreditPricing {
    /// 1 credit ≈ $0.001 of model usage, scaled by plan.
    static let usdPerCredit: Double = 0.001
    static let minimumCharge = 1

    static func credits(for usage: TokenUsage, model: AIModel, plan: PlanTier) -> Int {
        let usd = usage.costUSD > 0 ? usage.costUSD : model.estimatedCost(for: usage)
        guard usd > 0 else { return 0 }
        let raw = usd / usdPerCredit * plan.creditMultiplier
        return max(minimumCharge, Int(ceil(raw)))
    }

    /// Worked example used in the subscription explainer.
    static func exampleCost(plan: PlanTier) -> (credits: Int, usd: Double, tokens: Int) {
        let model = AIModel.fallbackCatalog[0] // Gemini 3.8 Flash
        let usage = TokenUsage(promptTokens: 3_000, completionTokens: 800, totalTokens: 3_800)
        let usd = model.estimatedCost(for: usage)
        return (credits(for: usage, model: model, plan: plan), usd, usage.totalTokens)
    }
}

// MARK: - Onboarding

struct OnboardingAnswers: Codable, Hashable, Sendable {
    var garageSize: GarageSize?
    var vehicleAge: VehicleAge?
    var discoverySource: DiscoverySource?
    var goals: Set<Goal> = []
    var experience: ExperienceLevel?
    var wantsVehicleSetup: Bool = true

    enum GarageSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case one, two, threePlus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .one: return "Just one"
            case .two: return "Two vehicles"
            case .threePlus: return "Three or more"
            }
        }
        var icon: String {
            switch self {
            case .one: return "car.fill"
            case .two: return "car.2.fill"
            case .threePlus: return "car.2.fill"
            }
        }
    }

    enum VehicleAge: String, Codable, CaseIterable, Identifiable, Sendable {
        case brandNew, recent, older, classic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brandNew: return "2023 or newer"
            case .recent: return "2015 – 2022"
            case .older: return "2005 – 2014"
            case .classic: return "Before 2005"
            }
        }
        var subtitle: String {
            switch self {
            case .brandNew: return "Under warranty, mostly OBD-II standard PID"
            case .recent: return "Full OBD-II with some manufacturer data"
            case .older: return "OBD-II era, more wear items"
            case .classic: return "Pre-CAN — limited live data"
            }
        }
    }

    enum DiscoverySource: String, Codable, CaseIterable, Identifiable, Sendable {
        case appStore, friend, youtube, forum, search, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appStore: return "App Store"
            case .friend: return "A friend or family member"
            case .youtube: return "YouTube"
            case .forum: return "A car forum"
            case .search: return "Web search"
            case .other: return "Somewhere else"
            }
        }
    }

    enum Goal: String, Codable, CaseIterable, Identifiable, Sendable {
        case diagnose, saveMoney, maintain, learn, performance
        var id: String { rawValue }
        var title: String {
            switch self {
            case .diagnose: return "Figure out a warning light"
            case .saveMoney: return "Avoid unnecessary shop visits"
            case .maintain: return "Stay ahead of maintenance"
            case .learn: return "Learn how my car works"
            case .performance: return "Track performance & health"
            }
        }
        var icon: String {
            switch self {
            case .diagnose: return "exclamationmark.triangle"
            case .saveMoney: return "dollarsign.circle"
            case .maintain: return "calendar.badge.clock"
            case .learn: return "book"
            case .performance: return "gauge.with.dots.needle.67percent"
            }
        }
    }

    enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        case beginner, intermediate, expert
        var id: String { rawValue }
        var title: String {
            switch self {
            case .beginner: return "I just drive it"
            case .intermediate: return "I do basic maintenance"
            case .expert: return "I turn my own wrenches"
            }
        }
        var subtitle: String {
            switch self {
            case .beginner: return "Explain things in plain language"
            case .intermediate: return "Comfortable with tools and parts"
            case .expert: return "Give me the technical detail"
            }
        }
    }

    /// System-prompt guidance derived from the questionnaire.
    var assistantStyleGuide: String {
        var lines: [String] = []
        switch experience {
        case .beginner:
            lines.append("Explain in plain language; avoid unexplained jargon and define terms the first time.")
        case .intermediate:
            lines.append("Use standard automotive terms, briefly explaining anything advanced.")
        case .expert:
            lines.append("Assume professional familiarity; include specs, torque values, and diagnostic detail.")
        case .none:
            break
        }
        if goals.contains(.saveMoney) {
            lines.append("Call out which steps a shop should do versus what the owner can do cheaply at home.")
        }
        if goals.contains(.maintain) {
            lines.append("Mention maintenance items that often accompany this problem.")
        }
        if goals.contains(.learn) {
            lines.append("Briefly explain how the affected system works so the owner learns something.")
        }
        if goals.contains(.performance) {
            lines.append("Note any performance or drivability implications.")
        }
        return lines.joined(separator: " ")
    }
}
