import XCTest
@testable import AskmeCore

final class ContextTests: XCTestCase {
    func testPassageIsCentredOnTheTargetNotTheStartOfTheDocument() {
        let opening = (0..<200).map { "第\($0)段是无关的开头内容。" }.joined(separator: "\n")
        let closing = (0..<200).map { "后文\($0)。" }.joined(separator: "\n")
        let paragraph = "长上下文推理时，KV Cache 会随序列长度线性增长，占满显存。"
        let text = opening + "\n" + paragraph + "\n" + closing
        let range = (text as NSString).range(of: "KV")
        let passage = ContextWindow.around(range, in: text, limit: 300)
        XCTAssertTrue(passage.contains("长上下文推理时，⟦KV⟧ Cache 会随序列长度线性增长"))
        XCTAssertFalse(passage.contains("第0段"))
        XCTAssertLessThanOrEqual((passage as NSString).length, 300 + 4)
        XCTAssertTrue(passage.hasPrefix("…"))
        XCTAssertTrue(passage.hasSuffix("…"))
    }

    func testShortDocumentIsReturnedWhole() {
        let text = "标题\n\nTransformer 是一种基于注意力的架构。\n它取代了 RNN。"
        let range = (text as NSString).range(of: "Transformer")
        let passage = ContextWindow.around(range, in: text)
        XCTAssertEqual(passage, "标题\n\n⟦Transformer⟧ 是一种基于注意力的架构。\n它取代了 RNN。")
    }

    func testLongParagraphIsSnappedToSentences() {
        let sentences = (0..<80).map { "这是第\($0)句话，用来填充一个很长的段落。" }
        var text = sentences.joined()
        let insertAt = (text as NSString).length / 2
        text = (text as NSString).replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "目标词")
        let range = (text as NSString).range(of: "目标词")
        let passage = ContextWindow.around(range, in: text, limit: 200)
        XCTAssertTrue(passage.contains("⟦目标词⟧"))
        let body = passage.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        XCTAssertTrue(body.hasPrefix("这是第"), body)
        XCTAssertTrue(body.hasSuffix("。"), body)
        XCTAssertLessThanOrEqual((passage as NSString).length, 210)
    }

    func testFindsNeedleAndHandlesEdges() {
        XCTAssertEqual(ContextWindow.around("缓存", in: "这里讲缓存。"), "这里讲⟦缓存⟧。")
        XCTAssertNil(ContextWindow.around("不存在", in: "这里讲缓存。"))
        XCTAssertEqual(ContextWindow.around(NSRange(location: 99, length: 3), in: ""), "")
        XCTAssertEqual(ContextWindow.around(NSRange(location: 2, length: 0), in: "abc", mark: true), "abc")
        let long = String(repeating: "长", count: 2_000)
        XCTAssertEqual(ContextWindow.around(NSRange(location: 0, length: 2_000), in: long, limit: 100).count, 100)
    }
}
