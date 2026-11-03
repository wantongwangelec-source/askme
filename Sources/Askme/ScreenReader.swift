import AppKit
import ScreenCaptureKit
import Vision
import AskmeCore

struct ScreenSnippet: Sendable {
    let jpeg: Data
    let text: String?
    let nearbyText: String
}

enum ScreenReadError: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法安全定位当前窗口的截图区域。" }
}

final class ScreenReader: Sendable {
    private let queue = DispatchQueue(label: "local.askme.ocr", qos: .userInitiated)

    func read(at point: CGPoint, snapshot: AXSnapshot, recognizeText: Bool) async throws -> ScreenSnippet {
        let (window, display) = try await locate(pid: snapshot.pid, frame: snapshot.windowFrame, containing: point)
        // Capture one bounded region of the identified window, never the whole desktop.
        let crop = CGRect(x: point.x - 260, y: point.y - 150, width: 520, height: 300)
            .intersection(window.frame).intersection(display.frame)
        guard !crop.isNull, crop.width > 2, crop.height > 2 else { throw ScreenReadError.unavailable }
        let filter = SCContentFilter(display: display, including: [window])
        let config = SCStreamConfiguration()
        config.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(crop.width * 2)
        config.height = Int(crop.height * 2)
        config.showsCursor = false
        config.scalesToFit = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let normalized = CGPoint(x: (point.x - crop.minX) / crop.width, y: 1 - (point.y - crop.minY) / crop.height)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.analyze(image, at: normalized, recognizeText: recognizeText)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Local OCR of one identified window, for preloading when accessibility exposes no page text.
    /// The image never leaves this function; only recognized lines are returned.
    func readWindow(pid: pid_t, frame: CGRect?) async throws -> String {
        guard let frame else { throw ScreenReadError.unavailable }
        let (window, _) = try await locate(pid: pid, frame: frame, containing: CGPoint(x: frame.midX, y: frame.midY))
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(2, 2_400 / max(window.frame.width, window.frame.height, 1))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let lines = (request.results ?? [])
                        .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                            ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: String(lines.joined(separator: "\n").prefix(12_000)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func locate(pid: pid_t, frame: CGRect?, containing point: CGPoint) async throws -> (SCWindow, SCDisplay) {
        guard CGPreflightScreenCaptureAccess(), let frame else { throw ScreenReadError.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.contains(point) }),
              let window = content.windows.first(where: {
                  $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.contains(point)
                      && abs($0.frame.minX - frame.minX) < 4 && abs($0.frame.minY - frame.minY) < 4
                      && abs($0.frame.width - frame.width) < 4 && abs($0.frame.height - frame.height) < 4
              }) else { throw ScreenReadError.unavailable }
        return (window, display)
    }

    private func analyze(_ image: CGImage, at point: CGPoint, recognizeText: Bool) throws -> ScreenSnippet {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ScreenReadError.unavailable
        }
        guard recognizeText else { return ScreenSnippet(jpeg: jpeg, text: nil, nearbyText: "") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        let nearby = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let hit = observations.filter { $0.boundingBox.insetBy(dx: -0.012, dy: -0.018).contains(point) }
            .min { a, b in
                hypot(a.boundingBox.midX - point.x, a.boundingBox.midY - point.y)
                    < hypot(b.boundingBox.midX - point.x, b.boundingBox.midY - point.y)
            }
        guard let candidate = hit?.topCandidates(1).first else {
            return ScreenSnippet(jpeg: jpeg, text: nil, nearbyText: String(nearby.prefix(4_000)))
        }
        var target: String?
        var targetRange: NSRange?
        candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex,
                                             options: [.byWords, .localized]) { word, range, _, stop in
            if let rect = try? candidate.boundingBox(for: range)?.boundingBox,
               rect.insetBy(dx: -0.008, dy: -0.012).contains(point) {
                target = word
                targetRange = NSRange(range, in: candidate.string)
                stop = true
            }
        }
        // Centre the context on the recognized line, with the pointed word marked when known.
        let line = targetRange.map { ContextWindow.around($0, in: candidate.string) } ?? candidate.string
        let context = nearby.replacingOccurrences(of: candidate.string, with: line)
        let lineRange = (context as NSString).range(of: line)
        let passage = lineRange.location == NSNotFound
            ? String(context.prefix(1_600))
            : ContextWindow.around(lineRange, in: context, limit: 1_600, mark: false)
        return ScreenSnippet(jpeg: jpeg, text: target ?? candidate.string, nearbyText: passage)
    }
}
