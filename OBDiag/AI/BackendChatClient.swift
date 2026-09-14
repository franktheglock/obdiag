import Foundation

/// Assistant provider backed by the OBDiag service.
///
/// The server holds the OpenRouter key and meters credits; this client only
/// forwards an OpenAI-shaped request and re-uses the same chunk parser as the
/// direct provider, because the server relays OpenRouter's SSE frames verbatim.
@MainActor
final class BackendChatClient: ChatCompletionClient {
    let displayName = "OBDiag"

    /// Credits are debited server-side during the stream, so the local ledger
    /// must stay out of it.
    let isServerMetered = true

    private let callable: CallableClient
    private let account: BackendAccountStore

    init(callable: CallableClient, account: BackendAccountStore) {
        self.callable = callable
        self.account = account
    }

    func stream(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let payload = try Self.encode(request)
        let upstream = callable.stream(BackendConfig.Function.chat, payload: payload)

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await event in upstream {
                        try Task.checkCancellation()
                        switch event {
                        case .chunk(let raw):
                            guard let value = JSONValue.parse(raw) else { continue }
                            for mapped in RemoteChatClient.parse(chunk: value) {
                                continuation.yield(mapped)
                            }
                        case .finished(let receipt):
                            account.applyReceipt(receipt)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The server is the catalogue authority, so newly added models appear
    /// without an app update.
    func fetchModels() async throws -> [AIModel] {
        struct Response: Decodable { var models: [Model] }
        struct Model: Decodable {
            var id: String
            var name: String
            var provider: String
            var contextLength: Int
            var promptPricePerToken: Double
            var completionPricePerToken: Double
            var supportsTools: Bool
            var supportsReasoning: Bool
            var supportsImages: Bool
            var isFree: Bool
            var isRecommended: Bool
            var description: String?
        }

        let response = try await callable.call(
            BackendConfig.Function.listModels,
            as: Response.self
        )

        return response.models.map { model in
            AIModel(
                id: model.id,
                name: model.name,
                provider: model.provider,
                contextLength: model.contextLength,
                promptPricePerToken: model.promptPricePerToken,
                completionPricePerToken: model.completionPricePerToken,
                supportsTools: model.supportsTools,
                supportsReasoning: model.supportsReasoning,
                supportsImages: model.supportsImages,
                isFree: model.isFree,
                isRecommended: model.isRecommended,
                description: model.description
            )
        }
    }

    private static func encode(_ request: ChatCompletionRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.malformedResponse("Could not encode the request.")
        }
        return object
    }
}
