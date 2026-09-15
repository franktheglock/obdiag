import Foundation

// MARK: - Wire types (OpenAI-compatible chat completions)

struct WireFunctionCall: Codable, Hashable {
    var name: String
    var arguments: String
}

struct WireToolCall: Codable, Hashable, Identifiable {
    var id: String
    var type: String = "function"
    var function: WireFunctionCall

    enum CodingKeys: String, CodingKey { case id, type, function }
}

/// A content block. Used to place explicit prompt-cache breakpoints, which
/// Anthropic models require (`cache_control: {"type": "ephemeral"}`).
///
/// A breakpoint marks the end of a reusable prefix: the provider caches
/// everything up to and including that block and serves it at the much cheaper
/// cache-read rate on later turns. Other providers cache automatically and
/// ignore the marker, so it is only attached when the model needs it.
struct WireContentBlock: Codable, Hashable {
    var type: String = "text"
    var text: String
    var cacheControl: CacheControl?

    struct CacheControl: Codable, Hashable {
        var type: String = "ephemeral"
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    static func text(_ text: String, cacheBreakpoint: Bool = false) -> WireContentBlock {
        WireContentBlock(text: text, cacheControl: cacheBreakpoint ? CacheControl() : nil)
    }
}

struct WireMessage: Codable {
    var role: String
    var content: String?
    /// `data:image/jpeg;base64,…` payloads for vision models.
    var imageDataURLs: [String]
    var toolCalls: [WireToolCall]?
    var toolCallID: String?
    var name: String?
    /// Explicit multi-block content. Takes precedence over `content` when set,
    /// and is how cache breakpoints are expressed.
    var blocks: [WireContentBlock]?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(
        role: String,
        content: String? = nil,
        imageDataURLs: [String] = [],
        toolCalls: [WireToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        blocks: [WireContentBlock]? = nil
    ) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.blocks = blocks
    }

    /// Multimodal content is emitted as the OpenAI/OpenRouter part array;
    /// plain text messages stay a simple string.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let blocks, !blocks.isEmpty {
            try container.encode(blocks, forKey: .content)
        } else if !imageDataURLs.isEmpty {
            var parts: [JSONValue] = []
            if let content, !content.isEmpty {
                parts.append(.object([
                    "type": .string("text"),
                    "text": .string(content)
                ]))
            }
            for dataURL in imageDataURLs {
                parts.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(dataURL)])
                ]))
            }
            try container.encode(JSONValue.array(parts), forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }

        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        imageDataURLs = []
        toolCalls = try container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        blocks = nil
    }

    /// A system message whose fixed part is marked as a cache breakpoint and
    /// whose variable part follows it uncached.
    static func system(
        stable: String,
        volatile: String,
        cacheStable: Bool
    ) -> WireMessage {
        guard cacheStable, !volatile.isEmpty else {
            if cacheStable {
                return WireMessage(role: "system", blocks: [.text(stable, cacheBreakpoint: true)])
            }
            return WireMessage(role: "system", content: volatile.isEmpty ? stable : stable + "\n\n" + volatile)
        }
        return WireMessage(role: "system", blocks: [
            .text(stable, cacheBreakpoint: true),
            .text(volatile)
        ])
    }

    /// Re-emits this message with a cache breakpoint at its end, so a later turn
    /// can reuse the whole transcript prefix. Only meaningful for text content;
    /// returns self unchanged otherwise.
    func markingCacheBreakpoint() -> WireMessage {
        guard blocks == nil, imageDataURLs.isEmpty, toolCalls == nil else { return self }
        let text = content ?? ""
        guard !text.isEmpty else { return self }
        var copy = self
        copy.content = nil
        copy.blocks = [.text(text, cacheBreakpoint: true)]
        return copy
    }

    static func system(_ content: String) -> WireMessage {
        WireMessage(role: "system", content: content)
    }
    static func user(_ content: String, images: [String] = []) -> WireMessage {
        WireMessage(role: "user", content: content, imageDataURLs: images)
    }

    static func assistant(content: String?, toolCalls: [WireToolCall]? = nil) -> WireMessage {
        WireMessage(role: "assistant", content: content, toolCalls: toolCalls)
    }

    static func tool(_ content: String, toolCallID: String, name: String) -> WireMessage {
        WireMessage(role: "tool", content: content, toolCallID: toolCallID, name: name)
    }
}

struct ToolDefinition: Codable, Hashable {
    var type: String = "function"
    var function: FunctionDefinition?
    /// Server-side tools (e.g. `openrouter:web_search`) carry parameters here.
    var parameters: JSONValue?

    struct FunctionDefinition: Codable, Hashable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    static func function(name: String, description: String, parameters: JSONValue) -> ToolDefinition {
        ToolDefinition(function: FunctionDefinition(name: name, description: description, parameters: parameters))
    }

    /// A server-executed OpenRouter tool, e.g. `openrouter:web_search`.
    static func serverTool(_ type: String, parameters: JSONValue? = nil) -> ToolDefinition {
        ToolDefinition(type: type, function: nil, parameters: parameters)
    }
}

struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [WireMessage]
    var stream = true
    var streamOptions = StreamOptions(includeUsage: true)
    var usage = UsageInclude(include: true)
    var tools: [ToolDefinition]?
    var toolChoice: String?
    var reasoning: ReasoningConfig?
    var temperature: Double?
    var maxTokens: Int?
    var provider: ProviderPreferences?

    struct StreamOptions: Encodable { var includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }
    struct UsageInclude: Encodable { var include: Bool }
    struct ReasoningConfig: Encodable {
        var effort: String?
        var exclude = false
    }
    struct ProviderPreferences: Encodable {
        var sort: String?
        var requireParameters: Bool?
        enum CodingKeys: String, CodingKey {
            case sort
            case requireParameters = "require_parameters"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools, usage, reasoning, temperature, provider
        case streamOptions = "stream_options"
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

/// Normalized streaming events from any provider.
enum StreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case citations([Citation])
    case usage(TokenUsage)
    case finish(reason: String?)
}

enum AIError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case http(status: Int, message: String)
    case noModelSelected
    case insufficientCredits
    case cancelled
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider) API key in Settings → AI provider to use cloud models."
        case .invalidResponse:
            return "The AI provider returned an unexpected response."
        case .http(let status, let message):
            return message.isEmpty ? "The AI provider returned HTTP \(status)." : message
        case .noModelSelected:
            return "Choose a model in Settings → AI model."
        case .insufficientCredits:
            return "You're out of AI credits. Top up or switch to a local model in Settings."
        case .cancelled:
            return "Generation stopped."
        case .provider(let message):
            return message
        }
    }
}
