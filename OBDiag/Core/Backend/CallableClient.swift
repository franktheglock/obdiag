import Foundation

/// Errors surfaced by the OBDiag backend.
enum BackendError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case http(status: Int, message: String)
    case malformedResponse(String)
    case function(code: String, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build isn't connected to the OBDiag service yet."
        case .notSignedIn:
            return "Sign in to use the AI assistant."
        case .http(let status, let message):
            return message.isEmpty ? "The service returned HTTP \(status)." : message
        case .malformedResponse(let detail):
            return "The service returned an unexpected response. \(detail)"
        case .function(_, let message):
            return message
        case .transport(let message):
            return message
        }
    }

    /// True when the caller should top up or upgrade.
    var isInsufficientCredits: Bool {
        if case .function(let code, _) = self {
            return code == "resource-exhausted"
        }
        return false
    }

    /// True when the account needs to sign in again.
    var isUnauthenticated: Bool {
        switch self {
        case .notSignedIn:
            return true
        case .function(let code, _):
            return code == "unauthenticated"
        case .http(let status, _):
            return status == 401
        default:
            return false
        }
    }
}

/// A chunk of a streamed assistant response.
enum BackendStreamEvent: Sendable {
    /// A raw OpenRouter SSE payload, forwarded verbatim by the server.
    case chunk(String)
    /// The server's final accounting for the request.
    case finished(BackendChatReceipt)
}

/// Final accounting returned when a streamed chat completes.
struct BackendChatReceipt: Decodable, Sendable {
    var model: String?
    var creditsCharged: Int?
    var balance: Int?
}

private struct BackendChatMessageEnvelope: Decodable {
    var message: BackendChatChunk?
    var result: BackendChatReceipt?
    var error: BackendFunctionError?
}

private struct BackendChatChunk: Decodable {
    var chunk: String
}

private struct BackendFunctionError: Decodable {
    var status: String?
    var message: String?
}

/// Minimal client for Firebase callable functions.
///
/// The Firebase iOS SDK exposes streaming callables only as an internal API, so
/// this implements the documented callable wire protocol directly:
///
///   POST https://<region>-<project>.cloudfunctions.net/<name>
///   { "data": <payload> }
///   Accept: text/event-stream
///
/// Response frames are SSE (`data: <json>`), where each frame is one of
/// `{"message": …}` (a streamed chunk), `{"result": …}` (the final value) or
/// `{"error": …}`. Blank lines and heartbeats are ignored.
final class CallableClient: @unchecked Sendable {
    private let session: URLSession
    /// Supplies a Firebase ID token, refreshed per request.
    private let idTokenProvider: () async throws -> String
    /// Supplies an App Check token, when App Check is configured.
    private let appCheckTokenProvider: () async throws -> String?

    init(
        idTokenProvider: @escaping () async throws -> String,
        appCheckTokenProvider: @escaping () async throws -> String? = { nil },
        session: URLSession = .shared
    ) {
        self.idTokenProvider = idTokenProvider
        self.appCheckTokenProvider = appCheckTokenProvider
        self.session = session
    }

    // MARK: Request building

    private func makeRequest(name: String, payload: [String: Any]) async throws -> URLRequest {
        guard let url = BackendConfig.callableURL(name) else {
            throw BackendError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let token = try await idTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let appCheck = try await appCheckTokenProvider() {
            request.setValue(appCheck, forHTTPHeaderField: "X-Firebase-AppCheck")
        }

        // The callable envelope wraps the payload in `data`.
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["data": payload],
            options: [.fragmentsAllowed]
        )
        return request
    }

    // MARK: Unary calls

    func call<T: Decodable>(
        _ name: String,
        payload: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T {
        let request = try await makeRequest(name: name, payload: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.malformedResponse("No HTTP response.")
        }

        if let envelope = try? JSONDecoder().decode(UnaryEnvelope<T>.self, from: data) {
            if let error = envelope.error {
                throw BackendError.function(
                    code: error.status ?? "internal",
                    message: error.message ?? "The request failed."
                )
            }
            if let result = envelope.result {
                return result
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(
                status: http.statusCode,
                message: Self.readableMessage(from: data)
            )
        }
        throw BackendError.malformedResponse("Could not decode the result.")
    }

    // MARK: Streaming

    func stream(
        _ name: String,
        payload: [String: Any]
    ) -> AsyncThrowingStream<BackendStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await makeRequest(name: name, payload: payload)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw BackendError.malformedResponse("No HTTP response.")
                    }
                    // A callable error response is JSON, not SSE.
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4_000 { break }
                        }
                        throw BackendError.http(
                            status: http.statusCode,
                            message: Self.readableMessage(from: Data(body.utf8))
                        )
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !json.isEmpty, let data = json.data(using: .utf8) else { continue }

                        guard let envelope = try? JSONDecoder().decode(
                            BackendChatMessageEnvelope.self, from: data
                        ) else { continue }

                        if let error = envelope.error {
                            throw BackendError.function(
                                code: error.status ?? "internal",
                                message: error.message ?? "The assistant failed."
                            )
                        }
                        if let chunk = envelope.message {
                            continuation.yield(.chunk(chunk.chunk))
                        }
                        if let result = envelope.result {
                            continuation.yield(.finished(result))
                            break
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

    // MARK: Helpers

    private struct UnaryEnvelope<T: Decodable>: Decodable {
        var result: T?
        var error: BackendFunctionError?
    }

    /// Pulls a readable message out of a callable error body.
    static func readableMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.map { String($0.prefix(300)) } ?? ""
    }
}
