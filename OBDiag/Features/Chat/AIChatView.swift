import SwiftUI
import PhotosUI
import UIKit

/// AI diagnostic chat scoped to the currently selected vehicle.
struct AIChatView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var conversationID: UUID?
    @State private var composerText = ""
    @State private var showHistory = false
    @State private var showModelPicker = false
    @State private var showPaywall = false
    @State private var showVehiclePicker = false
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var isLoadingPhotos = false
    @FocusState private var composerFocused: Bool
    @Namespace private var composerNamespace

    private var conversation: Conversation? {
        guard let conversationID else { return nil }
        return env.conversations.conversation(withID: conversationID)
    }

    private var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if env.chat.isConfigured {
                    chatBody
                } else {
                    setupPrompt
                }
            }
            .transparentSheetContent()
            // The composer is a bar: the system gives it the scroll edge effect
            // under it and keeps it above the keyboard, so no painted scrim.
            .safeAreaBar(edge: .bottom) {
                if env.chat.isConfigured { composer }
            }
            .background { AppBackground() }
            .navigationTitle(title)
            .navigationSubtitle(env.chat.selectedModel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showHistory) {
                ChatHistoryView { id in
                    conversationID = id
                    showHistory = false
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(conversationID: conversationID)
            }
            .sheet(isPresented: $showPaywall) {
                SubscriptionView()
            }
            .sheet(isPresented: $showVehiclePicker) {
                VehiclePickerSheet { vehicle in
                    env.garage.select(vehicle.id)
                    conversationID = env.activeConversationID()
                    showVehiclePicker = false
                }
            }
            .sheet(item: Binding(
                get: { env.chat.pendingQuestion },
                set: { if $0 == nil { env.chat.dismissPendingQuestion() } }
            )) { question in
                AskUserSheet(question: question)
            }
            .onAppear(perform: prepareConversation)
            .onChange(of: env.pendingChatPrompt) { _, prompt in
                guard let prompt, !prompt.isBlank else { return }
                env.pendingChatPrompt = nil
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    send(prompt)
                }
            }
            .onChange(of: env.garage.selectedVehicleID) { _, _ in
                conversationID = env.activeConversationID()
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItems,
                maxSelectionCount: AttachmentStore.maxAttachmentsPerMessage,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: photoPickerItems) { _, _ in
                loadPhotoItems()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    addImage(image)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Titles & toolbar

    private var title: String {
        env.garage.selectedVehicle?.displayName ?? "Assistant"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Haptics.tap()
                conversationID = env.startFreshConversation()
                composerText = ""
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New conversation")

            Menu {
                Button {
                    showHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showModelPicker = true
                } label: {
                    Label("Change model", systemImage: env.chat.selectedModel.tier.icon)
                }
                Button {
                    showVehiclePicker = true
                } label: {
                    Label("Switch vehicle", systemImage: "car.2")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Conversation options")
        }
    }

    // MARK: Body

    private var chatBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        chatEmptyState
                    } else {
                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .dismissKeyboardOnScroll()
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: messages.count) { _, count in
                guard count > 0 else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: messages.last?.text.count ?? 0) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: messages.last?.toolCalls.count ?? 0) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Quiet start: a heading, one line of context, and the suggestions as
    /// plain rows in a single card. No hero icon, no pills.
    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask about your car")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(env.obd.isConnected
                     ? (env.obd.hasFaults
                        ? "\(env.obd.dtcs.count) fault code\(env.obd.dtcs.count == 1 ? "" : "s") and live data are included."
                        : "Live data is included.")
                     : "Answers use your vehicle, its fault codes and live data.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.element) { index, suggestion in
                    Button {
                        Haptics.tap()
                        send(suggestion)
                    } label: {
                        HStack(spacing: 10) {
                            Text(suggestion)
                                .font(.body)
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < Self.suggestions.count - 1 {
                        Divider().overlay(Palette.stroke)
                    }
                }
            }
            .padding(.vertical, 2)
            .panel()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private static let suggestions = [
        "What should I check first?",
        "Explain my fault codes in plain language",
        "Is it safe to keep driving?",
        "Find the repair procedure and parts for my main code"
    ]

    // MARK: Composer

    /// Every glass element in the composer shares one container, so the
    /// system renders them in a single pass and they can merge and morph as
    /// warnings appear or the send button changes state.
    private var composer: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                if !pendingAttachments.isEmpty {
                    attachmentStrip
                }
                if showsVisionWarning {
                    visionWarning
                        .glassEffectID("vision", in: composerNamespace)
                }
                if showsLowCreditWarning, !env.chat.isGenerating {
                    lowCreditWarning
                        .glassEffectID("credits", in: composerNamespace)
                }
                if env.chat.isGenerating, !env.chat.activeToolCalls.isEmpty {
                    liveToolStrip
                }
                // One glass field with the controls inside it, like Messages:
                // no glass-on-glass, one shape to read.
                HStack(alignment: .bottom, spacing: 4) {
                    attachButton

                    TextField("Ask about your car", text: $composerText, axis: .vertical)
                        .font(.obBody)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.vertical, 10)
                        .onSubmit { send() }

                    Button {
                        if env.chat.isGenerating {
                            env.chat.stop()
                        } else {
                            send()
                        }
                    } label: {
                        Image(systemName: env.chat.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(sendEnabled ? Palette.accent : Palette.textTertiary.opacity(0.35), in: Circle())
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!sendEnabled)
                    .accessibilityLabel(env.chat.isGenerating ? "Stop generating" : "Send message")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .glassEffectID("composer", in: composerNamespace)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.25), value: sendEnabled)
    }

    // MARK: Attachments

    /// The "+" affordance: photo library, camera, or clear the pending set.
    private var attachButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo library", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take photo", systemImage: "camera")
                }
            }
            if !pendingAttachments.isEmpty {
                Divider()
                Button(role: .destructive) {
                    clearPendingAttachments()
                } label: {
                    Label("Remove all photos", systemImage: "xmark.circle")
                }
            }
        } label: {
            ZStack {
                if isLoadingPhotos {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: pendingAttachments.isEmpty ? "plus" : "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(pendingAttachments.isEmpty ? Palette.textSecondary : Palette.accent)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a photo to your message")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumbnail(attachment: attachment, width: 58, height: 58) {}
                        Button {
                            removePendingAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.white, Color.black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove photo")
                    }
                }
                Text("\(pendingAttachments.count)/\(AttachmentStore.maxAttachmentsPerMessage) · \(Format.byteCount(pendingAttachments.reduce(0) { $0 + $1.byteCount }))")
                    .font(.obMicro)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
        .frame(height: 70)
    }

    private var showsVisionWarning: Bool {
        !pendingAttachments.isEmpty && !env.chat.selectedModel.supportsImages
    }

    private var visionWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.amber)
            Text("\(env.chat.selectedModel.name) can't view images.")
                .font(.obMicro)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
            Button("Switch model") {
                showModelPicker = true
            }
            .font(.obMicro.weight(.semibold))
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(Palette.amber.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    private var showsLowCreditWarning: Bool {
        switch env.settings.provider {
        case .obdiag:
            // Server-metered, and the only provider that actually blocks once
            // the balance runs out — so the warning matters most here, not least.
            guard env.creditsComeFromServer else { return false }
            return env.creditBalance <= max(10, env.account.plan.monthlyCredits / 10)
        case .openRouter:
            return env.creditBalance <= max(10, env.subscriptions.plan.monthlyCredits / 10)
        case .lmStudio, .demo:
            return false
        }
    }

    private var lowCreditWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.amber)
            Text("\(Format.credits(env.creditBalance)) credits left")
                .font(.obMicro)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
            Button("Top up") { showPaywall = true }
                .font(.obMicro.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(Palette.amber.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    private func addImage(_ image: UIImage) {
        guard pendingAttachments.count < AttachmentStore.maxAttachmentsPerMessage else {
            return
        }
        guard let attachment = AttachmentStore.save(image) else { return }
        pendingAttachments.append(attachment)
        Haptics.success()
    }

    private func removePendingAttachment(_ attachment: MessageAttachment) {
        AttachmentStore.delete(attachment)
        pendingAttachments.removeAll { $0.id == attachment.id }
        Haptics.tap()
    }

    private func clearPendingAttachments() {
        AttachmentStore.delete(pendingAttachments)
        pendingAttachments.removeAll()
        Haptics.tap()
    }

    private func loadPhotoItems() {
        guard !photoPickerItems.isEmpty else { return }
        isLoadingPhotos = true
        Task {
            for item in photoPickerItems {
                guard pendingAttachments.count < AttachmentStore.maxAttachmentsPerMessage else { break }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    addImage(image)
                }
            }
            photoPickerItems = []
            isLoadingPhotos = false
        }
    }

    private var sendEnabled: Bool {
        env.chat.isGenerating || !composerText.trimmed.isEmpty || !pendingAttachments.isEmpty
    }

    private var liveToolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(env.chat.activeToolCalls) { call in
                    HStack(spacing: 6) {
                        if call.status == .running {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: call.systemImage)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(call.status == .failed ? Palette.amber : Palette.success)
                        }
                        Text(call.displayName)
                            .font(.obMicro)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
            }
        }
        .frame(height: 30)
    }

    // MARK: Setup prompt

    private var setupPrompt: some View {
        VStack {
            EmptyStateView(
                systemImage: "key.horizontal",
                title: "Finish assistant setup",
                message: "Add an OpenRouter API key or point OBDiag at LM Studio to chat with a cloud or local model. The demo assistant works with no setup.",
                actionTitle: "Open AI settings",
                action: { env.requestedSection = .settings }
            )
            Button {
                Haptics.tap()
                env.settings.provider = .demo
            } label: {
                Label("Use the demo assistant", systemImage: "play.circle")
                    .font(.obCallout.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func prepareConversation() {
        if conversationID == nil {
            conversationID = env.activeConversationID()
        }
        if !env.pendingAttachments.isEmpty {
            pendingAttachments = env.pendingAttachments
            env.pendingAttachments = []
        }
        if let prompt = env.pendingChatPrompt, !prompt.isBlank {
            env.pendingChatPrompt = nil
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                send(prompt)
            }
        }
    }

    private func send(_ text: String? = nil) {
        let message = (text ?? composerText).trimmed
        let attachments = pendingAttachments
        guard !message.isEmpty || !attachments.isEmpty else { return }
        guard let conversationID else {
            self.conversationID = env.activeConversationID()
            if let id = self.conversationID { env.chat.send(message, attachments: attachments, in: id) }
            composerText = ""
            pendingAttachments = []
            return
        }
        composerText = ""
        pendingAttachments = []
        env.chat.send(message, attachments: attachments, in: conversationID)
    }
}

// MARK: - Vehicle picker

struct VehiclePickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var onSelect: (Vehicle) -> Void

    var body: some View {
        SheetNavigationStack {
            List {
                ForEach(env.garage.vehicles) { vehicle in
                    Button {
                        Haptics.selection()
                        onSelect(vehicle)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: vehicle.isDirectConnection ? "bolt.horizontal.circle.fill" : "car.fill")
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.displayName)
                                    .font(.obCallout.weight(.semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                if !vehicle.subtitle.isEmpty {
                                    Text(vehicle.subtitle)
                                        .font(.obCaption)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                            Spacer()
                            if env.garage.selectedVehicleID == vehicle.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Chat about…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
