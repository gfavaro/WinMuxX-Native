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

    func testOrdinarySelectionFollowsAlreadyVisibleWorkspaceWithoutSwap() async throws {
        driver.actions = []
        try await command("workspace --monitor Main 3")
        XCTAssertTrue(main.activeWorkspace === a)
        XCTAssertTrue(secondary.activeWorkspace === b)
        XCTAssertTrue(focus.workspace === b)
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") || $0.hasPrefix("create:") })
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
