import SwiftUI

/// Conversation history for the selected vehicle: switch, rename, pin, delete.
struct ChatHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onSelect: (UUID) -> Void

    @State private var search = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var pendingDeletion: Conversation?

    private var conversations: [Conversation] {
        let all = env.conversations.conversations(for: env.garage.selectedVehicleID)
        guard !search.isBlank else { return all }
        return all.filter { conversation in
            if conversation.title.localizedCaseInsensitiveContains(search) { return true }
            if let preview = conversation.lastMessagePreview, preview.localizedCaseInsensitiveContains(search) { return true }
            return false
        }
    }

    var body: some View {
        SheetNavigationStack {
            historyList
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Search conversations")
                .overlay { emptyOverlay }
                .toolbar { toolbarItems }
                .alert("Rename conversation", isPresented: isRenamePresented) {
                    TextField("Title", text: $renameText)
                    Button("Save") { commitRename() }
                    Button("Cancel", role: .cancel) { renaming = nil }
                }
                .confirmationDialog("Delete this conversation?", isPresented: isDeletionPresented, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { commitDeletion() }
                    Button("Cancel", role: .cancel) { pendingDeletion = nil }
                }
        }
    }

    private var historyList: some View {
        List {
            ForEach(conversations) { conversation in
                conversationRow(conversation)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.tap()
                let id = env.startFreshConversation()
                onSelect(id)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New conversation")
        }
    }

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation) -> some View {
        Button {
            Haptics.selection()
            onSelect(conversation.id)
        } label: {
            conversationLabel(conversation)
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
            pinButton(conversation)
        }
        .contextMenu {
            Button {
                renameText = conversation.title
                renaming = conversation
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            pinButton(conversation)
            Button(role: .destructive) {
                pendingDeletion = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func pinButton(_ conversation: Conversation) -> some View {
        Button {
            env.conversations.togglePin(conversation.id)
        } label: {
            Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin")
        }
        .tint(Palette.amber)
    }

    private func conversationLabel(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left.and.bubble.right")
                .font(.system(size: 15))
                .foregroundStyle(conversation.isPinned ? Palette.amber : Palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let preview = conversation.lastMessagePreview {
                    Text(preview)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(Format.relative(conversation.updatedAt))
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if conversations.isEmpty {
            ContentUnavailableView(
                "No conversations yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Chats with the assistant are saved here, per vehicle.")
            )
        }
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { value in if !value { renaming = nil } })
    }

    private var isDeletionPresented: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { value in if !value { pendingDeletion = nil } })
    }

    private func commitRename() {
        if let renaming {
            env.conversations.rename(renaming.id, to: renameText)
        }
        renaming = nil
    }

    private func commitDeletion() {
        if let pendingDeletion {
            env.conversations.delete(pendingDeletion.id)
        }
        pendingDeletion = nil
    }
}

// MARK: - Model picker

/// In-chat model switcher with tier grouping and plan gating.
struct ModelPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var conversationID: UUID?

    @State private var showPaywall = false
    @State private var search = ""
    @State private var isRefreshing = false

    private var models: [AIModel] {
        let all = env.settings.availableModels
        guard !search.isBlank else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    private func models(in tier: ModelTier) -> [AIModel] {
        models.filter { $0.tier == tier }.sorted { lhs, rhs in
            if lhs.isRecommended != rhs.isRecommended { return lhs.isRecommended }
            return lhs.promptPricePerToken < rhs.promptPricePerToken
        }
    }

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if env.settings.provider == .demo {
                        demoNotice
                    }
                    planBanner

                    ForEach(ModelTier.allCases, id: \.rawValue) { tier in
                        let tierModels = models(in: tier)
                        if !tierModels.isEmpty {
                            tierSection(tier, models: tierModels)
                        }
                    }

                    if env.settings.provider == .openRouter {
                        Button {
                            refreshCatalog()
                        } label: {
                            HStack(spacing: 8) {
                                if isRefreshing { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.clockwise") }
                                Text("Refresh model list from OpenRouter")
                                    .font(.obCaption.weight(.semibold))
                            }
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .disabled(isRefreshing)
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("Choose a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                SubscriptionView()
            }
        }
    }

    private var demoNotice: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 17))
                .foregroundStyle(Palette.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo assistant is active")
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Answers are scripted on-device. Add a provider to use these models.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Set up") {
                env.requestedSection = .settings
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .controlSize(.small)
        }
        .padding(14)
        .panel(cornerRadius: 14, tint: Palette.purple.opacity(0.10))
    }

    private var planBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(env.subscriptions.plan.title) plan · \(Format.credits(env.creditBalance)) credits")
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Higher tiers reason deeper and cost more credits per answer.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Upgrade") { showPaywall = true }
                .font(.obCaption.weight(.semibold))
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.small)
        }
        .padding(14)
        .panel(cornerRadius: 14)
    }

    private func tierSection(_ tier: ModelTier, models: [AIModel]) -> some View {
        let locked = tier > env.subscriptions.plan.modelTierLimit
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: tier.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(locked ? Palette.textTertiary : Palette.accent)
                Text(tier.title)
                    .font(.obHeadline)
                    .foregroundStyle(Palette.textPrimary)
                Text("· \(tier.subtitle)")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                if locked {
                    Label("\(tier.requiredPlan.title)+", systemImage: "lock.fill")
                        .font(.obMicro)
                        .foregroundStyle(Palette.amber)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    modelRow(model, locked: locked)
                    if index < models.count - 1 {
                        Divider().overlay(Palette.stroke)
                    }
                }
            }
            .padding(.vertical, 4)
            .panel(cornerRadius: 14)
        }
    }

    private func modelRow(_ model: AIModel, locked: Bool) -> some View {
        let isSelected = (env.chat.modelOverride ?? env.settings.selectedModelID) == model.id
        return Button {
            guard !locked else {
                showPaywall = true
                return
            }
            Haptics.selection()
            env.chat.modelOverride = model.id
            env.settings.selectedModelID = model.id
            if let conversationID {
                env.conversations.setModel(model.id, for: conversationID)
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.obCallout.weight(.semibold))
                            .foregroundStyle(locked ? Palette.textTertiary : Palette.textPrimary)
                        if model.supportsImages {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.accent.opacity(locked ? 0.4 : 1))
                                .accessibilityLabel("Can view images")
                        }
                        if model.isRecommended {
                            Text("recommended")
                                .font(.obMicro)
                                .foregroundStyle(Palette.success)
                        }
                    }
                    Text("\(model.provider) · \(model.contextLabel) · \(model.priceLabel)")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.amber)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshCatalog() {
        isRefreshing = true
        Task {
            do {
                let client = try RemoteChatClient(
                    kind: .openRouter,
                    apiKey: env.settings.openRouterAPIKey,
                    baseURLString: ""
                )
                let models = try await client.fetchModels()
                if !models.isEmpty {
                    env.settings.cachedModels = models
                    env.settings.lastCatalogRefresh = Date()
                }
            } catch {
                // Keep the curated fallback silently; the settings screen shows details.
            }
            isRefreshing = false
        }
    }
}

private extension ModelTier {
    var requiredPlan: PlanTier {
        switch self {
        case .flash: return .free
        case .plus: return .plus
        case .max: return .pro
        }
    }
}
