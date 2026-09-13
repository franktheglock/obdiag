import Foundation

// MARK: - Chat domain

enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// A source the assistant cited while answering.
struct Citation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var snippet: String?

    var urlValue: URL? { URL(string: url) }
    var host: String { urlValue?.hostDisplayName ?? url.truncated(to: 40) }
}

enum ToolCallStatus: String, Codable, Sendable {
    case running
    case awaitingUser
    case succeeded
    case failed
}

/// A tool invocation the assistant made, retained in the transcript so users
/// can see exactly how it arrived at an answer.
struct ToolCallRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var systemImage: String
    var arguments: String
    var result: String?
    var status: ToolCallStatus
    var startedAt: Date
    var finishedAt: Date?

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var resultPreview: String? {
        result?.truncated(to: 400)
    }
}

struct TokenUsage: Codable, Hashable, Sendable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var reasoningTokens: Int = 0
    /// Prompt tokens served from a provider cache — billed at a steep discount.
    var cachedPromptTokens: Int = 0
    var costUSD: Double = 0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            cachedPromptTokens: lhs.cachedPromptTokens + rhs.cachedPromptTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }
}

/// A multiple-choice question the assistant can ask mid-answer.
struct AskUserQuestion: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var question: String
    var header: String?
    var options: [Option]
    var allowsMultiple: Bool
    var allowsFreeform: Bool
    var answer: String?

    struct Option: Identifiable, Codable, Hashable, Sendable {
        var id: String = UUID().uuidString
        var label: String
        var detail: String?
        var isRecommended: Bool = false
    }

    var isAnswered: Bool { answer != nil }
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: ChatRole
    var text: String = ""
    /// Images the user attached to this message (stored on disk).
    var attachments: [MessageAttachment] = []
    var reasoning: String?
    var createdAt: Date = Date()
    var citations: [Citation] = []
    var toolCalls: [ToolCallRecord] = []
    var question: AskUserQuestion?
    var usage: TokenUsage?
    var modelID: String?
    var isError: Bool = false
    /// True while the reply is being streamed. Never persisted as true.
    var isStreaming: Bool = false
    /// True when generation was halted with Stop.
    var isStopped: Bool = false

    var hasBody: Bool { !text.isBlank || !attachments.isEmpty }

    static func user(_ text: String, attachments: [MessageAttachment] = []) -> ChatMessage {
        ChatMessage(role: .user, text: text, attachments: attachments)
    }

    static func assistant(text: String = "", modelID: String? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, modelID: modelID, isStreaming: true)
    }

    static func error(_ message: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: message, isError: true)
    }
}

/// One chat thread, always scoped to a vehicle (or the direct connection).
struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var vehicleID: UUID?
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []
    var modelID: String
    var isPinned: Bool = false
    var totalUsage: TokenUsage = TokenUsage()

    var lastMessagePreview: String? {
        messages.last(where: { $0.role == .user || ($0.role == .assistant && $0.hasBody) })?.text.truncated(to: 90)
    }

    var messageCount: Int { messages.count }

    static func new(for vehicle: Vehicle?, modelID: String) -> Conversation {
        Conversation(
            vehicleID: vehicle?.id,
            title: "New conversation",
            modelID: modelID
        )
    }
}
