import Foundation
import CoreGraphics

public enum CaptureSource: String, Sendable {
    case selection = "选中文字"
    case accessibility = "指向文字"
    case ocr = "局部 OCR"
    case image = "局部图片"
    case window = "当前窗口"
    case concept = "延伸概念"
}

public enum EndpointError: LocalizedError {
    case invalid
    public var errorDescription: String? {
        "请输入完整的 Chat Completions URL（HTTPS；仅 localhost / 127.0.0.1 / ::1 允许 HTTP），不要在 URL 中放密钥。"
    }
}

public enum Endpoint {
    public static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw EndpointError.invalid }
        return url
    }
}

public enum TextTarget {
    /// AXRangeForPosition commonly returns one UTF-16 character. Expand it into a word.
    public static func wordRange(in text: String, utf16Offset: Int) -> NSRange? {
        let source = text as NSString
        guard utf16Offset >= 0, utf16Offset < source.length else { return nil }
        var result: NSRange?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .localized, .substringNotRequired]) { _, range, _, stop in
            let candidate = NSRange(range, in: text)
            if NSLocationInRange(utf16Offset, candidate) {
                result = candidate
                stop = true
            } else if candidate.location > utf16Offset {
                stop = true
            }
        }
        return result
    }

    public static func word(in text: String, utf16Offset: Int) -> String? {
        wordRange(in: text, utf16Offset: utf16Offset).map { (text as NSString).substring(with: $0) }
    }

    /// Word segmentation on a slice around the offset, so pointing deep into a long document does
    /// not walk every word from the beginning.
    public static func localWordRange(in text: String, utf16Offset: Int, radius: Int = 256) -> NSRange? {
        let source = text as NSString
        guard utf16Offset >= 0, utf16Offset < source.length else { return nil }
        let lower = max(0, utf16Offset - radius)
        let upper = min(source.length, utf16Offset + radius)
        let slice = source.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
        guard let local = wordRange(in: source.substring(with: slice), utf16Offset: utf16Offset - slice.location) else { return nil }
        return NSRange(location: local.location + slice.location, length: local.length)
    }

    public static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// Short strings that look like a term rather than a sentence or a passage.
    public static func isConceptLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return false }
        return trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？；\n")) == nil
    }
}

public enum ScreenGeometry {
    /// AppKit has a bottom-left origin, AX / Quartz a top-left origin on the primary display.
    public static func quartzPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func quartzRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func clampedOrigin(anchor: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = min(max(anchor.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        let y = min(max(anchor.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}

/// Where a card sits relative to the line being read (AppKit coordinates). The card grows away
/// from the target so the line the user pointed at is never covered while the answer streams in.
public struct CardAnchor: Equatable, Sendable {
    public var x: CGFloat
    /// Top edge when growing down, bottom edge when growing up.
    public var edge: CGFloat
    public var growsDown: Bool
    public var maxHeight: CGFloat

    public init(x: CGFloat, edge: CGFloat, growsDown: Bool, maxHeight: CGFloat) {
        self.x = x
        self.edge = edge
        self.growsDown = growsDown
        self.maxHeight = maxHeight
    }

    public func frame(width: CGFloat, height: CGFloat) -> CGRect {
        let h = min(max(height, 56), maxHeight)
        return CGRect(x: x, y: growsDown ? edge - h : edge, width: width, height: h)
    }

    public static func near(_ target: CGPoint, width: CGFloat, visibleFrame v: CGRect,
                            gap: CGFloat = 16, comfortable: CGFloat = 320, cap: CGFloat = 560) -> CardAnchor {
        let margin: CGFloat = 8
        let below = target.y - gap - (v.minY + margin)
        let above = (v.maxY - margin) - (target.y + gap)
        let growsDown = below >= comfortable || below >= above
        let x = min(max(target.x - 28, v.minX + margin), max(v.minX + margin, v.maxX - width - margin))
        let room = max(120, growsDown ? below : above)
        return CardAnchor(x: x, edge: growsDown ? target.y - gap : target.y + gap,
                          growsDown: growsDown, maxHeight: min(cap, room))
    }
}

/// One trigger per stationary point; do not retry failed OCR until the pointer moves.
public struct DwellGate {
    public private(set) var anchor: CGPoint?
    private var triggered = false
    public let tolerance: CGFloat

    public init(tolerance: CGFloat = 5) { self.tolerance = tolerance }

    public mutating func moved(to point: CGPoint) -> Bool {
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= tolerance { return false }
        anchor = point
        triggered = false
        return true
    }

    public mutating func trigger() -> Bool {
        guard anchor != nil, !triggered else { return false }
        triggered = true
        return true
    }

    public mutating func reset() { anchor = nil; triggered = false }
}
