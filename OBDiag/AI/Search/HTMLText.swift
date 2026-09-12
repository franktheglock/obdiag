import Foundation

/// Lightweight HTML helpers used by the keyless search backend and the URL
/// reader. Not a full parser — tolerant regex extraction plus entity decoding.
enum HTMLText {

    private static let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let commentRegex = try? NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])
    private static let scriptRegex = try? NSRegularExpression(
        pattern: "<(script|style|noscript|svg|template)[^>]*>.*?</\\1>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let articleRegex = try? NSRegularExpression(
        pattern: "<(article|main)[^>]*>(.*?)</\\1>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let bodyRegex = try? NSRegularExpression(
        pattern: "<body[^>]*>(.*?)</body>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    static func stripTags(_ html: String) -> String {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let withoutTags = tagRegex?.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: " ") ?? html
        return withoutTags
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’",
            "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&middot;": "·", "&bull;": "•",
            "&deg;": "°", "&times;": "×", "&trade;": "™", "&copy;": "©", "&rarr;": "→",
            "&laquo;": "«", "&raquo;": "»", "&euro;": "€", "&pound;": "£", "&yen;": "¥"
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Numeric entities: &#123; and &#x1F600;
        if result.contains("&#") {
            result = replaceNumericEntities(in: result)
        }
        return result
    }

    private static func replaceNumericEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#x?([0-9A-Fa-f]+);", options: []) else { return text }
        var result = text
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[valueRange])
            let isHex = result[fullRange].lowercased().hasPrefix("&#x")
            guard let scalarValue = UInt32(token, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }

    static func clean(_ html: String) -> String {
        let decoded = decodeEntities(stripTags(html))
        return decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }

    /// Extracts the most content-dense readable text from a full page.
    static func readableText(fromHTML html: String, maxLength: Int = 12_000) -> String {
        var working = html
        for regex in [commentRegex, scriptRegex] {
            guard let regex else { continue }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            working = regex.stringByReplacingMatches(in: working, options: [], range: range, withTemplate: " ")
        }

        func firstGroup(_ regex: NSRegularExpression?) -> String? {
            guard let regex else { return nil }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            guard let match = regex.firstMatch(in: working, options: [], range: range),
                  match.numberOfRanges > 2,
                  let groupRange = Range(match.range(at: 2), in: working) else { return nil }
            return String(working[groupRange])
        }

        let body = firstGroup(articleRegex) ?? firstGroup(bodyRegex) ?? working

        // Preserve paragraph breaks before stripping tags.
        var text = body
        for breaker in ["</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "</tr>", "<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: breaker, with: breaker + "\n", options: .caseInsensitive)
        }
        text = cleanPreservingLines(text)
        return String(text.prefix(maxLength))
    }

    private static func cleanPreservingLines(_ html: String) -> String {
        let decoded = decodeEntities(stripTags(html))
        let lines = decoded
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed }
            .filter { !$0.isEmpty }
        // Collapse repeated short navigation-like fragments.
        var result: [String] = []
        for line in lines where line != result.last {
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    /// Decodes DuckDuckGo's `//duckduckgo.com/l/?uddg=…` redirect links.
    static func decodeDuckDuckGoLink(_ href: String) -> String? {
        var candidate = href
        if candidate.hasPrefix("//") { candidate = "https:" + candidate }
        guard let url = URL(string: candidate) else { return href.hasPrefix("http") ? href : nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return url.scheme?.hasPrefix("http") == true ? url.absoluteString : nil
    }
}
