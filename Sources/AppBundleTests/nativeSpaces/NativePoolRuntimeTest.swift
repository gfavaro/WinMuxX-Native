@testable import AppBundle
import Common
import XCTest

@MainActor
final class NativePoolRuntimeTest: XCTestCase {
    private var directory: URL!
    private var driver: FakeNativeSpaceDriver!
    private var engine: NativeSpaceCoordinator!
    private var a: Workspace!
    private var b: Workspace!
    private var c: Workspace!
    private var main: TestMonitor!
    private var secondary: TestMonitor!

    override func setUp() async throws {
        NativeSpacesRuntime.shared.installForTests(nil)
        setUpWorkspacesForTests()
        config.onFocusChanged = []
        config.onFocusedMonitorChanged = []
        main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main", rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        secondary = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary", rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([main, secondary])
        a = Workspace.get(byName: "1")
        b = Workspace.get(byName: "2")
        c = Workspace.get(byName: "3")
        for workspace in [a!, b!, c!] { workspace.markAsAutomaticallyNamed() }
        a.seedMonitorIfNeeded(main)
        b.seedMonitorIfNeeded(secondary)
        c.seedMonitorIfNeeded(main)
        _ = TestWindow.new(id: 11, parent: a.rootTilingContainer)
        _ = TestWindow.new(id: 12, parent: b.rootTilingContainer)
        _ = TestWindow.new(id: 13, parent: c.rootTilingContainer)
        XCTAssertTrue(main.setActiveWorkspace(a))
        XCTAssertTrue(secondary.setActiveWorkspace(b))
        _ = a.focusWorkspace()
        TrayMenuModel.shared.isEnabled = true
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        driver = FakeNativeSpaceDriver()
        engine = try NativeSpaceCoordinator(driver: driver, store: NativeSpaceStore(url: directory.appendingPathComponent("state.json")), attempts: 4)
        try engine.adopt([
            NativeSpaceBinding(workspace: a.id.rawValue, name: a.name, project: "default", display: "left", space: 1, spaceUUID: "one"),
            NativeSpaceBinding(workspace: b.id.rawValue, name: b.name, project: "default", display: "right", space: 2, spaceUUID: "two"),
            NativeSpaceBinding(workspace: c.id.rawValue, name: c.name, project: "default", display: "left", space: 3, spaceUUID: "three"),
        ])
        try engine.configurePool(on: "left")
        try await engine.synchronize([
            NativeWorkspaceRequest(key: a.id.rawValue, name: a.name, project: "default", display: "left", visible: true, windows: [driver.identity(11)]),
            NativeWorkspaceRequest(key: b.id.rawValue, name: b.name, project: "default", display: "right", visible: true, windows: [driver.identity(12)]),
            NativeWorkspaceRequest(key: c.id.rawValue, name: c.name, project: "default", display: "left", visible: false, windows: [driver.identity(13)]),
        ], activate: ["left", "right"])
        NativeSpacesRuntime.shared.installForTests(engine, windows: [driver.identity(11), driver.identity(12), driver.identity(13)])
    }

    override func tearDown() async throws {
        NativeSpacesRuntime.shared.installForTests(nil)
        setMonitorsForTests(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func command(_ command: String) async throws {
        let result = try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
            try await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined(separator: "\n"))
    }

    func testNumericSelectionUsesSameGlobalPoolOnBothMonitors() async throws {
        XCTAssertEqual(workspaceDefaultDisplayName(c.name), "Workspace 2")
        XCTAssertEqual(workspaceDefaultDisplayName(b.name), "Workspace 3")
        try await command("workspace --monitor Secondary 2")
        XCTAssertTrue(main.activeWorkspace === a)
        XCTAssertTrue(secondary.activeWorkspace === c)
        XCTAssertEqual(driver.windows[13], [2])
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes[b.id.rawValue]!.space])
        XCTAssertEqual(workspaceDefaultDisplayName(c.name), "Workspace 2")
        try await command("workspace --monitor Main 3")
        XCTAssertTrue(main.activeWorkspace === b)
        XCTAssertTrue(secondary.activeWorkspace === c)
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes[b.id.rawValue]!.space])
    }

    func testSelectingNewSecondaryDesktopReusesCarrierAndAbsorbsWorkspaceIntoPool() async throws {
        let right = driver.snapshot.displays[1]
        driver.snapshot.displays[1] = NativeDisplaySnapshot(uuid: right.uuid, displayID: right.displayID,
            currentSpace: 8, spaces: right.spaces + [NativeDesktop(id: 8, uuid: "manual", isUser: true)])
        try NativeSpacesRuntime.shared.observeTopology()
        let adopted = try XCTUnwrap(engine.state.bindings.values.first { $0.spaceUUID == "manual" })
        XCTAssertEqual(engine.state.pool?.carriers["right"]?.id, 2)
        let workspace = try XCTUnwrap(Workspace.existing(byName: adopted.name))
        XCTAssertTrue(secondary.activeWorkspace === workspace)
        _ = TestWindow.new(id: 99, parent: workspace.rootTilingContainer)
        driver.windows[99] = [8]
        driver.identities[99] = driver.identity(99)
        NativeSpacesRuntime.shared.installForTests(engine, windows: [11, 12, 13, 99].map { driver.identity($0) })
        try await NativeSpacesRuntime.shared.synchronize()
        XCTAssertEqual(engine.state.bindings[workspace.id.rawValue]?.space, 2)
        XCTAssertEqual(driver.snapshot.display("right")?.currentSpace, 2)
        XCTAssertEqual(driver.snapshot.display("right")?.spaces.filter(\.isUser).count, 1)
        XCTAssertNotNil(engine.state.pool?.homes[workspace.id.rawValue])
        XCTAssertNil(driver.snapshot.desktop(8))
        XCTAssertEqual(driver.windows[99], [2])
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes[b.id.rawValue]!.space])
    }

    func testHiddenOwnedOriginSurvivesBeforeAccessibilityWindowsAreDiscovered() throws {
        engine.state.pool?.retained.remove(c.id.rawValue)
        engine.state.ownedSpaces.append(NativeOwnedSpace(id: 3, uuid: "three", display: "left"))
        _ = Window.get(byId: 13)?.unbindFromParent()
        XCTAssertFalse(workspaceHasLifecycleWindows(c))
        XCTAssertEqual(driver.windows[13], [3])
        XCTAssertTrue(NativeSpacesRuntime.shared.retainsExternalDesktop(c))
        XCTAssertTrue(workspaceShouldSurviveReconciliation(c, retainedEmptyWorkspaceIds: [:]))
        pruneEmptyWorkspaces()
        XCTAssertTrue(Workspace.existing(byName: c.name) === c)
        driver.windows[13] = []
        XCTAssertFalse(NativeSpacesRuntime.shared.retainsExternalDesktop(c))
    }

    func testExplicitNumericNamesDisplayGlobalIndexButCustomLabelsSurvive() {
        c.restoreNamingStyle(.explicit)
        XCTAssertEqual(workspaceDefaultDisplayName(c.name), "Workspace 2")
        XCTAssertTrue(usesNativePoolNumber(c))
        XCTAssertEqual(menuWorkspaceTargets().first { $0.workspace === c }?.target, "2")
        config.workspaceSidebar.workspaceLabels[c.name] = "Research"
        XCTAssertEqual(workspaceDisplayName(c.name), "Research")
        config.workspaceSidebar.workspaceLabels.removeValue(forKey: c.name)
    }

    func testRetiredUnownedPrincipalDesktopIsAdoptedWithoutNumberingGap() throws {
        let display = driver.snapshot.displays[0]
        driver.snapshot.displays[0] = NativeDisplaySnapshot(uuid: display.uuid, displayID: display.displayID,
            currentSpace: display.currentSpace, spaces: [display.spaces[0], NativeDesktop(id: 8, uuid: "returned", isUser: true)] + Array(display.spaces.dropFirst()))
        engine.state.pool?.retiredUUIDs.insert("returned")
        driver.actions = []
        try NativeSpacesRuntime.shared.observeTopology()
        let binding = try XCTUnwrap(engine.state.bindings.values.first { $0.spaceUUID == "returned" })
        let workspace = try XCTUnwrap(Workspace.existing(byName: binding.name))
        XCTAssertEqual(NativeSpacesRuntime.shared.desktopIndex(workspace), 2)
        XCTAssertEqual(NativeSpacesRuntime.shared.desktopIndex(c), 3)
        XCTAssertFalse(engine.state.pool!.retiredUUIDs.contains("returned"))
        XCTAssertTrue(driver.actions.isEmpty)
        let count = engine.state.bindings.count
        try NativeSpacesRuntime.shared.observeTopology()
        XCTAssertEqual(engine.state.bindings.count, count)
    }

    func testRetiredOwnedStagingDesktopIsNotAdopted() throws {
        let display = driver.snapshot.displays[0]
        driver.snapshot.displays[0] = NativeDisplaySnapshot(uuid: display.uuid, displayID: display.displayID,
            currentSpace: display.currentSpace, spaces: display.spaces + [NativeDesktop(id: 8, uuid: "staging", isUser: true)])
        engine.state.pool?.retiredUUIDs.insert("staging")
        engine.state.ownedSpaces.append(NativeOwnedSpace(id: 8, uuid: "staging", display: "left"))
        try NativeSpacesRuntime.shared.observeTopology()
        XCTAssertNil(engine.state.bindings.values.first { $0.spaceUUID == "staging" })
    }

    func testOrdinarySelectionFollowsAlreadyVisibleWorkspaceWithoutSwap() async throws {
        driver.actions = []
        try await command("workspace --monitor Main 3")
        XCTAssertTrue(main.activeWorkspace === a)
        XCTAssertTrue(secondary.activeWorkspace === b)
        XCTAssertTrue(focus.workspace === b)
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") || $0.hasPrefix("create:") })
    }

    func testExplicitMoveFocusesIncomingWhenItHidesThePreviouslyFocusedWorkspace() async throws {
        _ = b.focusWorkspace()
        try await command("move-workspace-to-monitor --workspace 1 Secondary")
        XCTAssertTrue(secondary.activeWorkspace === a)
        XCTAssertFalse(b.isVisible)
        XCTAssertTrue(focus.workspace === a)
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes[b.id.rawValue]!.space])
        // A delayed AX focus event from the outgoing window cannot reselect it.
        updateFocusCache(Window.get(byId: 12))
        XCTAssertTrue(focus.workspace === a)
        XCTAssertFalse(b.isVisible)
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertTrue(secondary.activeWorkspace === a)
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes[b.id.rawValue]!.space])
    }

    func testMissionControlSelectingBorrowedHomePerformsOverride() async throws {
        let homeB = engine.state.pool!.homes[b.id.rawValue]!.space
        try await driver.activate(homeB, on: "left")
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertTrue(main.activeWorkspace === b)
        XCTAssertTrue(secondary.activeWorkspace === a)
        XCTAssertEqual(driver.windows[12], [homeB])
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertTrue(focus.workspace === b)
        XCTAssertNil(engine.state.pending)
    }

    func testFailedBorrowedHomeOverrideRestoresBothViewportsAndNativeDesktops() async throws {
        let homeB = engine.state.pool!.homes[b.id.rawValue]!.space
        try await driver.activate(homeB, on: "left")
        driver.failMoveNumber = driver.moveCount + 2
        do {
            try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {}
            XCTFail("partial swap must fail")
        } catch {}
        XCTAssertTrue(main.activeWorkspace === a)
        XCTAssertTrue(secondary.activeWorkspace === b)
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(driver.snapshot.display("left")?.currentSpace, 1)
    }

    func testMoveWindowNumbersUseGlobalPoolAndReturnTheWindowToItsHome() async throws {
        try await command("move-node-to-workspace --window-id 11 3")
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertTrue(Window.get(byId: 11)?.nodeWorkspace === b)
        try await command("move-node-to-workspace --window-id 11 1")
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertTrue(Window.get(byId: 11)?.nodeWorkspace === a)
    }
}
