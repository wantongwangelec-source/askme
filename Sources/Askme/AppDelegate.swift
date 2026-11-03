import AppKit
import SwiftUI
import Combine
import AskmeCore

@main
struct AskmeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
    private let settings = Settings()
    private let knowledge = KnowledgeStore(persistent: !AppDelegate.isSmokeTest)
    private let overlay = Overlay()
    private var controller: LookupController!
    private var monitor: InputMonitor!
    private var statusItem: NSStatusItem!
    private var settingsController: SettingsController!
    private var knowledgeController: KnowledgeWindowController!
    private var subscriptions = Set<AnyCancellable>()
    private var menuOpen = false
    private var sessionObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        knowledgeController = KnowledgeWindowController(store: knowledge, settings: settings)
        settingsController = SettingsController(settings: settings, knowledge: knowledge) { [weak self] in
            self?.knowledgeController.show()
        }
        controller = LookupController(settings: settings, knowledge: knowledge, overlay: overlay)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = BrandIcon.menuBarImage()
        statusItem.button?.toolTip = "Askme · 指哪懂哪"
        rebuildMenu()
        installEditingMenu()

        monitor = InputMonitor(settings: settings)
        monitor.onTrigger = { [weak self] in self?.controller.handle($0) }
        monitor.onHoverDwell = { [weak self] in self?.controller.hoverDwell(at: $0) }
        monitor.onHoverInvalidate = { [weak self] in self?.controller.hoverInvalidated() }
        monitor.onEscape = { [weak self] in self?.controller.escape() }
        monitor.onOutside = { [weak self] in self?.controller.outside($0) }
        monitor.onOverlayScroll = { [weak self] in self?.controller.cardScrolled() }
        monitor.onContextChange = { [weak self] in self?.controller.contextChanged() }
        monitor.isOnOverlay = { [weak self] point in self?.overlay.contains(point) ?? false }
        monitor.isHoverSuspended = { [weak self] in
            guard let self else { return true }
            return self.menuOpen || self.controller.hasCard || self.settingsController.isVisible || self.knowledgeController.isVisible
        }
        if Self.isSmokeTest {
            runSmokeTest()
            return
        }
        monitor.start()
        settings.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.settings.enabled {
                    self.monitor.reset()
                    self.controller.closeCard()
                }
                self.rebuildMenu()
            }
            .store(in: &subscriptions)
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.controller.closeCard() } }
        // No main window or automatic permission dialogs. All setup lives in the menu bar.
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        controller.closeCard()
        if let sessionObserver { NSWorkspace.shared.notificationCenter.removeObserver(sessionObserver) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        monitor.reset()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: Permissions.accessibility ? "Askme · 本地识别，主动触发才发送" : "Askme · 请先授予辅助功能权限",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let hint = NSMenuItem(title: settings.triggerHint, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        addItem(settings.enabled ? "暂停 Askme" : "恢复 Askme", action: #selector(toggleEnabled), to: menu)
        addItem("预装载当前窗口（⇧ + 轻点 \(settings.triggerKey.symbol)）", action: #selector(preloadFrontWindow), to: menu)
        let due = knowledge.dueCount
        addItem(due > 0 ? "知识库与复习…（\(due) 个待复习）" : "知识库与复习…", action: #selector(openKnowledge), to: menu)
        addItem("设置与权限…", action: #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        addItem("退出 Askme", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !settings.enabled
    }

    private func installEditingMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Askme")
        addItem("退出 Askme", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                    ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func preloadFrontWindow() { controller.startPrimer(at: nil) }
    @objc private func openKnowledge() { controller.closeCard(); knowledgeController.show() }
    @objc private func openSettings() { controller.closeCard(); monitor.reset(); settingsController.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Smoke test

    /// Synthetic UI probe: no global listeners, AX reads, screen capture, Keychain reads or stored
    /// history. With ASKME_SMOKE_ENDPOINT set to a local mock server, it also streams one real
    /// request (without a key) through the same client and card the app uses.
    private func runSmokeTest() {
        switch ProcessInfo.processInfo.environment["ASKME_SMOKE_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        precondition(NSApp.activationPolicy() == .accessory, "Unexpected activation policy")
        precondition(statusItem.button?.image?.isTemplate == true, "Menu icon must adapt to system appearance")
        precondition(Bundle.main.url(forResource: "Askme", withExtension: "icns") != nil, "Missing app icon")
        precondition(NSApp.windows.allSatisfy { !$0.isVisible || !$0.styleMask.contains(.titled) }, "Unexpected launch window")
        let point = NSScreen.main.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY + 120) } ?? .zero
        let candidate = Candidate(point: point, pid: getpid(), bundleID: "local.askme.test", appName: "Synthetic test",
                                  windowTitle: "Test window", text: "KV Cache",
                                  nearbyText: "长上下文推理时，⟦KV Cache⟧ 会随序列长度线性增长。", source: .accessibility, jpeg: nil)
        overlay.showHint(candidate: candidate) {}
        precondition(overlay.contains(point), "Hint approach region unavailable")
        overlay.closeHint()
        print("SMOKE: hover hint initialized")

        guard let (card, page) = controller.showSynthetic(candidate, mode: .transient) else { preconditionFailure("Card unavailable") }
        let answer = """
        【概念】KV Cache（键值缓存）
        【一句话】模型逐字生成时，把算过的注意力中间结果缓存下来，下一个字只算新增部分。
        【在这里】文中说的"随序列长度线性增长"，就是这份缓存越来越占显存。
        【类比】像前端的增量渲染：已经渲染过的部分不重算；不同的是缓存会一直变大。
        【要点】
        - 每个新 token 只计算自己的 K 和 V
        - 缓存大小与层数、序列长度成正比
        【例子】生成第 1000 个字时，前 999 个字的 K/V 直接复用。
        【前置】Attention｜Token
        【相关】PagedAttention｜Prefill 与 Decode
        【把握】高
        """
        var cursor = answer.startIndex
        while cursor < answer.endIndex {
            let next = answer.index(cursor, offsetBy: 7, limitedBy: answer.endIndex) ?? answer.endIndex
            page.append(String(answer[cursor..<next]))
            cursor = next
        }
        page.complete()
        precondition(page.card.concept == "KV Cache（键值缓存）", "Concept not parsed")
        precondition(page.card.prerequisites == ["Attention", "Token"], "Prerequisites not parsed")
        precondition(overlay.isCardVisible, "Card panel unavailable")
        print("SMOKE: concept card streamed and parsed")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            let height = overlay.cardFrame?.height ?? 0
            precondition(height > 200, "Card did not grow with its content (\(height))")
            print("SMOKE: card sized to content (\(Int(height)) pt)")
            controller.toggleDockForTesting()
            precondition(card.mode == .docked && (overlay.cardFrame?.height ?? 0) > 300, "Docking failed")
            print("SMOKE: docked")
            controller.closeCard()
            knowledgeController.show()
            precondition(knowledgeController.isVisible, "Knowledge window unavailable")
            print("SMOKE: knowledge window initialized")
            settingsController.show()
            precondition(settingsController.isVisible, "Settings unavailable")
            print("SMOKE: settings initialized")
            snapshots(answer: answer) { [self] in
                streamProbe {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        print("SMOKE: done; exiting without capture or stored history")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// With ASKME_SMOKE_SNAPSHOT_DIR set, renders the main card states to PNG files for review.
    private func snapshots(answer: String, then finish: @escaping () -> Void) {
        guard let directory = ProcessInfo.processInfo.environment["ASKME_SMOKE_SNAPSHOT_DIR"] else {
            finish()
            return
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The smoke-test store is in memory only.
        for (term, summary, recalls) in [("KV Cache（键值缓存）", "把算过的注意力中间结果缓存下来，下一个字只算新增部分。", 2),
                                         ("灰度放量", "先让一小部分用户用上新版本，观察没问题再逐步扩大。", 0),
                                         ("Attention（注意力）", "让每个词按相关性参考其他词。", 4)] {
            guard let entry = knowledge.record(term: term, summary: summary, source: "Google Chrome") else { continue }
            for _ in 0..<recalls { knowledge.review(entry.key, remembered: true) }
        }
        let point = NSScreen.main.map { CGPoint(x: $0.visibleFrame.midX - 200, y: $0.visibleFrame.maxY - 80) } ?? .zero
        let candidate = Candidate(point: point, pid: getpid(), bundleID: "com.google.Chrome", appName: "Google Chrome",
                                  windowTitle: "LLM 推理优化笔记", text: "KV Cache",
                                  nearbyText: "长上下文推理时，⟦KV Cache⟧ 会随序列长度线性增长，占满显存。", source: .accessibility, jpeg: nil)
        let primerText = """
        【主旨】这页讲大模型推理时如何用缓存和分页节省显存。
        【前置】
        1. Token：模型处理文字的最小单位
        2. Attention（注意力）：让每个词按相关性参考其他词
        3. KV Cache（键值缓存）：复用已经算过的中间结果
        4. PagedAttention：像操作系统分页一样管理缓存
        【难点】为什么缓存会随长度线性增长，以及分页如何减少碎片。
        """
        let steps: [(String, Overlay.Snapshot, () -> Void)] = [
            ("peek", .card, { [self] in
                guard let (model, page) = controller.showSynthetic(candidate, mode: .peek) else { return }
                model.showsPeekHint = true
                page.loading = true
                page.append(String(answer.prefix(90)))
            }),
            ("loading", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .transient) else { return }
                page.loading = true
            }),
            ("card", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .transient) else { return }
                page.append(answer)
                page.complete()
                page.sent = "目标：KV Cache\n应用：Google Chrome"
            }),
            ("pinned", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .pinned) else { return }
                page.recall = knowledge.entry(for: "KV Cache")
                page.append(answer)
                page.complete()
                page.sent = "目标：KV Cache\n应用：Google Chrome\n附近原文：长上下文推理时，「KV Cache」会随序列长度线性增长，占满显存。"
                page.showsSent = true
                let turn = FollowUpTurn(question: "更通俗", prompt: "")
                turn.answer = "想象你在抄写一本书：每写一个新字，都要回头看前面写过的内容。KV Cache 就是**把前面每页的要点记在便签上**，不用每次都重读整本书。"
                turn.loading = false
                page.followUps.append(turn)
            }),
            ("followup", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .pinned) else { return }
                page.append(answer)
                page.complete()
                stream("比如生成「今天天气很好」时，写到「好」字只需要算「好」自己的 K 和 V，前面五个字的结果直接从缓存里取。",
                       question: "举个例子", into: page)
            }),
            ("followup-long", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .pinned) else { return }
                page.append(answer)
                page.complete()
                stream((1...30).map { "\($0). 第 \($0) 层的 K/V 各占一份显存，随序列长度线性增长。" }.joined(separator: "\n"),
                       question: "更深入", into: page)
            }),
            ("drill", .card, { [self] in
                guard let (model, page) = controller.showSynthetic(candidate, mode: .pinned) else { return }
                page.append(answer)
                page.complete()
                let child = ConceptPage(candidate: Candidate(point: point, pid: getpid(), bundleID: "com.google.Chrome",
                                                             appName: "Google Chrome", windowTitle: "LLM 推理优化笔记", text: "Attention",
                                                             nearbyText: "", source: .concept, jpeg: nil),
                                        parentConcept: "KV Cache（键值缓存）")
                child.append("【概念】Attention（注意力机制）\n【一句话】让每个词按相关性，从其他词那里取信息。\n【在这里】KV Cache 缓存的正是注意力计算里每个词的 K 和 V。\n【前置】向量｜点积\n")
                child.complete()
                model.push(child)
            }),
            ("lowconf", .card, { [self] in
                let codename = Candidate(point: point, pid: getpid(), bundleID: "com.apple.Notes", appName: "备忘录", windowTitle: "周会记录",
                                         text: "Nebula", nearbyText: "下周把 ⟦Nebula⟧ 的灰度比例提到 20%。", source: .accessibility, jpeg: nil)
                guard let (_, page) = controller.showSynthetic(codename, mode: .transient) else { return }
                page.append("【概念】Nebula\n【一句话】看起来是团队内部的项目代号，我没有可靠资料，以下仅供参考。\n【在这里】这里指一个正在灰度发布的项目，20% 是放量比例。\n【把握】低\n")
                page.complete()
            }),
            ("sent", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .transient) else { return }
                page.append("【概念】KV Cache（键值缓存）\n【一句话】模型逐字生成时，把算过的注意力中间结果缓存下来。\n")
                page.complete()
                page.sent = "目标：KV Cache\n应用：Google Chrome\n附近原文：长上下文推理时，「KV Cache」会随序列长度线性增长，占满显存。"
                page.showsSent = true
            }),
            ("error", .card, { [self] in
                guard let (_, page) = controller.showSynthetic(candidate, mode: .transient) else { return }
                page.fail("请求太频繁或额度不足（HTTP 429），稍后再试。")
            }),
            ("hint", .hint, { [self] in
                controller.closeCard()
                overlay.showHint(candidate: candidate) {}
            }),
            ("toast", .toast, { [self] in
                overlay.closeHint()
                overlay.toast("这里没有读到文字。可以先选中文字再按 ⌃，或在设置里开启 OCR。", near: point)
            }),
            ("confirm", .card, { [self] in
                let chat = Candidate(point: point, pid: getpid(), bundleID: "com.tencent.xinWeChat", appName: "微信", windowTitle: "项目群",
                                     text: "灰度放量", nearbyText: "明天先⟦灰度放量⟧ 5%，观察指标再全量。", source: .selection, jpeg: nil)
                guard let (_, page) = controller.showSynthetic(chat, mode: .transient) else { return }
                page.needsConfirmation = true
                page.confirmReason = "「微信」设为发送前确认：这里常有他人的私人信息，你看过之后才会发送。"
            }),
            ("primer", .card, { [self] in
                let window = Candidate(point: point, pid: getpid(), bundleID: "com.google.Chrome", appName: "Google Chrome",
                                       windowTitle: "vLLM: Easy, Fast, and Cheap LLM Serving", text: "", nearbyText: "",
                                       source: .window, jpeg: nil)
                guard let (_, page) = controller.showSynthetic(window, mode: .pinned, kind: .primer) else { return }
                page.append(primerText)
                page.complete()
            })
        ]
        /// Streams a follow-up the way LookupController does, in small timed chunks.
        func stream(_ reply: String, question: String, into page: ConceptPage) {
            let turn = FollowUpTurn(question: question, prompt: "")
            page.followsLatest = true
            page.followUpLoading = true
            page.followUps.append(turn)
            let characters = Array(reply)
            let chunks = stride(from: 0, to: characters.count, by: 24).map { String(characters[$0..<min($0 + 24, characters.count)]) }
            for (index, chunk) in chunks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + 0.015 * Double(index)) {
                    turn.answer += chunk
                    if index == chunks.count - 1 {
                        turn.loading = false
                        page.followUpLoading = false
                    }
                }
            }
        }
        func capture(window title: String, as name: String) {
            // The frame view draws the window background that the content view leaves transparent.
            guard let content = NSApp.windows.first(where: { $0.title == title })?.contentView,
                  let view = content.superview ?? Optional(content),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathComponent("\(name).png"))
        }
        func windows() {
            controller.closeCard()
            capture(window: "Askme 设置", as: "settings")
            knowledgeController.show(tab: .all)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                capture(window: "Askme 知识库", as: "knowledge-all")
                knowledgeController.show(tab: .review)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    capture(window: "Askme 知识库", as: "knowledge-review")
                    print("SMOKE: snapshots written to \(base.path)")
                    finish()
                }
            }
        }
        /// A few frames of the loading label, to see the highlight travel across it.
        func shimmerFrames(_ frame: Int = 0) {
            if frame == 0, let (_, page) = controller.showSynthetic(candidate, mode: .transient) { page.loading = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + (frame == 0 ? 0.4 : 0.18)) { [self] in
                try? overlay.snapshot(.card)?.write(to: base.appendingPathComponent("shimmer-\(frame).png"))
                if frame < 5 { shimmerFrames(frame + 1) } else { windows() }
            }
        }
        func run(_ index: Int) {
            guard index < steps.count else {
                shimmerFrames()
                return
            }
            steps[index].2()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                if let data = overlay.snapshot(steps[index].1) {
                    try? data.write(to: base.appendingPathComponent("\(steps[index].0).png"))
                }
                run(index + 1)
            }
        }
        run(0)
    }

    private func streamProbe(then finish: @escaping () -> Void) {
        guard let value = ProcessInfo.processInfo.environment["ASKME_SMOKE_ENDPOINT"],
              let url = try? Endpoint.validate(value), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") else {
            finish()
            return
        }
        let candidate = Candidate(point: NSEvent.mouseLocation, pid: getpid(), bundleID: "local.askme.test", appName: "Synthetic test",
                                  windowTitle: "Stream probe", text: "Transformer",
                                  nearbyText: "⟦Transformer⟧ 取代了 RNN。", source: .accessibility, jpeg: nil)
        guard let (_, page) = controller.showSynthetic(candidate, mode: .pinned) else { preconditionFailure("Card unavailable") }
        let input = PromptInput(text: candidate.text, application: candidate.appName, windowTitle: candidate.windowTitle,
                                nearbyText: candidate.nearbyText)
        let request = ChatRequest(endpoint: url, model: "mock", key: "", messages: [
            ChatMessage(.system, PromptBuilder.system), ChatMessage(.user, PromptBuilder.user(input))
        ])
        let started = Date()
        var firstToken: TimeInterval?
        page.loading = true
        page.task = Task {
            do {
                for try await event in AIClient.shared.stream(request) {
                    if case .content(let delta) = event {
                        if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                        page.append(delta)
                    }
                }
                page.complete()
                precondition(page.card.oneLiner?.isEmpty == false, "Streamed card has no one-liner")
                print(String(format: "SMOKE: streamed from %@ · first token %.0f ms · total %.0f ms · one-liner: %@",
                             url.absoluteString, (firstToken ?? 0) * 1000, Date().timeIntervalSince(started) * 1000,
                             page.card.oneLiner ?? ""))
            } catch {
                preconditionFailure("Stream probe failed: \(ChatError.describe(error))")
            }
            finish()
        }
    }
}
