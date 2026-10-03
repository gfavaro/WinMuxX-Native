@testable import AppBundle
import XCTest

@MainActor
final class WindowTerminationTest: XCTestCase {
    func testFramesRespectDisplayOriginAndVisibleInsets() {
        for origin in [CGPoint(x: -1920, y: -1080), CGPoint(x: 1920, y: 100)] {
            let visible = CGRect(origin: origin, size: CGSize(width: 1920, height: 1000))
            let frame = terminationFrame(visibleFrame: visible, floatingSize: CGSize(width: 800, height: 600))
            XCTAssertEqual(frame.origin, CGPoint(x: origin.x + 560, y: origin.y + 200))
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testOversizedAndInvalidFloatingSizesFitDisplay() {
        let visible = CGRect(x: 100, y: 25, width: 1000, height: 700)
        XCTAssertEqual(terminationFrame(visibleFrame: visible, floatingSize: CGSize(width: 2000, height: 900)), visible)
        XCTAssertEqual(terminationFrame(visibleFrame: visible, floatingSize: nil), visible)
        XCTAssertEqual(terminationFrame(visibleFrame: visible, floatingSize: CGSize(width: CGFloat.nan, height: -1)), visible)
    }

    func testFailureDoesNotInterruptRemainingWindows() async {
        enum Failure: Error { case rejected }
        var attempted: [Int] = []
        var reported: [Int] = []
        let pending = await restoreTerminationWindows([1, 2, 3]) { window in
            attempted.append(window)
            if window == 2 { throw Failure.rejected }
        } onFailure: { window, _ in reported.append(window) }
        XCTAssertEqual(attempted, [1, 2, 3])
        XCTAssertEqual(pending, [2])
        XCTAssertEqual(reported, [2])
    }

    func testConcurrentAndRepeatedTerminationSharesCleanup() async {
        let coordinator = WindowTerminationCoordinator()
        var count = 0
        let first = Task { @MainActor in
            await coordinator.run {
                count += 1
                await Task.yield()
            }
        }
        await Task.yield()
        await coordinator.run { count += 1 }
        await first.value
        await coordinator.run { count += 1 }
        XCTAssertEqual(count, 1)
    }
}
