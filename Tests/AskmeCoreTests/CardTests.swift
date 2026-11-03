import XCTest
@testable import AskmeCore

final class CardTests: XCTestCase {
    private let sample = """
    【概念】KV Cache（键值缓存）
    【一句话】模型逐字生成时，把算过的注意力中间结果缓存下来。
    【在这里】文中说的"显存吃紧"就是指这份缓存随长度增长。
    【类比】像前端的增量渲染；不同的是缓存会一直变大。
    【要点】
    - 每个新 token 只计算自己的 K 和 V
    - 缓存大小与层数、长度成正比
    【例子】生成第 1000 个字时，前 999 个字的 K/V 直接复用。
    【前置】Attention｜Token、Transformer
    【相关】PagedAttention｜Prefill 与 Decode
    【把握】高
    """

    func testParsesAllSections() {
        let card = CardParser.parse(sample)
        XCTAssertEqual(card.concept, "KV Cache（键值缓存）")
        XCTAssertEqual(card.oneLiner, "模型逐字生成时，把算过的注意力中间结果缓存下来。")
        XCTAssertEqual(card[.keyPoints], "- 每个新 token 只计算自己的 K 和 V\n- 缓存大小与层数、长度成正比")
        XCTAssertEqual(card.prerequisites, ["Attention", "Token", "Transformer"])
        XCTAssertEqual(card.related, ["PagedAttention", "Prefill 与 Decode"])
        XCTAssertEqual(card.confidence, .high)
        XCTAssertNil(card[.pitfall])
        XCTAssertNil(card.freeform)
    }

    func testStreamingPrefixesNeverShowHalfMarkersOrHalfChips() {
        var card = CardParser.parse("【概念】KV Cache\n【一句话】缓存中间结果\n【在这", complete: false)
        XCTAssertEqual(card.oneLiner, "缓存中间结果")
        XCTAssertNil(card[.inContext])

        card = CardParser.parse("【一句话】缓存\n【前置】Attention｜Tok", complete: false)
        XCTAssertEqual(card.prerequisites, ["Attention"])
        card = CardParser.parse("【一句话】缓存\n【前置】Attention｜Token", complete: true)
        XCTAssertEqual(card.prerequisites, ["Attention", "Token"])

        // Every prefix of a full answer parses without crashing and never loses the one-liner once seen.
        var seenOneLiner = false
        for end in sample.indices {
            let partial = CardParser.parse(String(sample[..<end]), complete: false)
            if partial.oneLiner?.hasPrefix("模型逐字生成时") == true { seenOneLiner = true }
            if seenOneLiner { XCTAssertNotNil(partial.oneLiner) }
        }
        XCTAssertTrue(seenOneLiner)
    }

    func testFreeformWhenTheModelIgnoresTheFormat() {
        let card = CardParser.parse("它是一种缓存。\n\n- 第一点")
        XCTAssertEqual(card.freeform, "它是一种缓存。\n\n- 第一点")
        XCTAssertNil(card.oneLiner)
        XCTAssertTrue(CardParser.parse("  ").isEmpty)
    }

    func testChipCleanup() {
        XCTAssertEqual(CardParser.chips("1. 注意力机制｜ [[Token]] 、 无 ｜Token｜《Softmax》"), ["注意力机制", "Token", "Softmax"])
        XCTAssertEqual(CardParser.chips("a|b|c|d|e|f|g").count, 5)
        XCTAssertEqual(CardParser.chips(String(repeating: "长", count: 40)), [])
    }

    func testLowConfidence() {
        XCTAssertEqual(CardParser.parse("【一句话】可能是内部代号\n【把握】低（没有资料）").confidence, .low)
    }

    func testPrimerItemsInDependencyOrder() {
        let text = """
        【主旨】这篇文章讲大模型推理如何节省显存。
        【前置】
        1. Token：模型处理文字的最小单位
        2. Attention（注意力）：让每个词参考其他词
        3、KV Cache: 复用算过的中间结果
        【难点】PagedAttention 的分页思路。
        """
        let primer = PrimerParser.parse(text)
        XCTAssertEqual(primer.gist, "这篇文章讲大模型推理如何节省显存。")
        XCTAssertEqual(primer.items.map(\.term), ["Token", "Attention（注意力）", "KV Cache"])
        XCTAssertEqual(primer.items[2].summary, "复用算过的中间结果")
        XCTAssertEqual(primer.hardest, "PagedAttention 的分页思路。")

        let streaming = PrimerParser.parse("【主旨】讲显存\n【前置】\n1. Token：最小单位\n2. Atten", complete: false)
        XCTAssertEqual(streaming.items.map(\.term), ["Token"])
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownLite.blocks("""
        ## 原理
        第一段
        接着第一段

        - 要点一
        * 要点二
        1. 步骤一
        2) 步骤二
        > 引用
        ```
        let x = 1
        ```
        ```
        unterminated
        """)
        XCTAssertEqual(blocks, [
            .heading("原理"), .paragraph("第一段\n接着第一段"), .bullet("要点一"), .bullet("要点二"),
            .numbered("1", "步骤一"), .numbered("2", "步骤二"), .quote("引用"), .code("let x = 1"), .code("unterminated")
        ])
    }
}
