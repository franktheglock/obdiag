import SwiftUI

/// Lightweight markdown renderer for assistant replies. Handles headings,
/// bullets, numbered lists, code fences, quotes, rules and inline styling
/// (bold, italic, code, links) without any dependency.
struct MarkdownText: View {
    let markdown: String
    var baseFont: Font = .obBody
    var textColor: Color = Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.parse(markdown)) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .obTitle2 : level == 2 ? .obHeadline : .obCallout.weight(.semibold))
                .foregroundStyle(textColor)
                .padding(.top, block.isFirst ? 0 : 4)

        case .paragraph(let text):
            Text(Self.inline(text))
                .font(baseFont)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text, let depth):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Palette.accent.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(.leading, CGFloat(depth) * 14)
                Text(Self.inline(text))
                    .font(baseFont)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

        case .ordered(let number, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .font(.obMono(14, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inline(text))
                    .font(baseFont)
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.obMono(13, weight: .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(11)
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: 1)
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.accent.opacity(0.6))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.obCallout)
                    .italic()
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider().overlay(Palette.stroke).padding(.vertical, 2)
        }
    }

    // MARK: Inline styling

    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributed[run.range].font = .system(size: 14, weight: .medium, design: .monospaced)
                    attributed[run.range].foregroundColor = Palette.accent
                    attributed[run.range].backgroundColor = Palette.accent.opacity(0.12)
                }
                if intent.contains(.strikethrough) {
                    attributed[run.range].strikethroughStyle = .single
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Palette.accent
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }

    // MARK: Parsing

    struct MarkdownBlock: Identifiable {
        enum Kind {
            case heading(level: Int, text: String)
            case paragraph(String)
            case bullet(String, depth: Int)
            case ordered(Int, String)
            case code(String)
            case quote(String)
            case rule
        }

        let id = UUID()
        var kind: Kind
        var isFirst = false
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: " ").trimmed
            paragraphBuffer = []
            guard !text.isEmpty else { return }
            // A paragraph that is entirely bold acts as a heading.
            if text.hasPrefix("**"), text.hasSuffix("**"), text.filter({ $0 == "*" }).count == 4 {
                let inner = String(text.dropFirst(2).dropLast(2))
                blocks.append(MarkdownBlock(kind: .heading(level: 3, text: inner)))
            } else {
                blocks.append(MarkdownBlock(kind: .paragraph(text)))
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(MarkdownBlock(kind: .code(codeBuffer.joined(separator: "\n"))))
                    codeBuffer = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule))
                continue
            }

            if let heading = headingMatch(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote(String(line.dropFirst(2)))))
                continue
            }

            if let bullet = bulletMatch(line) {
                flushParagraph()
                let depth = min(indent / 2, 2)
                blocks.append(MarkdownBlock(kind: .bullet(bullet, depth: depth)))
                continue
            }

            if let ordered = orderedMatch(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .ordered(ordered.number, ordered.text)))
                continue
            }

            paragraphBuffer.append(line)
        }

        if inCode, !codeBuffer.isEmpty {
            blocks.append(MarkdownBlock(kind: .code(codeBuffer.joined(separator: "\n"))))
        }
        flushParagraph()

        if !blocks.isEmpty {
            blocks[0].isFirst = true
        }
        return blocks
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func bulletMatch(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• ", "· "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> (number: Int, text: String)? {
        guard let spaceIndex = line.firstIndex(of: " "),
              line[line.startIndex..<spaceIndex].hasSuffix("."),
              let number = Int(line[line.startIndex..<spaceIndex].dropLast()) else { return nil }
        return (number, String(line[line.index(after: spaceIndex)...]))
    }
}
