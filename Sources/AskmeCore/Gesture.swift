import Foundation

/// The trigger key as a spring-loaded mode (Raskin's quasimode): holding it shows the card for
/// whatever is under the pointer and releasing it dismisses the card, so there is no mode to forget.
/// A quick tap keeps the card instead. Anything that looks like part of a shortcut cancels silently.
public struct TriggerGesture: Sendable {
    public enum Output: Equatable, Sendable {
        case none
        /// Trigger pressed: start a silent local capture so the answer can start as early as possible.
        case begin
        /// Held past the threshold: reveal the card and send while the key stays down.
        case peek
        /// Pressed and released quickly: reveal the card and keep it.
        case tap
        /// Released after peeking.
        case end
        /// The press turned out to be part of a shortcut, a click or a scroll: discard silently.
        case cancel
    }

    public enum Interruption: Sendable { case key, click, scroll }

    private enum State: Equatable { case idle, pressed(TimeInterval), peeking, suppressed }

    public let holdThreshold: TimeInterval
    private var state: State = .idle

    public init(holdThreshold: TimeInterval = 0.18) { self.holdThreshold = holdThreshold }

    public var isActive: Bool { state != .idle }
    public var isPeeking: Bool { state == .peeking }

    public mutating func press(at time: TimeInterval) -> Output {
        guard state == .idle else { return .none }
        state = .pressed(time)
        return .begin
    }

    /// A press that arrives together with other modifiers is a chord, not a trigger.
    public mutating func suppress() {
        state = .suppressed
    }

    public mutating func tick(at time: TimeInterval) -> Output {
        guard case .pressed(let start) = state, time - start >= holdThreshold else { return .none }
        state = .peeking
        return .peek
    }

    public mutating func release() -> Output {
        defer { state = .idle }
        switch state {
        case .pressed: return .tap
        case .peeking: return .end
        case .idle, .suppressed: return .none
        }
    }

    public mutating func interrupt(_ kind: Interruption) -> Output {
        switch state {
        case .pressed:
            state = .suppressed
            return .cancel
        case .peeking where kind != .scroll:
            state = .suppressed
            return .cancel
        default:
            return .none
        }
    }

    public mutating func reset() { state = .idle }
}
