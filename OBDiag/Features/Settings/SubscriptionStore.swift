import Foundation
import StoreKit
import Observation

/// StoreKit 2 entitlement manager. Owns the plan, purchases and credit grants.
@MainActor
@Observable
final class SubscriptionStore {
    private(set) var products: [Product] = []
    private(set) var plan: PlanTier = .free
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var lastError: String?
    private(set) var currentSubscription: Product.SubscriptionInfo.Status?
    private(set) var renewalDate: Date?

    private let credits: CreditLedger
    private var updatesTask: Task<Void, Never>?

    init(credits: CreditLedger) {
        self.credits = credits
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                await self.handle(transactionResult: update)
            }
        }
        Task { await refresh() }
    }

    // MARK: Catalog

    var subscriptionOffers: [Product] {
        products
            .filter { StoreProduct.subscriptions.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsTier = StoreProduct.plan(for: lhs.id) ?? .free
                let rhsTier = StoreProduct.plan(for: rhs.id) ?? .free
                if lhsTier != rhsTier { return lhsTier.rawValue < rhsTier.rawValue }
                return lhs.id.contains("yearly") && !rhs.id.contains("yearly")
            }
    }

    var creditPacks: [Product] {
        products
            .filter { StoreProduct.consumables.contains($0.id) }
            .sorted { (StoreProduct.credits(for: $0.id) ?? 0) < (StoreProduct.credits(for: $1.id) ?? 0) }
    }

    func offer(for product: Product) -> PlanOffer? {
        guard let tier = StoreProduct.plan(for: product.id) else { return nil }
        let period: PlanOffer.Period = product.id.contains("yearly") ? .yearly : .monthly
        return PlanOffer(id: product.id, tier: tier, period: period, displayPrice: product.displayPrice, isRecommended: period == .yearly)
    }

    /// Yearly monthly-equivalent savings versus monthly billing, if both exist.
    func savingsLabel(for product: Product) -> String? {
        guard product.id.contains("yearly"),
              let monthly = products.first(where: {
                  $0.id == product.id.replacingOccurrences(of: "yearly", with: "monthly") && $0.id != product.id
              }) else { return nil }
        let yearlyMonthly = product.price / Decimal(12)
        guard monthly.price > 0 else { return nil }
        let ratio = yearlyMonthly / monthly.price
        let savings = Decimal(1) - ratio
        guard savings > Decimal(0.02) else { return nil }
        let percent = NSDecimalNumber(decimal: savings * 100).doubleValue
        return "Save \(Int(percent.rounded()))%"
    }

    // MARK: Refresh

    func refresh() async {
        await loadProducts()
        await updateEntitlements()
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: StoreProduct.all)
        } catch {
            lastError = "Could not load the store: \(error.localizedDescription)"
        }
    }

    func updateEntitlements() async {
        var activePlan: PlanTier = .free
        var activeStatus: Product.SubscriptionInfo.Status?
        var activeRenewal: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let tier = StoreProduct.plan(for: transaction.productID) {
                if tier.rawValue > activePlan.rawValue { activePlan = tier }
                if let status = await transaction.subscriptionStatus {
                    activeStatus = status
                    if case .verified(let renewalTransaction) = status.transaction {
                        activeRenewal = renewalTransaction.expirationDate
                    }
                }
            }
        }
        plan = activePlan
        currentSubscription = activeStatus
        renewalDate = activeRenewal
        credits.applyMonthlyGrantIfNeeded(plan: activePlan)
    }

    // MARK: Purchasing

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(transactionResult: verification)
                Haptics.success()
                return true
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }
        try? await AppStore.sync()
        await updateEntitlements()
    }

    private func handle(transactionResult: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = transactionResult else { return }
        if let creditsToAdd = StoreProduct.credits(for: transaction.productID) {
            credits.grant(creditsToAdd, reason: .purchase, note: "Credit pack")
        }
        await transaction.finish()
        await updateEntitlements()
    }

    // MARK: Presentation

    var planSummary: String {
        switch plan {
        case .free: return "Free plan"
        case .plus: return "Plus"
        case .pro: return "Pro"
        }
    }

    var renewalSummary: String? {
        guard let renewalDate else { return nil }
        return "Renews \(Format.shortDate(renewalDate))"
    }
}
