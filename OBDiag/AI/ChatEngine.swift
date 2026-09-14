import Foundation
import Observation

/// Orchestrates the full assistant loop: system prompt assembly, streaming,
/// client-side tool execution, follow-up turns, credit accounting and the
/// ask-the-user bridge.
@MainActor
@Observable
final class ChatEngine {

    // MARK: Observable state

    private(set) var isGenerating = false
    private(set) var streamingConversationID: UUID?
    private(set) var activeToolCalls: [ToolCallRecord] = []
    private(set) var lastError: String?
    /// In-chat model override (nil = the model chosen in Settings).
    var modelOverride: String?
    /// Question currently awaiting the user's answer.
    var pendingQuestion: AskUserQuestion?

    var planProvider: (() -> PlanTier)?
    /// Supplies the managed-service client, once the user is signed in.
    var managedClientProvider: (() -> ChatCompletionClient?)?
    /// Supplies the server-authoritative credit balance for the pre-flight check.
    var serverBalanceProvider: (() -> Int?)?

    // MARK: Dependencies

    private let settings: AppSettings
    private let garage: GarageStore
    private let conversations: ConversationStore
    private let credits: CreditLedger
    private let obd: OBDSession
    private let search: SearchService
    private let tools: ToolExecutor

    private var demoAssistant: DemoAssistant?
    private var task: Task<Void, Never>?
    private var askContinuation: CheckedContinuation<String, Never>?

    init(
        settings: AppSettings,
        garage: GarageStore,
        conversations: ConversationStore,
        credits: CreditLedger,
        obd: OBDSession,
        search: SearchService
    ) {
        self.settings = settings
        self.garage = garage
        self.conversations = conversations
        self.credits = credits
        self.obd = obd
        self.search = search
        self.tools = ToolExecutor(obd: obd, garage: garage, search: search, settings: settings)
        self.tools.askUser = { [weak self] question in
            guard let self else { return "The user did not answer." }
            return await self.present(question)
        }
    }

    // MARK: Model & client selection

    var selectedModel: AIModel {
        if settings.provider == .demo {
            return AIModel(
                id: "obdiag/demo",
                name: "OBDiag Demo",
                provider: "On-device",
                contextLength: 32_768,
                promptPricePerToken: 0,
                completionPricePerToken: 0,
                supportsTools: true,
                supportsReasoning: false,
                supportsImages: false,
                isFree: true,
                isRecommended: false,
                description: "Scripted answers that use your live data, fault codes and vehicle profile."
            )
        }
        if settings.provider == .lmStudio {
            return AIModel(
                id: settings.lmStudioModelID,
                name: settings.lmStudioModelID,
                provider: "Local", contextLength: 32_768,
                promptPricePerToken: 0, completionPricePerToken: 0,
                supportsTools: true, supportsReasoning: false, supportsImages: false,
                isFree: true, isRecommended: false,
                description: "Running locally through LM Studio."
            )
        }
        if let override = modelOverride, let model = settings.model(withID: override) {
            return model
        }
        return settings.selectedModel
    }

    var currentPlan: PlanTier { planProvider?() ?? .free }

    var availableModels: [AIModel] {
        settings.availableModels
            .filter { $0.tier <= currentPlan.modelTierLimit }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.isRecommended != rhs.isRecommended { return lhs.isRecommended }
                return lhs.promptPricePerToken < rhs.promptPricePerToken
            }
    }

    private func makeClient() throws -> ChatCompletionClient {
        switch settings.provider {
        case .obdiag:
            guard let client = managedClientProvider?() else {
                throw AIError.provider("Sign in to use the OBDiag assistant.")
            }
            return client
        case .demo:
            if let demoAssistant { return demoAssistant }
            let assistant = DemoAssistant(obd: obd, garage: garage)
            demoAssistant = assistant
            return assistant
        case .openRouter:
            guard !settings.openRouterAPIKey.isBlank else { throw AIError.missingAPIKey("OpenRouter") }
            return try RemoteChatClient(kind: .openRouter, apiKey: settings.openRouterAPIKey, baseURLString: "")
        case .lmStudio:
            return try RemoteChatClient(kind: .lmStudio, apiKey: "", baseURLString: settings.lmStudioBaseURL)
        }
    }

    var isConfigured: Bool {
        switch settings.provider {
        case .obdiag: return managedClientProvider?() != nil
        case .demo: return true
        case .openRouter: return !settings.openRouterAPIKey.isBlank
        case .lmStudio: return !settings.lmStudioBaseURL.isBlank
        }
    }

    // MARK: Sending

    func send(_ text: String, attachments: [MessageAttachment] = [], in conversationID: UUID) {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty || !attachments.isEmpty, !isGenerating else { return }
        guard conversations.conversation(withID: conversationID) != nil else { return }

        if !isConfigured {
            let message = settings.provider == .obdiag
                ? "Sign in to use the OBDiag assistant. You can keep browsing live data and fault codes meanwhile."
                : "Add an API key in Settings → AI provider, or switch to the demo assistant. You can keep browsing live data and fault codes meanwhile."
            conversations.appendMessage(.error(message), to: conversationID)
            return
        }

        // Pre-flight credit check for metered providers. The server is the real
        // authority; this just avoids a round-trip and a confusing failure.
        let balance: Int? = settings.provider == .obdiag
            ? serverBalanceProvider?()
            : settings.provider == .openRouter ? credits.balance : nil
        if let balance, balance <= 0 {
            conversations.appendMessage(
                .error("You're out of AI credits. Top up in Settings → Subscription, or switch to a local/demo model."),
                to: conversationID
            )
            return
        }

        conversations.appendMessage(.user(trimmed, attachments: attachments), to: conversationID)
        conversations.setTitleIfNeeded(conversationID, from: trimmed.isEmpty ? "Photo diagnosis" : trimmed)
        conversations.persist()
        start(conversationID: conversationID)
    }

    /// Removes trailing assistant/error messages and re-runs the last user turn.
    func retry(conversationID: UUID) {
        guard !isGenerating, conversations.conversation(withID: conversationID) != nil else { return }
        conversations.mutate(conversationID) { conversation in
            while let last = conversation.messages.last, last.role == .assistant {
                conversation.messages.removeLast()
            }
        }
        guard conversations.conversation(withID: conversationID)?.messages.contains(where: { $0.role == .user }) == true else { return }
        start(conversationID: conversationID)
    }

    private func start(conversationID: UUID) {
        activeToolCalls = []
        lastError = nil
        isGenerating = true
        streamingConversationID = conversationID
        task = Task { [weak self] in
            await self?.run(conversationID: conversationID)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let askContinuation {
            self.askContinuation = nil
            pendingQuestion = nil
            askContinuation.resume(returning: "The user cancelled the question.")
        }
        finalizeStreamingMessages(in: streamingConversationID, stopped: true)
        isGenerating = false
        streamingConversationID = nil
        activeToolCalls = []
        Haptics.soft()
    }

    // MARK: Ask-user bridge

    private func present(_ question: AskUserQuestion) async -> String {
        pendingQuestion = question
        Haptics.soft()
        return await withCheckedContinuation { continuation in
            askContinuation = continuation
        }
    }

    func answerPendingQuestion(_ answer: String) {
        guard pendingQuestion != nil else { return }
        pendingQuestion = nil
        let continuation = askContinuation
        askContinuation = nil
        continuation?.resume(returning: answer)
    }

    func dismissPendingQuestion() {
        answerPendingQuestion("The user dismissed the question without answering. Continue with your best judgment and state any assumptions.")
    }

    // MARK: Main loop

    private func run(conversationID: UUID) async {
        defer {
            isGenerating = false
            streamingConversationID = nil
            activeToolCalls = []
        }

        do {
            let client = try makeClient()
            let model = selectedModel
            let toolDefinitions = ToolExecutor.toolDefinitions(searchService: search, settings: settings)
            var wire = buildWireMessages(conversationID: conversationID, model: model, hasTools: !toolDefinitions.isEmpty)

            for turn in 0..<6 {
                try Task.checkCancellation()

                let request = ChatCompletionRequest(
                    model: model.id,
                    messages: wire,
                    tools: toolDefinitions.isEmpty ? nil : toolDefinitions,
                    toolChoice: toolDefinitions.isEmpty ? nil : "auto",
                    reasoning: model.supportsReasoning
                        ? ChatCompletionRequest.ReasoningConfig(effort: "medium", exclude: !settings.showReasoning)
                        : nil,
                    temperature: nil,
                    maxTokens: nil,
                    provider: nil
                )

                let estimatePrompt = wire.reduce(0) { total, message in
                    total + (message.content?.count ?? 0) + (message.toolCalls?.reduce(0) { $0 + $1.function.arguments.count } ?? 0)
                } / 4
                let result = try await consume(
                    stream: client.stream(request: request),
                    conversationID: conversationID,
                    model: model,
                    estimatedPromptTokens: estimatePrompt
                )

                applyUsage(result.usage, model: model, conversationID: conversationID, client: client)

                guard !result.toolCalls.isEmpty else { break }

                // Append the assistant tool-call turn and each tool result.
                wire.append(
                    .assistant(
                        content: result.text.isEmpty ? nil : result.text,
                        toolCalls: result.toolCalls.map {
                            WireToolCall(id: $0.id, function: WireFunctionCall(name: $0.name, arguments: $0.arguments.jsonString))
                        }
                    )
                )
                for call in result.toolCalls {
                    let outcome = await tools.execute(call)
                    applyToolOutcome(outcome, invocation: call, conversationID: conversationID, messageID: result.messageID)
                    wire.append(.tool(outcome.content, toolCallID: call.id, name: call.name))
                }

                // Context protection: drop oldest turns if the conversation is huge.
                wire = trim(wire)

                if turn == 5 {
                    conversations.appendMessage(
                        .error("I hit the tool-call limit for one question. Ask a follow-up to continue."),
                        to: conversationID
                    )
                }
            }

            conversations.persist()
        } catch is CancellationError {
            finalizeStreamingMessages(in: conversationID, stopped: true)
            conversations.persist()
        } catch {
            let message = error.localizedDescription
            lastError = message
            finalizeStreamingMessages(in: conversationID, stopped: true)
            conversations.appendMessage(.error(message), to: conversationID)
            conversations.persist()
            Haptics.error()
        }
    }

    // MARK: Consuming a stream

    private struct ConsumeResult {
        var messageID: UUID
        var text: String
        var toolCalls: [ToolInvocation]
        var usage: TokenUsage
    }

    private struct PartialToolCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private func consume(
        stream: AsyncThrowingStream<StreamEvent, Error>,
        conversationID: UUID,
        model: AIModel,
        estimatedPromptTokens: Int
    ) async throws -> ConsumeResult {
        var message = ChatMessage.assistant(modelID: model.id)
        conversations.appendMessage(message, to: conversationID)
        let messageID = message.id

        var partials: [Int: PartialToolCall] = [:]
        var usage = TokenUsage()
        var finishReason: String?

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .text(let chunk):
                message.text += chunk
                updateMessage(messageID, in: conversationID) { $0.text += chunk }

            case .reasoning(let chunk):
                if settings.showReasoning {
                    message.reasoning = (message.reasoning ?? "") + chunk
                    updateMessage(messageID, in: conversationID) { stored in
                        stored.reasoning = (stored.reasoning ?? "") + chunk
                    }
                }

            case .toolCallDelta(let index, let id, let name, let arguments):
                var partial = partials[index] ?? PartialToolCall()
                if let id, !id.isEmpty { partial.id = id }
                if let name, !name.isEmpty { partial.name = name }
                if let arguments { partial.arguments += arguments }
                partials[index] = partial

                if let name, !name.isEmpty {
                    let callID = partial.id ?? "call_\(messageID.uuidString.prefix(8))_\(index)"
                    partial.id = callID
                    partials[index] = partial
                    let record = ToolCallRecord(
                        id: callID,
                        name: name,
                        displayName: Self.displayName(for: name),
                        systemImage: Self.systemImage(for: name),
                        arguments: partial.arguments,
                        result: nil,
                        status: .running,
                        startedAt: Date()
                    )
                    updateMessage(messageID, in: conversationID) { stored in
                        if let existing = stored.toolCalls.firstIndex(where: { $0.id == callID }) {
                            stored.toolCalls[existing].arguments = partial.arguments
                        } else {
                            stored.toolCalls.append(record)
                        }
                    }
                }

            case .citations(let citations):
                updateMessage(messageID, in: conversationID) { stored in
                    for citation in citations where !stored.citations.contains(where: { $0.url == citation.url }) {
                        stored.citations.append(citation)
                    }
                }

            case .usage(let reported):
                usage = usage + reported

            case .finish(let reason):
                finishReason = reason
            }
        }

        if usage.totalTokens == 0 {
            usage.promptTokens = estimatedPromptTokens
            usage.completionTokens = message.text.count / 4
            usage.totalTokens = usage.promptTokens + usage.completionTokens
        }

        let invocations: [ToolInvocation] = partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], let name = partial.name else { return nil }
            let id = partial.id ?? "call_\(index)"
            return ToolInvocation(id: id, name: name, arguments: JSONValue.parse(partial.arguments) ?? .object([:]))
        }

        updateMessage(messageID, in: conversationID) { stored in
            stored.isStreaming = false
            stored.usage = usage
            if finishReason == nil { stored.isStopped = true }
            for invocation in invocations {
                if let index = stored.toolCalls.firstIndex(where: { $0.id == invocation.id }) {
                    stored.toolCalls[index].arguments = invocation.arguments.jsonString
                }
            }
        }

        return ConsumeResult(messageID: messageID, text: message.text, toolCalls: invocations, usage: usage)
    }

    private func applyToolOutcome(
        _ outcome: ToolOutcome,
        invocation: ToolInvocation,
        conversationID: UUID,
        messageID: UUID
    ) {
        updateMessage(messageID, in: conversationID) { stored in
            guard let index = stored.toolCalls.firstIndex(where: { $0.id == invocation.id }) else { return }
            stored.toolCalls[index].result = outcome.content
            stored.toolCalls[index].status = outcome.isError ? .failed : .succeeded
            stored.toolCalls[index].finishedAt = Date()
            stored.toolCalls[index].displayName = outcome.displayName
            stored.toolCalls[index].systemImage = outcome.systemImage
        }
        if let call = conversations.conversation(withID: conversationID)?.messages
            .first(where: { $0.id == messageID })?
            .toolCalls.first(where: { $0.id == invocation.id }) {
            if let existing = activeToolCalls.firstIndex(where: { $0.id == call.id }) {
                activeToolCalls[existing] = call
            } else {
                activeToolCalls.append(call)
            }
        }
    }

    private func applyUsage(_ usage: TokenUsage, model: AIModel, conversationID: UUID, client: ChatCompletionClient) {
        conversations.addUsage(usage, to: conversationID)
        // The managed service debits server-side, so don't double-charge locally.
        guard !client.isLocal, !client.isServerMetered, usage.totalTokens > 0 else { return }
        let cost = CreditPricing.credits(for: usage, model: model, plan: currentPlan)
        guard cost > 0 else { return }
        credits.spend(cost, note: "\(model.name) · \(usage.totalTokens) tokens", modelID: model.id)
    }

    // MARK: Message helpers

    private func updateMessage(_ messageID: UUID, in conversationID: UUID, _ transform: (inout ChatMessage) -> Void) {
        conversations.mutate(conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            transform(&conversation.messages[index])
            conversation.updatedAt = Date()
        }
    }

    private func finalizeStreamingMessages(in conversationID: UUID?, stopped: Bool) {
        guard let conversationID else { return }
        conversations.mutate(conversationID) { conversation in
            for index in conversation.messages.indices where conversation.messages[index].isStreaming {
                conversation.messages[index].isStreaming = false
                if stopped { conversation.messages[index].isStopped = true }
            }
        }
    }

    // MARK: Wire context

    private func buildWireMessages(conversationID: UUID, model: AIModel, hasTools: Bool) -> [WireMessage] {
        let system = PromptBuilder.systemPrompt(
            vehicle: garage.selectedVehicle,
            obd: obd,
            garage: garage,
            settings: settings,
            search: search,
            hasTools: hasTools
        )
        var wire: [WireMessage] = [.system(system)]
        guard let conversation = conversations.conversation(withID: conversationID) else { return wire }

        for message in conversation.messages {
            switch message.role {
            case .user:
                var text = message.text
                var images: [String] = []
                if !message.attachments.isEmpty {
                    if model.supportsImages || settings.provider == .demo {
                        images = message.attachments.compactMap { AttachmentStore.dataURL(for: $0) }
                    } else {
                        let count = message.attachments.count
                        let note = "[The user attached \(count) image\(count == 1 ? "" : "s"), but the selected model cannot view images. Answer from the text and ask for a description if the image matters.]"
                        text = text.isEmpty ? note : note + "\n\n" + text
                    }
                }
                wire.append(.user(text, images: images))
            case .assistant:
                if message.isError { continue }
                let calls = message.toolCalls.filter { $0.status == .succeeded || $0.status == .failed }
                if !calls.isEmpty {
                    wire.append(.assistant(
                        content: message.text.isEmpty ? nil : message.text,
                        toolCalls: calls.map {
                            WireToolCall(id: $0.id, function: WireFunctionCall(name: $0.name, arguments: $0.arguments))
                        }
                    ))
                    for call in calls {
                        wire.append(.tool(call.result ?? "{\"error\":\"tool did not finish\"}", toolCallID: call.id, name: call.name))
                    }
                } else if !message.text.isEmpty {
                    wire.append(.assistant(content: message.text))
                }
            case .tool, .system:
                continue
            }
        }
        return trim(wire)
    }

    /// Keeps the system prompt plus the most recent turns, never starting on an
    /// orphaned tool message or splitting a tool call from its result.
    private func trim(_ wire: [WireMessage]) -> [WireMessage] {
        let maxMessages = 44
        let maxCharacters = 180_000
        guard wire.count > maxMessages else { return wire }
        var result = Array(wire.prefix(1))
        var tail = Array(wire.suffix(maxMessages - 1))
        while let first = tail.first, first.role == "tool" {
            tail.removeFirst()
        }
        result.append(contentsOf: tail)

        var total = result.reduce(0) { $0 + ($1.content?.count ?? 0) }
        while total > maxCharacters, result.count > 3 {
            let removed = result.remove(at: 1)
            total -= removed.content?.count ?? 0
        }
        return result
    }

    // MARK: Tool presentation

    static func displayName(for tool: String) -> String {
        switch tool {
        case "get_live_data": return "Reading live data"
        case "get_fault_codes": return "Scanning fault codes"
        case "web_search": return "Searching the web"
        case "search_videos": return "Finding videos"
        case "search_parts": return "Finding parts"
        case "read_url": return "Reading a page"
        case "ask_user": return "Asking you"
        default: return tool.humanizedIdentifier
        }
    }

    static func systemImage(for tool: String) -> String {
        switch tool {
        case "get_live_data": return "waveform.path.ecg"
        case "get_fault_codes": return "exclamationmark.triangle"
        case "web_search": return "magnifyingglass"
        case "search_videos": return "play.rectangle"
        case "search_parts": return "wrench.and.screwdriver"
        case "read_url": return "doc.text.magnifyingglass"
        case "ask_user": return "questionmark.bubble"
        default: return "gearshape"
        }
    }
}
