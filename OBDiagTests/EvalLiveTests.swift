import XCTest
@testable import OBDiag

/// Live model comparison. Skipped automatically when no API key is configured,
/// so CI stays green and free; run it locally (or in a nightly job with the
/// key in a secret) when choosing or re-validating a tier model.
///
///     mkdir -p .eval && echo "$OPENROUTER_KEY" > .eval/openrouter-key
///     xcodebuild test -project OBDiag.xcodeproj -scheme OBDiag \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:OBDiagTests/EvalLiveTests
@MainActor
final class EvalLiveTests: XCTestCase {

    func testLiveModelComparison() async throws {
        guard let apiKey = EvalConfig.apiKey() else {
            throw XCTSkip("No eval key. Add .eval/openrouter-key or set OBDIAG_EVAL_KEY.")
        }

        let models = EvalConfig.selectedModels()
        let scenarios = try EvalScenarioLibrary.load(ids: EvalConfig.selectedScenarioIDs())
        XCTAssertFalse(models.isEmpty, "No models selected")
        XCTAssertFalse(scenarios.isEmpty, "No scenarios selected")

        var results: [(EvalHarness.RunResult, [GraderOutcome])] = []

        for model in models {
            print("▶︎ \(model.name) (\(model.priceLabel)) · \(scenarios.count) scenarios")
            for scenario in scenarios {
                let result = await EvalHarness.run(scenario: scenario, model: model, apiKey: apiKey)
                let outcomes = EvalGraders.grade(result, scenario: scenario)
                results.append((result, outcomes))

                let passed = outcomes.allSatisfy(\.passed)
                let failures = outcomes.filter { !$0.passed }.map { "\($0.name)(\($0.detail))" }.joined(separator: ", ")
                print(String(
                    format: "  %@ %-28@ %5.1fs %4d cr %@",
                    passed ? "✓" : "✗",
                    scenario.id,
                    result.latency,
                    result.creditsSpent,
                    passed ? "" : "→ \(failures)"
                ))
            }
        }

        let aggregates = models.map { model in
            EvalAggregator.aggregate(model: model, results: results.filter { $0.0.modelID == model.id })
        }
        let markdown = EvalReport.render(aggregates: aggregates, results: results)
        print("\n" + markdown)
        EvalReport.write(aggregates: aggregates, results: results, markdown: markdown)

        // Optional release gate: fail the run when quality regresses.
        if ProcessInfo.processInfo.environment["OBDIAG_EVAL_GATE"] == "1" {
            for aggregate in aggregates {
                XCTAssertEqual(aggregate.timeouts, 0, "\(aggregate.modelName) had timeouts")
                XCTAssertEqual(aggregate.safetyPassRate, 1.0, "\(aggregate.modelName) missed safety guidance")
                XCTAssertGreaterThanOrEqual(aggregate.passRate, 0.8, "\(aggregate.modelName) below 80% pass rate")
            }
        }
    }
}
