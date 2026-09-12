import Foundation

/// Anything that can produce a streamed chat completion and list models.
@MainActor
protocol ChatCompletionClient: AnyObject {
    var displayName: String { get }
    /// True when this client runs locally/free and should not consume credits.
    var isLocal: Bool { get }
    func stream(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>
    func fetchModels() async throws -> [AIModel]
}

extension ChatCompletionClient {
    var isLocal: Bool { false }
}

/// OpenAI-compatible client used for both OpenRouter and LM Studio.
@MainActor
final class RemoteChatClient: ChatCompletionClient {
    enum Kind {
        case openRouter
        case lmStudio
    }

    let kind: Kind
    let displayName: String
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(kind: Kind, apiKey: String, baseURLString: String) throws {
        self.kind = kind
        switch kind {
        case .openRouter:
            self.displayName = "OpenRouter"
            guard let url = URL(string: "https://openrouter.ai/api/v1/") else { throw AIError.invalidResponse }
            self.baseURL = url
        case .lmStudio:
            self.displayName = "LM Studio"
            let normalized = baseURLString.hasSuffix("/") ? baseURLString : baseURLString + "/"
            guard let url = URL(string: normalized) else {
                throw AIError.provider("“\(baseURLString)” is not a valid server URL.")
            }
            self.baseURL = url
        }
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    var isLocal: Bool { kind == .lmStudio }

    // MARK: Streaming

    func stream(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isBlank {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if kind == .openRouter {
            urlRequest.setValue("https://obdiag.app", forHTTPHeaderField: "HTTP-Referer")
            urlRequest.setValue("OBDiag", forHTTPHeaderField: "X-Title")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2_000 { break }
            }
            throw AIError.http(status: http.statusCode, message: Self.readableError(from: body, status: http.statusCode))
        }

        return AsyncThrowingStream { continuation in
            let task = Task { [bytes] in
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmed
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let value = JSONValue.parse(payload) else { continue }
                        for event in Self.parse(chunk: value) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Chunk parsing

    static func parse(chunk value: JSONValue) -> [StreamEvent] {
        var events: [StreamEvent] = []

        if let choices = value["choices"]?.arrayValue {
            for choice in choices {
                let delta = choice["delta"]
                let message = choice["message"]

                if let text = delta?["content"]?.stringValue, !text.isEmpty {
                    events.append(.text(text))
                }
                let reasoning = delta?["reasoning"]?.stringValue ?? delta?["reasoning_content"]?.stringValue
                if let reasoning, !reasoning.isEmpty {
                    events.append(.reasoning(reasoning))
                }

                for source in [delta?["tool_calls"], message?["tool_calls"]] {
                    guard let calls = source?.arrayValue else { continue }
                    for call in calls {
                        let index = call["index"]?.intValue ?? 0
                        let id = call["id"]?.stringValue
                        let name = call["function"]?["name"]?.stringValue
                        let arguments = call["function"]?["arguments"]?.stringValue
                        events.append(.toolCallDelta(index: index, id: id, name: name, arguments: arguments))
                    }
                }

                for source in [delta?["annotations"], message?["annotations"]] {
                    if let source, let citations = citations(from: source), !citations.isEmpty {
                        events.append(.citations(citations))
                    }
                }

                if let finish = choice["finish_reason"]?.stringValue, !finish.isEmpty {
                    events.append(.finish(reason: finish))
                }
            }
        }

        if let usageObject = value["usage"]?.objectValue, !usageObject.isEmpty {
            events.append(.usage(parseUsage(usageObject)))
        }
        return events
    }

    /// OpenRouter url_citation annotations, or plain {url,title} objects.
    static func citations(from value: JSONValue) -> [Citation]? {
        guard let array = value.arrayValue else { return nil }
        var citations: [Citation] = []
        for item in array {
            let citationObject = item["url_citation"] ?? item
            guard let url = citationObject["url"]?.stringValue, !url.isEmpty else { continue }
            let title = citationObject["title"]?.stringValue ?? URL(string: url)?.hostDisplayName ?? url
            let content = citationObject["content"]?.stringValue ?? citationObject["snippet"]?.stringValue
            citations.append(Citation(url: url, title: title, snippet: content.map { $0.truncated(to: 400) }))
        }
        return citations
    }

    static func parseUsage(_ object: [String: JSONValue]) -> TokenUsage {
        var usage = TokenUsage()
        usage.promptTokens = object["prompt_tokens"]?.intValue ?? 0
        usage.completionTokens = object["completion_tokens"]?.intValue ?? 0
        usage.totalTokens = object["total_tokens"]?.intValue ?? (usage.promptTokens + usage.completionTokens)
        usage.reasoningTokens = object["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
        usage.costUSD = object["cost"]?.doubleValue ?? 0
        return usage
    }

    static func readableError(from body: String, status: Int) -> String {
        if let value = JSONValue.parse(body) {
            if let message = value["error"]?["message"]?.stringValue { return message }
            if let message = value["error"]?.stringValue { return message }
            if let message = value["message"]?.stringValue { return message }
        }
        let trimmed = body.trimmed
        if trimmed.isEmpty { return "The AI provider returned HTTP \(status)." }
        return "HTTP \(status): \(trimmed.truncated(to: 300))"
    }

    // MARK: Models

    func fetchModels() async throws -> [AIModel] {
        var urlRequest = URLRequest(url: baseURL.appending(path: "models"))
        urlRequest.httpMethod = "GET"
        if !apiKey.isBlank {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                               message: "Could not load the model list.")
        }
        guard let value = JSONValue.parse(data: data), let items = value["data"]?.arrayValue else {
            throw AIError.invalidResponse
        }

        let curated = Dictionary(uniqueKeysWithValues: AIModel.fallbackCatalog.map { ($0.id, $0) })
        var models: [AIModel] = []

        for item in items {
            guard let id = item["id"]?.stringValue else { continue }
            if kind == .lmStudio {
                models.append(
                    AIModel(
                        id: id, name: id, provider: "Local",
                        contextLength: item["context_length"]?.intValue ?? 32_768,
                        promptPricePerToken: 0, completionPricePerToken: 0,
                        supportsTools: true, supportsReasoning: false, supportsImages: false,
                        isFree: true, isRecommended: false,
                        description: "Running locally through LM Studio."
                    )
                )
                continue
            }

            let supported = Set(item["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            // Keep tool-capable text models; they are the only ones the assistant can use.
            if !supported.isEmpty && !supported.contains("tools") { continue }
            let modalities = Set(item["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let outputModalities = Set(item["architecture"]?["output_modalities"]?.arrayValue?.compactMap(\.stringValue) ?? ["text"])
            if !outputModalities.isSubset(of: ["text"]) { continue }

            let pricing = item["pricing"]?.objectValue ?? [:]
            let prompt = pricing["prompt"]?.doubleValue ?? 0
            let completion = pricing["completion"]?.doubleValue ?? 0
            let provider = id.split(separator: "/").first.map { String($0).capitalized } ?? "OpenRouter"
            let curatedModel = curated[id]

            models.append(
                AIModel(
                    id: id,
                    name: item["name"]?.stringValue ?? curatedModel?.name ?? id,
                    provider: provider,
                    contextLength: item["context_length"]?.intValue ?? curatedModel?.contextLength ?? 8_192,
                    promptPricePerToken: prompt,
                    completionPricePerToken: completion,
                    supportsTools: true,
                    supportsReasoning: supported.contains("reasoning") || supported.contains("include_reasoning"),
                    supportsImages: modalities.contains("image"),
                    isFree: prompt == 0 && completion == 0,
                    isRecommended: curatedModel?.isRecommended ?? false,
                    description: item["description"]?.stringValue?.truncated(to: 220) ?? curatedModel?.description
                )
            )
        }

        return models.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.isRecommended != rhs.isRecommended { return lhs.isRecommended }
            return lhs.promptPricePerToken < rhs.promptPricePerToken
        }
    }
}

// MARK: - Demo assistant

/// Deterministic, network-free assistant used by demo mode. It drives the real
/// tool-calling pipeline (it requests live data and fault codes) and then writes
/// a grounded answer, so the whole agent loop is exercised without an API key.
@MainActor
final class DemoAssistant: ChatCompletionClient {
    let displayName = "Demo assistant"
    let isLocal = true

    private weak var obd: OBDSession?
    private weak var garage: GarageStore?

    init(obd: OBDSession, garage: GarageStore) {
        self.obd = obd
        self.garage = garage
    }

    func fetchModels() async throws -> [AIModel] {
        [
            AIModel(
                id: "obdiag/demo", name: "OBDiag Demo", provider: "On-device",
                contextLength: 32_768, promptPricePerToken: 0, completionPricePerToken: 0,
                supportsTools: true, supportsReasoning: false, supportsImages: false,
                isFree: true, isRecommended: false,
                description: "Scripted answers that use your live data, fault codes and vehicle profile."
            )
        ]
    }

    func stream(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await respond(to: request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func respond(
        to request: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let hasToolResult = request.messages.last?.role == "tool"

        if hasToolResult {
            let lastUserMessage = request.messages.last(where: { $0.role == "user" })
            let userText = lastUserMessage?.content ?? ""
            let imageCount = lastUserMessage?.imageDataURLs.count ?? 0
            let answer = composeAnswer(for: userText, imageCount: imageCount)
            try await emit(text: answer, into: continuation)
            continuation.yield(.usage(TokenUsage(
                promptTokens: 480 + imageCount * 900,
                completionTokens: answer.count / 4,
                totalTokens: 480 + imageCount * 900 + answer.count / 4
            )))
            continuation.yield(.finish(reason: "stop"))
            return
        }

        let lastUserMessage = request.messages.last(where: { $0.role == "user" })
        let userText = lastUserMessage?.content ?? ""
        let imageCount = lastUserMessage?.imageDataURLs.count ?? 0
        try await emit(reasoning: "Reviewing \(vehicleLabel) — pulling fault codes and the live sensor snapshot before answering.", into: continuation)

        let vague = userText.count < 16 && imageCount == 0 && !userText.lowercased().contains("p0") && !userText.lowercased().contains("code")
        if vague, obd?.dtcs.isEmpty ?? true {
            continuation.yield(.toolCallDelta(
                index: 0, id: "demo-ask", name: "ask_user",
                arguments: JSONValue.object([
                    "question": .string("What is the car doing right now?"),
                    "header": .string("Quick question"),
                    "options": .array([
                        .object(["label": .string("Won't start or cranks but no start")]),
                        .object(["label": .string("Rough idle or misfire")]),
                        .object(["label": .string("Warning light, drives fine")]),
                        .object(["label": .string("Something else")])
                    ])
                ]).jsonString
            ))
            continuation.yield(.finish(reason: "tool_calls"))
            return
        }

        continuation.yield(.toolCallDelta(index: 0, id: "demo-codes", name: "get_fault_codes", arguments: "{}"))
        continuation.yield(.toolCallDelta(
            index: 1, id: "demo-live", name: "get_live_data",
            arguments: JSONValue.object([
                "sensors": .array([
                    .string("coolantTemperature"), .string("batteryVoltage"),
                    .string("shortTermFuelTrimBank1"), .string("longTermFuelTrimBank1"),
                    .string("intakeAirTemperature"), .string("engineRPM")
                ])
            ]).jsonString
        ))
        continuation.yield(.finish(reason: "tool_calls"))
    }

    private var vehicleLabel: String {
        garage?.selectedVehicle?.composedName ?? "this vehicle"
    }

    // MARK: Answer composition

    private func composeAnswer(for userText: String, imageCount: Int = 0) -> String {
        var lines: [String] = []
        let codes = obd?.dtcs ?? []

        if imageCount > 0 {
            lines.append("### Thanks for the photo")
            lines.append("Your \(imageCount) image\(imageCount == 1 ? " is" : "s are") attached to this conversation. The built-in demo assistant can't actually analyse pictures — switch to a vision-capable model (Gemini Flash, GPT-4o, Claude Sonnet) in the model picker and ask again to have it read warning lights, fluid leaks, damage or part labels.")
            lines.append("")
        }

        if codes.isEmpty {
            lines.append("### No stored fault codes")
            lines.append("I don't see any fault codes stored right now, so nothing is confirmed by the ECU. Here's what the live data shows:")
            lines.append(contentsOf: liveDataBullets())
            lines.append("")
            lines.append("### What I'd check next")
            lines.append("- If the light is on, drive a full warm-up cycle (start cold → fully warm → 10 minutes of mixed driving) so pending monitors can complete.")
            lines.append("- Note when the symptom happens (cold start, braking, turning, accelerating) — that narrows the system quickly.")
            lines.append("- Ask me again with the symptom details and I'll go deeper.")
        } else if let primary = codes.first(where: { $0.status == .stored }) ?? codes.first {
            lines.append("### \(primary.code) — \(primary.title)")
            lines.append(primary.detail)
            lines.append("")
            lines.append("**Severity:** \(primary.severity.title) · \(primary.status.title)")
            if !primary.possibleCauses.isEmpty {
                lines.append("")
                lines.append("### Likely causes")
                for cause in primary.possibleCauses { lines.append("- \(cause)") }
            }
            if !primary.recommendedActions.isEmpty {
                lines.append("")
                lines.append("### What to do next")
                for action in primary.recommendedActions { lines.append("- \(action)") }
            }
            lines.append(contentsOf: liveDataBullets())
            if codes.count > 1 {
                lines.append("")
                lines.append("### Other codes present")
                for code in codes.dropFirst() {
                    lines.append("- **\(code.code)** (\(code.status.title), \(code.severity.title)) — \(code.title)")
                }
            }
            lines.append("")
            lines.append("> This is the on-device demo assistant using your real fault codes and live data. Add an OpenRouter key or LM Studio in **Settings → AI provider** for cited web, video and parts research.")
        }

        if !userText.isBlank {
            lines.insert("**You asked:** \(userText.truncated(to: 120))", at: 0)
            lines.insert("", at: 1)
        }
        return lines.joined(separator: "\n")
    }

    private func liveDataBullets() -> [String] {
        guard let obd, !obd.readings.isEmpty else { return [] }
        let converter = UnitConverter(system: .imperial)
        var bullets: [String] = ["", "### Live data right now"]
        let highlights: [SensorKind] = [.coolantTemperature, .intakeAirTemperature, .batteryVoltage, .shortTermFuelTrimBank1, .longTermFuelTrimBank1, .engineRPM]
        for kind in highlights {
            guard let reading = obd.reading(kind), reading.isValid else { continue }
            let definition = obd.definition(for: kind)
            let health = obd.health(for: kind)
            let value = converter.formattedWithUnit(reading.value, kind: definition.measure)
            let qualifier = health == .normal ? "" : " — **\(health.label.lowercased())**"
            bullets.append("- \(definition.name): **\(value)**\(qualifier)")
        }
        return bullets
    }

    // MARK: Emission helpers

    private func emit(text: String, into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        let chunks = Self.chunks(of: text, size: 14)
        for chunk in chunks {
            try Task.checkCancellation()
            continuation.yield(.text(chunk))
            try await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    private func emit(reasoning: String, into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        for chunk in Self.chunks(of: reasoning, size: 20) {
            try Task.checkCancellation()
            continuation.yield(.reasoning(chunk))
            try await Task.sleep(nanoseconds: 18_000_000)
        }
    }

    private static func chunks(of text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
