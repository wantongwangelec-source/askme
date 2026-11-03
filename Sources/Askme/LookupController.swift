import AppKit
import Carbon
import AskmeCore

/// Orchestrates one lookup from gesture to card: capture locally, apply the app's privacy policy,
/// stream the answer, and handle follow-ups, drill-downs, memory and page preloading.
@MainActor
final class LookupController {
    private let settings: Settings
    private let knowledge: KnowledgeStore
    private let overlay: Overlay
    private let reader = AccessibilityReader()
    private let screenReader = ScreenReader()
    private let browser = BrowserContext()

    private var card: CardModel?
    private var keyHeld = false
    private var pendingPrimer = false
    private var pendingPoint = CGPoint.zero
    private var pendingCapture: Task<Candidate?, Never>?
    private var captureToken = UUID()
    private var peekPage: ConceptPage?
    private var hoverTask: Task<Void, Never>?
    private var hoverToken = UUID()
    private var browserTask: Task<Void, Never>?

    init(settings: Settings, knowledge: KnowledgeStore, overlay: Overlay) {
        self.settings = settings
        self.knowledge = knowledge
        self.overlay = overlay
    }

    var hasCard: Bool { card != nil }

    // MARK: - Trigger key

    func handle(_ trigger: InputMonitor.Trigger) {
        switch trigger {
        case .began(let point, let primer): begin(at: point, primer: primer)
        case .peek: reveal(.peek)
        case .tap: keyHeld = false; reveal(.transient)
        case .ended(let onCard): endPeek(onCard: onCard)
        case .cancelled: cancelPending()
        case .retarget(let point): retarget(at: point)
        }
    }

    private func begin(at point: CGPoint, primer: Bool) {
        guard settings.enabled else { return }
        keyHeld = true
        pendingPrimer = primer
        pendingPoint = point
        captureToken = UUID()
        pendingCapture?.cancel()
        hoverInvalidated()
        // Pressing the key over Askme's own card is not a request about the card itself.
        guard Permissions.accessibility, !overlay.contains(point) else {
            pendingCapture = nil
            pendingPrimer = false
            return
        }
        // Read locally right away: by the time the hold is confirmed the text is usually ready.
        pendingCapture = primer ? nil : Task { [weak self] in await self?.capture(at: point, explicit: true) }
    }

    private func reveal(_ mode: CardModel.Mode) {
        guard Permissions.accessibility else {
            overlay.toast("Askme 还没有辅助功能权限。请在菜单栏 Askme → 设置与权限中授权。", near: pendingPoint)
            return
        }
        guard !overlay.contains(pendingPoint) else { return }
        if pendingPrimer {
            pendingPrimer = false
            startPrimer(at: pendingPoint)
            return
        }
        guard let task = pendingCapture else { return }
        let token = captureToken
        let point = pendingPoint
        Task { [weak self] in
            let candidate = await task.value
            guard let self, token == self.captureToken else { return }
            guard let candidate else {
                if mode == .transient || self.keyHeld { self.overlay.toast(self.missHint, near: point) }
                return
            }
            self.present(candidate, mode: mode)
        }
    }

    private func endPeek(onCard: Bool) {
        keyHeld = false
        defer { peekPage = nil }
        guard let card else { return }
        if card.mode == .peek {
            if onCard {
                card.mode = .transient
            } else {
                closeCard()
            }
        }
    }

    private func cancelPending() {
        keyHeld = false
        pendingPrimer = false
        captureToken = UUID()
        pendingCapture?.cancel()
        pendingCapture = nil
        if card?.mode == .peek { closeCard() }
        peekPage = nil
    }

    private func retarget(at point: CGPoint) {
        guard keyHeld, let card, card.mode == .peek || peekPage != nil else { return }
        let token = UUID()
        captureToken = token
        Task { [weak self] in
            guard let self, let candidate = await self.capture(at: point, explicit: true),
                  token == self.captureToken, self.keyHeld else { return }
            if let current = self.card?.current, current.candidate.text == candidate.text,
               current.candidate.nearbyText == candidate.nearbyText { return }
            self.present(candidate, mode: .peek, replacingPeek: true)
        }
    }

    private var missHint: String {
        "这里没有读到文字。可以先选中文字再按 \(settings.triggerKey.symbol)，或在设置里开启 OCR。"
    }

    // MARK: - Hover hint (optional, always previews before sending)

    func hoverDwell(at point: CGPoint) {
        guard hoverTask == nil, card == nil, Permissions.accessibility else { return }
        let token = UUID()
        hoverToken = token
        hoverTask = Task { [weak self] in
            guard let self else { return }
            defer { self.hoverTask = nil }
            guard let candidate = await self.capture(at: point, explicit: false),
                  token == self.hoverToken, self.card == nil else { return }
            self.overlay.showHint(candidate: candidate) { [weak self] in
                self?.present(candidate, mode: .transient, confirm: true)
            }
        }
    }

    func hoverInvalidated() {
        hoverToken = UUID()
        hoverTask?.cancel()
        overlay.closeHint()
    }

    // MARK: - Dismissal

    func escape() {
        guard let card else { return }
        if !card.mode.isPersistent || overlay.isCardKey { closeCard() }
    }

    func outside(_ kind: InputMonitor.Outside) {
        guard let card, card.mode == .transient, !keyHeld else { return }
        closeCard()
    }

    func contextChanged() {
        guard let card, !card.mode.isPersistent else { return }
        closeCard()
    }

    /// Scrolling the card by hand means the reader is in charge of the position now.
    func cardScrolled() {
        card?.current?.followsLatest = false
    }

    func closeCard() {
        card?.cancelAll()
        card = nil
        peekPage = nil
        browserTask?.cancel()
        browserTask = nil
        overlay.closeCard()
    }

    // MARK: - Capture

    private func capture(at point: CGPoint, explicit: Bool) async -> Candidate? {
        guard Permissions.accessibility, settings.enabled, !IsSecureEventInputEnabled() else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartz = ScreenGeometry.quartzPoint(fromAppKit: point, primaryHeight: primaryHeight)
        guard let snapshot = await reader.read(at: quartz, excluding: settings.exclusions, explicit: explicit,
                                               enhanceWeb: settings.enhanceWeb),
              !Task.isCancelled,
              let app = NSRunningApplication(processIdentifier: snapshot.pid),
              let bundleID = app.bundleIdentifier, !settings.excludes(bundleID),
              app.activationPolicy == .regular else { return nil }
        var text = snapshot.text
        var source = snapshot.source
        var nearby = snapshot.nearbyText
        var jpeg: Data?
        if text == nil, settings.ocrEnabled || settings.imageEnabled, Permissions.screenRecording {
            do {
                let preferImage = snapshot.isImage && settings.imageEnabled
                let snippet = try await screenReader.read(at: quartz, snapshot: snapshot,
                                                          recognizeText: settings.ocrEnabled && !preferImage)
                if let recognized = snippet.text {
                    text = recognized
                    nearby = snippet.nearbyText
                    source = .ocr
                } else if settings.imageEnabled {
                    text = "鼠标附近的这张图片"
                    source = .image
                    jpeg = snippet.jpeg
                }
            } catch { return nil } // A failed capture must never interrupt the user with an alert.
        }
        guard !Task.isCancelled, !IsSecureEventInputEnabled(), let text, !text.isEmpty else { return nil }
        return Candidate(point: point, pid: snapshot.pid, bundleID: bundleID, appName: app.localizedName ?? bundleID,
                         windowTitle: snapshot.windowTitle, text: text, nearbyText: nearby, source: source, jpeg: jpeg,
                         windowFrame: snapshot.windowFrame)
    }

    // MARK: - Presenting

    private func present(_ candidate: Candidate, mode requested: CardModel.Mode, confirm: Bool = false, replacingPeek: Bool = false) {
        // Released before the card could appear: show it as a kept card rather than lose the answer.
        let mode: CardModel.Mode = requested == .peek && !keyHeld ? .transient : requested
        let page = ConceptPage(candidate: candidate)
        page.recall = settings.memoryEnabled ? knowledge.entry(for: candidate.text) : nil
        if confirm {
            page.needsConfirmation = true
            page.confirmReason = "悬停触发的提示会先让你确认，确认后才发送。"
        } else if settings.policy(for: candidate.bundleID) == .askFirst {
            page.needsConfirmation = true
            page.confirmReason = "「\(candidate.appName)」设为发送前确认：这里常有他人的私人信息，你看过之后才会发送。"
        }

        if let card, card.mode.isPersistent {
            if replacingPeek, let peekPage, card.current === peekPage {
                card.replaceTop(with: page)
            } else {
                card.push(page)
            }
        } else if let card, card.mode == .peek, replacingPeek {
            card.replaceTop(with: page)
            overlay.reanchor(near: candidate.point)
        } else {
            closeCard()
            let model = makeCard(mode: mode)
            model.push(page)
            card = model
            overlay.showCard(model, near: candidate.point)
        }
        if keyHeld { peekPage = page }
        if page.needsConfirmation {
            // A confirmation needs a click, so it must survive releasing the key.
            if card?.mode == .peek { card?.mode = .transient }
        } else {
            explain(page)
        }
    }

    private func makeCard(mode: CardModel.Mode) -> CardModel {
        let model = CardModel(mode: mode, destination: AIClient.destination(settings), triggerSymbol: settings.triggerKey.symbol)
        if mode == .peek {
            let shown = UserDefaults.standard.integer(forKey: "peekHintsShown")
            model.showsPeekHint = shown < 6
            if model.showsPeekHint { UserDefaults.standard.set(shown + 1, forKey: "peekHintsShown") }
        }
        model.onClose = { [weak self] in self?.closeCard() }
        model.onTogglePin = { [weak self, weak model] in
            guard let model else { return }
            if model.mode == .docked { self?.overlay.setDocked(false) }
            model.mode = model.mode.isPersistent ? .transient : .pinned
        }
        model.onToggleDock = { [weak self, weak model] in
            guard let self, let model else { return }
            let dock = model.mode != .docked
            model.mode = dock ? .docked : .pinned
            self.overlay.setDocked(dock)
        }
        model.onInteract = { [weak self] in self?.interact() }
        model.onDragged = { [weak self] in
            self?.overlay.markUserPlaced()
            self?.interact()
        }
        model.onBack = { [weak self, weak model] in
            model?.pop()
            self?.interact()
        }
        model.onConfirm = { [weak self] page in
            self?.interact()
            self?.explain(page)
        }
        model.onRetry = { [weak self] page in self?.explain(page) }
        model.onFollowUp = { [weak self] page, label, prompt in self?.followUp(page, label: label, prompt: prompt) }
        model.onDrill = { [weak self] page, term in self?.drill(from: page, term: term) }
        model.onSearch = { [weak self] page in
            guard let self, let url = self.settings.searchLink(for: page.conceptName) else { return }
            NSWorkspace.shared.open(url)
        }
        model.onReadBrowserPage = { [weak self] page in self?.readBrowserPage(page) }
        return model
    }

    /// Any deliberate interaction with a card means the user wants to keep it.
    private func interact() {
        guard let card, card.mode == .peek || card.mode == .transient else { return }
        card.mode = .pinned
    }

    // MARK: - Asking the model

    private func learner() -> Learner {
        Learner(background: settings.background,
                knownConcepts: settings.memoryEnabled ? knowledge.book.anchors(limit: 30) : [],
                language: settings.language)
    }

    private func input(for page: ConceptPage) -> PromptInput {
        PromptInput(text: page.target,
                    application: page.includeContext ? page.candidate.appName : "",
                    windowTitle: page.includeContext ? page.candidate.windowTitle : "",
                    nearbyText: page.includeContext ? page.candidate.nearbyText : "",
                    pageContext: page.includeBrowserPage ? page.browserPage?.promptContext ?? "" : "",
                    parentConcept: page.parentConcept,
                    hasImage: page.includeImage && page.candidate.jpeg != nil)
    }

    private func baseMessages(for page: ConceptPage) -> [ChatMessage] {
        let learner = learner()
        switch page.kind {
        case .concept:
            let input = input(for: page)
            return [ChatMessage(.system, PromptBuilder.system(language: settings.language)),
                    ChatMessage(.user, PromptBuilder.user(input, learner: learner),
                                imageJPEG: input.hasImage ? page.candidate.jpeg : nil)]
        case .primer:
            return [ChatMessage(.system, PromptBuilder.primerSystem(language: settings.language)),
                    ChatMessage(.user, PromptBuilder.primerUser(page: page.pageText, application: page.candidate.appName,
                                                                windowTitle: page.candidate.windowTitle, learner: learner))]
        }
    }

    private func explain(_ page: ConceptPage) {
        page.resetAnswer()
        page.needsConfirmation = false
        let request: ChatRequest
        do { request = try AIClient.request(settings, messages: baseMessages(for: page)) } catch {
            page.fail(ChatError.describe(error))
            return
        }
        page.sent = describeSent(page)
        page.loading = true
        page.task = Task { [weak self, weak page] in
            do {
                for try await event in AIClient.shared.stream(request) {
                    guard let page, !Task.isCancelled else { return }
                    switch event {
                    case .content(let delta):
                        page.append(delta)
                        self?.resolveRecall(page)
                    case .reasoning: page.thinking = true
                    case .done, .failed: break
                    }
                }
                guard let page, !Task.isCancelled else { return }
                page.complete()
                self?.remember(page)
            } catch {
                guard let page, !Task.isCancelled else { return }
                page.fail(ChatError.describe(error))
            }
        }
    }

    private func followUp(_ page: ConceptPage, label: String, prompt: String) {
        guard page.finished, !page.loading, !page.followUpLoading else { return }
        interact()
        var messages = baseMessages(for: page)
        messages.append(ChatMessage(.assistant, page.text))
        for turn in page.followUps where !turn.answer.isEmpty {
            messages.append(ChatMessage(.user, turn.prompt))
            messages.append(ChatMessage(.assistant, turn.answer))
        }
        messages.append(ChatMessage(.user, prompt))
        let turn = FollowUpTurn(question: label, prompt: prompt)
        page.followsLatest = true
        page.followUps.append(turn)
        let request: ChatRequest
        do { request = try AIClient.request(settings, messages: messages) } catch {
            turn.error = ChatError.describe(error)
            turn.loading = false
            return
        }
        page.followUpLoading = true
        turn.task = Task { [weak turn, weak page] in
            defer {
                turn?.loading = false
                page?.followUpLoading = false
            }
            do {
                for try await event in AIClient.shared.stream(request) {
                    guard let turn, !Task.isCancelled else { return }
                    switch event {
                    case .content(let delta):
                        turn.answer += delta
                        turn.thinking = false
                    case .reasoning: turn.thinking = true
                    case .done, .failed: break
                    }
                }
            } catch {
                guard let turn, !Task.isCancelled else { return }
                turn.error = ChatError.describe(error)
            }
        }
    }

    /// Opens a prerequisite or related concept in the same card, explained in the light of the
    /// concept (or page) it came from. Only text already sent for the parent is reused.
    private func drill(from page: ConceptPage, term: String) {
        guard let card else { return }
        interact()
        var nearby = page.includeContext ? page.candidate.nearbyText : ""
        let parent: String
        switch page.kind {
        case .concept:
            parent = "\(page.conceptName)：\(page.card.oneLiner ?? "")"
        case .primer:
            parent = "页面主旨：\(page.primer.gist ?? page.candidate.windowTitle)"
            // "Attention（注意力）" appears on the page as "Attention".
            let bare = term.replacingOccurrences(of: #"\s*[（(][^（）()]*[）)]\s*$"#, with: "", options: .regularExpression)
            nearby = ContextWindow.around(term, in: page.pageText) ?? ContextWindow.around(bare, in: page.pageText)
                ?? String(page.pageText.prefix(1_200))
        }
        let candidate = Candidate(point: page.candidate.point, pid: page.candidate.pid, bundleID: page.candidate.bundleID,
                                  appName: page.candidate.appName, windowTitle: page.candidate.windowTitle,
                                  text: term, nearbyText: nearby, source: .concept, jpeg: nil,
                                  windowFrame: page.candidate.windowFrame)
        let child = ConceptPage(candidate: candidate, parentConcept: parent)
        child.includeContext = page.includeContext || page.kind == .primer
        child.recall = settings.memoryEnabled ? knowledge.entry(for: term) : nil
        card.push(child)
        explain(child)
    }

    private func describeSent(_ page: ConceptPage) -> String {
        var lines: [String] = []
        let learner = learner()
        switch page.kind {
        case .concept:
            let input = input(for: page)
            lines.append("目标：\(input.text)")
            if !input.application.isEmpty { lines.append("应用：\(input.application)") }
            if !input.windowTitle.isEmpty { lines.append("窗口：\(input.windowTitle)") }
            if !input.nearbyText.isEmpty { lines.append("附近原文：\(input.nearbyText)") }
            if !input.pageContext.isEmpty { lines.append("网页正文：已附加 \(input.pageContext.count) 字") }
            if input.hasImage { lines.append("图片：已附加局部截图") }
            if !input.parentConcept.isEmpty { lines.append("上一个概念：\(input.parentConcept)") }
        case .primer:
            lines.append("应用：\(page.candidate.appName)")
            if !page.candidate.windowTitle.isEmpty { lines.append("窗口：\(page.candidate.windowTitle)") }
            lines.append("窗口可见文字：\(page.pageText.count) 字")
        }
        if !learner.background.isEmpty { lines.append("你的背景：\(learner.background)") }
        if !learner.knownConcepts.isEmpty { lines.append("已掌握的概念：\(learner.knownConcepts.joined(separator: "、"))") }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: ContextWindow.openMark, with: "「")
            .replacingOccurrences(of: ContextWindow.closeMark, with: "」")
    }

    // MARK: - Memory

    private func resolveRecall(_ page: ConceptPage) {
        guard !page.recallResolved, page.kind == .concept, page.card.oneLiner != nil, let concept = page.card.concept else { return }
        page.recallResolved = true
        guard settings.memoryEnabled, page.recall == nil, let entry = knowledge.entry(for: concept) else { return }
        page.recall = entry
    }

    /// Every finished lookup of a concept joins the review queue; a selected sentence or paragraph
    /// is not a concept to review.
    private func remember(_ page: ConceptPage) {
        guard settings.memoryEnabled, page.kind == .concept, let summary = page.card.oneLiner,
              TextTarget.isConceptLike(page.target), TextTarget.isConceptLike(page.conceptName) else { return }
        knowledge.record(term: page.conceptName, summary: summary, source: page.candidate.appName)
    }

    // MARK: - Knowledge preloading

    /// Reads the visible text of a window (accessibility first, local OCR as a fallback) and asks
    /// for the prerequisites a reader needs, in dependency order.
    func startPrimer(at point: CGPoint?) {
        guard Permissions.accessibility else {
            overlay.toast("Askme 还没有辅助功能权限。请在菜单栏 Askme → 设置与权限中授权。", near: point ?? NSEvent.mouseLocation)
            return
        }
        let location = point ?? NSEvent.mouseLocation
        closeCard()
        let placeholder = Candidate(point: location, pid: 0, bundleID: "", appName: "当前窗口", windowTitle: "",
                                    text: "", nearbyText: "", source: .window, jpeg: nil)
        let waiting = ConceptPage(kind: .primer, candidate: placeholder)
        waiting.preparing = true
        let model = makeCard(mode: .pinned)
        model.push(waiting)
        card = model
        overlay.showCard(model, near: location)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartz = point.map { ScreenGeometry.quartzPoint(fromAppKit: $0, primaryHeight: primaryHeight) }
        Task { [weak self, weak model] in
            guard let self else { return }
            let snapshot = await self.reader.windowText(at: quartz, excluding: self.settings.exclusions, enhanceWeb: self.settings.enhanceWeb)
            guard let model, self.card === model else { return }
            guard let snapshot, let app = NSRunningApplication(processIdentifier: snapshot.pid),
                  let bundleID = app.bundleIdentifier, !self.settings.excludes(bundleID) else {
                waiting.fail("没有读到这个窗口的文字。请确认已授予辅助功能权限，且窗口不在排除名单里。")
                return
            }
            var text = snapshot.text
            if text.count < 200, self.settings.ocrEnabled, Permissions.screenRecording,
               let recognized = try? await self.screenReader.readWindow(pid: snapshot.pid, frame: snapshot.windowFrame),
               recognized.count > text.count {
                text = recognized
            }
            guard self.card === model else { return }
            let candidate = Candidate(point: location, pid: snapshot.pid, bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                      windowTitle: snapshot.windowTitle, text: "", nearbyText: "", source: .window, jpeg: nil,
                                      windowFrame: snapshot.windowFrame)
            let page = ConceptPage(kind: .primer, candidate: candidate)
            page.pageText = text
            model.replaceTop(with: page)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
                page.fail(self.settings.ocrEnabled
                          ? "这个窗口里可读的文字太少，没法预装载。"
                          : "这个窗口里可读的文字太少。可以在设置里开启 OCR，让 Askme 在本地识别窗口文字。")
                return
            }
            if self.settings.policy(for: bundleID) == .askFirst {
                page.needsConfirmation = true
                page.confirmReason = "「\(candidate.appName)」设为发送前确认：预装载会发送整个窗口的可见文字，请先检查。"
                return
            }
            self.explain(page)
        }
    }

    // MARK: - Chrome page (explicit, optional)

    private func readBrowserPage(_ page: ConceptPage) {
        guard !page.readingBrowserPage, !page.loading, page.candidate.bundleID == "com.google.Chrome" else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == page.candidate.pid else {
            page.error = "请让原 Chrome 窗口保持在前台，再读取当前页。"
            return
        }
        page.readingBrowserPage = true
        page.error = ""
        browserTask = Task { [weak self, weak page] in
            guard let self, let page else { return }
            defer { page.readingBrowserPage = false }
            do {
                let result = try await self.browser.read(expectedTitle: page.candidate.windowTitle)
                guard !Task.isCancelled else { return }
                page.browserPage = result
                page.includeBrowserPage = true
            } catch {
                guard !Task.isCancelled else { return }
                page.error = error.localizedDescription
            }
        }
    }

    // MARK: - Smoke test support

    /// Shows a card for synthetic data without capturing, sending or storing anything.
    func showSynthetic(_ candidate: Candidate, mode: CardModel.Mode, kind: ConceptPage.Kind = .concept) -> (CardModel, ConceptPage)? {
        closeCard()
        let page = ConceptPage(kind: kind, candidate: candidate)
        let model = makeCard(mode: mode)
        model.push(page)
        card = model
        overlay.showCard(model, near: candidate.point)
        return (model, page)
    }

    func toggleDockForTesting() { card?.onToggleDock?() }
}
