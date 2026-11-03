import AppKit
import SwiftUI
import ServiceManagement
import AskmeCore

@MainActor
final class SettingsController {
    private let settings: Settings
    private let knowledge: KnowledgeStore
    private let openKnowledge: () -> Void
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible ?? false }

    init(settings: Settings, knowledge: KnowledgeStore, openKnowledge: @escaping () -> Void) {
        self.settings = settings
        self.knowledge = knowledge
        self.openKnowledge = openKnowledge
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Askme 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, knowledge: knowledge, openKnowledge: openKnowledge))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var knowledge: KnowledgeStore
    let openKnowledge: () -> Void

    var body: some View {
        TabView {
            TriggerPane(settings: settings)
                .tabItem { Label("触发", systemImage: "hand.point.up.left") }
            LearnerPane(settings: settings, knowledge: knowledge, openKnowledge: openKnowledge)
                .tabItem { Label("理解你", systemImage: "person.crop.circle") }
            ModelPane(settings: settings)
                .tabItem { Label("模型", systemImage: "cpu") }
            PrivacyPane(settings: settings)
                .tabItem { Label("隐私与权限", systemImage: "lock.shield") }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 520)
    }
}

private struct Note: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(color).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
    }
}

private struct TriggerPane: View {
    @ObservedObject var settings: Settings
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用 Askme", isOn: $settings.enabled)
                Picker("触发键", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Note("按住 \(settings.triggerKey.symbol) 指向文字：立即解释，松开关闭。")
                    Note("轻点 \(settings.triggerKey.symbol)：解释并保留卡片；先选中文字再按，解释整段选区。")
                    Note("⇧ + 轻点 \(settings.triggerKey.symbol)：预装载当前窗口，先列出读懂这页需要的前置概念。")
                }
                if settings.triggerKey == .function {
                    Note("使用 fn 时，请在系统设置 → 键盘中把「按下 🌐 键时」设为「不执行任何操作」，避免同时切换输入法。", color: .orange)
                }
            }
            Section("悬停提示") {
                Toggle("停留后出现按钮（确认后才发送）", isOn: $settings.hoverMode)
                if settings.hoverMode {
                    HStack {
                        Text("停留时间")
                        Slider(value: $settings.dwell, in: 0.4...3, step: 0.1)
                        Text(String(format: "%.1f 秒", settings.dwell)).monospacedDigit().frame(width: 56)
                    }
                }
                Note("默认关闭：读文章时鼠标常停在字上，被动弹出会打扰阅读。")
            }
            Section {
                Toggle("登录时启动", isOn: Binding(get: { loginEnabled }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        message = loginEnabled ? "已设置登录启动。" : "未启用；如状态待批准，请在系统设置 → 通用 → 登录项中确认。"
                    } catch { message = error.localizedDescription }
                }))
                if !message.isEmpty { Note(message) }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

private struct LearnerPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var knowledge: KnowledgeStore
    let openKnowledge: () -> Void
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("我的背景") {
                TextEditor(text: $settings.background)
                    .font(.body)
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if settings.background.isEmpty {
                            Text("例如：前端工程师，熟悉 React 和 TypeScript，没系统学过机器学习")
                                .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Note("会随每次查询发送，用来挑你最容易懂的类比、跳过你已经会的前置知识。")
                Picker("回答语言", selection: $settings.language) {
                    ForEach(Learner.languages, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("本机学习记录") {
                Toggle("记住查过的概念并安排复习", isOn: $settings.memoryEnabled)
                Note("只存概念名、一句话解释和来源应用，不存原文和窗口标题。查过的概念自动按 1、3、7、16、35、90 天的间隔进入复习；复习时想起来的概念名会随请求发送，作为类比的锚点。")
                HStack {
                    Button("打开知识库…") { openKnowledge() }
                    Button("清空学习记录…", role: .destructive) { confirmClear = true }
                        .disabled(knowledge.book.entries.isEmpty)
                    Spacer()
                    Text("已记录 \(knowledge.book.entries.count) 个概念").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空全部学习记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { knowledge.removeAll() }
        } message: {
            Text("这会删除本机上所有已记录的概念和复习进度，无法撤销。")
        }
    }
}

private struct ModelPane: View {
    @ObservedObject var settings: Settings
    @State private var apiKey = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section("OpenAI 兼容 Chat Completions（流式）") {
                TextField("完整 URL", text: $settings.endpoint)
                TextField("模型名称", text: $settings.model)
                SecureField("API Key", text: $apiKey, prompt: Text("仅保存到 Keychain"))
                HStack {
                    Button("保存 API Key") {
                        do {
                            _ = try Endpoint.validate(settings.endpoint)
                            try Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: settings.endpoint)
                            apiKey = ""
                            message = "API Key 已更新。输入框已清空；本地模型可留空并保存以删除旧 Key。"
                        } catch { message = error.localizedDescription }
                    }
                    Button("删除当前接口 Key") {
                        do { try Keychain.save("", endpoint: settings.endpoint); message = "已删除当前接口的 API Key。" }
                        catch { message = error.localizedDescription }
                    }
                }
                if !message.isEmpty { Note(message) }
                Note("支持 HTTPS 和本机 HTTP（如 http://localhost:11434/v1/chat/completions）；密钥按完整接口地址隔离，换地址不会带走旧密钥。")
            }
            Section("速度") {
                TextField("额外请求参数（JSON，可选）", text: $settings.extraParameters, prompt: Text(#"{"reasoning_effort": "low"}"#))
                    .font(.system(.body, design: .monospaced))
                if let problem = extraProblem { Note(problem, color: .red) }
                Note("首字延迟决定「瞬间」的手感：建议用不开深度思考的快模型，或用额外参数关掉推理（参数名取决于服务商）。")
            }
        }
        .formStyle(.grouped)
    }

    private var extraProblem: String? {
        do { _ = try ChatRequest.parseExtra(settings.extraParameters); return nil }
        catch { return ChatError.describe(error) }
    }
}

private struct PrivacyPane: View {
    @ObservedObject var settings: Settings
    @State private var axGranted = Permissions.accessibility
    @State private var screenGranted = Permissions.screenRecording

    var body: some View {
        Form {
            Section("权限") {
                HStack {
                    Label(axGranted ? "辅助功能已授权" : "辅助功能未授权（必需）",
                          systemImage: axGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    Spacer()
                    Button("授权") { Permissions.requestAccessibility(); refresh() }
                    Button("系统设置") { Permissions.openPrivacy("Privacy_Accessibility") }
                }
                HStack {
                    Label(screenGranted ? "屏幕录制已授权" : "屏幕录制未授权（可选）",
                          systemImage: screenGranted ? "checkmark.circle.fill" : "circle")
                    Spacer()
                    Button("授权") { Permissions.requestScreenRecording(); refresh() }
                    Button("刷新状态") { refresh() }
                }
                Note("权限改变后可能需要退出并重新打开应用。Chrome 自动化只在点击「读取 Chrome 当前页」时申请。")
            }
            Section("识别") {
                Toggle("为 Chrome / Electron 应用开启辅助功能内容树", isOn: $settings.enhanceWeb)
                Note("Chrome、VS Code、Cursor、Slack 等只有被请求时才公开网页文字。开启后首次在这些应用里使用时请求一次，可能略增加它们的内存占用。")
                Toggle("辅助功能读不到文字时，使用本地 OCR", isOn: $settings.ocrEnabled)
                Toggle("没有文字时，允许把局部截图作为图片输入", isOn: $settings.imageEnabled)
                Note("OCR 与图片需要屏幕录制权限，只在你触发时截取当前窗口的局部（预装载时为整个窗口），OCR 在本地完成。")
            }
            Section("按应用") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发送前先确认（Bundle ID，每行一个）")
                    TextEditor(text: $settings.askFirstApps)
                        .font(.system(.caption, design: .monospaced)).frame(height: 54)
                    Note("聊天、邮件里常有他人的私人信息：在这些应用里会先显示将要发送的内容，确认后才发送。")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("完全排除（不读取、不 OCR）")
                    TextEditor(text: $settings.excludedApps)
                        .font(.system(.caption, design: .monospaced)).frame(height: 72)
                    Note("会跳过系统安全输入状态和密码框，但并非所有应用都会正确标注敏感内容。金融等高敏感应用建议加入这里。")
                }
            }
            Section("搜索") {
                TextField("「搜索」按钮使用的地址（%s 代表概念）", text: $settings.searchURL)
                Note("模型没把握时（比如内部术语），卡片上的「搜索」会用默认浏览器打开这个地址，可以换成公司内部的文档搜索。")
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        axGranted = Permissions.accessibility
        screenGranted = Permissions.screenRecording
    }
}
