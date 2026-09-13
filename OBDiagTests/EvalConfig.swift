import Foundation
@testable import OBDiag

/// Where the eval gets its key, models and scenario selection. Nothing here is
/// needed for a normal build — the eval only runs when a key is present.
enum EvalConfig {
    /// Repo root, derived from this file's compile-time path.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OBDiagTests
            .deletingLastPathComponent()   // repo root
    }

    static var supportDirectory: URL {
        repoRoot.appendingPathComponent(".eval", isDirectory: true)
    }

    /// Env var wins; otherwise `.eval/openrouter-key` (gitignored).
    static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["OBDIAG_EVAL_KEY"], !key.isBlank {
            return key.trimmed
        }
        let file = supportDirectory.appendingPathComponent("openrouter-key")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmed
        return trimmed.isBlank ? nil : trimmed
    }

    static var isLiveEnabled: Bool { apiKey() != nil }

    /// Model IDs to compare, one per line. Defaults to the tier candidates.
    static func selectedModels() -> [EvalModel] {
        let file = supportDirectory.appendingPathComponent("models.txt")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
            return EvalCatalogue.candidates
        }
        let ids = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isBlank && !$0.hasPrefix("#") }
        guard !ids.isEmpty else { return EvalCatalogue.candidates }
        return ids.compactMap { id in
            EvalCatalogue.model(withID: id)
                ?? EvalModel(id: id, name: id.split(separator: "/").last.map(String.init) ?? id,
                             tier: "custom", inputPrice: 0, outputPrice: 0)
        }
    }

    /// Scenario IDs to run, one per line. Defaults to all.
    static func selectedScenarioIDs() -> [String] {
        let file = supportDirectory.appendingPathComponent("scenarios.txt")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isBlank && !$0.hasPrefix("#") }
    }

    static var reportsDirectory: URL {
        supportDirectory.appendingPathComponent("reports", isDirectory: true)
    }
}
