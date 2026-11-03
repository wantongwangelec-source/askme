import XCTest
@testable import AskmeCore

final class StreamingTests: XCTestCase {
    func testParsesServerSentEvents() {
        var parser = ChatStreamParser()
        XCTAssertEqual(parser.feed(": keep-alive"), [])
        XCTAssertEqual(parser.feed(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), [])
        XCTAssertEqual(parser.feed(#"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#), [.reasoning])
        XCTAssertEqual(parser.feed(#"data:{"choices":[{"delta":{"content":"【一句话】"}}]}"#), [.content("【一句话】")])
        XCTAssertEqual(parser.feed(""), [])
        XCTAssertEqual(parser.feed(#"data: {"choices":[{"delta":{"content":[{"type":"text","text":"缓存"}]}}]}\#r"#), [.content("缓存")])
        XCTAssertEqual(parser.feed("event: message"), [])
        XCTAssertEqual(parser.feed("data: [DONE]"), [.done])
        XCTAssertEqual(parser.finish(), [])
    }

    func testJoinsMultiLineDataEvents() {
        var parser = ChatStreamParser()
        XCTAssertEqual(parser.feed(#"data: {"choices":[{"delta":"#), [])
        XCTAssertEqual(parser.feed(#"data: {"content":"拼接"}}]}"#), [.content("拼接")])
    }

    func testFallsBackToPlainJSONBodyAndReportsErrors() {
        var parser = ChatStreamParser()
        XCTAssertEqual(parser.feed("{"), [])
        XCTAssertEqual(parser.feed(#""choices": [{"message": {"content": "完整回答"}}]"#), [])
        XCTAssertEqual(parser.feed("}"), [])
        XCTAssertEqual(parser.finish(), [.content("完整回答")])

        var failing = ChatStreamParser()
        XCTAssertEqual(failing.feed(#"data: {"error":{"message":"secret echo"}}"#), [.failed])
    }

    func testRequestBodyIsStreamingAndMergesExtraParameters() throws {
        let request = ChatRequest(endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "m",
                                  key: "k", messages: [ChatMessage(.system, "s"), ChatMessage(.user, "u", imageJPEG: Data([1, 2]))],
                                  extraJSON: #"{"reasoning_effort":"low","stream":false,"model":"other"}"#)
        let urlRequest = try request.urlRequest()
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "s")
        XCTAssertEqual((messages.last?["content"] as? [[String: Any]])?.count, 2)

        var bad = request
        bad.extraJSON = "[1, 2]"
        XCTAssertThrowsError(try bad.urlRequest()) { XCTAssertEqual($0 as? ChatError, .badExtra) }
        var unnamed = request
        unnamed.model = " "
        XCTAssertThrowsError(try unnamed.urlRequest()) { XCTAssertEqual($0 as? ChatError, .missingModel) }
    }

    func testClientStreamsDeltasInOrder() async throws {
        MockServer.respond(status: 200, chunks: [
            "data: {\"choices\":[{\"delta\":{\"content\":\"【概念】KV\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" Cache\\n【一句话】缓存\"}}]}\n",
            "\ndata: {\"choices\":[{\"delta\":{\"content\":\"中间结果\"}}]}\n\ndata: [DONE]\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ignored after done\"}}]}\n\n"
        ])
        var text = ""
        for try await event in makeClient().stream(sampleRequest()) {
            if case .content(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "【概念】KV Cache\n【一句话】缓存中间结果")
        XCTAssertEqual(CardParser.parse(text).oneLiner, "缓存中间结果")
        let sent = try XCTUnwrap(MockServer.lastBody)
        XCTAssertEqual(sent["stream"] as? Bool, true)
    }

    func testClientMapsHTTPErrorsWithoutLeakingBodies() async {
        MockServer.respond(status: 401, chunks: ["{\"error\":\"key sk-secret is invalid\"}"])
        do {
            for try await _ in makeClient().stream(sampleRequest()) {}
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ChatError, .http(401))
            XCTAssertFalse(ChatError.describe(error).contains("sk-secret"))
        }
    }

    func testClientRejectsEmptyAnswers() async {
        MockServer.respond(status: 200, chunks: ["data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: [DONE]\n\n"])
        do {
            for try await _ in makeClient().stream(sampleRequest()) {}
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ChatError, .noContent)
        }
    }

    func testDescribesTransportErrors() {
        XCTAssertTrue(ChatError.describe(URLError(.cannotConnectToHost)).contains("连不上"))
        XCTAssertTrue(ChatError.describe(URLError(.timedOut)).contains("超时"))
    }

    private func makeClient() -> ChatClient {
        let config = ChatClient.defaultConfiguration()
        config.protocolClasses = [MockServer.self]
        return ChatClient(configuration: config)
    }

    private func sampleRequest() -> ChatRequest {
        ChatRequest(endpoint: URL(string: "https://mock.local/v1/chat/completions")!, model: "test", key: "",
                    messages: [ChatMessage(.user, "hi")])
    }
}

final class MockServer: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var chunks: [String] = []
    private(set) static var lastBody: [String: Any]?

    static func respond(status: Int, chunks: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.chunks = chunks
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        let chunks = Self.chunks
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
