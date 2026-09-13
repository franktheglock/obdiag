import Foundation
import UIKit
@testable import OBDiag

/// Runs one scenario through the *production* pipeline — the real
/// `PromptBuilder`, `ChatEngine` agent loop, tool executor and streaming client —
/// with the network only used for the model call itself.
@MainActor
enum EvalHarness {

    struct RunResult {
        var scenarioID: String
        var scenarioTitle: String
        var category: String
        var modelID: String
        var modelName: String
        var finalText: String
        var messages: [ChatMessage]
        var toolCalls: [ToolCallRecord]
        var toolCorpus: String
        var usage: TokenUsage
        var creditsSpent: Int
        var latency: TimeInterval
        var timedOut: Bool
        var error: String?

        var toolNames: [String] { toolCalls.map(\.name) }

        var transcriptMarkdown: String {
            messages.map { message in
                var lines: [String] = []
                switch message.role {
                case .user:
                    let images = message.attachments.isEmpty ? "" : " [\(message.attachments.count) image(s)]"
                    lines.append("**User**: \(message.text)\(images)")
                case .assistant:
                    if let reasoning = message.reasoning, !reasoning.isBlank {
                        lines.append("<details><summary>reasoning</summary>\n\n\(reasoning)\n\n</details>")
                    }
                    if !message.text.isBlank { lines.append("**Assistant**: \(message.text)") }
                    for call in message.toolCalls {
                        let status = call.status == .succeeded ? "ok" : call.status.rawValue
                        lines.append("- tool `\(call.name)` (\(status)) args=\(call.arguments.truncated(to: 300))")
                    }
                case .tool, .system:
                    break
                }
                return lines.joined(separator: "\n")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }
    }

    static func run(scenario: EvalScenario, model: EvalModel, apiKey: String) async -> RunResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("obdiag-eval-\(scenario.id)-\(UUID().uuidString)")
        FileStore.overrideRoot = scratch
        defer { FileStore.overrideRoot = nil }

        let defaults = UserDefaults(suiteName: "obdiag.eval.\(UUID().uuidString)") ?? .standard
        let settings = AppSettings(defaults: defaults)
        settings.provider = .openRouter
        settings.searchBackend = .duckDuckGo   // use client-side tools so fixtures apply
        settings.cachedModels = [model.asAIModel]
        settings.selectedModelID = model.id
        settings.showReasoning = false
        settings.webSearchEnabled = true
        settings.videoSearchEnabled = true
        settings.partsSearchEnabled = true
        settings.urlReadingEnabled = true
        settings.askUserEnabled = true

        let garage = GarageStore()
        let vehicle = garage.add(scenario.vehicle.vehicle())
        if !scenario.vehicle.lastKnownCodes.isEmpty {
            garage.recordScan(vehicleID: vehicle.id, codes: scenario.vehicle.lastKnownCodes)
        }

        let conversations = ConversationStore()
        let credits = CreditLedger()
        credits.grant(1_000_000, reason: .adjustment, note: "eval run")

        let search = SearchService(settings: settings)
        search.backendOverride = FixtureSearchBackend(fixtures: scenario.searchFixtures)
        search.readURLOverride = { url in
            guard let page = FixtureSearchBackend.page(for: url, in: scenario.searchFixtures) else {
                throw SearchError.noResults
            }
            return page
        }

        let obd = OBDSession(settings: settings, garage: garage)
        obd.applyFixture(
            adapterName: scenario.obd.adapterName,
            connected: scenario.obd.connected,
            readings: sensorReadings(from: scenario.obd.readings),
            codes: scenario.obd.codes.map { ($0.code, dtcStatus($0.status)) },
            monitor: scenario.obd.monitor.map {
                MonitorStatus(
                    milOn: $0.milOn,
                    dtcCount: $0.dtcCount,
                    misfireMonitorComplete: $0.misfireComplete,
                    fuelSystemMonitorComplete: $0.fuelComplete,
                    componentsMonitorComplete: $0.componentsComplete
                )
            },
            vin: scenario.obd.vin
        )

        let chat = ChatEngine(
            settings: settings,
            garage: garage,
            conversations: conversations,
            credits: credits,
            obd: obd,
            search: search
        )
        chat.planProvider = { .pro }
        if let apiKeyNonEmpty = Optional(apiKey), !apiKeyNonEmpty.isEmpty {
            chat.clientOverride = try? RemoteChatClient(kind: .openRouter, apiKey: apiKey, baseURLString: "")
        }
        chat.autoAnswer = { question in
            scenario.autoAnswer ?? question.options.first?.label ?? "Not sure"
        }

        var attachments: [MessageAttachment] = []
        if scenario.attachImage, let image = syntheticWarningLightImage(), let attachment = AttachmentStore.save(image) {
            attachments.append(attachment)
        }

        let conversation = conversations.create(for: vehicle, modelID: model.id)
        for turn in scenario.history {
            conversations.appendMessage(.user(turn.user), to: conversation.id)
            conversations.appendMessage(.assistant(text: turn.assistant), to: conversation.id)
        }

        let start = Date()
        chat.send(scenario.prompt, attachments: attachments, in: conversation.id)
        await chat.waitUntilIdle(timeout: scenario.timeout)
        let elapsed = Date().timeIntervalSince(start)

        let messages = conversations.conversation(withID: conversation.id)?.messages ?? []
        let assistantMessages = messages.filter { $0.role == .assistant && !$0.isError }
        let toolCalls = assistantMessages.flatMap(\.toolCalls)
        let usage = assistantMessages.compactMap(\.usage).reduce(TokenUsage()) { $0 + $1 }
        let finalText = assistantMessages.last(where: { $0.hasBody })?.text ?? ""
        let error = messages.last(where: { $0.isError })?.text

        let result = RunResult(
            scenarioID: scenario.id,
            scenarioTitle: scenario.title,
            category: scenario.category,
            modelID: model.id,
            modelName: model.name,
            finalText: finalText,
            messages: messages,
            toolCalls: toolCalls,
            toolCorpus: toolCalls.compactMap(\.result).joined(separator: "\n"),
            usage: usage,
            creditsSpent: credits.lifetimeSpent,
            latency: elapsed,
            timedOut: chat.isGenerating,
            error: error
        )

        AttachmentStore.delete(attachments)
        return result
    }

    // MARK: Fixture helpers

    private static func sensorReadings(from raw: [String: Double]) -> [SensorKind: Double] {
        var readings: [SensorKind: Double] = [:]
        for (key, value) in raw {
            if let kind = SensorKind(rawValue: key) {
                readings[kind] = value
            }
        }
        return readings
    }

    private static func dtcStatus(_ raw: String) -> DTCStatus {
        DTCStatus(rawValue: raw.lowercased()) ?? .stored
    }

    /// Draws a plausible "CHECK ENGINE" dashboard photo so vision scenarios have
    /// something readable to reason about.
    private static func syntheticWarningLightImage() -> UIImage? {
        let size = CGSize(width: 900, height: 620)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.05, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let centerX = size.width / 2
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: centerX, y: 90))
            triangle.addLine(to: CGPoint(x: centerX + 180, y: 400))
            triangle.addLine(to: CGPoint(x: centerX - 180, y: 400))
            triangle.close()
            UIColor(red: 1.0, green: 0.72, blue: 0.08, alpha: 1).setFill()
            triangle.fill()

            let stem = UIBezierPath(roundedRect: CGRect(x: centerX - 16, y: 190, width: 32, height: 120), cornerRadius: 16)
            UIColor(white: 0.05, alpha: 1).setFill()
            stem.fill()
            UIBezierPath(ovalIn: CGRect(x: centerX - 17, y: 330, width: 34, height: 34)).fill()

            let caption = "CHECK ENGINE" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 58, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let textSize = caption.size(withAttributes: attributes)
            caption.draw(at: CGPoint(x: centerX - textSize.width / 2, y: 450), withAttributes: attributes)
        }
    }
}
