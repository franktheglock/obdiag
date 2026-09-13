import Foundation
@testable import OBDiag

/// Deterministic search backend for evals: results come from the scenario's
/// fixtures instead of the network, so groundedness can be graded precisely.
struct FixtureSearchBackend: SearchBackend {
    let kind: SearchBackendKind = .duckDuckGo
    let fixtures: [EvalScenario.SearchFixture]

    func search(
        query: String,
        scope: SearchScope,
        maxResults: Int,
        region: String,
        language: String
    ) async throws -> [SearchResult] {
        let needle = query.lowercased()
        let matched = fixtures.filter { fixture in
            let scopeMatches = fixture.scope == nil || fixture.scope == scope.rawValue
            let keywordMatches = fixture.matchAny.contains { needle.contains($0.lowercased()) }
            return scopeMatches && keywordMatches
        }

        let results = matched
            .flatMap(\.results)
            .enumerated()
            .map { index, fixture in
                SearchResult(
                    title: fixture.title,
                    url: fixture.url,
                    snippet: fixture.snippet,
                    position: index + 1
                )
            }

        guard !results.isEmpty else { throw SearchError.noResults }
        return Array(results.prefix(maxResults))
    }

    /// Page contents for `read_url`, matched on the URL.
    static func page(for url: String, in fixtures: [EvalScenario.SearchFixture]) -> (title: String, text: String, url: String)? {
        for fixture in fixtures {
            for result in fixture.results where url.contains(result.url) || result.url.contains(url) {
                return (result.title, result.snippet, result.url)
            }
        }
        return nil
    }
}
