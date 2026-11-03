import AppKit
import SwiftUI
import AskmeCore

/// Card colors. Saturated accent-colored text glares on dark translucent panels and blurs at small
/// sizes, so text stays neutral; interactivity is carried by shape, a soft tint and hover states.
enum Palette {
    /// The user's accent color, calmed for the current appearance: lighter on dark, deeper on light.
    static let tint = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? accent.blended(withFraction: 0.3, of: .white) : accent.blended(withFraction: 0.12, of: .black)) ?? accent
    })
}

struct CardView: View {
    @ObservedObject var model: CardModel

    var body: some View {
        Group {
            if let page = model.current {
                CardContent(model: model, page: page).id(page.id)
            }
        }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CardContent: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage
    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var lastTurnHeight: CGFloat = 0
    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(model: model, page: page)
                .background(HeightReader { headerHeight = $0; report() })
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        PageBody(model: model, page: page) { height in
                            lastTurnHeight = height
                            follow(proxy)
                        }
                            .padding(.horizontal, 16)
                            .padding(.top, 13)
                            .padding(.bottom, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .background(HeightReader { height in
                        bodyHeight = height
                        report()
                        follow(proxy)
                    })
                }
                .background(HeightReader { viewportHeight = $0 })
                .onChange(of: page.followUps.count) { _, _ in follow(proxy) }
            }
            CardFooter(model: model, page: page)
                .background(HeightReader { footerHeight = $0; report() })
        }
        .onChange(of: settled) { _, _ in report() }
    }

    private var settled: Bool { !(page.loading || page.preparing || page.followUpLoading) }

    private func report() {
        // A page being replaced (drill-down, back) can still measure while it is torn down.
        guard model.current === page, headerHeight > 0 else { return }
        model.onHeight?(headerHeight + bodyHeight + footerHeight + 1, settled)
    }

    /// Keeps a streaming follow-up answer in view: follow the bottom while the whole turn fits,
    /// then park its question at the top so the answer can be read from its start. Scrolling the
    /// card by hand turns this off until the next follow-up.
    private func follow(_ proxy: ScrollViewProxy) {
        guard page.followsLatest, let turn = page.followUps.last else { return }
        if viewportHeight == 0 || lastTurnHeight < viewportHeight - 16 {
            proxy.scrollTo(Self.bottom, anchor: .bottom)
        } else {
            proxy.scrollTo(turn.id, anchor: .top)
            page.followsLatest = false
        }
    }
}

private struct CardHeader: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if model.stack.count > 1 {
                IconButton(symbol: "chevron.left", help: "返回上一个概念") { model.onBack?() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if model.mode != .peek {
                IconButton(symbol: model.mode.isPersistent ? "pin.fill" : "pin", active: model.mode.isPersistent,
                           help: model.mode.isPersistent ? "取消钉住" : "钉住：点击别处也不关闭，后续查询会加入这张卡") { model.onTogglePin?() }
                IconButton(symbol: model.mode == .docked ? "macwindow" : "sidebar.right", active: model.mode == .docked,
                           help: model.mode == .docked ? "取消停靠" : "停靠到屏幕右侧，边读边查") { model.onToggleDock?() }
                IconButton(symbol: "xmark", help: "关闭（Esc）") { model.onClose?() }
            }
        }
        .padding(.leading, model.stack.count > 1 ? 8 : 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(WindowDragArea { model.onDragged?() })
    }

    /// Where the text came from. Plain pointing is the default and needs no label; a selection,
    /// OCR or an image is worth knowing because it changes how far the text can be trusted.
    private var subtitle: String {
        if model.stack.count > 1 { return model.breadcrumb }
        let app = page.candidate.appName
        switch page.candidate.source {
        case .selection, .ocr, .image:
            return app.isEmpty ? page.candidate.source.rawValue : "\(app) · \(page.candidate.source.rawValue)"
        case .accessibility, .window, .concept:
            return app
        }
    }
}

private struct PageBody: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage
    /// Height of the newest follow-up turn. A callback rather than a preference: preferences set
    /// inside a macOS ScrollView do not reach views outside it.
    var onLastTurnHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if page.needsConfirmation {
                ConfirmView(model: model, page: page)
            } else if page.kind == .primer {
                PrimerBody(model: model, page: page)
            } else {
                ConceptBody(model: model, page: page)
            }
            ForEach(page.followUps) { turn in
                FollowUpView(turn: turn)
                    .id(turn.id)
                    .background(HeightReader { height in
                        if turn === page.followUps.last { onLastTurnHeight(height) }
                    })
            }
            if !page.error.isEmpty {
                Callout(kind: .error, text: page.error,
                        actionTitle: page.needsConfirmation || page.preparing ? nil : "重试") { model.onRetry?(page) }
            }
            if page.showsSent, !page.sent.isEmpty {
                SentBox(destination: model.destination, sent: page.sent) { page.showsSent = false }
            }
        }
    }
}

private struct ConceptBody: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        if let recall = page.recall { RecallRow(entry: recall) }
        if let oneLiner = page.card.oneLiner {
            RichText(oneLiner)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let free = page.card.freeform {
            MarkdownView(text: free)
        } else if page.loading {
            ShimmerText(text: page.thinking ? "正在思考…" : "正在装载…")
        }
        if page.card.confidence == .low {
            Callout(kind: .caution, text: "模型对它把握不大，可能是专有名词或内部术语。", actionTitle: "搜索") { model.onSearch?(page) }
        }
        SectionRow(section: .inContext, text: page.card[.inContext])
        SectionRow(section: .analogy, text: page.card[.analogy])
        let deeper = [CardSection.keyPoints, .example, .pitfall].filter { page.card[$0] != nil }
        if !deeper.isEmpty {
            if page.expanded || model.mode.isPersistent {
                ForEach(deeper, id: \.self) { SectionRow(section: $0, text: page.card[$0]) }
            } else {
                ExpandButton(title: "展开" + deeper.map(\.rawValue).joined(separator: " · ")) {
                    page.expanded = true
                    model.onInteract?()
                }
            }
        }
        ChipRow(title: CardSection.prerequisites.rawValue, items: page.card.prerequisites) { model.onDrill?(page, $0) }
        ChipRow(title: CardSection.related.rawValue, items: page.card.related) { model.onDrill?(page, $0) }
    }
}

private struct PrimerBody: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        if page.preparing { ShimmerText(text: "正在读取当前窗口…") }
        if let gist = page.primer.gist {
            RichText(gist)
                .font(.system(size: 15, weight: .medium))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let free = page.primer.freeform {
            MarkdownView(text: free)
        } else if page.loading {
            ShimmerText(text: page.thinking ? "正在思考…" : "正在找出读懂这页需要的前置知识…")
        }
        if !page.primer.items.isEmpty {
            Text("读懂这页，先装载这些").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(page.primer.items.enumerated()), id: \.element.id) { index, item in
                    PrimerRow(index: index + 1, item: item) { model.onDrill?(page, item.term) }
                }
            }
            .padding(.horizontal, -8)
        }
        SectionRow(section: .hardest, text: page.primer.hardest)
    }
}

private struct PrimerRow: View {
    let index: Int
    let item: Primer.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.tint)
                    .frame(width: 18, height: 18)
                    .background(Palette.tint.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.term).font(.system(size: 13, weight: .semibold))
                    if !item.summary.isEmpty {
                        RichText(item.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("展开「\(item.term)」")
    }
}

private struct ConfirmView: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Callout(kind: .info, symbol: "hand.raised.fill", text: page.confirmReason)
            if page.kind == .primer {
                Text("将发送当前窗口的可见文字（\(page.pageText.count) 字）").font(.system(size: 12, weight: .medium))
                DisclosureGroup("查看将要发送的文字") {
                    Text(page.pageText).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            } else {
                Text("解释什么？").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $page.target)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 60)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                if let data = page.candidate.jpeg, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Toggle("发送这张局部截图（需要视觉模型）", isOn: $page.includeImage).font(.system(size: 12))
                }
                Toggle("附加应用、窗口标题和附近原文", isOn: $page.includeContext).font(.system(size: 12))
                DisclosureGroup("查看本地上下文 · \(page.candidate.appName)") {
                    Text([page.candidate.windowTitle, page.candidate.nearbyText].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                if page.candidate.bundleID == "com.google.Chrome" { BrowserPageControls(model: model, page: page) }
            }
            HStack {
                Spacer()
                Button(page.kind == .primer ? "发送并预装载" : "解释") { model.onConfirm?(page) }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(page.readingBrowserPage || (page.kind == .concept
                        && page.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !page.includeImage))
            }
        }
    }
}

private struct BrowserPageControls: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        if let browserPage = page.browserPage {
            Toggle("附加已读取的 Chrome 页面", isOn: $page.includeBrowserPage).font(.system(size: 12))
            DisclosureGroup("查看页面内容（最多 10,000 字符）") {
                Text(browserPage.promptContext).font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
        } else {
            Button {
                model.onReadBrowserPage?(page)
            } label: {
                HStack(spacing: 6) {
                    if page.readingBrowserPage { ProgressView().controlSize(.small) }
                    Text(page.readingBrowserPage ? "正在本地读取…" : "读取 Chrome 当前页（可选）")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(page.readingBrowserPage)
            Text("仅此操作请求自动化权限。请保持原标签页不变；读取后可预览，点击解释才发送。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CardFooter: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage
    @State private var question = ""
    @State private var composing = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        if model.mode == .peek {
            if model.showsPeekHint {
                VStack(spacing: 0) {
                    Divider().opacity(0.6)
                    Text("松开 \(model.triggerSymbol) 关闭 · 指针移到卡片上再松开可保留")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        } else if !page.needsConfirmation && !page.preparing {
            VStack(spacing: 0) {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 8) {
                    actions
                    if showsInput { input }
                }
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 11)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            ForEach(FollowUp.allCases, id: \.self) { kind in
                ActionChip(title: kind.rawValue) { model.onFollowUp?(page, kind.rawValue, kind.prompt) }
                    .disabled(!canFollowUp)
            }
            if !showsInput {
                ActionChip(title: "追问", systemImage: "text.bubble") {
                    model.onInteract?()
                    composing = true
                    DispatchQueue.main.async { inputFocused = true }
                }
                .disabled(!canFollowUp)
            }
            Spacer(minLength: 4)
            MoreMenu(model: model, page: page)
        }
    }

    private var input: some View {
        HStack(spacing: 6) {
            TextField("继续追问，回车发送", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($inputFocused)
                .focusEffectDisabled()
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Palette.tint : Color.secondary.opacity(0.35))
            .disabled(!canSend)
            .accessibilityLabel("发送追问")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(inputFocused ? 0.25 : 0.1)))
    }

    private var showsInput: Bool { composing || model.mode.isPersistent }

    private var canFollowUp: Bool { page.finished && !page.loading && !page.followUpLoading }

    private var canSend: Bool { canFollowUp && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onFollowUp?(page, text, text)
        question = ""
    }
}

private struct FollowUpView: View {
    @ObservedObject var turn: FollowUpTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.6)
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                Text(turn.question).lineLimit(2)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer)
            } else if turn.loading {
                ShimmerText(text: turn.thinking ? "正在思考…" : "正在回答…")
            }
            if !turn.error.isEmpty { Callout(kind: .error, text: turn.error) }
        }
    }
}

/// Less frequent actions live behind one quiet button instead of crowding every card.
private struct MoreMenu: View {
    @ObservedObject var model: CardModel
    @ObservedObject var page: ConceptPage

    var body: some View {
        Menu {
            Button("复制卡片内容") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.plainText, forType: .string)
            }
            .disabled(!page.hasAnswer)
            if page.kind == .concept {
                Button("搜索「\(String(page.conceptName.prefix(20)))」") { model.onSearch?(page) }
            }
            Divider()
            Button(page.showsSent ? "收起发送内容" : "查看本次发送内容") { page.showsSent.toggle() }
                .disabled(page.sent.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("复制、搜索、查看发送内容")
        .accessibilityLabel("更多操作")
    }
}

/// What this card sent to the model, opened from the card's menu.
private struct SentBox: View {
    let destination: String
    let sent: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "paperplane").font(.system(size: 10))
                Text("本次发送的内容")
                Spacer(minLength: 4)
                Button("收起", action: close).buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            Text(sent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("发往 \(destination)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecallRow: View {
    let entry: KnowledgeEntry

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
            Text(description)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var description: String {
        let streak = entry.recalled ? " · 复习中已想起 \(entry.stage) 次" : ""
        return "\(RelativeTime.string(entry.lastSeen))查过 · 这是第 \(entry.lookups + 1) 次\(streak)"
    }
}

private struct SectionRow: View {
    let section: CardSection
    let text: String?

    var body: some View {
        if let text {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(title: section.rawValue)
                MarkdownView(text: text)
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .leading)
    }
}

private struct ChipRow: View {
    let title: String
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(title: title)
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        ConceptChip(title: item) { action(item) }
                    }
                }
            }
        }
    }
}

/// A concept you can open: neutral text on a soft tinted capsule.
private struct ConceptChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Palette.tint.opacity(hovering ? 0.24 : 0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.tint.opacity(hovering ? 0.4 : 0.22), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("展开「\(title)」")
    }
}

/// A follow-up on the current concept: a neutral capsule.
private struct ActionChip: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(hovering && isEnabled ? 0.11 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

private struct ExpandButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct IconButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(active ? Palette.tint : (hovering && isEnabled ? Color.primary : Color.secondary))
                .background(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Short, tinted notes: low confidence, errors, confirmations and offers. Text stays neutral.
private struct Callout: View {
    enum Kind { case caution, error, info }

    let kind: Kind
    var symbol: String?
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol ?? defaultSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var defaultSymbol: String {
        switch kind {
        case .caution: return "questionmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .caution: return .orange
        case .error: return .red
        case .info: return Palette.tint
        }
    }
}

/// The "thinking" label AI tools use: a highlight sweeps across the glyphs, then rests briefly.
/// Driven by the clock rather than a repeating animation, which would also loop any resize that
/// happens in the same transaction.
private struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycle = 1.9
    private static let sweep = 1.35
    private static let band = 0.32

    var body: some View {
        if reduceMotion {
            label.foregroundStyle(.secondary)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                label.foregroundStyle(highlight(at: context.date))
            }
        }
    }

    private var label: Text { Text(text).font(.system(size: 13)) }

    private func highlight(at date: Date) -> LinearGradient {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
        let progress = min(elapsed / Self.sweep, 1)
        // The band travels from fully left of the text to fully right of it.
        let center = -Self.band + progress * (1 + 2 * Self.band)
        return LinearGradient(colors: [Color.primary.opacity(0.38), Color.primary.opacity(0.95), Color.primary.opacity(0.38)],
                              startPoint: UnitPoint(x: center - Self.band, y: 0.5),
                              endPoint: UnitPoint(x: center + Self.band, y: 0.5))
    }
}

/// The card is a non-activating panel that is rarely the key window, where the system draws
/// prominent buttons in their inactive grey. Keep the primary action visibly primary.
private struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Inline Markdown (bold, emphasis, code) with links stripped: model output never becomes a
/// clickable URL, and the ⟦ ⟧ position marks are never shown back to the user.
struct RichText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View { Text(Self.attributed(text)) }

    static func attributed(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(of: ContextWindow.openMark, with: "")
            .replacingOccurrences(of: ContextWindow.closeMark, with: "")
        var value = (try? AttributedString(markdown: cleaned, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(cleaned)
        let links = value.runs.filter { $0.link != nil }.map(\.range)
        for range in links { value[range].link = nil }
        return value
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownLite.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value):
                    RichText(value)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        RichText(value)
                    }
                case .numbered(let number, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                        RichText(value)
                    }
                case .heading(let value):
                    RichText(value).fontWeight(.semibold)
                case .quote(let value):
                    RichText(value)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2) }
                case .code(let value):
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2.5)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

struct HeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in onChange(height) }
        }
    }
}

/// Lets the borderless card be dragged by its header; a drag means the user placed it on purpose.
struct WindowDragArea: NSViewRepresentable {
    let onDragged: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDragged = onDragged
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDragged = onDragged }

    final class DragView: NSView {
        var onDragged: (() -> Void)?
        private var start: (mouse: NSPoint, origin: NSPoint)?
        private var moved = false

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.origin)
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start else { return }
            let point = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: start.origin.x + point.x - start.mouse.x,
                                          y: start.origin.y + point.y - start.mouse.y))
            moved = true
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onDragged?() }
            start = nil
            moved = false
        }
    }
}
