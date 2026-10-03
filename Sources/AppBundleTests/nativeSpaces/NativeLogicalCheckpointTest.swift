@testable import AppBundle
import Common
import XCTest

@MainActor
final class NativeLogicalCheckpointTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFailedTransferRestoresTreeIdentityDwindleSharesFocusAndHistory() {
        let source = focus.workspace
        let root = source.rootTilingContainer
        root.layout = .dwindle
        let first = TestWindow.new(id: 11, parent: root)
        let second = TestWindow.new(id: 12, parent: root)
        root.dwindleSplitRatios = [0.37]
        first.markAsMostRecentChild()
        _ = first.focusWindow()
        let stateBefore = winMuxWorkspaceState.monitorViewportsById
        let checkpoint = NativeLogicalCheckpoint()
        let target = createBlankWorkspace(projectId: source.projectId, monitor: mainMonitor)
        first.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        _ = target.focusWorkspace()
        checkpoint.restore()
        XCTAssertTrue(first.parent === root)
        XCTAssertTrue(second.parent === root)
        XCTAssertEqual(root.children, [first, second])
        XCTAssertEqual(root.dwindleSplitRatios, [0.37])
        XCTAssertTrue(root.mostRecentChild === first)
        XCTAssertTrue(focus.windowOrNil === first)
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]?.activeWorkspaceId, stateBefore[MonitorViewportId(mainMonitor)]?.activeWorkspaceId)
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]?.previousWorkspaceId, stateBefore[MonitorViewportId(mainMonitor)]?.previousWorkspaceId)
        XCTAssertNil(Workspace.existing(byName: target.name))
    }

    func testFailedMoveRetainsMinimizedOwnerAndNativeState() {
        let source = focus.workspace
        let window = TestWindow.new(id: 17, parent: source.rootTilingContainer)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: source.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let checkpoint = NativeLogicalCheckpoint()
        let target = createBlankWorkspace(projectId: source.projectId, monitor: mainMonitor)
        moveWorkspaceContents(from: source, to: target)
        checkpoint.restore()
        XCTAssertTrue(window.parent === macosMinimizedWindowsContainer)
        if case .macos(_, let name) = window.layoutReason { XCTAssertEqual(name, source.name) }
        else { XCTFail("minimized state must be preserved") }
    }
}
