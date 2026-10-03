@testable import AppBundle
import Common
import CoreGraphics
import XCTest

@MainActor
final class NativeSpacesRuntimeTest: XCTestCase {
    private var directory: URL!
    private var driver: FakeNativeSpaceDriver!
    private var engine: NativeSpaceCoordinator!
    private var source: Workspace!
    private var target: Workspace!

    override func setUp() async throws {
        NativeSpacesRuntime.shared.installForTests(nil)
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        source = focus.workspace
        target = Workspace.get(byName: "Native Target")
        target.seedMonitorIfNeeded(mainMonitor)
        _ = TestWindow.new(id: 11, parent: source.rootTilingContainer)
        _ = TestWindow.new(id: 13, parent: target.rootTilingContainer)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        driver = FakeNativeSpaceDriver()
        driver.snapshot.displays = [NativeDisplaySnapshot(uuid: "left", displayID: CGMainDisplayID(), currentSpace: 1, spaces: [NativeDesktop(id: 1, uuid: "one", isUser: true), NativeDesktop(id: 3, uuid: "three", isUser: true)])]
        engine = try NativeSpaceCoordinator(driver: driver, store: NativeSpaceStore(url: directory.appendingPathComponent("state.json")), attempts: 3)
        try engine.adopt([
            NativeSpaceBinding(workspace: source.id.rawValue, name: source.name, project: "default", display: "left", space: 1, spaceUUID: "one"),
            NativeSpaceBinding(workspace: target.id.rawValue, name: target.name, project: "default", display: "left", space: 3, spaceUUID: "three"),
        ])
        NativeSpacesRuntime.shared.installForTests(engine, windows: [driver.identity(11), driver.identity(13)])
    }

    override func tearDown() async throws {
        NativeSpacesRuntime.shared.installForTests(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    func testWorkspaceSelectionActivatesNativeSpaceThroughRealSession() async throws {
        let selected = try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
            activateWorkspaceForUser(self.target, on: mainMonitor)
        }
        XCTAssertTrue(selected)
        XCTAssertEqual(driver.snapshot.display("left")?.currentSpace, 3)
        XCTAssertTrue(focus.workspace === target)
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(driver.windows[13], [3])
        XCTAssertTrue(NativeSpacesRuntime.shared.isActuallyVisible(target))
        XCTAssertFalse(NativeSpacesRuntime.shared.isActuallyVisible(source))
    }

    func testFailedNativeActivationRestoresLogicalViewportAndFocus() async throws {
        let before = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]
        driver.activationFailure = 3
        do {
            _ = try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
                activateWorkspaceForUser(self.target, on: mainMonitor)
            }
            XCTFail("unconfirmed activation must fail the session")
        } catch {}
        XCTAssertEqual(driver.snapshot.display("left")?.currentSpace, 1)
        XCTAssertTrue(focus.workspace === source)
        let after = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]
        XCTAssertEqual(before?.activeWorkspaceId, after?.activeWorkspaceId)
        XCTAssertEqual(before?.previousWorkspaceId, after?.previousWorkspaceId)
        XCTAssertTrue(NativeSpacesRuntime.shared.isActuallyVisible(source))
    }

    func testManualMissionControlSwitchUpdatesLogicalViewportWithoutSwitchingBack() async throws {
        try await driver.activate(3, on: "left")
        driver.actions = []
        try NativeSpacesRuntime.shared.observeTopology()
        XCTAssertTrue(mainMonitor.activeWorkspace === target)
        try await NativeSpacesRuntime.shared.synchronize()
        XCTAssertEqual(driver.snapshot.display("left")?.currentSpace, 3)
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("activate:") })
    }

    func testAdoptsEmptyExternalDesktopsWithoutMutationsOrDuplicates() throws {
        let display = driver.snapshot.displays[0]
        driver.snapshot.displays[0] = NativeDisplaySnapshot(uuid: display.uuid, displayID: display.displayID, currentSpace: display.currentSpace, spaces: display.spaces + [NativeDesktop(id: 8, uuid: "empty", isUser: true), NativeDesktop(id: 9, uuid: "fullscreen", isUser: false)])
        try NativeSpacesRuntime.shared.observeTopology()
        let binding = try XCTUnwrap(engine.state.bindings.values.first { $0.space == 8 })
        let workspace = try XCTUnwrap(Workspace.existing(byName: binding.name))
        XCTAssertTrue(NativeSpacesRuntime.shared.retainsExternalDesktop(workspace))
        XCTAssertNil(engine.state.bindings.values.first { $0.space == 9 })
        XCTAssertTrue(engine.state.ownedSpaces.isEmpty)
        XCTAssertTrue(driver.actions.isEmpty)
        let bindings = engine.state.bindings
        try NativeSpacesRuntime.shared.observeTopology()
        XCTAssertEqual(engine.state.bindings, bindings)
    }

    func testStartupReusesOwnedDesktopButRefreshDoesNotAdoptStagingSlot() throws {
        let display = driver.snapshot.displays[0]
        driver.snapshot.displays[0] = NativeDisplaySnapshot(uuid: display.uuid, displayID: display.displayID, currentSpace: display.currentSpace, spaces: display.spaces + [NativeDesktop(id: 8, uuid: "owned", isUser: true)])
        var state = engine.state
        state.ownedSpaces.append(NativeOwnedSpace(id: 8, uuid: "owned", display: "left"))
        try engine.store.save(state)
        engine = try NativeSpaceCoordinator(driver: driver, store: engine.store, attempts: 3)
        NativeSpacesRuntime.shared.installForTests(engine, windows: [driver.identity(11), driver.identity(13)])
        try NativeSpacesRuntime.shared.observeTopology()
        XCTAssertNil(engine.state.bindings.values.first { $0.space == 8 })
        try NativeSpacesRuntime.shared.observeTopology(adoptExistingOwnedSpaces: true)
        let binding = try XCTUnwrap(engine.state.bindings.values.first { $0.space == 8 })
        let workspace = try XCTUnwrap(Workspace.existing(byName: binding.name))
        XCTAssertTrue(NativeSpacesRuntime.shared.retainsExternalDesktop(workspace))
        XCTAssertTrue(workspaceShouldSurviveReconciliation(workspace, retainedEmptyWorkspaceIds: [:]))
        XCTAssertEqual(engine.state.ownedSpaces, state.ownedSpaces)
        XCTAssertTrue(driver.actions.isEmpty)
        let bindings = engine.state.bindings
        try NativeSpacesRuntime.shared.observeTopology(adoptExistingOwnedSpaces: true)
        XCTAssertEqual(engine.state.bindings, bindings)
    }

}
