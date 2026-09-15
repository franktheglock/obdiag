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
    /// Billing multiplier per model tier, served by the backend.
    private(set) var modelTierMultipliers: [String: Double] = [:]

    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshed: Date?

    /// Recent ledger entries, newest first. This is the only source of credit
    /// *history* for a managed account: the client has no Firestore access, and
    /// the local ledger is never written when the server meters usage.
    private(set) var ledgerEntries: [CreditActivity] = []

    private var client: CallableClient?

    /// Response shape of `getAccountSummary` / `syncEntitlements`.
    struct Summary: Decodable {
        var plan: PlanTier
        var credits: Int
        var lifetimeGranted: Int?
        var lifetimeSpent: Int?
        var monthlyCredits: Int?
        var modelTierMultipliers: [String: Double]?
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

    /// Response shape of `getLedger`.
    private struct LedgerResponse: Decodable {
        struct Entry: Decodable {
            var id: String
            var amount: Int
            var reason: CreditReason
            var note: String
            var balanceAfter: Int?
            var modelId: String?
            var createdAt: Double?
        }
        var entries: [Entry]
    }

    /// Fetch recent credit activity. Separate from `refresh()` so the subscribe
    /// screen can show a balance immediately and fill history in behind it.
    func refreshLedger() async {
        guard let client else { return }
        do {
            let response = try await client.call(
                BackendConfig.Function.ledger,
                payload: ["limit": 25],
                as: LedgerResponse.self
            )
            ledgerEntries = response.entries.map { entry in
                CreditActivity(
                    id: entry.id,
                    amount: entry.amount,
                    reason: entry.reason,
                    note: entry.note,
                    date: entry.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                )
            }
        } catch {
            // History is a nicety; a failure here must not blank the screen.
            lastError = error.localizedDescription
        }
    }

    /// Total spent, from the server, when a balance has been read at least once.
    var spentTotal: Int { lifetimeSpent }

    func apply(_ summary: Summary) {
        plan = summary.plan
        credits = summary.credits
        lifetimeGranted = summary.lifetimeGranted ?? lifetimeGranted
        lifetimeSpent = summary.lifetimeSpent ?? lifetimeSpent
        monthlyCredits = summary.monthlyCredits ?? monthlyCredits
        modelTierMultipliers = summary.modelTierMultipliers ?? modelTierMultipliers
        lastRefreshed = Date()
    }
}
