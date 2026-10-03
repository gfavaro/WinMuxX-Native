import Common
@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class DoubleSidedWindowsTest: XCTestCase {
    func testBodyClickTargetsPairButDoesNotPassThroughOtherWindows() {
        setUpWorkspacesForTests()
        let saved = nativePreferences.object(forKey: "doubleSidedWindows")
        defer { nativePreferences.set(saved, forKey: "doubleSidedWindows") }
        var settings = ExperimentalUISettings()
        settings.doubleSidedWindows = true
        config.windowTabs.enabled = true
        let group = Workspace.get(byName: "pair").rootTilingContainer
        group.layout = .tabGroup
        let front = TestWindow.new(id: 1, parent: group)
        _ = TestWindow.new(id: 2, parent: group)
        front.markAsMostRecentChild()
        let rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        let pair: [String: Any] = [
            kCGWindowNumber as String: UInt32(1),
            kCGWindowBounds as String: rect.dictionaryRepresentation,
            kCGWindowAlpha as String: 1.0,
        ]
        let point = CGPoint(x: 400, y: 300)
        XCTAssertEqual(doubleSidedWindowId(at: point, in: [pair]), 1)
        XCTAssertNil(doubleSidedWindowId(at: CGPoint(x: 50, y: 50), in: [pair]))
        var coveringWindow = pair
        coveringWindow[kCGWindowNumber as String] = UInt32(999)
        XCTAssertNil(doubleSidedWindowId(at: point, in: [coveringWindow, pair]))
        coveringWindow[kCGWindowAlpha as String] = 0.0
        XCTAssertEqual(doubleSidedWindowId(at: point, in: [coveringWindow, pair]), 1)
    }

    func testOptionTabShortcutDoesNotClaimOtherTabCombinations() {
        XCTAssertTrue(isDoubleSidedFlipShortcut(keyCode: 48, flags: .maskAlternate))
        XCTAssertTrue(isDoubleSidedFlipShortcut(keyCode: 48, flags: [.maskAlternate, .maskAlphaShift]))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 48, flags: []))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 48, flags: .maskCommand))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 48, flags: [.maskAlternate, .maskCommand]))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 48, flags: [.maskAlternate, .maskControl]))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 48, flags: [.maskAlternate, .maskShift]))
        XCTAssertFalse(isDoubleSidedFlipShortcut(keyCode: 49, flags: .maskAlternate))
    }

    func testClickTolerancePreservesDrags() {
        XCTAssertFalse(doubleSidedClickMoved(from: .zero, to: CGPoint(x: 4, y: 0)))
        XCTAssertTrue(doubleSidedClickMoved(from: .zero, to: CGPoint(x: 4, y: 1)))
        XCTAssertTrue(doubleSidedClickMoved(from: .zero, to: CGPoint(x: -5, y: 0)))
    }

    func testPairReturnsToTabsWhenThirdWindowJoins() {
        setUpWorkspacesForTests()
        let saved = nativePreferences.object(forKey: "doubleSidedWindows")
        defer { nativePreferences.set(saved, forKey: "doubleSidedWindows") }
        var settings = ExperimentalUISettings()
        settings.doubleSidedWindows = true
        config.windowTabs.enabled = true
        let group = Workspace.get(byName: "pair").rootTilingContainer
        group.layout = .tabGroup
        _ = TestWindow.new(id: 1, parent: group)
        _ = TestWindow.new(id: 2, parent: group)
        XCTAssertTrue(group.usesDoubleSidedWindows)
        XCTAssertTrue(group.usesWindowTabBehavior)
        XCTAssertFalse(group.showsWindowTabs)
        XCTAssertEqual(group.windowTabBarHeight, 0)
        XCTAssertNil(group.windowTabGroupFrameRect)

        let third = TestWindow.new(id: 3, parent: group)
        XCTAssertFalse(group.usesDoubleSidedWindows)
        XCTAssertTrue(group.showsWindowTabs)
        third.unbindFromParent()
        XCTAssertTrue(group.usesDoubleSidedWindows)

        settings.doubleSidedWindows = false
        XCTAssertFalse(group.usesDoubleSidedWindows)
        XCTAssertTrue(group.showsWindowTabs)
        XCTAssertEqual(group.children.count, 2)
    }

    func testDefaultAndFullscreenKeepExistingBehavior() {
        setUpWorkspacesForTests()
        let saved = nativePreferences.object(forKey: "doubleSidedWindows")
        defer { nativePreferences.set(saved, forKey: "doubleSidedWindows") }
        nativePreferences.removeObject(forKey: "doubleSidedWindows")
        XCTAssertFalse(ExperimentalUISettings().doubleSidedWindows)
        config.windowTabs.enabled = true
        let group = Workspace.get(byName: "pair").rootTilingContainer
        group.layout = .tabGroup
        let front = TestWindow.new(id: 1, parent: group)
        _ = TestWindow.new(id: 2, parent: group)
        XCTAssertTrue(group.showsWindowTabs)
        var settings = ExperimentalUISettings()
        settings.doubleSidedWindows = true
        front.isFullscreen = true
        XCTAssertFalse(group.usesDoubleSidedWindows)
        XCTAssertFalse(group.showsWindowTabs)
        front.isFullscreen = false
        config.windowTabs.enabled = false
        XCTAssertFalse(group.usesDoubleSidedWindows)
    }
}
