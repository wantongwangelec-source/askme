import AppKit
import SwiftUI
import AskmeCore

enum RelativeTime {
    static func string(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

@MainActor
final class KnowledgeWindowController {
    enum Tab: Int { case review, all }

    private let store: KnowledgeStore
    private let settings: Settings
    private let state = KnowledgeViewState()
    private var window: NSWindow?

    init(store: KnowledgeStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens on the review tab when something is due, otherwise on the full list.
    func show(tab: Tab? = nil) {
        state.tab = tab ?? (store.dueCount > 0 ? .review : .all)
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Askme 知识库"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: KnowledgeView(store: store, settings: settings, state: state))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class KnowledgeViewState: ObservableObject {
    @Published var tab = KnowledgeWindowController.Tab.all
}

private struct KnowledgeView: View {
    @ObservedObject var store: KnowledgeStore
    @ObservedObject var settings: Settings
    @ObservedObject var state: KnowledgeViewState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                Text("复习（\(store.book.due(at: Date()).count)）").tag(KnowledgeWindowController.Tab.review)
                Text("全部概念（\(store.book.entries.count)）").tag(KnowledgeWindowController.Tab.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)
            if !settings.memoryEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("本机学习记录未开启：新的查询不会被记住。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("开启") { settings.memoryEnabled = true }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            if state.tab == .review { ReviewPane(store: store) } else { ConceptList(store: store) }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

private struct ReviewPane: View {
    @ObservedObject var store: KnowledgeStore
    @State private var revealed = false

    var body: some View {
        let due = store.book.due(at: Date())
        if let entry = due.first {
            VStack(spacing: 18) {
                Spacer()
                Text("还剩 \(due.count) 个").font(.caption).foregroundStyle(.secondary)
                Text(entry.term).font(.system(size: 26, weight: .semibold)).multilineTextAlignment(.center)
                if revealed {
                    VStack(spacing: 8) {
                        Text(entry.summary.isEmpty ? "（没有记下一句话解释）" : entry.summary)
                            .font(.title3).multilineTextAlignment(.center).textSelection(.enabled)
                        Text("第 \(entry.stage + 1) 轮复习 · 来自 \(entry.source.isEmpty ? "未知应用" : entry.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 32)
                    HStack(spacing: 14) {
                        Button("忘了，明天再来") { answer(entry, remembered: false) }
                        Button("记得") { answer(entry, remembered: true) }
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.large)
                    Button("不用记这个") {
                        store.remove(entry.key)
                        revealed = false
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("从学习记录里删除，不再复习")
                } else {
                    Text("先在心里说出它是什么，再看答案。").foregroundStyle(.secondary)
                    Button("显示答案") { revealed = true }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("现在没有要复习的概念").font(.headline)
                Text("查过的概念会自动加入复习，按 1、3、7、16、35、90 天的间隔回来找你。\n每次想起来，间隔就拉长一档；忘了或又去查了，就从头开始。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func answer(_ entry: KnowledgeEntry, remembered: Bool) {
        store.review(entry.key, remembered: remembered)
        revealed = false
    }
}

private struct ConceptList: View {
    @ObservedObject var store: KnowledgeStore
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索概念或解释", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List {
                ForEach(filtered) { entry in
                    ConceptRow(entry: entry) { store.remove(entry.key) }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text("只保存在本机：概念名、一句话解释、来源应用和复习进度。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空全部…", role: .destructive) { confirmClear = true }
                    .disabled(store.book.entries.isEmpty)
            }
            .padding(12)
        }
        .confirmationDialog("清空全部学习记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.removeAll() }
        } message: {
            Text("这会删除本机上所有已记录的概念和复习进度，无法撤销。")
        }
    }

    private var filtered: [KnowledgeEntry] {
        let all = store.book.recent()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.term.localizedCaseInsensitiveContains(needle) || $0.summary.localizedCaseInsensitiveContains(needle) }
    }
}

private struct ConceptRow: View {
    let entry: KnowledgeEntry
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ReviewRing(stage: entry.stage)
                .padding(.top, 3)
                .help(entry.stage == 0 ? "还没在复习中想起过" : "复习中已连续想起 \(entry.stage) 次")
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.term).font(.headline)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(meta).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除这条记录")
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        var parts = ["查过 \(entry.lookups) 次", RelativeTime.string(entry.lastSeen)]
        if !entry.source.isEmpty { parts.append("来自 \(entry.source)") }
        let next = KnowledgeBook.reviewDate(of: entry)
        parts.append(next <= Date() ? "该复习了" : "\(RelativeTime.string(next))复习")
        return parts.joined(separator: " · ")
    }
}

/// How far a concept has come through the review intervals.
private struct ReviewRing: View {
    let stage: Int

    var body: some View {
        let progress = CGFloat(stage) / CGFloat(KnowledgeBook.intervals.count - 1)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Palette.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}
