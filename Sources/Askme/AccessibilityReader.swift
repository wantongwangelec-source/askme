import AppKit
import ApplicationServices
import AskmeCore

struct AXSnapshot: Sendable {
    var pid: pid_t
    var text: String?
    var source: CaptureSource
    var nearbyText: String
    var windowTitle: String
    var windowFrame: CGRect?
    var isImage: Bool
}

struct WindowSnapshot: Sendable {
    var pid: pid_t
    var windowTitle: String
    var windowFrame: CGRect?
    var text: String
}

/// All potentially slow cross-process AX calls are serialized off the main thread.
final class AccessibilityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.askme.accessibility", qos: .userInitiated)
    /// Apps whose web content tree we already asked for. Only touched on `queue`.
    private var enhanced = Set<pid_t>()

    private static let webArea = "AXWebArea"
    private static let webTextRoles: Set<String> = [kAXStaticTextRole as String, "AXLink", "AXHeading"]
    private static let coarseRoles: Set<String> = [webArea, kAXGroupRole as String, kAXScrollAreaRole as String,
                                                   kAXWindowRole as String, kAXUnknownRole as String, kAXSplitGroupRole as String]
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]

    func read(at point: CGPoint, excluding bundleIDs: Set<String>, explicit: Bool, enhanceWeb: Bool) async -> AXSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.probe(at: point, excluding: bundleIDs, explicit: explicit, enhanceWeb: enhanceWeb))
            }
        }
    }

    /// Visible text of the window under `point`, or of the frontmost window when `point` is nil.
    func windowText(at point: CGPoint?, excluding bundleIDs: Set<String>, enhanceWeb: Bool) async -> WindowSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.collectWindow(at: point, excluding: bundleIDs, enhanceWeb: enhanceWeb))
            }
        }
    }

    // MARK: - Pointing

    private func probe(at point: CGPoint, excluding bundleIDs: Set<String>, explicit: Bool, enhanceWeb: Bool) -> AXSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        guard var hit = hitTest(point) else { return explicit ? focusedSelection(excluding: bundleIDs) : nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier, !bundleIDs.contains(bundleID),
              app.activationPolicy == .regular else { return nil }

        if enhanceWeb, !enhanced.contains(pid), Self.isWebEngine(app) {
            enhanced.insert(pid)
            if enableWebAccessibility(pid) {
                // Chromium builds the content tree asynchronously once accessibility is switched on.
                for delay in [0.12, 0.25] {
                    Thread.sleep(forTimeInterval: delay)
                    if let again = hitTest(point) {
                        hit = again
                        if !Self.coarseRoles.contains(role(again)) { break }
                    }
                }
            }
        }

        var chain = [hit]
        var roles = [role(hit)]
        var cursor = hit
        for _ in 0..<48 {
            guard let parent = element(cursor, kAXParentAttribute as String), !CFEqual(parent, cursor) else { break }
            let parentRole = role(parent)
            chain.append(parent)
            roles.append(parentRole)
            cursor = parent
            if parentRole == (kAXWindowRole as String) { break }
        }
        // Never read, OCR or send when the hit element or its near ancestors report a protected field.
        guard !chain.prefix(8).contains(where: isProtected) else { return nil }

        let window = element(hit, kAXWindowAttribute as String)
            ?? zip(chain, roles).first(where: { $0.1 == (kAXWindowRole as String) })?.0
        let webArea = zip(chain, roles).first(where: { $0.1 == Self.webArea })?.0
        let hitRole = roles[0]
        let isImage = hitRole == (kAXImageRole as String)
        var result = AXSnapshot(pid: pid, text: nil, source: .accessibility, nearbyText: "",
                                windowTitle: String((window.flatMap { string($0, kAXTitleAttribute as String) } ?? "").prefix(500)),
                                windowFrame: window.flatMap(frame), isImage: isImage)

        // A selection only counts when it is under the pointer: a selection in an unrelated editor
        // must not override what the user is pointing at.
        for item in chain.prefix(3) {
            if let selection = TextTarget.clean(string(item, kAXSelectedTextAttribute as String), limit: 4_000) {
                result.text = selection
                result.source = .selection
                result.nearbyText = selectionContext(in: item, selection: selection)
                return result
            }
        }
        if let webArea, let (selection, passage) = webSelection(in: webArea, at: point, requirePointer: true) {
            result.text = selection
            result.source = .selection
            result.nearbyText = passage
            return result
        }
        if isImage { return result }
        if let webArea, Self.webTextRoles.contains(hitRole), let (word, passage) = webWord(at: point, in: webArea) {
            result.text = word
            result.nearbyText = passage
            return result
        }
        for item in chain.prefix(2) {
            if let (word, passage) = nativeWord(at: point, in: item) {
                result.text = word
                result.nearbyText = passage
                return result
            }
        }
        let textRoles: Set<String> = [kAXStaticTextRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String, "AXLink", "AXHeading"]
        if textRoles.contains(hitRole) {
            let value = string(hit, kAXValueAttribute as String) ?? string(hit, kAXTitleAttribute as String)
            // No arbitrary paragraph chosen from a large editor when point-based lookup is unavailable.
            if let value, value.count <= 800, let cleaned = TextTarget.clean(value, limit: 800) {
                result.text = cleaned
                result.nearbyText = blockText(around: cleaned, chain: chain, roles: roles)
                return result
            }
        }
        if explicit {
            if let webArea, let (selection, passage) = webSelection(in: webArea, at: point, requirePointer: false) {
                result.text = selection
                result.source = .selection
                result.nearbyText = passage
                return result
            }
            if let focused = focusedSelection(excluding: bundleIDs) { return focused }
        }
        return result
    }

    private func hitTest(_ point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }

    private func nativeWord(at point: CGPoint, in element: AXUIElement) -> (String, String)? {
        var point = point
        guard let position = AXValueCreate(.cgPoint, &point),
              let raw = parameter(element, kAXRangeForPositionParameterizedAttribute as String, position),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        if let text = string(element, kAXValueAttribute as String), (text as NSString).length <= 200_000,
           let word = TextTarget.localWordRange(in: text, utf16Offset: range.location) {
            return ((text as NSString).substring(with: word), ContextWindow.around(word, in: text))
        }
        guard let count = (attribute(element, kAXNumberOfCharactersAttribute as String) as? NSNumber)?.intValue,
              count > range.location else { return nil }
        let start = max(0, range.location - 800)
        let end = min(count, range.location + 800)
        guard end > start else { return nil }
        var neighborhood = CFRange(location: start, length: end - start)
        guard let value = AXValueCreate(.cfRange, &neighborhood),
              let text = parameter(element, kAXStringForRangeParameterizedAttribute as String, value) as? String,
              let word = TextTarget.localWordRange(in: text, utf16Offset: range.location - start) else { return nil }
        return ((text as NSString).substring(with: word), ContextWindow.around(word, in: text))
    }

    private func selectionContext(in element: AXUIElement, selection: String) -> String {
        guard let text = string(element, kAXValueAttribute as String), (text as NSString).length <= 200_000 else { return "" }
        if let raw = attribute(element, kAXSelectedTextRangeAttribute as String), CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 {
                return ContextWindow.around(NSRange(location: range.location, length: range.length), in: text)
            }
        }
        return ContextWindow.around(selection, in: text) ?? TextTarget.clean(text, limit: 1_200) ?? ""
    }

    // MARK: - Web content (WebKit / Chromium text markers, the same interface VoiceOver uses)

    private func webWord(at point: CGPoint, in area: AXUIElement) -> (String, String)? {
        var point = point
        guard let position = AXValueCreate(.cgPoint, &point),
              let marker = parameter(area, "AXTextMarkerForPosition", position),
              let paragraphRange = parameter(area, "AXParagraphTextMarkerRangeForTextMarker", marker),
              let paragraph = parameter(area, "AXStringForTextMarkerRange", paragraphRange) as? String,
              !paragraph.isEmpty,
              let start = parameter(area, "AXStartTextMarkerForTextMarkerRange", paragraphRange),
              let prefixRange = parameter(area, "AXTextMarkerRangeForUnorderedTextMarkers", [start, marker] as CFArray),
              let prefix = parameter(area, "AXStringForTextMarkerRange", prefixRange) as? String else { return nil }
        let ns = paragraph as NSString
        let offset = min((prefix as NSString).length, ns.length - 1)
        guard let range = TextTarget.localWordRange(in: paragraph, utf16Offset: offset)
                ?? (offset > 0 ? TextTarget.localWordRange(in: paragraph, utf16Offset: offset - 1) : nil) else { return nil }
        let word = ns.substring(with: range)
        guard !word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty else { return nil }
        return (word, ContextWindow.around(range, in: paragraph))
    }

    private func webSelection(in area: AXUIElement, at point: CGPoint, requirePointer: Bool) -> (String, String)? {
        guard let range = attribute(area, "AXSelectedTextMarkerRange"),
              let text = parameter(area, "AXStringForTextMarkerRange", range) as? String,
              let selection = TextTarget.clean(text, limit: 4_000) else { return nil }
        if requirePointer {
            guard let bounds = rect(parameter(area, "AXBoundsForTextMarkerRange", range)),
                  bounds.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        }
        var passage = ""
        if let start = parameter(area, "AXStartTextMarkerForTextMarkerRange", range),
           let paragraphRange = parameter(area, "AXParagraphTextMarkerRangeForTextMarker", start),
           let paragraph = parameter(area, "AXStringForTextMarkerRange", paragraphRange) as? String {
            passage = ContextWindow.around(selection, in: paragraph) ?? TextTarget.clean(paragraph, limit: 1_200) ?? ""
        }
        return (selection, passage)
    }

    /// For a link or a styled run without range support, read the enclosing block so the model
    /// still sees the sentence around it.
    private func blockText(around target: String, chain: [AXUIElement], roles: [String]) -> String {
        for (element, role) in zip(chain.dropFirst(), roles.dropFirst()).prefix(3) {
            if [Self.webArea, kAXWindowRole as String, kAXScrollAreaRole as String].contains(role) { break }
            let text = descendantText(element, maxNodes: 80, maxChars: 2_400)
            if text.count > target.count + 10 {
                return ContextWindow.around(target, in: text) ?? String(text.prefix(1_200))
            }
        }
        return ""
    }

    private func descendantText(_ root: AXUIElement, maxNodes: Int, maxChars: Int) -> String {
        var stack = [root]
        var parts: [String] = []
        var chars = 0
        var visited = 0
        while let node = stack.popLast(), visited < maxNodes, chars < maxChars {
            visited += 1
            let values = multiple(node, [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute])
            let role = values[0] as? String ?? ""
            if role == (kAXStaticTextRole as String), let text = TextTarget.clean(values[1] as? String, limit: 1_000) {
                parts.append(text)
                chars += text.count
                continue
            }
            stack.append(contentsOf: children(values[2]).reversed())
        }
        return parts.joined(separator: " ")
    }

    private func focusedSelection(excluding bundleIDs: Set<String>) -> AXSnapshot? {
        guard let focused = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
              !bundleIDs.contains(bundleID), app.activationPolicy == .regular, !isProtected(focused) else { return nil }
        let window = element(focused, kAXWindowAttribute as String)
        var snapshot = AXSnapshot(pid: pid, text: nil, source: .selection, nearbyText: "",
                                  windowTitle: String((window.flatMap { string($0, kAXTitleAttribute as String) } ?? "").prefix(500)),
                                  windowFrame: window.flatMap(frame), isImage: false)
        if let selection = TextTarget.clean(string(focused, kAXSelectedTextAttribute as String), limit: 4_000) {
            snapshot.text = selection
            snapshot.nearbyText = selectionContext(in: focused, selection: selection)
            return snapshot
        }
        var cursor: AXUIElement? = focused
        for _ in 0..<48 {
            guard let current = cursor else { break }
            if role(current) == Self.webArea {
                guard let (selection, passage) = webSelection(in: current, at: .zero, requirePointer: false) else { return nil }
                snapshot.text = selection
                snapshot.nearbyText = passage
                return snapshot
            }
            cursor = element(current, kAXParentAttribute as String)
        }
        return nil
    }

    // MARK: - Whole window (knowledge preloading)

    private func collectWindow(at point: CGPoint?, excluding bundleIDs: Set<String>, enhanceWeb: Bool) -> WindowSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let pid: pid_t
        var window: AXUIElement?
        if let point, let hit = hitTest(point) {
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success else { return nil }
            pid = hitPID
            window = element(hit, kAXWindowAttribute as String)
            var cursor = hit
            for _ in 0..<48 where window == nil {
                guard let parent = element(cursor, kAXParentAttribute as String), !CFEqual(parent, cursor) else { break }
                if role(parent) == (kAXWindowRole as String) { window = parent }
                cursor = parent
            }
        } else {
            guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
            pid = front.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            window = element(app, kAXFocusedWindowAttribute as String) ?? element(app, kAXMainWindowAttribute as String)
        }
        guard pid != getpid(), let window,
              let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
              !bundleIDs.contains(bundleID), app.activationPolicy == .regular else { return nil }
        if enhanceWeb, !enhanced.contains(pid), Self.isWebEngine(app) {
            enhanced.insert(pid)
            if enableWebAccessibility(pid) { Thread.sleep(forTimeInterval: 0.35) }
        }
        let windowFrame = frame(window)
        let title = String((string(window, kAXTitleAttribute as String) ?? "").prefix(500))
        return WindowSnapshot(pid: pid, windowTitle: title, windowFrame: windowFrame,
                              text: visibleText(from: window, visible: windowFrame))
    }

    /// Document-order walk that keeps only text on screen, skips protected fields, and stops at a
    /// node, character and time budget so a huge page cannot stall the reader.
    private func visibleText(from root: AXUIElement, visible: CGRect?) -> String {
        let deadline = Date().addingTimeInterval(0.9)
        var stack = [root]
        var lines: [String] = []
        var chars = 0
        var visited = 0
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
                          kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute]
        while let node = stack.popLast(), visited < 6_000, chars < 12_000, Date() < deadline {
            visited += 1
            let values = multiple(node, attributes)
            let role = values[0] as? String ?? ""
            if values[1] as? String == (kAXSecureTextFieldSubrole as String) { continue }
            if let visible, let box = frame(position: values[5], size: values[6]), !box.intersects(visible) { continue }
            var text: String?
            switch role {
            case kAXStaticTextRole:
                text = values[2] as? String
            case kAXTextAreaRole:
                text = visibleCharacters(of: node) ?? (values[2] as? String).map { String($0.prefix(3_000)) }
            case kAXTextFieldRole, "AXHeading":
                text = (values[2] as? String) ?? (values[3] as? String)
            default:
                break
            }
            if let cleaned = TextTarget.clean(text, limit: 3_000) {
                if lines.last != cleaned {
                    lines.append(cleaned)
                    chars += cleaned.count
                }
                if role != "AXHeading" { continue }
            }
            stack.append(contentsOf: children(values[4]).reversed())
        }
        return String(lines.joined(separator: "\n").prefix(12_000))
    }

    private func visibleCharacters(of element: AXUIElement) -> String? {
        guard let range = attribute(element, kAXVisibleCharacterRangeAttribute as String),
              CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        return parameter(element, kAXStringForRangeParameterizedAttribute as String, range) as? String
    }

    // MARK: - Chromium / Electron

    static func isWebEngine(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, chromiumBrowsers.contains(id) { return true }
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Chromium and Electron only expose page text to assistive apps that ask for it. Unlike
    /// AXEnhancedUserInterface, this attribute does not change window animation behaviour.
    private func enableWebAccessibility(_ pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - AX helpers

    private func isProtected(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute as String) == (kAXSecureTextFieldSubrole as String)
            || (attribute(element, "AXProtectedContent") as? Bool == true)
    }

    private func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute as String) ?? "" }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func multiple(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == names.count else { return Array(repeating: nil, count: names.count) }
        return array.map { $0 }
    }

    private func children(_ value: AnyObject?) -> [AXUIElement] {
        guard let items = value as? [AnyObject] else { return [] }
        return items.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }

    private func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize,
              AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        let values = multiple(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let box = frame(position: values[0], size: values[1]), box.width > 0, box.height > 0 else { return nil }
        return box
    }
}
