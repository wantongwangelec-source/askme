import Foundation

/// Picks the passage around what the user pointed at, so the model sees the sentence and paragraph
/// the term lives in rather than whatever happens to be at the start of a long document.
public enum ContextWindow {
    public static let openMark = "⟦"
    public static let closeMark = "⟧"
    private static let terminators = CharacterSet(charactersIn: "。！？；.!?;\n")

    /// The paragraph containing `range`, widened with neighbouring paragraphs up to `limit` UTF-16
    /// units, or a sentence-snapped slice of a long paragraph. The target is wrapped in ⟦ ⟧.
    public static func around(_ range: NSRange, in text: String, limit: Int = 1_200, mark: Bool = true) -> String {
        let ns = text as NSString
        guard ns.length > 0, limit > 0 else { return "" }
        let location = min(max(0, range.location), ns.length)
        let target = NSRange(location: location, length: min(max(0, range.length), ns.length - location))
        if target.length >= limit {
            return clean(ns.substring(with: NSRange(location: target.location, length: limit)))
        }

        let paragraph = ns.paragraphRange(for: target)
        var window = paragraph
        while window.length < limit {
            var grew = false
            if window.location > 0 {
                let previous = ns.paragraphRange(for: NSRange(location: window.location - 1, length: 0))
                let union = NSUnionRange(previous, window)
                if union.length <= limit { window = union; grew = true }
            }
            let end = NSMaxRange(window)
            if end < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
                let union = NSUnionRange(window, next)
                if union.length <= limit { window = union; grew = true }
            }
            if !grew { break }
        }

        if window.length > limit {
            let half = max(0, (limit - target.length) / 2)
            var start = max(paragraph.location, target.location - half)
            var end = min(NSMaxRange(paragraph), start + limit)
            start = max(paragraph.location, end - limit)
            if start > paragraph.location {
                let slackEnd = min(target.location, start + limit / 4)
                if slackEnd > start {
                    let hit = ns.rangeOfCharacter(from: terminators, options: [],
                                                  range: NSRange(location: start, length: slackEnd - start))
                    if hit.location != NSNotFound { start = NSMaxRange(hit) }
                }
            }
            if end < NSMaxRange(paragraph) {
                let slackStart = max(NSMaxRange(target), end - limit / 4)
                if end > slackStart {
                    let hit = ns.rangeOfCharacter(from: terminators, options: .backwards,
                                                  range: NSRange(location: slackStart, length: end - slackStart))
                    if hit.location != NSNotFound { end = NSMaxRange(hit) }
                }
            }
            window = NSRange(location: start, length: max(0, end - start))
        }

        var passage: String
        if mark, target.length > 0, NSLocationInRange(target.location, window), NSMaxRange(target) <= NSMaxRange(window) {
            let before = ns.substring(with: NSRange(location: window.location, length: target.location - window.location))
            let middle = ns.substring(with: target)
            let after = ns.substring(with: NSRange(location: NSMaxRange(target), length: NSMaxRange(window) - NSMaxRange(target)))
            passage = before + openMark + middle + closeMark + after
        } else {
            passage = ns.substring(with: window)
        }
        passage = clean(passage)
        if window.location > 0 { passage = "…" + passage }
        if NSMaxRange(window) < ns.length { passage += "…" }
        return passage
    }

    /// Locates `needle` inside `text` (first occurrence) and returns the passage around it.
    public static func around(_ needle: String, in text: String, limit: Int = 1_200) -> String? {
        let ns = text as NSString
        let probe = String(needle.prefix(160))
        guard !probe.isEmpty else { return nil }
        let hit = ns.range(of: probe, options: [.caseInsensitive, .widthInsensitive])
        guard hit.location != NSNotFound else { return nil }
        let full = NSRange(location: hit.location, length: min((needle as NSString).length, ns.length - hit.location))
        return around(full, in: text, limit: limit)
    }

    private static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result
    }
}
