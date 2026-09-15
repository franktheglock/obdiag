import SwiftUI

/// First-run experience: adaptive questionnaire, first vehicle setup and an
/// optional subscription upsell with yearly billing recommended.
struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var env

    enum Step: Int, CaseIterable {
        case welcome
        case garageSize
        case vehicleAge
        case discovery
        case goals
        case experience
        case vehicle
        case plan
    }

    @State private var step: Step = .welcome
    @State private var answers = OnboardingAnswers()
    @State private var showAddVehicle = false
    @State private var addedVehicleName: String?
    @State private var isPurchasing = false
    @State private var purchaseError: String?

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    content
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                }
                .dismissKeyboardOnScroll()
                footer
            }
        }
        .sheet(isPresented: $showAddVehicle, onDismiss: {
            addedVehicleName = env.garage.selectedVehicle?.displayName
        }) {
            AddVehicleFlow()
        }
        .task {
            await env.subscriptions.loadProducts()
        }
        .animation(.smooth(duration: 0.3), value: step)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                if step != .welcome {
                    Button {
                        Haptics.tap()
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "bolt.car.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.accent)
                        Text("OBDiag")
                            .font(.obTitle2)
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
                Spacer()
                if step != .plan {
                    Button("Skip") { complete() }
                        .font(.obCallout)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            progressBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Palette.accent : Palette.stroke)
                    .frame(height: 3)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if let purchaseError {
                Text(purchaseError)
                    .font(.obCaption)
                    .foregroundStyle(Palette.amber)
                    .multilineTextAlignment(.center)
            }
            switch step {
            case .plan:
                EmptyView()
            case .vehicle:
                GlassActionButton(title: addedVehicleName == nil ? "Add my vehicle" : "Continue", systemImage: "car.fill") {
                    if addedVehicleName == nil {
                        showAddVehicle = true
                    } else {
                        advance()
                    }
                }
                Button {
                    Haptics.tap()
                    skipVehicleSetup()
                } label: {
                    Text("Skip — I'll use Direct OBD Connection")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
            default:
                GlassActionButton(title: "Continue", systemImage: "arrow.right", isEnabled: canContinue) {
                    advance()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .bottomFade()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .garageSize: garageSizeStep
        case .vehicleAge: vehicleAgeStep
        case .discovery: discoveryStep
        case .goals: goalsStep
        case .experience: experienceStep
        case .vehicle: vehicleStep
        case .plan: planStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Palette.accent.opacity(0.15))
                    .frame(width: 112, height: 112)
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.top, 18)

            Text("Your car, explained in plain language")
                .font(.obLargeTitle)
                .foregroundStyle(Palette.textPrimary)

            Text("Pair a Bluetooth OBD-II adapter and OBDiag reads live engine data and fault codes — then an AI assistant tells you what's actually wrong and what to do about it.")
                .font(.obBody)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "gauge.with.dots.needle.67percent", title: "Live sensors", detail: "RPM, coolant, fuel trims, O₂ sensors and more.")
                featureRow(icon: "exclamationmark.triangle.fill", title: "Fault codes", detail: "Stored, pending and permanent codes, decoded instantly.")
                featureRow(icon: "sparkles", title: "AI diagnosis", detail: "Answers with causes, step-by-step checks, parts and videos.")
            }
            .padding(.top, 4)

            Text("A few quick questions and you're in. Everything stays on this device.")
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, 6)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Palette.accent.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.obHeadline).foregroundStyle(Palette.textPrimary)
                Text(detail).font(.obCaption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var garageSizeStep: some View {
        questionStep(
            title: "How many vehicles are in your garage?",
            subtitle: "You can add more later — this just tunes the setup."
        ) {
            VStack(spacing: 10) {
                ForEach(OnboardingAnswers.GarageSize.allCases) { option in
                    optionRow(
                        icon: option.icon,
                        title: option.title,
                        subtitle: nil,
                        isSelected: answers.garageSize == option
                    ) {
                        answers.garageSize = option
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private var vehicleAgeStep: some View {
        questionStep(
            title: "How old is the primary vehicle?",
            subtitle: "Older vehicles expose fewer sensors over OBD-II; the assistant adjusts."
        ) {
            VStack(spacing: 10) {
                ForEach(OnboardingAnswers.VehicleAge.allCases) { option in
                    optionRow(
                        icon: "calendar",
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: answers.vehicleAge == option
                    ) {
                        answers.vehicleAge = option
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private var discoveryStep: some View {
        questionStep(
            title: "How did you hear about OBDiag?",
            subtitle: "Optional — it helps us improve."
        ) {
            VStack(spacing: 10) {
                ForEach(OnboardingAnswers.DiscoverySource.allCases) { option in
                    optionRow(
                        icon: "megaphone",
                        title: option.title,
                        subtitle: nil,
                        isSelected: answers.discoverySource == option
                    ) {
                        answers.discoverySource = option
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private var goalsStep: some View {
        questionStep(
            title: "What do you want help with?",
            subtitle: "Pick as many as you like."
        ) {
            VStack(spacing: 10) {
                ForEach(OnboardingAnswers.Goal.allCases) { goal in
                    optionRow(
                        icon: goal.icon,
                        title: goal.title,
                        subtitle: nil,
                        isSelected: answers.goals.contains(goal)
                    ) {
                        if answers.goals.contains(goal) {
                            answers.goals.remove(goal)
                        } else {
                            answers.goals.insert(goal)
                        }
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private var experienceStep: some View {
        questionStep(
            title: "How hands-on are you?",
            subtitle: "This sets how much detail the assistant includes."
        ) {
            VStack(spacing: 10) {
                ForEach(OnboardingAnswers.ExperienceLevel.allCases) { level in
                    optionRow(
                        icon: "wrench.and.screwdriver",
                        title: level.title,
                        subtitle: level.subtitle,
                        isSelected: answers.experience == level
                    ) {
                        answers.experience = level
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private var vehicleStep: some View {
        questionStep(
            title: "Add your first vehicle",
            subtitle: "Year, make and model — or decode the VIN — makes every answer vehicle-specific."
        ) {
            VStack(spacing: 12) {
                if let addedVehicleName {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Palette.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(addedVehicleName)
                                .font(.obHeadline)
                                .foregroundStyle(Palette.textPrimary)
                            Text("Added to your garage")
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Button("Change") { showAddVehicle = true }
                            .font(.obCaption)
                            .buttonStyle(.glass)
                    }
                    .padding(14)
                    .panel()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        benefitRow("Answers reference your exact engine and trim")
                        benefitRow("Fault codes decode with vehicle-specific context")
                        benefitRow("Parts, recalls and videos are matched to your car")
                    }
                    .padding(14)
                    .panel()
                }
            }
        }
    }

    private var planStep: some View {
        questionStep(
            title: "Choose how you want to power the assistant",
            subtitle: "Start free. Upgrade any time — credits refresh monthly."
        ) {
            VStack(spacing: 12) {
                ForEach(env.subscriptions.subscriptionOffers) { offer in
                    subscriptionCard(offer: offer)
                }

                if env.subscriptions.subscriptionOffers.isEmpty {
                    staticPlanCard(tier: .free, price: "$0", features: PlanTier.free.features, isSelected: true)
                    Text("App Store products unavailable in this build — the free plan is active.")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                }

                Button {
                    Haptics.tap()
                    complete()
                } label: {
                    Text("Continue with Free")
                        .font(.obCallout.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Text("Subscriptions renew automatically unless cancelled at least 24 hours before the period ends. Manage in App Store settings.")
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func subscriptionCard(offer: PlanOffer) -> some View {
        Button {
            Task {
                isPurchasing = true
                purchaseError = nil
                let success = await env.subscriptions.purchase(offer)
                isPurchasing = false
                if success { complete() }
                else if let error = env.subscriptions.lastError { purchaseError = error }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(offer.tier.title) · \(offer.period.title)")
                            .font(.obTitle2)
                            .foregroundStyle(Palette.textPrimary)
                        Text(offer.tier.modelTierLimit.title + "-tier models · \(Format.credits(offer.tier.monthlyCredits)) credits/month")
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(offer.displayPrice)
                            .font(.obHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        if let savings = env.subscriptions.savingsLabel(for: offer) {
                            Text(savings)
                                .font(.obMicro)
                                .foregroundStyle(Palette.success)
                        } else if offer.period == .yearly {
                            Text("Recommended")
                                .font(.obMicro)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }
                ForEach(offer.tier.features.prefix(3), id: \.self) { feature in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.success)
                        Text(feature)
                            .font(.obCaption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(cornerRadius: 20, tint: offer.period == .yearly ? Palette.accent.opacity(0.10) : nil, interactive: true)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(offer.period == .yearly ? Palette.accent.opacity(0.6) : Palette.stroke, lineWidth: 1)
        )
        .disabled(isPurchasing)
    }

    private func staticPlanCard(tier: PlanTier, price: String, features: [String], isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tier.title).font(.obTitle2).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(price).font(.obHeadline).foregroundStyle(Palette.textPrimary)
            }
            ForEach(features.prefix(4), id: \.self) { feature in
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.success)
                    Text(feature).font(.obCaption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(15)
        .panel(cornerRadius: 14, tint: isSelected ? Palette.accent.opacity(0.10) : nil)
    }

    // MARK: Building blocks

    private func questionStep<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.obTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(.obCallout)
                    .foregroundStyle(Palette.textSecondary)
            }
            content()
        }
        .padding(.top, 6)
    }

    private func optionRow(icon: String, title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.obCaption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary.opacity(0.5))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(cornerRadius: 18, tint: isSelected ? Palette.accent.opacity(0.15) : nil, interactive: true)
    }

    private func benefitRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.success)
                .padding(.top, 1)
            Text(text)
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Flow control

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .garageSize: return answers.garageSize != nil
        case .vehicleAge: return answers.vehicleAge != nil
        case .discovery: return true
        case .goals: return true
        case .experience: return answers.experience != nil
        default: return true
        }
    }

    private func advance() {
        Haptics.tap()
        switch step {
        case .welcome: step = .garageSize
        case .garageSize: step = .vehicleAge
        case .vehicleAge: step = .discovery
        case .discovery: step = .goals
        case .goals: step = .experience
        case .experience: step = .vehicle
        case .vehicle: step = .plan
        case .plan: complete()
        }
    }

    private func goBack() {
        switch step {
        case .welcome: break
        case .garageSize: step = .welcome
        case .vehicleAge: step = .garageSize
        case .discovery: step = .vehicleAge
        case .goals: step = .discovery
        case .experience: step = .goals
        case .vehicle: step = .experience
        case .plan: step = .vehicle
        }
    }

    private func skipVehicleSetup() {
        Haptics.tap()
        if !env.garage.vehicles.contains(where: { $0.isDirectConnection }) {
            _ = env.garage.add(Vehicle.directConnection)
        }
        step = .plan
    }

    private func complete() {
        answers.wantsVehicleSetup = env.garage.hasVehicles
        env.settings.completeOnboarding(with: answers)
        Haptics.success()
    }
}
