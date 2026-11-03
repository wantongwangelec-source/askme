import AppKit
import ApplicationServices
import Combine
import Security
import ServiceManagement
import AskmeCore

/// The key that turns pointing into asking. Left-hand reachable keys work while the right hand is on
/// the mouse or trackpad; each is rarely held on its own, and chords with it cancel silently.
enum TriggerKey: String, CaseIterable, Identifiable {
    case control, option, rightCommand, function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "⌃ Control（左右均可）"
        case .option: return "⌥ Option（左右均可）"
        case .rightCommand: return "右侧 ⌘ Command"
        case .function: return "fn（地球仪键）"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .rightCommand: return "右 ⌘"
        case .function: return "fn"
        }
    }

    var keyCodes: Set<UInt16> {
        switch self {
        case .control: return [59, 62]
        case .option: return [58, 61]
        case .rightCommand: return [54]
        case .function: return [63]
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .rightCommand: return .command
        case .function: return .function
        }
    }

    /// Device-dependent state, so the right ⌘ is tracked even while the left one is held.
    func isDown(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch self {
        case .control: return raw & 0x2001 != 0
        case .option: return raw & 0x0060 != 0
        case .rightCommand: return raw & 0x0010 != 0
        case .function: return event.modifierFlags.contains(.function)
        }
    }
}

/// How an explicit trigger is allowed to send from a given app.
enum AppPolicy {
    /// Pointing with the trigger key is the consent: send the bounded context directly.
    case direct
    /// Third-party private communication lives here: preview before anything leaves the Mac.
    case askFirst
}

@MainActor
final class Settings: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var triggerKey: TriggerKey { didSet { defaults.set(triggerKey.rawValue, forKey: "triggerKey") } }
    @Published var hoverMode: Bool { didSet { defaults.set(hoverMode, forKey: "hoverMode") } }
    @Published var dwell: Double { didSet { defaults.set(dwell, forKey: "dwell") } }
    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocr") } }
    @Published var imageEnabled: Bool { didSet { defaults.set(imageEnabled, forKey: "image") } }
    @Published var enhanceWeb: Bool { didSet { defaults.set(enhanceWeb, forKey: "enhanceWeb") } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var askFirstApps: String { didSet { defaults.set(askFirstApps, forKey: "askFirstApps") } }
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var extraParameters: String { didSet { defaults.set(extraParameters, forKey: "extraParameters") } }
    @Published var background: String { didSet { defaults.set(background, forKey: "background") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: "memoryEnabled") } }
    @Published var searchURL: String { didSet { defaults.set(searchURL, forKey: "searchURL") } }
    private let defaults = UserDefaults.standard

    static let defaultExcluded = "com.1password.1password\ncom.agilebits.onepassword7\ncom.apple.Passwords\ncom.apple.keychainaccess\ncom.bitwarden.desktop\norg.keepassxc.keepassxc"
    static let defaultAskFirst = "com.apple.MobileSMS\ncom.tencent.xinWeChat\ncom.apple.mail"
    static let defaultSearch = "https://www.bing.com/search?q=%s"

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        triggerKey = d.string(forKey: "triggerKey").flatMap(TriggerKey.init(rawValue:)) ?? .control
        hoverMode = d.bool(forKey: "hoverMode")
        dwell = d.object(forKey: "dwell") as? Double ?? 0.9
        ocrEnabled = d.bool(forKey: "ocr")
        imageEnabled = d.bool(forKey: "image")
        enhanceWeb = d.object(forKey: "enhanceWeb") as? Bool ?? true
        excludedApps = d.string(forKey: "excludedApps") ?? Self.defaultExcluded
        askFirstApps = d.string(forKey: "askFirstApps") ?? Self.defaultAskFirst
        endpoint = d.string(forKey: "endpoint") ?? "https://api.openai.com/v1/chat/completions"
        model = d.string(forKey: "model") ?? "gpt-4o-mini"
        extraParameters = d.string(forKey: "extraParameters") ?? ""
        background = d.string(forKey: "background") ?? ""
        language = d.string(forKey: "language") ?? Learner.defaultLanguage
        memoryEnabled = d.bool(forKey: "memoryEnabled")
        searchURL = d.string(forKey: "searchURL") ?? Self.defaultSearch
    }

    var exclusions: Set<String> { Self.bundleIDs(excludedApps) }

    func excludes(_ bundleID: String) -> Bool { exclusions.contains(bundleID) }

    func policy(for bundleID: String) -> AppPolicy {
        Self.bundleIDs(askFirstApps).contains(bundleID) ? .askFirst : .direct
    }

    func searchLink(for term: String) -> URL? {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))),
              let url = URL(string: searchURL.replacingOccurrences(of: "%s", with: encoded)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var triggerHint: String { "按住 \(triggerKey.symbol) 指向文字即解释，松开关闭；轻点 \(triggerKey.symbol) 保留卡片" }

    private static func bundleIDs(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
    }
}

enum Keychain {
    private static let service = "local.askme.api"
    private static func query(for endpoint: String) throws -> [String: Any] {
        let account = try Endpoint.validate(endpoint).absoluteString
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(endpoint: String) throws -> String {
        var q = try query(for: endpoint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return value
    }

    static func save(_ value: String, endpoint: String) throws {
        let query = try query(for: endpoint)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain 操作失败（\(status)）；请使用固定路径下的已签名应用。" }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
