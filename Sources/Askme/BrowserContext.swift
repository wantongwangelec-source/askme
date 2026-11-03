import Foundation

struct BrowserPage: Decodable {
    let title: String
    let url: String
    let text: String
    var promptContext: String { "标题：\(title)\nURL：\(url)\n页面文本（截断）：\n\(text)" }
}

enum BrowserError: LocalizedError {
    case unavailable, changed, privateWindow
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "未读取到 Chrome 页面。请允许 Askme 控制 Chrome，并在 Chrome 菜单「查看 → 开发者 → 允许来自 Apple 事件的 JavaScript」中手动开启。也可能是内部页面或请求超时；可以不附加网页继续解释。"
        case .changed: return "Chrome 当前标签页与悬停时的窗口标题不匹配，请回到原页面重新触发。"
        case .privateWindow: return "不读取 Chrome 无痕窗口。"
        }
    }
}

final class BrowserContext {
    /// Called only by the explicit "Read current Chrome page" action, never by hovering.
    func read(expectedTitle: String) async throws -> BrowserPage {
        let script = """
        with timeout of 4 seconds
            tell application id "com.google.Chrome"
                if (count of windows) is 0 then error "NO_WINDOW"
                if mode of front window is "incognito" then return "PRIVATE_WINDOW"
                return execute active tab of front window javascript "JSON.stringify({title:document.title,url:location.href,text:(document.body ? document.body.innerText : '').slice(0,10000)})"
            end tell
        end timeout
        """
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    guard process.terminationStatus == 0 else { throw BrowserError.unavailable }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: BrowserError.unavailable) }
            }
        }
        try Task.checkCancellation()
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "PRIVATE_WINDOW" {
            throw BrowserError.privateWindow
        }
        guard let page = try? JSONDecoder().decode(BrowserPage.self, from: data) else { throw BrowserError.unavailable }
        guard !page.title.isEmpty, !expectedTitle.isEmpty,
              expectedTitle == page.title || expectedTitle.hasPrefix(page.title + " - ")
                || expectedTitle.hasPrefix(page.title + " — ") else { throw BrowserError.changed }
        return page
    }
}
