import AppKit
import SwiftUI
import AskmeCore

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Non-activating floating panels: the hover hint, the concept card and short toasts. None of them
/// take focus from the app being read unless the user clicks into the card.
@MainActor
final class Overlay {
    private var hintPanel: NSPanel?
    private var hintApproach: CGRect?
    private var cardPanel: NSPanel?
    private var toastPanel: NSPanel?
    private var toastWork: DispatchWorkItem?
    private var anchor: CardAnchor?
    private var cardWidth: CGFloat = 400
    private var lastHeight: CGFloat = 132
    private var docked = false
    private var userPlaced = false
    private var targetFrame: CGRect?
    private var shownAt: CFTimeInterval = 0
    private weak var cardModel: CardModel?

    var isCardVisible: Bool { cardPanel?.isVisible ?? false }
    var isCardKey: Bool { cardPanel?.isKeyWindow ?? false }
    var cardFrame: CGRect? { cardPanel?.frame }

    func contains(_ point: CGPoint) -> Bool {
        if let panel = cardPanel, panel.isVisible, panel.frame.insetBy(dx: -6, dy: -6).contains(point) { return true }
        if let panel = hintPanel, panel.isVisible,
           panel.frame.insetBy(dx: -8, dy: -8).contains(point) || (hintApproach?.contains(point) ?? false) { return true }
        return false
    }

    // MARK: - Card

    func showCard(_ model: CardModel, near point: CGPoint) {
        closeCard()
        closeHint()
        let visible = Self.visibleFrame(containing: point)
        cardWidth = min(400, visible.width - 16)
        let anchor = CardAnchor.near(point, width: cardWidth, visibleFrame: visible)
        self.anchor = anchor
        docked = false
        userPlaced = false
        lastHeight = 132
        targetFrame = nil
        shownAt = CACurrentMediaTime()
        let panel = makePanel(frame: anchor.frame(width: cardWidth, height: lastHeight))
        cardModel = model
        // A closing card's view can still report a last height; only the current card may resize.
        model.onHeight = { [weak self, weak model] height, settled in
            guard let self, let model, self.cardModel === model else { return }
            self.resize(to: height, settled: settled)
        }
        let hosting = NSHostingView(rootView: CardView(model: model))
        // The card's size is managed here. Left on, the hosting view turns SwiftUI's minimum size
        // (a wrapping text measured at zero width is very tall) into window constraints.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
        cardPanel = panel
    }

    /// Moves a peeking card next to a new target without recreating it.
    func reanchor(near point: CGPoint) {
        guard cardPanel != nil, !docked, !userPlaced else { return }
        anchor = CardAnchor.near(point, width: cardWidth, visibleFrame: Self.visibleFrame(containing: point))
        resize(to: lastHeight, settled: true, force: true)
    }

    /// While an answer streams, the card only grows, and with some headroom, so it resizes a few
    /// times instead of on every line and the text being read does not keep shifting. Once the
    /// answer settles, it fits the content exactly.
    func resize(to height: CGFloat, settled: Bool, force: Bool = false) {
        guard let panel = cardPanel else { return }
        lastHeight = height
        guard !docked else { return }
        let shown = targetFrame?.height ?? panel.frame.height
        let wanted = settled || force ? height : (height > shown ? height + 44 : shown)
        var frame: CGRect
        if userPlaced {
            let visible = panel.screen?.visibleFrame ?? Self.visibleFrame(containing: panel.frame.origin)
            let top = (targetFrame ?? panel.frame).maxY
            let room = max(120, min(560, top - visible.minY - 8))
            let h = min(max(wanted, 56), room)
            frame = CGRect(x: panel.frame.minX, y: top - h, width: panel.frame.width, height: h)
        } else if let anchor {
            frame = anchor.frame(width: cardWidth, height: wanted)
        } else {
            return
        }
        frame = frame.integral
        guard force || frame != targetFrame else { return }
        targetFrame = frame
        // The first layout passes right after showing are sized instantly; later changes ease.
        if !force, CACurrentMediaTime() - shownAt > 0.2, abs(frame.height - panel.frame.height) > 1 {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { panel.invalidateShadow() })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    func markUserPlaced() {
        userPlaced = true
        targetFrame = nil
    }

    func setDocked(_ value: Bool) {
        guard let panel = cardPanel else { return }
        docked = value
        if value {
            let visible = panel.screen?.visibleFrame ?? Self.visibleFrame(containing: panel.frame.origin)
            let width = min(420, visible.width - 24)
            panel.setFrame(CGRect(x: visible.maxX - width - 12, y: visible.minY + 12, width: width, height: visible.height - 24),
                           display: true, animate: true)
        } else {
            userPlaced = false
            resize(to: lastHeight, settled: true, force: true)
        }
        targetFrame = nil
        panel.invalidateShadow()
    }

    func focusCard() { cardPanel?.makeKey() }

    enum Snapshot { case card, hint, toast }

    /// Renders a panel inside this process (no screen recording), for the smoke test.
    func snapshot(_ which: Snapshot) -> Data? {
        let panel: NSPanel? = switch which {
        case .card: cardPanel
        case .hint: hintPanel
        case .toast: toastPanel
        }
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func closeCard() {
        cardModel?.onHeight = nil
        cardModel = nil
        cardPanel?.orderOut(nil)
        cardPanel?.contentView = nil
        cardPanel = nil
        anchor = nil
        targetFrame = nil
        docked = false
        userPlaced = false
    }

    // MARK: - Hover hint

    func showHint(candidate: Candidate, action: @escaping () -> Void) {
        closeHint()
        let pill = Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Askme").font(.system(size: 12, weight: .semibold))
            }
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("预览并解释：\(String(candidate.text.prefix(80)))")
        let (hosting, size) = Overlay.fitted(pill, maxWidth: 200)
        let visible = Self.visibleFrame(containing: candidate.point)
        let origin = ScreenGeometry.clampedOrigin(anchor: CGPoint(x: candidate.point.x + 12, y: candidate.point.y - size.height - 12),
                                                  size: size, visibleFrame: visible)
        let panel = makePanel(frame: CGRect(origin: origin, size: size))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        hintPanel = panel
        // A small bridge lets the pointer reach the button without dismissing it.
        hintApproach = panel.frame.union(CGRect(x: candidate.point.x - 6, y: candidate.point.y - 6, width: 12, height: 12))
    }

    func closeHint() {
        hintPanel?.orderOut(nil)
        hintPanel?.contentView = nil
        hintPanel = nil
        hintApproach = nil
    }

    // MARK: - Toast

    /// Brief, non-interactive feedback near the pointer, e.g. when nothing readable was found.
    func toast(_ text: String, near point: CGPoint) {
        closeToast()
        let bubble = Text(text)
            .font(.system(size: 12))
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        let (hosting, size) = Overlay.fitted(bubble, maxWidth: 344)
        let visible = Self.visibleFrame(containing: point)
        let origin = ScreenGeometry.clampedOrigin(anchor: CGPoint(x: point.x + 14, y: point.y - size.height - 14),
                                                  size: size, visibleFrame: visible)
        let panel = makePanel(frame: CGRect(origin: origin, size: size))
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        toastPanel = panel
        let work = DispatchWorkItem { [weak self] in self?.closeToast() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func closeToast() {
        toastWork?.cancel()
        toastWork = nil
        toastPanel?.orderOut(nil)
        toastPanel?.contentView = nil
        toastPanel = nil
    }

    // MARK: - Helpers

    /// Measures a view at a given maximum width. `fittingSize` asks for the minimum size, where
    /// wrapping text measured at zero width comes out absurdly tall.
    private static func fitted<V: View>(_ view: V, maxWidth: CGFloat) -> (NSView, CGSize) {
        let measured = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: maxWidth, height: 2_000))
        let size = CGSize(width: ceil(measured.width) + 1, height: ceil(measured.height) + 1)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        return (hosting, size)
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = FloatingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setFrame(frame, display: false)
        return panel
    }

    private static func visibleFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
