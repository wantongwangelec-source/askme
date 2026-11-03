import Foundation
import AskmeCore

/// Builds requests from the current settings. The key is read from the Keychain entry of the exact
/// endpoint at send time, so changing the URL never forwards an old key to a new service.
@MainActor
enum AIClient {
    static let shared = ChatClient()

    static func request(_ settings: Settings, messages: [ChatMessage]) throws -> ChatRequest {
        let url = try Endpoint.validate(settings.endpoint)
        let key = try Keychain.read(endpoint: settings.endpoint)
        return ChatRequest(endpoint: url, model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
                           key: key, messages: messages, extraJSON: settings.extraParameters)
    }

    /// Where requests go, e.g. "api.openai.com" or "local service localhost:11434". A local endpoint is
    /// often a proxy, so it is not described as "stays on this Mac".
    static func destination(_ settings: Settings) -> String {
        guard let url = URL(string: settings.endpoint), let host = url.host else { return "设置的模型服务" }
        let address = url.port.map { "\(host):\($0)" } ?? host
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        return local ? "本机服务 \(address)（可能会再转发到远端模型）" : address
    }
}
