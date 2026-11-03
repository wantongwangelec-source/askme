import Foundation

/// One concept the user has looked up. Only the concept, its one-line essence and the app it came
/// from are kept; the surrounding text, window titles and page content are never stored.
public struct KnowledgeEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public var term: String
    public var summary: String
    public var source: String
    public var firstSeen: Date
    /// The last lookup (reviews do not count).
    public var lastSeen: Date
    public var lookups: Int
    /// Successful recalls in a row; the review interval grows with it.
    public var stage: Int
    public var nextReview: Date?

    /// Recalled at least once in review, so it can serve as an analogy anchor.
    public var recalled: Bool { stage > 0 }
}

/// A local learning log. Every concept looked up joins a Leitner-style review queue on its own:
/// recalling it stretches the interval, forgetting it or looking it up again starts over. No
/// "got it" button is needed; the review answers are the signal.
public struct KnowledgeBook: Codable, Equatable, Sendable {
    /// Review intervals in days for each successful recall.
    public static let intervals: [Double] = [1, 3, 7, 16, 35, 90]
    public static let capacity = 5_000

    public private(set) var entries: [String: KnowledgeEntry] = [:]

    public init() {}

    /// "KV Cache（键值缓存）", "kv  cache" and "ＫＶ Cache" share one key.
    public static func key(for term: String) -> String {
        var value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"\s*[（(][^（）()]*[）)]\s*$"#, options: .regularExpression), range.lowerBound != value.startIndex {
            value.removeSubrange(range)
        }
        return value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func isRecordable(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40 && !key(for: trimmed).isEmpty
    }

    /// Entries saved before reviews were automatic may have no date yet.
    public static func reviewDate(of entry: KnowledgeEntry) -> Date {
        entry.nextReview ?? entry.lastSeen.addingTimeInterval(intervals[0] * 86_400)
    }

    public func entry(for term: String) -> KnowledgeEntry? { entries[Self.key(for: term)] }

    @discardableResult
    public mutating func record(term: String, summary: String, source: String, at date: Date) -> KnowledgeEntry? {
        guard Self.isRecordable(term) else { return nil }
        let key = Self.key(for: term)
        let summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let firstReview = date.addingTimeInterval(Self.intervals[0] * 86_400)
        if var entry = entries[key] {
            entry.term = term
            if !summary.isEmpty { entry.summary = summary }
            entry.source = source
            entry.lastSeen = date
            entry.lookups += 1
            // Looking it up again means it has not stuck yet: start the intervals over.
            entry.stage = 0
            entry.nextReview = firstReview
            entries[key] = entry
            return entry
        }
        let entry = KnowledgeEntry(key: key, term: term, summary: summary, source: source, firstSeen: date,
                                   lastSeen: date, lookups: 1, stage: 0, nextReview: firstReview)
        entries[key] = entry
        evictIfNeeded()
        return entry
    }

    public mutating func review(_ key: String, remembered: Bool, at date: Date) {
        guard var entry = entries[key] else { return }
        entry.stage = remembered ? min(entry.stage + 1, Self.intervals.count - 1) : 0
        entry.nextReview = date.addingTimeInterval(Self.intervals[entry.stage] * 86_400)
        entries[key] = entry
    }

    public mutating func remove(_ key: String) { entries[key] = nil }
    public mutating func removeAll() { entries.removeAll() }

    public func due(at date: Date) -> [KnowledgeEntry] {
        entries.values.filter { Self.reviewDate(of: $0) <= date }
            .sorted { Self.reviewDate(of: $0) < Self.reviewDate(of: $1) }
    }

    public func recent(limit: Int = .max) -> [KnowledgeEntry] {
        Array(entries.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }

    /// Concepts the user has recalled in review, most recent first. Used as analogy anchors and to
    /// skip prerequisites the user does not need.
    public func anchors(limit: Int) -> [String] {
        Array(entries.values.filter(\.recalled).sorted { $0.lastSeen > $1.lastSeen }.prefix(limit).map(\.term))
    }

    private mutating func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let removable = entries.values.sorted { ($0.recalled ? 1 : 0, $0.lastSeen) < ($1.recalled ? 1 : 0, $1.lastSeen) }
        for entry in removable.prefix(entries.count - Self.capacity) { entries[entry.key] = nil }
    }
}
