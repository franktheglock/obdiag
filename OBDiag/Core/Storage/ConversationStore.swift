import Foundation
import Observation

/// Per-vehicle chat history. Conversations survive relaunches and never leave
/// the device.
@MainActor
@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []

    private static let fileName = "conversations.json"

    init() {
        if let stored = FileStore.load([Conversation].self, from: Self.fileName) {
            conversations = stored
        }
    }

    func conversations(for vehicleID: UUID?) -> [Conversation] {
        conversations
            .filter { $0.vehicleID == vehicleID }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func conversation(withID id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func create(for vehicle: Vehicle?, modelID: String) -> Conversation {
        let conversation = Conversation.new(for: vehicle, modelID: modelID)
        conversations.append(conversation)
        persist()
        return conversation
    }

    func delete(_ id: UUID) {
        if let conversation = conversation(withID: id) {
            AttachmentStore.delete(conversation.messages.flatMap(\.attachments))
        }
        conversations.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        AttachmentStore.deleteAll()
        conversations.removeAll()
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        mutate(id) { conversation in
            conversation.title = title.trimmed.isEmpty ? conversation.title : title.trimmed
        }
    }

    func togglePin(_ id: UUID) {
        mutate(id) { $0.isPinned.toggle() }
    }

    func appendMessage(_ message: ChatMessage, to id: UUID) {
        mutate(id) { conversation in
            conversation.messages.append(message)
            conversation.updatedAt = Date()
        }
    }

    func replaceMessage(_ message: ChatMessage, in conversationID: UUID) {
        mutate(conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return }
            conversation.messages[index] = message
            conversation.updatedAt = Date()
        }
    }

    /// Applies a mutation and updates metadata. Use this for streaming updates
    /// to avoid writing on every token — call `persist()` when the stream ends.
    func mutate(_ id: UUID, _ transform: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        transform(&conversations[index])
    }

    func setTitleIfNeeded(_ id: UUID, from text: String) {
        mutate(id) { conversation in
            guard conversation.title == "New conversation" || conversation.title.isBlank else { return }
            let cleaned = text.trimmed
            guard !cleaned.isEmpty else { return }
            conversation.title = String(cleaned.prefix(48))
        }
        persist()
    }

    func setModel(_ modelID: String, for id: UUID) {
        mutate(id) { $0.modelID = modelID }
        persist()
    }

    func addUsage(_ usage: TokenUsage, to id: UUID) {
        mutate(id) { $0.totalUsage = $0.totalUsage + usage }
    }

    func persist() {
        FileStore.save(conversations, to: Self.fileName)
    }
}
