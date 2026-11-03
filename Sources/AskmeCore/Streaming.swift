import Foundation

/// Incremental parser for OpenAI-compatible Chat Completions streams (server-sent events).
/// Also accepts a plain JSON body from servers that ignore `"stream": true`.
public struct ChatStreamParser: Sendable {
    public enum Event: Equatable, Sendable {
        case content(String)
        /// The model is reasoning before it answers; there is no visible text yet.
        case reasoning
        case done
        case failed
    }

    private var pending: [String] = []
    private var raw = ""

    public init() {}

    /// Feeds one line of the HTTP body without its trailing newline.
    public mutating func feed(_ line: String) -> [Event] {
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return [] }
        if line.hasPrefix("data:") {
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" {
                pending.removeAll()
                return [.done]
            }
            if pending.isEmpty, let events = Self.decode(payload) { return events }
            pending.append(payload)
            if let events = Self.decode(pending.joined(separator: "\n")) {
                pending.removeAll()
                return events
            }
            return []
        }
        if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { return [] }
        raw += line + "\n"
        return []
    }

    public mutating func finish() -> [Event] {
        var events = flush()
        if !raw.isEmpty, let data = raw.data(using: .utf8) {
            if let content = Self.completeMessage(data), !content.isEmpty {
                events.append(.content(content))
            } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] != nil {
                events.append(.failed)
            }
        }
        raw = ""
        return events
    }

    private mutating func flush() -> [Event] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }
        return Self.decode(pending.joined(separator: "\n")) ?? []
    }

    static func decode(_ payload: String) -> [Event]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["error"] != nil { return [.failed] }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
        var events: [Event] = []
        if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
            events.append(.reasoning)
        }
        if let text = text(delta["content"]), !text.isEmpty { events.append(.content(text)) }
        return events
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    static func completeMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
        return text(message["content"]) ?? (message["refusal"] as? String)
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    public var imageJPEG: Data?

    public init(_ role: Role, _ text: String, imageJPEG: Data? = nil) {
        self.role = role
        self.text = text
        self.imageJPEG = imageJPEG
    }

    var json: [String: Any] {
        guard let imageJPEG else { return ["role": role.rawValue, "content": text] }
        return ["role": role.rawValue, "content": [
            ["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"]]
        ]]
    }
}

public struct ChatRequest: Sendable {
    public var endpoint: URL
    public var model: String
    public var key: String
    public var messages: [ChatMessage]
    /// Optional JSON object merged into the body, e.g. `{"reasoning_effort": "low"}`.
    public var extraJSON: String

    public init(endpoint: URL, model: String, key: String, messages: [ChatMessage], extraJSON: String = "") {
        self.endpoint = endpoint
        self.model = model
        self.key = key
        self.messages = messages
        self.extraJSON = extraJSON
    }

    public static func parseExtra(_ value: String) throws -> [String: Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.badExtra }
        return object
    }

    public func urlRequest() throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.missingModel }
        var body = try Self.parseExtra(extraJSON)
        body["model"] = model
        body["messages"] = messages.map(\.json)
        body["stream"] = true
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public enum ChatError: LocalizedError, Equatable {
    case missingModel, badExtra, http(Int), tooLarge, noContent, serviceError

    public var errorDescription: String? {
        switch self {
        case .missingModel: return "请先在设置里填写模型名称。"
        case .badExtra: return "「额外请求参数」不是合法的 JSON 对象。"
        case .http(let code) where code == 401 || code == 403:
            return "认证失败（HTTP \(code)）。请检查 API Key 是否正确、是否对应这个接口地址。"
        case .http(404): return "接口地址或模型名不正确（HTTP 404）。"
        case .http(429): return "请求太频繁或额度不足（HTTP 429），稍后再试。"
        case .http(400): return "请求被拒绝（HTTP 400）。请检查模型名和额外参数；附带图片时需要视觉模型。"
        case .http(let code) where code >= 500: return "模型服务暂时不可用（HTTP \(code)）。"
        case .http(let code): return "模型请求失败（HTTP \(code)）。"
        case .tooLarge: return "模型响应超过 2 MB，已停止读取。"
        case .noContent: return "没有收到文本回答。需要兼容 OpenAI Chat Completions 的接口；图片需要视觉模型。"
        case .serviceError: return "模型服务在返回过程中报错，请重试。"
        }
    }

    /// User-facing text for any error from a request. Server bodies are never shown: they may echo
    /// the submitted text or credentials.
    public static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "请求超时，请重试或换一个更快的模型。"
            case .cannotConnectToHost, .cannotFindHost: return "连不上模型服务。如果是本地服务，请确认它已经启动。"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接中断，请检查网络后重试。"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "无法建立安全连接（证书或 TLS 问题）。"
            default: return "网络请求失败（\(error.code.rawValue)）。"
            }
        }
        return "请求失败，请重试。"
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a key or captured content to a redirect destination.
        completionHandler(nil)
    }
}

/// One long-lived session so consecutive lookups reuse the same connection instead of paying a new
/// TCP / TLS handshake every time. Ephemeral: no cache, cookies or credential storage on disk.
public final class ChatClient: @unchecked Sendable {
    public static let responseLimit = 2_000_000
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = ChatClient.defaultConfiguration()) {
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return config
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamParser.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try request.urlRequest()
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ChatError.noContent }
                    guard (200..<300).contains(http.statusCode) else { throw ChatError.http(http.statusCode) }
                    var parser = ChatStreamParser()
                    var line = Data()
                    var total = 0
                    var sawContent = false
                    var finished = false

                    func handle(_ events: [ChatStreamParser.Event]) throws {
                        for event in events {
                            switch event {
                            case .content:
                                sawContent = true
                                continuation.yield(event)
                            case .reasoning:
                                continuation.yield(event)
                            case .done:
                                finished = true
                            case .failed:
                                throw ChatError.serviceError
                            }
                        }
                    }

                    reading: for try await byte in bytes {
                        total += 1
                        guard total <= Self.responseLimit else { throw ChatError.tooLarge }
                        guard byte == 0x0A else { line.append(byte); continue }
                        try handle(parser.feed(String(decoding: line, as: UTF8.self)))
                        line.removeAll(keepingCapacity: true)
                        if finished { break reading }
                    }
                    if !finished, !line.isEmpty { try handle(parser.feed(String(decoding: line, as: UTF8.self))) }
                    try handle(parser.finish())
                    guard sawContent else { throw ChatError.noContent }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
