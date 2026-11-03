import Foundation

/// Block structure for the small subset of Markdown models use in short answers. Inline styling
/// (bold, code, emphasis) is left to `AttributedString(markdown:)` in the UI layer.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case bullet(String)
    case numbered(String, String)
    case heading(String)
    case quote(String)
    case code(String)
}

public enum MarkdownLite {
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)、]\s+(.*)$"#)
    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}\s+(.*)$"#)

    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty { flush(); continue }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = heading.firstMatch(in: line, range: range) {
                flush()
                blocks.append(.heading(ns.substring(with: match.range(at: 1))))
            } else if let item = bullet(line) {
                flush()
                blocks.append(.bullet(item))
            } else if let match = numbered.firstMatch(in: line, range: range) {
                flush()
                blocks.append(.numbered(ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2))))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func bullet(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• ", "· ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
