import AppKit
import Carbon
import AskmeCore

/// Global input, event-driven only: no polling, and key events are inspected for the trigger, Esc
/// and "is the user typing" without ever storing what was typed.
@MainActor
final class InputMonitor {
    enum Trigger {
        case began(CGPoint, primer: Bool)
        case peek
        case tap
        case ended(onCard: Bool)
        case cancelled
        case retarget(CGPoint)
    }

    enum Outside { case click, scroll, typing }

    var onTrigger: ((Trigger) -> Void)?
    var onHoverDwell: ((CGPoint) -> Void)?
    var onHoverInvalidate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onOutside: ((Outside) -> Void)?
    var onOverlayScroll: (() -> Void)?
    var onContextChange: (() -> Void)?
    var isOnOverlay: ((CGPoint) -> Bool)?
    var isHoverSuspended: (() -> Bool)?

    private let settings: Settings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var gesture = TriggerGesture()
    private var triggerHeld = false
    private var primerPress = false
    private var holdTimer: Timer?
    private var retargetTimer: Timer?
    private var retargetGate = DwellGate(tolerance: 4)
    private var hoverGate = DwellGate()
    private var hoverTimer: Timer?

    init(settings: Settings) { self.settings = settings }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                          .leftMouseUp, .rightMouseUp, .scrollWheel, .keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: false) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: true) }
            return event
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.contextChanged(note) }
            })
        }
    }

    func stop() {
        reset()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func reset() {
        holdTimer?.invalidate()
        retargetTimer?.invalidate()
        if gesture.isActive {
            gesture.reset()
            onTrigger?(.cancelled)
        }
        resetHover()
    }

    private func contextChanged(_ note: Notification) {
        if note.name == NSWorkspace.didActivateApplicationNotification,
           (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == getpid() { return }
        reset()
        onContextChange?()
    }

    private func handle(_ event: NSEvent, local: Bool) {
        switch event.type {
        case .flagsChanged:
            handleFlags(event)
        case .keyDown:
            if gesture.isActive { cancelIfNeeded(gesture.interrupt(.key)) }
            resetHover()
            if event.keyCode == 53 { onEscape?() } else if !local { onOutside?(.typing) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let onOverlay = isOnOverlay?(NSEvent.mouseLocation) ?? false
            if gesture.isActive, !onOverlay { cancelIfNeeded(gesture.interrupt(.click)) }
            resetHover()
            if !onOverlay { onOutside?(.click) }
        case .scrollWheel:
            let point = NSEvent.mouseLocation
            if gesture.isActive {
                cancelIfNeeded(gesture.interrupt(.scroll))
                if gesture.isPeeking {
                    // The page moved under a still pointer: re-read once scrolling settles.
                    retargetGate.reset()
                    pointerMoved(point)
                }
            } else if isOnOverlay?(point) ?? false {
                onOverlayScroll?()
            } else {
                onOutside?(.scroll)
            }
            resetHover()
        case .mouseMoved, .leftMouseUp, .rightMouseUp, .leftMouseDragged, .rightMouseDragged:
            let point = NSEvent.mouseLocation
            if gesture.isPeeking { pointerMoved(point) } else if !gesture.isActive { hover(event, point) }
        default:
            break
        }
    }

    // MARK: - Trigger key

    private func handleFlags(_ event: NSEvent) {
        let key = settings.triggerKey
        guard key.keyCodes.contains(event.keyCode) else {
            // Another modifier joined while the trigger is down: a chord such as ⌃⇧→, not a request.
            // Letting go of ⇧ after ⇧ + trigger (preloading) is part of the gesture, not a chord.
            let isShift = event.keyCode == 56 || event.keyCode == 60
            if gesture.isActive, !(primerPress && isShift) { cancelIfNeeded(gesture.interrupt(.key)) }
            return
        }
        let down = key.isDown(event)
        if down {
            // A key-up can be missed (secure input, a Space switch): start over instead of
            // swallowing this press.
            if triggerHeld {
                holdTimer?.invalidate()
                retargetTimer?.invalidate()
                gesture.reset()
            }
            triggerHeld = true
            let others = event.modifierFlags.intersection([.command, .option, .control, .function]).subtracting(key.flag)
            guard settings.enabled, others.isEmpty, !IsSecureEventInputEnabled() else {
                gesture.suppress()
                return
            }
            let point = NSEvent.mouseLocation
            guard gesture.press(at: event.timestamp) == .begin else { return }
            resetHover()
            retargetGate.reset()
            _ = retargetGate.moved(to: point)
            primerPress = event.modifierFlags.contains(.shift)
            onTrigger?(.began(point, primer: primerPress))
            scheduleHold()
        } else if !down, triggerHeld {
            triggerHeld = false
            holdTimer?.invalidate()
            retargetTimer?.invalidate()
            switch gesture.release() {
            case .tap: onTrigger?(.tap)
            case .end: onTrigger?(.ended(onCard: isOnOverlay?(NSEvent.mouseLocation) ?? false))
            default: break
            }
        }
    }

    private func scheduleHold() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: gesture.holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.gesture.tick(at: ProcessInfo.processInfo.systemUptime + 0.005) == .peek { self.onTrigger?(.peek) }
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelIfNeeded(_ output: TriggerGesture.Output) {
        guard output == .cancel else { return }
        holdTimer?.invalidate()
        retargetTimer?.invalidate()
        onTrigger?(.cancelled)
    }

    /// While peeking, the card follows the pointer like a lens once it rests on new text.
    private func pointerMoved(_ point: CGPoint) {
        if isOnOverlay?(point) == true {
            retargetTimer?.invalidate()
            return
        }
        guard retargetGate.moved(to: point) else { return }
        retargetTimer?.invalidate()
        let timer = Timer(timeInterval: 0.22, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.gesture.isPeeking, let anchor = self.retargetGate.anchor else { return }
                self.onTrigger?(.retarget(anchor))
            }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        retargetTimer = timer
    }

    // MARK: - Optional hover hint

    private func hover(_ event: NSEvent, _ point: CGPoint) {
        guard settings.enabled, settings.hoverMode, !(isHoverSuspended?() ?? false), !IsSecureEventInputEnabled() else {
            resetHover()
            return
        }
        if isOnOverlay?(point) == true {
            hoverTimer?.invalidate()
            hoverTimer = nil
            return
        }
        switch event.type {
        case .mouseMoved, .leftMouseUp, .rightMouseUp:
            guard NSEvent.pressedMouseButtons == 0 else { resetHover(); return }
            if hoverGate.moved(to: point) { armHover() }
        default:
            resetHover()
        }
    }

    private func armHover() {
        hoverTimer?.invalidate()
        onHoverInvalidate?()
        let timer = Timer(timeInterval: max(0.4, min(settings.dwell, 3)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.enabled, self.settings.hoverMode, !(self.isHoverSuspended?() ?? false),
                      NSEvent.pressedMouseButtons == 0, !IsSecureEventInputEnabled(),
                      self.hoverGate.trigger(), let point = self.hoverGate.anchor else { return }
                self.onHoverDwell?(point)
            }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func resetHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverGate.reset()
        onHoverInvalidate?()
    }
}
