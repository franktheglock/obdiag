import Foundation
import Observation

/// A pluggable client-side search backend.
protocol SearchBackend: Sendable {
    var kind: SearchBackendKind { get }
    func search(query: String, scope: SearchScope, maxResults: Int, region: String, language: String) async throws -> [SearchResult]
}

// MARK: - DuckDuckGo (keyless)

/// Parses DuckDuckGo's HTML endpoints on-device. No key, no server of ours.
struct DuckDuckGoSearchBackend: SearchBackend {
    let kind: SearchBackendKind = .duckDuckGo

    func search(query: String, scope: SearchScope, maxResults: Int, region: String, language: String) async throws -> [SearchResult] {
        let augmented = scope.augment(query: query)
        if let results = try? await fetch(endpoint: "https://html.duckduckgo.com/html/", query: augmented, scope: scope, region: region, language: language),
           !results.isEmpty {
            return Array(results.prefix(maxResults))
        }
        // The lite endpoint uses simpler markup and is a good fallback.
        if let results = try? await fetchLite(query: augmented, region: region, language: language), !results.isEmpty {
            return Array(results.prefix(maxResults))
        }
        throw SearchError.noResults
    }

    private func request(url: URL, body: Data?, region: String, language: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("\(language)-\(region),\(language);q=0.9", forHTTPHeaderField: "Accept-Language")
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func fetch(endpoint: String, query: String, scope: SearchScope, region: String, language: String) async throws -> [SearchResult] {
        guard let url = URL(string: endpoint) else { throw SearchError.badResponse("bad endpoint") }
        let body = "q=\(formEncode(query))&kl=\(region.lowercased())-\(language.lowercased())".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request(url: url, body: body, region: region, language: language))
        guard let http = response as? HTTPURLResponse else { throw SearchError.badResponse("no response") }
        if http.statusCode == 429 { throw SearchError.rateLimited }
        guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw SearchError.badResponse("HTTP \(http.statusCode)")
        }
        return Self.parse(html: html, scope: scope)
    }

    private func fetchLite(query: String, region: String, language: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw SearchError.badResponse("bad endpoint") }
        let (data, response) = try await URLSession.shared.data(for: request(url: url, body: nil, region: region, language: language))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw SearchError.badResponse("lite endpoint failed")
        }
        return Self.parseLite(html: html)
    }

    private func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: Parsing

    static func parse(html: String, scope: SearchScope) -> [SearchResult] {
        let linkPattern = "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        let snippetPattern = "<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>"
        let links = matches(pattern: linkPattern, in: html)
        let snippets = matches(pattern: snippetPattern, in: html)

        var results: [SearchResult] = []
        for (index, link) in links.enumerated() {
            guard link.count >= 2 else { continue }
            let href = HTMLText.decodeEntities(link[0])
            guard let url = HTMLText.decodeDuckDuckGoLink(href) else { continue }
            let title = HTMLText.clean(link[1])
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count ? HTMLText.clean(snippets[index][0]) : ""
            results.append(SearchResult(title: title, url: url, snippet: snippet, position: index + 1))
        }
        return filter(results, for: scope)
    }

    static func parseLite(html: String) -> [SearchResult] {
        let linkPattern = "<a[^>]*class=\"result-link\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        let snippetPattern = "<td[^>]*class=\"result-snippet\"[^>]*>(.*?)</td>"
        let links = matches(pattern: linkPattern, in: html)
        let snippets = matches(pattern: snippetPattern, in: html)

        var results: [SearchResult] = []
        for (index, link) in links.enumerated() {
            guard link.count >= 2 else { continue }
            let href = HTMLText.decodeEntities(link[0])
            guard let url = HTMLText.decodeDuckDuckGoLink(href) else { continue }
            let title = HTMLText.clean(link[1])
            guard !title.isEmpty else { continue }
            let snippet = index < snippets.count ? HTMLText.clean(snippets[index][0]) : ""
            results.append(SearchResult(title: title, url: url, snippet: snippet, position: index + 1))
        }
        return results
    }

    private static func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                guard let groupRange = Range(match.range(at: index), in: text) else { return nil }
                return String(text[groupRange])
            }
        }
    }

    static func filter(_ results: [SearchResult], for scope: SearchScope) -> [SearchResult] {
        let include = Set(scope.includeDomains.map { $0.lowercased() })
        guard !include.isEmpty else { return results }
        return results.filter { result in
            guard let host = URL(string: result.url)?.host?.lowercased() else { return false }
            return include.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

// MARK: - TinyFish (structured search API)

/// TinyFish's Search API: geo-targeted JSON results, free with an API key.
struct TinyFishSearchBackend: SearchBackend {
    let kind: SearchBackendKind = .tinyFish
    let apiKey: String

    func search(query: String, scope: SearchScope, maxResults: Int, region: String, language: String) async throws -> [SearchResult] {
        guard !apiKey.isBlank else { throw SearchError.missingAPIKey(.tinyFish) }

        var components = URLComponents(string: "https://api.search.tinyfish.ai")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: scope.augment(query: query)),
            URLQueryItem(name: "location", value: region.uppercased()),
            URLQueryItem(name: "language", value: language.lowercased())
        ]
        if !scope.includeDomains.isEmpty {
            items.append(URLQueryItem(name: "include_domains", value: scope.includeDomains.joined(separator: ",")))
        }
        if !scope.excludeDomains.isEmpty {
            items.append(URLQueryItem(name: "exclude_domains", value: scope.excludeDomains.joined(separator: ",")))
        }
        if scope == .news { items.append(URLQueryItem(name: "domain_type", value: "news")) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.badResponse("no response") }
        if http.statusCode == 429 { throw SearchError.rateLimited }
        if http.statusCode == 401 { throw SearchError.missingAPIKey(.tinyFish) }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)?.truncated(to: 200) ?? ""
            throw SearchError.badResponse("HTTP \(http.statusCode) \(message)")
        }
        guard let value = JSONValue.parse(data: data), let results = value["results"]?.arrayValue else {
            throw SearchError.badResponse("unexpected JSON")
        }

        let parsed: [SearchResult] = results.enumerated().compactMap { index, item in
            guard let url = item["url"]?.stringValue, let title = item["title"]?.stringValue else { return nil }
            return SearchResult(
                title: title,
                url: url,
                snippet: item["snippet"]?.stringValue ?? "",
                siteName: item["site_name"]?.stringValue,
                publishedDate: item["date"]?.stringValue ?? item["publisher"]?.stringValue,
                position: item["position"]?.intValue ?? index + 1
            )
        }
        guard !parsed.isEmpty else { throw SearchError.noResults }
        return Array(parsed.prefix(maxResults))
    }
}

// MARK: - Routing service

/// Chooses between server-side OpenRouter search and the client-side backends,
/// caches results briefly, and reports what was used.
@MainActor
@Observable
final class SearchService {
    private let settings: AppSettings

    private struct CacheEntry {
        let date: Date
        let results: [SearchResult]
    }

    @ObservationIgnored private var cache: [String: CacheEntry] = [:]
    private(set) var lastBackendUsed: String?
    private(set) var activeSearches = 0
    private(set) var lastError: String?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isSearching: Bool { activeSearches > 0 }

    /// True when the assistant should rely on OpenRouter's server-side web
    /// search tool instead of a client-side `web_search` function tool.
    var useServerWebSearch: Bool {
        guard settings.provider == .openRouter, !settings.openRouterAPIKey.isBlank else { return false }
        switch settings.searchBackend {
        case .openRouter, .automatic: return true
        case .duckDuckGo, .tinyFish: return false
        }
    }

    /// The client-side backend used for video/parts lookups and for web search
    /// when server-side search is unavailable.
    var clientBackend: SearchBackend? {
        switch settings.searchBackend {
        case .tinyFish:
            if !settings.tinyFishAPIKey.isBlank {
                return TinyFishSearchBackend(apiKey: settings.tinyFishAPIKey)
            }
            return DuckDuckGoSearchBackend()
        case .duckDuckGo, .automatic, .openRouter:
            return DuckDuckGoSearchBackend()
        }
    }

    var backendLabel: String {
        if useServerWebSearch { return "OpenRouter (server)" }
        return clientBackend?.kind.title ?? "None"
    }

    func search(_ query: String, scope: SearchScope, maxResults: Int = 6) async throws -> [SearchResult] {
        let key = "\(scope.rawValue)|\(query.lowercased())|\(maxResults)"
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < 600 {
            lastBackendUsed = "cache"
            return entry.results
        }

        guard let backend = clientBackend else { throw SearchError.noResults }
        activeSearches += 1
        defer { activeSearches -= 1 }

        do {
            let results = try await backend.search(
                query: query,
                scope: scope,
                maxResults: maxResults,
                region: settings.regionCode,
                language: settings.languageCode
            )
            cache[key] = CacheEntry(date: Date(), results: results)
            lastBackendUsed = backend.kind.title
            lastError = nil
            return results
        } catch {
            lastError = error.localizedDescription
            lastBackendUsed = backend.kind.title
            throw error
        }
    }

    /// Fetches and extracts a URL's readable text (used when OpenRouter's
    /// server-side web_fetch tool is not available).
    func readURL(_ urlString: String, maxLength: Int = 12_000) async throws -> (title: String, text: String, url: String) {
        guard let url = URL(string: urlString.trimmed), url.scheme?.hasPrefix("http") == true else {
            throw SearchError.badResponse("Not a valid http(s) URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/plain"), let text = String(data: data, encoding: .utf8) {
            return (url.hostDisplayName, String(text.prefix(maxLength)), url.absoluteString)
        }

        guard var html = String(data: data, encoding: .utf8) else {
            throw SearchError.badResponse("Could not decode the page.")
        }
        var title = url.hostDisplayName
        if let titleRange = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = HTMLText.clean(String(html[titleRange]).replacingOccurrences(of: "<title>", with: "", options: .caseInsensitive))
        }
        html = String(html.prefix(600_000))
        return (title.isEmpty ? url.hostDisplayName : title, HTMLText.readableText(fromHTML: html, maxLength: maxLength), url.absoluteString)
    }

    func clearCache() {
        cache.removeAll()
    }
}
