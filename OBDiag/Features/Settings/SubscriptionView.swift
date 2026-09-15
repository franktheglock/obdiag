import SwiftUI

/// Subscription management content: plan comparison, credit packs, purchase
/// history. Presented as a sheet by `SubscriptionView` and pushed by
/// `SubscriptionDetailView` — never both stacks at once.
struct SubscriptionContent: View {
    @Environment(AppEnvironment.self) private var env

    @State private var selectedPeriod: PlanOffer.Period = .yearly
    @State private var isPurchasing = false
    @State private var banner: String?

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if env.showsStore {
                        balanceHero
                        if let banner {
                            Text(banner)
                                .font(.obCaption)
                                .foregroundStyle(Palette.accent)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panel()
                        }
                        periodPicker
                        plans
                        creditPacks
                        creditsExplainer
                        history
                        footer
                    } else if env.auth.state == .unconfigured {
                        unavailableNotice
                    } else {
                        // Purchases are gated on sign-in: credits are granted
                        // server-side against a Firebase uid, so there is nowhere
                        // for an anonymous purchase to land.
                        AccountRequiredView(
                            reason: "Credits and subscriptions are tied to your OBDiag account, so sign in before buying."
                        )
                        creditsExplainer
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
        .navigationTitle("Credits & plans")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await env.subscriptions.refresh()
        }
        .overlay {
            if isPurchasing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .padding(28)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
        }
    }

    // MARK: Hero

    private var balanceHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Credit balance")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(Format.credits(env.creditBalance))
                        .obMono(40, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                        .contentTransition(.numericText())
                }
                Spacer()
                GlassChip(text: env.subscriptions.plan.title, systemImage: "checkmark.seal.fill", tint: Palette.accent)
            }
            HStack(spacing: 14) {
                stat("Spent", Format.credits(env.creditSpent))
                stat("Monthly grant", "+\(Format.credits(env.subscriptions.plan.monthlyCredits))")
                if let renewal = env.subscriptions.renewalSummary {
                    stat("Renewal", renewal.replacingOccurrences(of: "Renews ", with: ""))
                }
            }
            Text("1 credit = 1,000 tokens. Flash models bill at 0.33×, Plus at 1× and Max at 5×. Local and demo models are free.")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(18)
        .panel()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .obMono(14, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Plans

    private var periodPicker: some View {
        Picker("Billing period", selection: $selectedPeriod) {
            ForEach([PlanOffer.Period.monthly, .yearly], id: \.self) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([PlanTier.plus, .pro], id: \.rawValue) { tier in
                planCard(tier)
            }
        }
    }

    private func planCard(_ tier: PlanTier) -> some View {
        let offer = offer(for: tier, period: selectedPeriod)
        let isCurrent = env.subscriptions.plan == tier
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(tier.title)
                            .font(.obTitle2)
                            .foregroundStyle(Palette.textPrimary)
                        if isCurrent {
                            Text("Current")
                                .font(.obMicro)
                                .foregroundStyle(Palette.success)
                        }
                    }
                    Text("\(tier.modelTierLimit.title)-tier models · \(Format.credits(tier.monthlyCredits)) credits/month")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(offer?.displayPrice ?? "—")
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    if selectedPeriod == .yearly, let savings = offer.flatMap({ env.subscriptions.savingsLabel(for: $0) }) {
                        Text(savings).font(.obMicro).foregroundStyle(Palette.success)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(tier.features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Palette.success)
                            .padding(.top, 3)
                        Text(feature)
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }

            if isCurrent {
                GlassSecondaryButton(title: "Current plan", systemImage: "checkmark") {}
                    .disabled(true)
            } else if let offer {
                GlassActionButton(
                    title: "Get \(tier.title) · \(selectedPeriod.title)",
                    systemImage: "star.fill",
                    tint: Palette.accent
                ) {
                    purchase(offer)
                }
                .disabled(isPurchasing)
            } else {
                GlassSecondaryButton(title: "Unavailable in this build", systemImage: "exclamationmark.circle") {}
                    .disabled(true)
            }
        }
        .padding(16)
        .panel(tint: tier == .pro || selectedPeriod == .yearly ? Palette.accent.opacity(0.10) : nil)
    }

    private func offer(for tier: PlanTier, period: PlanOffer.Period) -> PlanOffer? {
        env.subscriptions.subscriptionOffers.first { $0.tier == tier && $0.period == period }
    }

    /// Shown when the build has no backend credentials at all.
    private var unavailableNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Palette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Store unavailable in this build")
                    .font(.obCallout)
                    .foregroundStyle(Palette.textPrimary)
                Text("Add GoogleService-Info.plist and the RevenueCat key to enable subscriptions.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .panel()
    }

    // MARK: Credit packs

    private var creditPacks: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Top up credits", subtitle: "One-time purchases that never expire")

            if env.subscriptions.creditPacks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bag").foregroundStyle(Palette.textTertiary)
                    Text(env.subscriptions.isLoading ? "Loading store…" : "Credit packs are unavailable in this build.")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                }
                .padding(14)
                .panel()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(env.subscriptions.creditPacks) { pack in
                        Button {
                            purchase(pack)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(pack.title)
                                    .font(.obCallout.weight(.semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(pack.displayPrice)
                                    .obMono(15, weight: .semibold)
                                    .foregroundStyle(Palette.accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .panel()
                        .disabled(isPurchasing)
                    }
                }
            }
        }
    }

    // MARK: Credits explainer

    private var creditsExplainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "How credits work", subtitle: "1 credit = 1,000 tokens")

            VStack(alignment: .leading, spacing: 10) {
                explainerRow(
                    icon: "function",
                    text: "credits = ceil( tokens ÷ 1,000 × model tier multiplier )"
                )
                explainerRow(
                    icon: "gauge.with.dots.needle.33percent",
                    text: "Flash models bill at 0.33×, Plus at 1×, and Max at 5×. The multiplier reflects what the model costs to run."
                )
                explainerRow(
                    icon: "bolt.slash",
                    text: "Minimum 1 credit per request. LM Studio (local) and the demo assistant cost nothing."
                )

                let example = CreditPricing.exampleCost(plan: env.subscriptions.plan)
                explainerRow(
                    icon: "doc.text.magnifyingglass",
                    text: exampleText(example)
                )
            }
            .padding(14)
            .panel()
        }
    }

    private func exampleText(_ example: (credits: Int, usd: Double, tokens: Int)) -> String {
        "Example: a \(Format.credits(example.tokens))-token answer on Gemini 3.8 Flash (Flash tier) costs \(Format.credits(example.credits)) credits."
    }

    private func explainerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 22)
                .padding(.top, 1)
            Text(text)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: History

    @ViewBuilder
    private var history: some View {
        let activity = env.creditActivity
        if !activity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Credit activity", subtitle: "Most recent first")
                VStack(spacing: 0) {
                    ForEach(Array(activity.prefix(10).enumerated()), id: \.element.id) { index, transaction in
                        HStack(spacing: 11) {
                            Image(systemName: transaction.reason.icon)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(transaction.amount > 0 ? Palette.success : Palette.textSecondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.reason.title)
                                    .font(.obCaption.weight(.semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(transaction.note)
                                    .font(.obMicro)
                                    .foregroundStyle(Palette.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(transaction.amount > 0 ? "+\(transaction.amount)" : "\(transaction.amount)")
                                    .obMono(13, weight: .semibold)
                                    .foregroundStyle(transaction.amount > 0 ? Palette.success : Palette.textSecondary)
                                Text(Format.relative(transaction.date ?? Date()))
                                    .font(.obMicro)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < min(activity.count, 10) - 1 {
                            Divider().overlay(Palette.stroke)
                        }
                    }
                }
                .padding(.vertical, 4)
                .panel()
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            GlassSecondaryButton(title: "Restore purchases", systemImage: "arrow.clockwise") {
                Task {
                    let restored = await env.subscriptions.restorePurchases()
                    banner = restored
                        ? "Purchases restored."
                        : (env.subscriptions.lastError ?? "Nothing to restore.")
                }
            }
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                Text("Manage or cancel in App Store settings")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Text("Credits are held on your OBDiag account and spent on model usage. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period.")
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Purchase

    private func purchase(_ offer: PlanOffer) {
        Task {
            isPurchasing = true
            banner = nil
            let success = await env.subscriptions.purchase(offer)
            isPurchasing = false
            banner = success
                ? "You're on the \(offer.tier.title) plan. Credits refreshed."
                : env.subscriptions.lastError
        }
    }

    private func purchase(_ pack: CreditPack) {
        Task {
            isPurchasing = true
            banner = nil
            let success = await env.subscriptions.purchase(pack)
            isPurchasing = false
            banner = success
                ? "Credits added to your balance."
                : env.subscriptions.lastError
        }
    }
}

/// Sheet presentation: full-height with a Done button.
struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetNavigationStack {
            SubscriptionContent()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Pushed presentation inside the Settings stack.
struct SubscriptionDetailView: View {
    var body: some View {
        SubscriptionContent()
    }
}
