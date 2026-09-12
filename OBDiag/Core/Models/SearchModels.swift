import Foundation

/// Search backends the assistant can use for web, video and parts lookups.
enum SearchBackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// OpenRouter's `openrouter:web_search` server tool. No extra key needed.
    case openRouter
    /// DuckDuckGo HTML endpoint, parsed on-device. No key needed.
    case duckDuckGo
    /// TinyFish Search API (structured results, generous free tier).
    case tinyFish
    /// Try OpenRouter when available, otherwise DuckDuckGo.
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter Web Search"
        case .duckDuckGo: return "DuckDuckGo"
        case .tinyFish: return "TinyFish"
        case .automatic: return "Automatic"
        }
    }

    var subtitle: String {
        switch self {
        case .openRouter: return "Runs server-side with your OpenRouter key. Best quality, supports domain filters."
        case .duckDuckGo: return "Free and keyless. Parsed on-device from DuckDuckGo's HTML endpoint."
        case .tinyFish: return "Structured JSON results, geo-targeted, free with a TinyFish API key."
        case .automatic: return "Uses OpenRouter when configured, otherwise DuckDuckGo."
        }
    }

    var icon: String {
        switch self {
        case .openRouter: return "cloud.fill"
        case .duckDuckGo: return "magnifyingglass.circle.fill"
        case .tinyFish: return "fish.fill"
        case .automatic: return "wand.and.stars"
        }
    }

    var requiresAPIKey: Bool { self == .tinyFish }

    var isServerSide: Bool { self == .openRouter }
}

/// What kind of search a tool is performing. Domain scoping keeps video and
/// parts results useful instead of generic.
enum SearchScope: String, Codable, CaseIterable, Sendable {
    case web
    case videos
    case parts
    case news

    var title: String {
        switch self {
        case .web: return "Web"
        case .videos: return "Videos"
        case .parts: return "Parts & tools"
        case .news: return "News"
        }
    }

    /// Domains the backend should prefer or restrict to.
    var includeDomains: [String] {
        switch self {
        case .web, .news: return []
        case .videos: return ["youtube.com", "youtu.be", "vimeo.com"]
        case .parts: return ["rockauto.com", "autozone.com", "oreillyauto.com", "advanceautoparts.com", "amazon.com", "ebay.com", "harborfreight.com", "partsgeek.com"]
        }
    }

    var excludeDomains: [String] {
        switch self {
        case .videos: return ["pinterest.com", "facebook.com"]
        case .parts: return ["youtube.com", "reddit.com", "pinterest.com"]
        default: return []
        }
    }

    /// Extra query terms applied before hitting the backend.
    func augment(query: String) -> String {
        switch self {
        case .videos: return "\(query) repair how to"
        case .parts: return "\(query) buy price"
        case .news: return "\(query) recall"
        case .web: return query
        }
    }
}

/// Normalized search result across every backend.
struct SearchResult: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var snippet: String
    var siteName: String?
    var publishedDate: String?
    var position: Int = 0

    var host: String {
        if let siteName, !siteName.isBlank { return siteName }
        return URL(string: url)?.hostDisplayName ?? url.truncated(to: 40)
    }

    var citation: Citation {
        Citation(url: url, title: title, snippet: snippet.isEmpty ? nil : snippet.truncated(to: 280))
    }
}

enum SearchError: LocalizedError {
    case missingAPIKey(SearchBackendKind)
    case badResponse(String)
    case noResults
    case rateLimited
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let backend):
            return "\(backend.title) needs an API key. Add one in Settings → AI provider."
        case .badResponse(let detail):
            return "Search returned an unexpected response: \(detail)"
        case .noResults:
            return "No results found."
        case .rateLimited:
            return "Search rate limit reached. Try again in a moment."
        case .network(let error):
            return "Search failed: \(error.localizedDescription)"
        }
    }
}
