import Foundation

/// An image the user attached to a message. The bytes live on disk in
/// `AttachmentStore`; the message only stores metadata so transcripts stay small.
struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var addedAt: Date = Date()

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var sizeLabel: String { Format.byteCount(byteCount) }

    /// Rough multimodal token cost (OpenAI's 750px-per-token heuristic).
    var estimatedTokens: Int {
        max(85, (pixelWidth * pixelHeight) / 750)
    }
}
