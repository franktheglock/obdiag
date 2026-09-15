import Foundation
import Observation
import RevenueCat

/// RevenueCat-backed store client.
///
/// RevenueCat owns StoreKit: it validates receipts, computes entitlements from
/// the products the user actually owns, and notifies the backend by webhook.
/// The app therefore never inspects transactions itself, and **credits are never
/// granted here** — a purchase becomes credits only when RevenueCat's webhook
/// reaches the server and it writes the ledger. `onEntitlementsChanged` exists so
/// the UI can re-read the authoritative balance afterwards.
///
/// The `appUserID` is the Firebase uid. That is what lets a webhook be matched
/// to the right account, so `identify(_:)` must run on sign-in and
/// `forgetUser()` on sign-out.
@MainActor
@Observable
final class RevenueCatStore {

    // MARK: Catalogue

    private(set) var subscriptionOffers: [PlanOffer] = []
    private(set) var creditPacks: [CreditPack] = []

    // MARK: State

    /// Reflects the *store's* view of the entitlement. The server's `plan` is
    /// still authoritative for what the assistant may call; this is for display
    /// and for showing the right "current plan" tick.
    private(set) var plan: PlanTier = .free
    private(set) var renewalDate: Date?
    private(set) var managementURL: URL?

    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var lastError: String?

    /// True once `Purchases` has been configured with an API key.
    private(set) var isAvailable = false

    /// Fired after a purchase, restore, or entitlement refresh so the caller can
    /// re-sync the server balance.
    var onEntitlementsChanged: (() -> Void)?

    // RevenueCat objects, keyed so the views only deal in our own value types.
    private var packagesByOfferID: [String: Package] = [:]
    private var productsByPackID: [String: StoreProduct] = [:]

    private var configuredUserID: String?

    // MARK: Configuration

    /// Whether a usable public SDK key is present. Everything degrades to a
    /// no-op store when it isn't, so a checkout with no RevenueCat setup still
    /// runs.
    static var isConfigured: Bool {
        BackendConfig.isStoreConfigured && Purchases.isConfigured
    }

    func attach() {
        isAvailable = Self.isConfigured
        guard isAvailable else { return }
        Task { await refresh() }
    }

    // MARK: Identity

    /// Point RevenueCat at the signed-in Firebase uid.
    ///
    /// Aliases any anonymous purchases made before sign-in onto this account,
    /// which is why the anonymous purchaser does not lose what they bought.
    func identify(_ userID: String) async {
        guard isAvailable, configuredUserID != userID else { return }
        configuredUserID = userID
        do {
            let result = try await Purchases.shared.logIn(userID)
            apply(result.customerInfo)
            onEntitlementsChanged?()
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Drop back to an anonymous RevenueCat user on sign-out, so the next person
    /// to sign in on this device doesn't inherit the previous entitlements.
    func forgetUser() async {
        guard isAvailable else { return }
        configuredUserID = nil
        do {
            apply(try await Purchases.shared.logOut())
            subscriptionOffers = []
            creditPacks = []
            packagesByOfferID = [:]
            productsByPackID = [:]
        } catch {
            // RevenueCat throws if the user was already anonymous; not an error
            // worth surfacing.
        }
    }

    // MARK: Catalogue loading

    func loadProducts() async {
        guard isAvailable, subscriptionOffers.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            guard let offering = offerings.current else {
                lastError = "No current offering is configured in RevenueCat."
                return
            }
            map(offering)
        } catch {
            lastError = Self.message(for: error)
        }

        // Consumables are not part of an offering, so fetch them by identifier.
        let consumables = Array(StoreCatalog.consumables)
        let products = await Purchases.shared.products(consumables)
        productsByPackID = Dictionary(uniqueKeysWithValues: products.map {
            ($0.productIdentifier, $0)
        })
        creditPacks = products
            .compactMap { product in
                guard let credits = StoreCatalog.credits(for: product.productIdentifier) else {
                    return nil
                }
                return CreditPack(
                    id: product.productIdentifier,
                    credits: credits,
                    displayPrice: product.localizedPriceString
                )
            }
            .sorted { $0.credits < $1.credits }
    }

    func refresh() async {
        guard isAvailable else { return }
        await loadProducts()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        guard isAvailable else { return }
        do {
            apply(try await Purchases.shared.customerInfo())
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: Purchasing

    @discardableResult
    func purchase(_ offer: PlanOffer) async -> Bool {
        guard let package = packagesByOfferID[offer.id] else {
            lastError = "That plan is unavailable right now."
            return false
        }
        return await perform { try await Purchases.shared.purchase(package: package) }
    }

    @discardableResult
    func purchase(_ pack: CreditPack) async -> Bool {
        guard let product = productsByPackID[pack.id] else {
            lastError = "That credit pack is unavailable right now."
            return false
        }
        return await perform { try await Purchases.shared.purchase(product: product) }
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        guard isAvailable else {
            lastError = "Purchases aren't available in this build."
            return false
        }
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        do {
            apply(try await Purchases.shared.restorePurchases())
            onEntitlementsChanged?()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    private func perform(_ operation: () async throws -> PurchaseResultData) async -> Bool {
        guard isAvailable else {
            lastError = "Purchases aren't available in this build."
            return false
        }
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        do {
            let result = try await operation()
            if result.userCancelled { return false }
            apply(result.customerInfo)
            // Credits land server-side via the RevenueCat webhook, so ask the
            // backend to re-read rather than assuming anything here.
            onEntitlementsChanged?()
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            lastError = Self.message(for: error)
            return false
        }
    }

    // MARK: Mapping

    private func map(_ offering: Offering) {
        var offers: [PlanOffer] = []
        var packages: [String: Package] = [:]

        for package in offering.availablePackages {
            let productID = package.storeProduct.productIdentifier
            guard let tier = StoreCatalog.plan(for: productID) else { continue }
            // The identifier suffix is authoritative here because the server
            // derives the billing period the same way.
            let period: PlanOffer.Period = productID.contains("yearly") ? .yearly : .monthly
            let offer = PlanOffer(
                id: productID,
                tier: tier,
                period: period,
                displayPrice: package.storeProduct.localizedPriceString,
                isRecommended: period == .yearly
            )
            offers.append(offer)
            packages[productID] = package
        }

        packagesByOfferID = packages
        subscriptionOffers = offers.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier.rawValue < rhs.tier.rawValue }
            return lhs.period == .yearly && rhs.period == .monthly
        }
    }

    private func apply(_ info: CustomerInfo) {
        let active = info.entitlements.active
        var resolved: PlanTier = .free
        var expiry: Date?
        for (identifier, entitlement) in active where entitlement.isActive {
            guard let tier = StoreCatalog.plan(forEntitlement: identifier) else { continue }
            if tier.rawValue > resolved.rawValue {
                resolved = tier
                expiry = entitlement.expirationDate
            }
        }
        plan = resolved
        renewalDate = resolved == .free ? nil : expiry
        managementURL = info.managementURL
    }

    // MARK: Presentation helpers

    /// Yearly saving versus monthly, when both are offered.
    func savingsLabel(for offer: PlanOffer) -> String? {
        guard offer.period == .yearly else { return nil }
        let monthlyID = offer.id.replacingOccurrences(of: "yearly", with: "monthly")
        guard let monthly = subscriptionOffers.first(where: { $0.id == monthlyID }),
              let monthlyPrice = Self.price(from: monthly.displayPrice),
              let yearlyPrice = Self.price(from: offer.displayPrice),
              monthlyPrice > 0 else { return nil }
        let yearlyMonthly = yearlyPrice / 12
        let saving = 1 - (yearlyMonthly / monthlyPrice)
        guard saving > 0.02 else { return nil }
        return "Save \(Int((saving * 100).rounded()))%"
    }

    func offer(for productID: String) -> PlanOffer? {
        subscriptionOffers.first { $0.id == productID }
    }

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

    // MARK: Helpers

    /// Pulls a number out of a localised price string, for the savings badge
    /// only. Never used for anything the user is charged.
    private static func price(from display: String) -> Double? {
        let digits = display.filter { $0.isNumber || $0 == "." || $0 == "," }
        return Double(digits.replacingOccurrences(of: ",", with: "."))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        (error as? RevenueCat.ErrorCode) == .purchaseCancelledError
    }

    private static func message(for error: Error) -> String {
        guard let code = error as? RevenueCat.ErrorCode else {
            return error.localizedDescription
        }
        switch code {
        case .purchaseCancelledError:
            return "Purchase cancelled."
        case .networkError:
            return "Couldn't reach the App Store. Check your connection and try again."
        case .paymentPendingError:
            return "This purchase is pending approval."
        case .productNotAvailableForPurchaseError:
            return "That product isn't available for purchase right now."
        case .receiptAlreadyInUseError:
            return "This App Store account is already linked to another OBDiag account."
        default:
            return error.localizedDescription
        }
    }
}
