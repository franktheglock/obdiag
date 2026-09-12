import Foundation

// MARK: - StoreKit catalog

/// Product identifiers. Keep in sync with `Resources/StoreKit/OBDiag.storekit`
/// and App Store Connect.
enum StoreProduct {
    static let plusMonthly = "com.obdiag.plus.monthly"
    static let plusYearly = "com.obdiag.plus.yearly"
    static let proMonthly = "com.obdiag.pro.monthly"
    static let proYearly = "com.obdiag.pro.yearly"
    static let credits500 = "com.obdiag.credits.500"
    static let credits1500 = "com.obdiag.credits.1500"
    static let credits4000 = "com.obdiag.credits.4000"

    static let subscriptions: Set<String> = [plusMonthly, plusYearly, proMonthly, proYearly]
    static let consumables: Set<String> = [credits500, credits1500, credits4000]
    static let all: Set<String> = subscriptions.union(consumables)

    static func plan(for productID: String) -> PlanTier? {
        switch productID {
        case plusMonthly, plusYearly: return .plus
        case proMonthly, proYearly: return .pro
        default: return nil
        }
    }

    static func credits(for productID: String) -> Int? {
        switch productID {
        case credits500: return 500
        case credits1500: return 1_500
        case credits4000: return 4_000
        default: return nil
        }
    }
}

/// Presentable subscription offer, used by onboarding upsell and settings.
struct PlanOffer: Identifiable, Hashable {
    var id: String
    var tier: PlanTier
    var period: Period
    var displayPrice: String
    var isRecommended: Bool

    enum Period: String {
        case monthly, yearly
        var title: String { self == .monthly ? "Monthly" : "Yearly" }
        var badge: String? { self == .yearly ? "Save up to 33%" : nil }
    }

    var title: String { "\(tier.title) · \(period.title)" }
}

/// Features that can be gated by plan; used to present honest upsells.
enum PremiumFeature: String {
    case plusModels
    case maxModels
    case creditPacks

    var requiredTier: PlanTier {
        switch self {
        case .plusModels: return .plus
        case .maxModels: return .pro
        case .creditPacks: return .plus
        }
    }

    var title: String {
        switch self {
        case .plusModels: return "Plus models"
        case .maxModels: return "Max models"
        case .creditPacks: return "Credit packs"
        }
    }

    var message: String {
        switch self {
        case .plusModels:
            return "Deeper-reasoning models like Claude Sonnet and GPT-4o come with Plus."
        case .maxModels:
            return "Frontier models such as Claude Opus and GPT-5 are available on Pro."
        case .creditPacks:
            return "Top up your balance any time with a credit pack."
        }
    }
}
