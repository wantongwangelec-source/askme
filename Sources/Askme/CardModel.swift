import AppKit
import SwiftUI
import AskmeCore

struct Candidate: Identifiable {
    let id = UUID()
    /// Where the user pointed, in AppKit coordinates.
    let point: CGPoint
    let pid: pid_t
    let bundleID: String
    let appName: String
    let windowTitle: String
    let text: String
    let nearbyText: String
    let source: CaptureSource
    let jpeg: Data?
    var windowFrame: CGRect?
}

@MainActor
final class FollowUpTurn: ObservableObject, Identifiable {
    let id = UUID()
    let question: String
    let prompt: String
    @Published var answer = ""
    @Published var loading = true
    @Published var thinking = false
    @Published var error = ""
    var task: Task<Void, Never>?

    init(question: String, prompt: String) {
        self.question = question
        self.prompt = prompt
    }
}

/// One concept (or one page primer) inside a card. Drilling into a prerequisite pushes a new page;
/// the back button pops it, so the path through related concepts stays visible and reversible.
@MainActor
final class ConceptPage: ObservableObject, Identifiable {
    enum Kind { case concept, primer }

    let id = UUID()
    let kind: Kind
    let candidate: Candidate
    let parentConcept: String
    @Published var target: String
    @Published var pageText = ""
    @Published private(set) var text = ""
    @Published private(set) var card = ConceptCard()
    @Published private(set) var primer = Primer()
    @Published var loading = false
    @Published var finished = false
    @Published var thinking = false
    @Published var preparing = false
    @Published var error = ""
    @Published var needsConfirmation = false
    var confirmReason = ""
    @Published var includeContext = true
    @Published var includeImage: Bool
    @Published var browserPage: BrowserPage?
    @Published var includeBrowserPage = false
    @Published var readingBrowserPage = false
    @Published var followUps: [FollowUpTurn] = []
    @Published var followUpLoading = false
    /// The card keeps the newest follow-up answer in view until the user scrolls by hand.
    var followsLatest = false
    @Published var recall: KnowledgeEntry?
    /// Recall is looked up again once the model names the full concept (the user may have
    /// pointed at "Cache" in "KV Cache").
    var recallResolved = false
    @Published var expanded = false
    /// Exactly what left the Mac for this page, shown on demand from the card's menu.
    @Published var sent = ""
    @Published var showsSent = false
    var task: Task<Void, Never>?

    init(kind: Kind = .concept, candidate: Candidate, parentConcept: String = "") {
        self.kind = kind
        self.candidate = candidate
        self.parentConcept = parentConcept
        target = candidate.text
        includeImage = candidate.jpeg != nil
    }

    var title: String {
        switch kind {
        case .primer:
            let name = candidate.windowTitle.isEmpty ? candidate.appName : candidate.windowTitle
            return "预装载 · \(name)"
        case .concept:
            return card.concept ?? String(target.replacingOccurrences(of: "\n", with: " ").prefix(60))
        }
    }

    var conceptName: String { card.concept ?? target }

    var hasAnswer: Bool { !text.isEmpty }

    func resetAnswer() {
        task?.cancel()
        task = nil
        followUps.forEach { $0.task?.cancel() }
        followUps.removeAll()
        followUpLoading = false
        text = ""
        card = ConceptCard()
        primer = Primer()
        error = ""
        finished = false
        thinking = false
        expanded = false
        showsSent = false
    }

    func append(_ delta: String) {
        text += delta
        thinking = false
        reparse(complete: false)
    }

    func complete() {
        reparse(complete: true)
        finished = true
        loading = false
        thinking = false
    }

    func fail(_ message: String) {
        error = message
        loading = false
        thinking = false
        preparing = false
    }

    func cancel() {
        task?.cancel()
        task = nil
        followUps.forEach { $0.task?.cancel() }
        loading = false
        thinking = false
        followUpLoading = false
    }

    private func reparse(complete: Bool) {
        switch kind {
        case .concept: card = CardParser.parse(text, complete: complete)
        case .primer: primer = PrimerParser.parse(text, complete: complete)
        }
    }

    /// Plain text for the clipboard.
    var plainText: String {
        var lines: [String] = [title]
        switch kind {
        case .concept:
            if let free = card.freeform {
                lines.append(free)
            } else {
                for section in [CardSection.oneLiner, .inContext, .analogy, .keyPoints, .example, .pitfall] {
                    if let body = card[section] { lines.append("\(section.rawValue)：\(body)") }
                }
                if !card.prerequisites.isEmpty { lines.append("前置：" + card.prerequisites.joined(separator: "、")) }
                if !card.related.isEmpty { lines.append("相关：" + card.related.joined(separator: "、")) }
            }
        case .primer:
            if let gist = primer.gist { lines.append("主旨：\(gist)") }
            for (index, item) in primer.items.enumerated() {
                lines.append("\(index + 1). \(item.term)\(item.summary.isEmpty ? "" : "：\(item.summary)")")
            }
            if let hardest = primer.hardest { lines.append("难点：\(hardest)") }
            if let free = primer.freeform { lines.append(free) }
        }
        for turn in followUps where !turn.answer.isEmpty {
            lines.append("\n问：\(turn.question)\n\(turn.answer)")
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: ContextWindow.openMark, with: "")
            .replacingOccurrences(of: ContextWindow.closeMark, with: "")
    }
}

@MainActor
final class CardModel: ObservableObject {
    enum Mode {
        /// Visible while the trigger key is held.
        case peek
        /// Kept after a tap; goes away on an outside click, typing, scrolling or Esc.
        case transient
        /// Stays until closed. Further lookups join this card's path.
        case pinned
        /// Pinned and docked to the screen edge as a reading companion.
        case docked

        var isPersistent: Bool { self == .pinned || self == .docked }
    }

    @Published var mode: Mode
    @Published private(set) var stack: [ConceptPage] = []
    let destination: String
    let triggerSymbol: String
    /// Peek cards explain how to keep them only for the first few uses.
    var showsPeekHint = false

    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleDock: (() -> Void)?
    var onInteract: (() -> Void)?
    var onBack: (() -> Void)?
    var onConfirm: ((ConceptPage) -> Void)?
    var onRetry: ((ConceptPage) -> Void)?
    var onFollowUp: ((ConceptPage, String, String) -> Void)?
    var onDrill: ((ConceptPage, String) -> Void)?
    var onSearch: ((ConceptPage) -> Void)?
    var onReadBrowserPage: ((ConceptPage) -> Void)?
    /// Content height, and whether the page has stopped streaming.
    var onHeight: ((CGFloat, Bool) -> Void)?
    var onDragged: (() -> Void)?

    init(mode: Mode, destination: String, triggerSymbol: String) {
        self.mode = mode
        self.destination = destination
        self.triggerSymbol = triggerSymbol
    }

    var current: ConceptPage? { stack.last }

    var breadcrumb: String {
        stack.dropLast().map { String($0.title.prefix(16)) }.joined(separator: " › ")
    }

    func push(_ page: ConceptPage) { stack.append(page) }

    func replaceTop(with page: ConceptPage) {
        stack.popLast()?.cancel()
        stack.append(page)
    }

    func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast().cancel()
    }

    func cancelAll() { stack.forEach { $0.cancel() } }
}
