import XCTest
@testable import AskmeCore

final class KnowledgeTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeysIgnoreCaseWidthSpacingAndTranslations() {
        XCTAssertEqual(KnowledgeBook.key(for: "KV Cache（键值缓存）"), KnowledgeBook.key(for: " kv  cache "))
        XCTAssertEqual(KnowledgeBook.key(for: "ＫＶ Cache"), "kv cache")
        XCTAssertEqual(KnowledgeBook.key(for: "（括号）"), "(括号)")
        XCTAssertFalse(KnowledgeBook.isRecordable(String(repeating: "长", count: 41)))
    }

    func testRecordingCountsLookupsAndKeepsLatestSummary() throws {
        var book = KnowledgeBook()
        book.record(term: "KV Cache（键值缓存）", summary: "缓存中间结果", source: "Chrome", at: start)
        let again = try XCTUnwrap(book.record(term: "kv cache", summary: "", source: "Cursor", at: start + day))
        XCTAssertEqual(again.lookups, 2)
        XCTAssertEqual(again.summary, "缓存中间结果")
        XCTAssertEqual(again.source, "Cursor")
        XCTAssertEqual(book.entries.count, 1)
        XCTAssertNil(book.record(term: "  ", summary: "x", source: "", at: start))
    }

    func testEveryLookupJoinsTheReviewQueueWithoutAnExtraClick() throws {
        var book = KnowledgeBook()
        let key = try XCTUnwrap(book.record(term: "Attention", summary: "加权参考", source: "", at: start)).key
        XCTAssertTrue(book.due(at: start + 0.5 * day).isEmpty)
        XCTAssertEqual(book.due(at: start + day).map(\.key), [key])
        XCTAssertTrue(book.anchors(limit: 5).isEmpty, "Not an anchor until it has been recalled")

        book.review(key, remembered: true, at: start + day)
        XCTAssertEqual(book.entries[key]?.nextReview, start + day + 3 * day)
        XCTAssertEqual(book.anchors(limit: 5), ["Attention"])
        book.review(key, remembered: true, at: start + 4 * day)
        XCTAssertEqual(book.entries[key]?.stage, 2)
        book.review(key, remembered: false, at: start + 11 * day)
        XCTAssertEqual(book.entries[key]?.stage, 0)
        XCTAssertEqual(book.entries[key]?.nextReview, start + 12 * day)
        XCTAssertTrue(book.anchors(limit: 5).isEmpty)

        for _ in 0..<20 { book.review(key, remembered: true, at: start) }
        XCTAssertEqual(book.entries[key]?.stage, KnowledgeBook.intervals.count - 1)
    }

    func testLookingAConceptUpAgainStartsTheIntervalsOver() throws {
        var book = KnowledgeBook()
        let key = try XCTUnwrap(book.record(term: "Token", summary: "最小单位", source: "", at: start)).key
        for offset in 1...3 { book.review(key, remembered: true, at: start + Double(offset) * 20 * day) }
        book.record(term: "Token", summary: "", source: "", at: start + 100 * day)
        XCTAssertEqual(book.entries[key]?.stage, 0)
        XCTAssertEqual(book.entries[key]?.nextReview, start + 101 * day)
    }

    func testEntriesSavedBeforeAutomaticReviewsStillBecomeDue() throws {
        let saved = """
        {"entries":{"token":{"key":"token","term":"Token","summary":"最小单位","source":"Chrome",
        "firstSeen":0,"lastSeen":0,"lookups":1,"understood":false,"stage":0}}}
        """
        let book = try JSONDecoder().decode(KnowledgeBook.self, from: Data(saved.utf8))
        XCTAssertTrue(book.due(at: Date(timeIntervalSinceReferenceDate: 0.5 * day)).isEmpty)
        XCTAssertEqual(book.due(at: Date(timeIntervalSinceReferenceDate: day)).map(\.term), ["Token"])
    }

    func testCodableRoundTripAndRemoval() throws {
        var book = KnowledgeBook()
        book.record(term: "A", summary: "a", source: "x", at: start)
        book.record(term: "B", summary: "b", source: "y", at: start + 1)
        let decoded = try JSONDecoder().decode(KnowledgeBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
        XCTAssertEqual(book.recent(limit: 1).map(\.term), ["B"])
        book.remove("a")
        XCTAssertNil(book.entry(for: "A"))
        book.removeAll()
        XCTAssertTrue(book.entries.isEmpty)
    }
}
