import Foundation

/// Sections of a concept card, in the order the model is asked to write them. The one-liner comes
/// first so the essence is readable before the rest of the answer has streamed in.
public enum CardSection: String, CaseIterable, Sendable {
    case concept = "概念"
    case oneLiner = "一句话"
    case inContext = "在这里"
    case analogy = "类比"
    case keyPoints = "要点"
    case example = "例子"
    case pitfall = "误区"
    case prerequisites = "前置"
    case related = "相关"
    case confidence = "把握"
    case gist = "主旨"
    case hardest = "难点"
}

public enum Confidence: String, Sendable {
    case high = "高", medium = "中", low = "低"
}

public struct ConceptCard: Equatable, Sendable {
    public var sections: [CardSection: String] = [:]
    public var prerequisites: [String] = []
    public var related: [String] = []
    public var confidence: Confidence?
    /// The whole answer when the model ignored the format.
    public var freeform: String?

    public init() {}

    public subscript(_ section: CardSection) -> String? { sections[section] }
    public var concept: String? { sections[.concept] }
    public var oneLiner: String? { sections[.oneLiner] }
    public var isEmpty: Bool { sections.isEmpty && freeform == nil }
}

public enum CardParser {
    private static let marker = try! NSRegularExpression(pattern: "【([^【】\\n]{1,10})】")

    /// Parses the answer text into sections. While `complete` is false the text is still streaming,
    /// so a half-written marker or a half-written last chip is held back instead of flickering.
    public static func parse(_ text: String, complete: Bool = true) -> ConceptCard {
        var card = ConceptCard()
        let source = complete ? text : trimPartialMarker(text)
        let ns = source as NSString
        let matches = marker.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var known: [(CardSection, NSRange)] = []
        for match in matches {
            let label = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let section = CardSection.allCases.first(where: { label.hasPrefix($0.rawValue) }) {
                known.append((section, match.range))
            }
        }
        guard !known.isEmpty else {
            let free = source.trimmingCharacters(in: .whitespacesAndNewlines)
            card.freeform = free.isEmpty ? nil : free
            return card
        }
        for (index, entry) in known.enumerated() {
            let start = NSMaxRange(entry.1)
            let end = index + 1 < known.count ? known[index + 1].1.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, card.sections[entry.0] == nil else { continue }
            card.sections[entry.0] = body
        }
        if let concept = card.sections[.concept] {
            card.sections[.concept] = concept.components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*#")))
        }
        let streamingTail = !complete && !source.hasSuffix("\n") ? known.last?.0 : nil
        card.prerequisites = chips(card.sections[.prerequisites] ?? "", dropLast: streamingTail == .prerequisites)
        card.related = chips(card.sections[.related] ?? "", dropLast: streamingTail == .related)
        if let value = card.sections[.confidence] {
            card.confidence = [Confidence.low, .medium, .high].first { value.contains($0.rawValue) }
        }
        return card
    }

    /// Splits a chip list such as "Attention｜Token、Softmax" into short, clean items.
    public static func chips(_ value: String, dropLast: Bool = false) -> [String] {
        let separators = CharacterSet(charactersIn: "｜|、,，;；/\n")
        let junk = CharacterSet(charactersIn: " \t[]【】《》“”\"'`*•·-").union(.whitespaces)
        var seen = Set<String>()
        var result: [String] = []
        var pieces = value.components(separatedBy: separators)
        if dropLast, !pieces.isEmpty { pieces.removeLast() }
        for piece in pieces {
            var item = piece.trimmingCharacters(in: junk)
            if let match = item.range(of: #"^\d+[.、)）]\s*"#, options: .regularExpression) { item.removeSubrange(match) }
            item = item.trimmingCharacters(in: junk)
            guard !item.isEmpty, item.count <= 32, !["无", "暂无", "（无）", "none", "None", "N/A"].contains(item) else { continue }
            if seen.insert(item.lowercased()).inserted { result.append(item) }
            if result.count == 5 { break }
        }
        return result
    }

    /// Drops a marker that is still being streamed, e.g. a trailing "【在这".
    static func trimPartialMarker(_ text: String) -> String {
        guard let open = text.range(of: "【", options: .backwards) else { return text }
        let tail = text[open.upperBound...]
        guard !tail.contains("】"), tail.count <= 10, !tail.contains("\n") else { return text }
        return String(text[..<open.lowerBound])
    }
}

public struct Primer: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { term }
        public var term: String
        public var summary: String
    }

    public var gist: String?
    public var items: [Item] = []
    public var hardest: String?
    public var freeform: String?

    public init() {}
}

public enum PrimerParser {
    private static let line = try! NSRegularExpression(pattern: #"^\s*(?:\d{1,2}\s*[.、)）]|[-•·*])?\s*(.+?)\s*[：:]\s*(.*)$"#)

    public static func parse(_ text: String, complete: Bool = true) -> Primer {
        let card = CardParser.parse(text, complete: complete)
        var primer = Primer()
        primer.gist = card[.gist]
        primer.hardest = card[.hardest]
        primer.freeform = card.freeform
        guard let body = card[.prerequisites] else { return primer }
        let lines = body.components(separatedBy: "\n")
        let tailComplete = complete || text.hasSuffix("\n") || card[.hardest] != nil
        var seen = Set<String>()
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isLast = index == lines.count - 1
            let ns = trimmed as NSString
            var term: String
            var summary = ""
            if let match = line.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                term = ns.substring(with: match.range(at: 1))
                summary = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            } else {
                // A line without "term：summary" is only trusted once it is complete.
                guard !isLast || tailComplete else { continue }
                term = trimmed.replacingOccurrences(of: #"^\d{1,2}\s*[.、)）]\s*"#, with: "", options: .regularExpression)
            }
            term = term.trimmingCharacters(in: CharacterSet(charactersIn: " *`「」“”\""))
            guard !term.isEmpty, term.count <= 40, seen.insert(term.lowercased()).inserted else { continue }
            primer.items.append(Primer.Item(term: term, summary: summary))
        }
        return primer
    }
}
