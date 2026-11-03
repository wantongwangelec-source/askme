import XCTest
@testable import AskmeCore

final class GestureTests: XCTestCase {
    func testHoldPeeksAndReleaseEnds() {
        var gesture = TriggerGesture(holdThreshold: 0.18)
        XCTAssertEqual(gesture.press(at: 10), .begin)
        XCTAssertEqual(gesture.tick(at: 10.1), .none)
        XCTAssertEqual(gesture.tick(at: 10.2), .peek)
        XCTAssertTrue(gesture.isPeeking)
        XCTAssertEqual(gesture.tick(at: 10.5), .none)
        XCTAssertEqual(gesture.interrupt(.scroll), .none)
        XCTAssertEqual(gesture.release(), .end)
        XCTAssertFalse(gesture.isActive)
    }

    func testQuickPressIsATap() {
        var gesture = TriggerGesture()
        XCTAssertEqual(gesture.press(at: 1), .begin)
        XCTAssertEqual(gesture.release(), .tap)
        XCTAssertEqual(gesture.release(), .none)
    }

    func testShortcutsClicksAndChordsCancelSilently() {
        var gesture = TriggerGesture()
        XCTAssertEqual(gesture.press(at: 1), .begin)
        XCTAssertEqual(gesture.interrupt(.key), .cancel)
        XCTAssertEqual(gesture.tick(at: 5), .none)
        XCTAssertEqual(gesture.release(), .none)

        XCTAssertEqual(gesture.press(at: 6), .begin)
        XCTAssertEqual(gesture.tick(at: 7), .peek)
        XCTAssertEqual(gesture.interrupt(.click), .cancel)
        XCTAssertEqual(gesture.release(), .none)

        gesture.suppress()
        XCTAssertEqual(gesture.press(at: 8), .none)
        XCTAssertEqual(gesture.release(), .none)
        XCTAssertEqual(gesture.press(at: 9), .begin)
        XCTAssertEqual(gesture.interrupt(.scroll), .cancel)
    }
}
