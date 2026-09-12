import Foundation
import Observation

/// On-device credit ledger. Nothing here is authoritative for billing —
/// StoreKit transactions are — but it keeps the UX honest between launches.
@MainActor
@Observable
final class CreditLedger {
    private(set) var balance: Int = 0
    private(set) var transactions: [CreditTransaction] = []
    private(set) var lifetimeSpent: Int = 0
    private(set) var lastGrantDate: Date?

    private static let fileName = "credits.json"

    init() {
        if let stored = FileStore.load(Snapshot.self, from: Self.fileName) {
            balance = stored.balance
            transactions = stored.transactions
            lifetimeSpent = stored.lifetimeSpent
            lastGrantDate = stored.lastGrantDate
        }
    }

    var recentTransactions: [CreditTransaction] {
        transactions.sorted { $0.date > $1.date }
    }

    var spentThisMonth: Int {
        let calendar = Calendar.current
        return transactions
            .filter { $0.amount < 0 && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 - $1.amount }
    }

    func canAfford(_ amount: Int) -> Bool { balance >= amount }

    func grant(_ amount: Int, reason: CreditReason, note: String, modelID: String? = nil) {
        guard amount != 0 else { return }
        balance += amount
        record(amount: amount, reason: reason, note: note, modelID: modelID)
    }

    @discardableResult
    func spend(_ amount: Int, note: String, modelID: String? = nil) -> Bool {
        guard amount > 0 else { return true }
        guard canAfford(amount) else { return false }
        balance -= amount
        lifetimeSpent += amount
        record(amount: -amount, reason: .chat, note: note, modelID: modelID)
        return true
    }

    /// Grants the plan's monthly allowance when the billing month rolls over.
    func applyMonthlyGrantIfNeeded(plan: PlanTier, now: Date = Date()) {
        let calendar = Calendar.current
        if let lastGrantDate, calendar.isDate(lastGrantDate, equalTo: now, toGranularity: .month) {
            return
        }
        lastGrantDate = now
        // First-ever grant also includes the welcome bonus.
        if transactions.isEmpty {
            grant(100, reason: .welcome, note: "Welcome to OBDiag")
        }
        grant(plan.monthlyCredits, reason: .monthlyGrant, note: "\(plan.title) monthly allowance")
    }

    /// Used when a subscription lapses; credits already granted stay spendable.
    func refund(_ amount: Int, note: String) {
        grant(amount, reason: .adjustment, note: note)
    }

    func reset() {
        balance = 0
        transactions = []
        lifetimeSpent = 0
        lastGrantDate = nil
        persist()
    }

    private func record(amount: Int, reason: CreditReason, note: String, modelID: String?) {
        transactions.append(
            CreditTransaction(amount: amount, reason: reason, note: note, balanceAfter: balance, modelID: modelID)
        )
        if transactions.count > 500 { transactions.removeFirst(transactions.count - 500) }
        persist()
    }

    func persist() {
        FileStore.save(
            Snapshot(balance: balance, transactions: transactions, lifetimeSpent: lifetimeSpent, lastGrantDate: lastGrantDate),
            to: Self.fileName
        )
    }

    struct Snapshot: Codable {
        var balance: Int
        var transactions: [CreditTransaction]
        var lifetimeSpent: Int
        var lastGrantDate: Date?
    }
}
