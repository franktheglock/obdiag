import Foundation
@testable import OBDiag

/// Renders eval runs as a markdown table plus a JSON artifact, so regressions
/// can be tracked over time and compared across models.
enum EvalReport {

    static func render(
        aggregates: [EvalAggregate],
        results: [(EvalHarness.RunResult, [GraderOutcome])]
    ) -> String {
        var lines: [String] = []
        lines.append("# OBDiag eval report")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("## Summary")
        lines.append("")
        lines.append("| Model | Tier | Pass | Grounded | Citations | Safety | Abstention | Credits/answer | Latency | Tools | Timeouts |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for aggregate in aggregates {
            let grounded = percent(1 - Double(aggregate.unsupportedClaims) / Double(max(aggregate.scenarios, 1)))
            let abstention = aggregate.abstentionScenarios == 0
                ? "—"
                : "\(aggregate.abstentionCorrect)/\(aggregate.abstentionScenarios)"
            lines.append([
                aggregate.modelName,
                aggregate.tier,
                "\(aggregate.passed)/\(aggregate.scenarios) (\(percent(aggregate.passRate)))",
                grounded,
                percent(aggregate.citationRate),
                percent(aggregate.safetyPassRate),
                abstention,
                String(format: "%.0f", aggregate.avgCredits),
                String(format: "%.1fs", aggregate.avgLatency),
                String(format: "%.1f", aggregate.avgToolCalls),
                "\(aggregate.timeouts)"
            ].joined(separator: " | ").withTablePipes())
        }
        lines.append("")

        lines.append("## Per-grader pass rates")
        lines.append("")
        let graderNames = Set(aggregates.flatMap { $0.graderRates.keys }).sorted()
        if !graderNames.isEmpty {
            lines.append("| Model | " + graderNames.joined(separator: " | ") + " |")
            lines.append("|" + String(repeating: "---|", count: graderNames.count + 1))
            for aggregate in aggregates {
                let cells = graderNames.map { name in
                    aggregate.graderRates[name].map(percent) ?? "—"
                }
                lines.append("| \(aggregate.modelName) | " + cells.joined(separator: " | ") + " |")
            }
            lines.append("")
        }

        lines.append("## Failures")
        lines.append("")
        var anyFailures = false
        for (result, outcomes) in results {
            let failures = outcomes.filter { !$0.passed }
            guard !failures.isEmpty else { continue }
            anyFailures = true
            lines.append("### \(result.modelName) · `\(result.scenarioID)`")
            lines.append("")
            lines.append("_\(result.scenarioTitle)_")
            lines.append("")
            for failure in failures {
                lines.append("- **\(failure.name)**: \(failure.detail)")
            }
            if let error = result.error {
                lines.append("- error: \(error)")
            }
            lines.append("")
            lines.append("<details><summary>transcript</summary>")
            lines.append("")
            lines.append(result.transcriptMarkdown)
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }
        if !anyFailures {
            lines.append("No failures. 🎉")
            lines.append("")
        }

        lines.append("## Cost per scenario")
        lines.append("")
        lines.append("| Model | Scenario | Credits | Input tokens | Output tokens | Cached | Latency |")
        lines.append("|---|---|---|---|---|---|---|")
        for (result, _) in results {
            lines.append("| \(result.modelName) | \(result.scenarioID) | \(result.creditsSpent) | \(result.usage.promptTokens) | \(result.usage.completionTokens) | \(result.usage.cachedPromptTokens) | \(String(format: "%.1fs", result.latency)) |")
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    static func write(
        aggregates: [EvalAggregate],
        results: [(EvalHarness.RunResult, [GraderOutcome])],
        markdown: String
    ) {
        let directory = EvalConfig.reportsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let markdownURL = directory.appendingPathComponent("eval-\(stamp).md")
        try? markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let payload = JSONPayload(
            generatedAt: Date(),
            aggregates: aggregates,
            results: results.map { result, outcomes in
                JSONPayload.Result(
                    scenarioID: result.scenarioID,
                    scenarioTitle: result.scenarioTitle,
                    category: result.category,
                    modelID: result.modelID,
                    passed: outcomes.allSatisfy(\.passed),
                    outcomes: outcomes,
                    creditsSpent: result.creditsSpent,
                    promptTokens: result.usage.promptTokens,
                    completionTokens: result.usage.completionTokens,
                    cachedTokens: result.usage.cachedPromptTokens,
                    latency: result.latency,
                    timedOut: result.timedOut,
                    error: result.error
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            try? data.write(to: directory.appendingPathComponent("eval-\(stamp).json"))
        }

        print("Wrote eval report to \(markdownURL.path)")
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private struct JSONPayload: Codable {
        struct Result: Codable {
            var scenarioID: String
            var scenarioTitle: String
            var category: String
            var modelID: String
            var passed: Bool
            var outcomes: [GraderOutcome]
            var creditsSpent: Int
            var promptTokens: Int
            var completionTokens: Int
            var cachedTokens: Int
            var latency: TimeInterval
            var timedOut: Bool
            var error: String?
        }

        var generatedAt: Date
        var aggregates: [EvalAggregate]
        var results: [Result]
    }
}

private extension String {
    /// Escapes pipes so the value survives a markdown table.
    func withTablePipes() -> String {
        replacingOccurrences(of: "|", with: "\\|")
    }
}
