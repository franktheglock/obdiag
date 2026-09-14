import Foundation
import Observation

/// Server-authoritative plan and credit balance.
///
/// This replaces the on-device ledger as the source of truth. The local
/// `CreditLedger` still exists for display history, but nothing here can be
/// edited by the user: every value comes from a callable that re-checks the
/// caller's Firebase identity.
@MainActor
@Observable
final class BackendAccountStore {
    private(set) var plan: PlanTier = .free
    private(set) var credits: Int = 0
    private(set) var lifetimeGranted: Int = 0
    private(set) var lifetimeSpent: Int = 0
    private(set) var monthlyCredits: Int = 0
    private(set) var creditMultiplier: Double = 1

    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshed: Date?

    private var client: CallableClient?

    /// Response shape of `getAccountSummary` / `syncEntitlements`.
    struct Summary: Decodable {
        var plan: PlanTier
        var credits: Int
        var lifetimeGranted: Int?
        var lifetimeSpent: Int?
        var monthlyCredits: Int?
        var creditMultiplier: Double?
    }

    func configure(client: CallableClient) {
        self.client = client
    }

    var isConfigured: Bool { client != nil }

    /// Refresh balance and plan. Safe to call on foreground; the server is cheap
    /// here and also tops up the monthly allowance if it's due.
    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let summary = try await client.call(
                BackendConfig.Function.accountSummary,
                as: Summary.self
            )
            apply(summary)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reconcile with RevenueCat, then re-read. Used by "Restore purchases" and
    /// after a successful purchase.
    func syncEntitlements() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let summary = try await client.call(
                BackendConfig.Function.syncEntitlements,
                as: Summary.self
            )
            apply(summary)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Update the displayed balance from a completed chat's receipt, so the UI
    /// doesn't need a second round-trip after every message.
    func applyReceipt(_ receipt: BackendChatReceipt) {
        if let balance = receipt.balance {
            credits = balance
        }
    }

    func apply(_ summary: Summary) {
        plan = summary.plan
        credits = summary.credits
        lifetimeGranted = summary.lifetimeGranted ?? lifetimeGranted
        lifetimeSpent = summary.lifetimeSpent ?? lifetimeSpent
        monthlyCredits = summary.monthlyCredits ?? monthlyCredits
        creditMultiplier = summary.creditMultiplier ?? creditMultiplier
        lastRefreshed = Date()
    }
}
