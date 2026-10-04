@testable import AppBundle
import Foundation
import NativeSpacesPrivate
import XCTest

@MainActor
final class NativeGlobalPoolTest: XCTestCase {
    private var directory: URL!
    private var driver: FakeNativeSpaceDriver!
    private var engine: NativeSpaceCoordinator!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        driver = FakeNativeSpaceDriver()
        engine = try NativeSpaceCoordinator(driver: driver, store: NativeSpaceStore(url: directory.appendingPathComponent("state.json")), attempts: 4)
        try engine.adopt([binding("a", "left", 1, "one"), binding("b", "right", 2, "two"), binding("c", "left", 3, "three")])
        try engine.configurePool(on: "left")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func binding(_ key: String, _ display: String, _ space: UInt64, _ uuid: String) -> NativeSpaceBinding {
        NativeSpaceBinding(workspace: key, name: key, project: "default", display: display, space: space, spaceUUID: uuid)
    }

    private func request(_ key: String, _ display: String, _ visible: Bool, _ windows: [UInt32]) -> NativeWorkspaceRequest {
        NativeWorkspaceRequest(key: key, name: key, project: "default", display: display, visible: visible, windows: windows.map { driver.identity($0) })
    }

    private var baseline: [NativeWorkspaceRequest] {
        [request("a", "left", true, [11]), request("b", "right", true, [12]), request("c", "left", false, [13])]
    }

    private func initialize() async throws { try await engine.synchronize(baseline, activate: ["left", "right"]) }

    func testNativeContentClassificationPreservesDocumentsAndAuxiliaries() {
        XCTAssertTrue(winmux_native_is_content_window(0, 1))
        XCTAssertTrue(winmux_native_is_content_window(0, (1 << 1) | (1 << 31)))
        XCTAssertTrue(winmux_native_is_content_window(12, 0))
        XCTAssertTrue(winmux_native_is_content_window(0, 0x300000100480001)) // hidden/minimized document
        XCTAssertFalse(winmux_native_is_content_window(0, 0x8004204000019400)) // wallpaper
        XCTAssertFalse(winmux_native_is_content_window(0, 0x12021000c2202)) // display dimmer
        XCTAssertFalse(winmux_native_is_content_window(0, 0x1400c0201)) // non-cycling Safari utility surface
        XCTAssertFalse(winmux_native_is_content_window(0, 0x8140000d000400)) // menu chrome
    }

    func testMalformedPoolIsRejectedBeforeRuntimeCanUseDuplicateIdentities() throws {
        var malformed = engine.state
        malformed.pool?.order.append("a")
        try engine.store.save(malformed)
        XCTAssertThrowsError(try engine.store.load(bootID: driver.bootID))
        malformed = engine.state
        malformed.pool?.homes["c"]?.spaceUUID = "one"
        try engine.store.save(malformed)
        XCTAssertThrowsError(try engine.store.load(bootID: driver.bootID))
    }

    func testMigrationReservesSecondaryOriginWithoutMovingVisibleWindows() async throws {
        try await initialize()
        XCTAssertEqual(engine.state.version, 2)
        let home = try XCTUnwrap(engine.state.pool?.homes["b"])
        XCTAssertEqual(home.display, "left")
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(engine.state.pool?.carriers["right"]?.id, 2)
        XCTAssertEqual(try engine.orderedPoolKeys(), ["a", "c", "b"])
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-spaces.v1-backup.json").path))
    }

    func testCarrierIsReusedAndOutgoingReturnsHomeAcrossRepeatedSelections() async throws {
        try await initialize()
        let homeB = try XCTUnwrap(engine.state.pool?.homes["b"]?.space)
        let count = driver.nextID
        driver.actions = []
        for _ in 0..<3 {
            try await engine.synchronize([request("a", "left", true, [11]), request("b", "left", false, [12]), request("c", "right", true, [13])], activate: ["right"])
            XCTAssertEqual(driver.windows[12], [homeB])
            XCTAssertEqual(driver.windows[13], [2])
            XCTAssertEqual(engine.state.pool?.homes["c"]?.space, 3)
            try await engine.synchronize(baseline, activate: ["right"])
        }
        XCTAssertEqual(driver.nextID, count)
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(driver.windows[13], [3])
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") || $0.hasPrefix("destroy:") })
    }

    func testThreeLegSwapNeverExchangesHomesAndCollectsOnlyStaging() async throws {
        try await initialize()
        let homes = engine.state.pool!.homes
        driver.actions = []
        try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12]), request("c", "left", false, [13])], activate: ["left", "right"])
        let moves = driver.actions.filter { $0.hasPrefix("move:") }
        XCTAssertEqual(moves.count, 3)
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertEqual(driver.windows[12], [homes["b"]!.space])
        XCTAssertEqual(engine.state.pool!.homes, homes)
        XCTAssertEqual(driver.actions.filter { $0.hasPrefix("create:") }, ["create:right"])
        XCTAssertEqual(driver.snapshot.displays.flatMap(\.spaces).count, 4)
        XCTAssertNil(engine.state.pending)
    }

    func testFailedSwapRollsBackWindowsHomesAndCarrierThenRecoversAfterRestart() async throws {
        try await initialize()
        let original = engine.state
        driver.failMoveNumber = driver.moveCount + 2
        do {
            try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12]), request("c", "left", false, [13])], activate: ["left", "right"])
            XCTFail("partial swap must fail")
        } catch {}
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(engine.state.pool, original.pool)
        XCTAssertEqual(engine.state.bindings, original.bindings)
        engine = try NativeSpaceCoordinator(driver: driver, store: engine.store, attempts: 4)
        try await engine.recover()
        XCTAssertNil(engine.state.pending)
        XCTAssertEqual(engine.state.pool, original.pool)
    }

    func testHiddenEmptyNPlusOneDoesNotMaterializeAndItsOwnedOriginIsCollected() async throws {
        try await initialize()
        let count = driver.nextID
        try await engine.synchronize(baseline + [request("n", "left", false, [])], activate: [])
        XCTAssertEqual(driver.nextID, count)
        XCTAssertNil(engine.state.pool?.homes["n"])
        try await engine.synchronize([request("a", "left", true, [11]), request("b", "left", false, [12]), request("c", "left", false, [13]), request("n", "right", true, [])], activate: ["right"])
        let origin = try XCTUnwrap(engine.state.pool?.homes["n"]?.space)
        XCTAssertEqual(engine.state.pool?.carriers["right"]?.id, 2)
        try await engine.synchronize(baseline, activate: ["right"])
        XCTAssertNil(driver.snapshot.desktop(origin))
        XCTAssertNotNil(driver.snapshot.desktop(3))
    }

    func testStablePoolDoesNotRewriteJournalOrDispatch() async throws {
        try await initialize()
        driver.actions = []
        var saves = 0
        engine.store.beforeSaveForTests = { saves += 1 }
        try await engine.synchronize(baseline, activate: ["left", "right"])
        XCTAssertTrue(driver.actions.isEmpty)
        XCTAssertEqual(saves, 0)
    }

    func testPoolFollowsRelocatedUUIDsAndReturnsToPreferredDisplay() async throws {
        try await initialize()
        let order = try engine.orderedPoolKeys()
        let left = driver.snapshot.displays[0], right = driver.snapshot.displays[1]
        driver.snapshot.displays = [NativeDisplaySnapshot(uuid: "right", displayID: 2, currentSpace: 1, spaces: right.spaces + left.spaces)]
        try await engine.synchronize([request("a", "right", true, [11]), request("b", "right", false, [12]), request("c", "right", false, [13])], activate: ["right"])
        XCTAssertEqual(engine.state.pool?.effectiveDisplay, "right")
        XCTAssertEqual(driver.windows[12], [engine.state.pool!.homes["b"]!.space])
        driver.snapshot.displays.append(NativeDisplaySnapshot(uuid: "left", displayID: 1, currentSpace: 50, spaces: [NativeDesktop(id: 50, uuid: "returned", isUser: true)]))
        try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", false, [12]), request("c", "left", false, [13])], activate: ["right"])
        XCTAssertEqual(engine.state.pool?.effectiveDisplay, "left")
        XCTAssertEqual(try engine.orderedPoolKeys(), order)
        XCTAssertTrue(engine.state.pool!.homes.values.allSatisfy { $0.display == "left" })
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(engine.state.pool?.carriers["right"]?.id, 1)
    }

    func testUnchangedCarrierMayKeepAuxiliaryOccupantsButCannotBeReassigned() async throws {
        driver.windows[99] = [2]
        try await initialize()
        XCTAssertEqual(driver.windows[99], [2])
        driver.actions = []
        do {
            try await engine.synchronize([request("a", "left", true, [11]), request("b", "left", false, [12]), request("c", "right", true, [13])], activate: ["right"])
            XCTFail("auxiliary occupant must prevent carrier reassignment")
        } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
    }

    func testUntrackedDestinationAndDiskFailurePreventWindowDispatch() async throws {
        try await initialize()
        driver.windows[99] = [2]
        driver.actions = []
        do {
            try await engine.synchronize([request("a", "left", true, [11]), request("b", "left", false, [12]), request("c", "right", true, [13])], activate: ["right"])
            XCTFail("unknown occupant must block reuse")
        } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
        driver.windows.removeValue(forKey: 99)
        engine.store.beforeSaveForTests = { throw NativeSpaceError.unavailable("disk full") }
        do {
            try await engine.synchronize([request("a", "left", true, [11]), request("b", "left", false, [12]), request("c", "right", true, [13])], activate: ["right"])
            XCTFail("intent must precede dispatch")
        } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
    }

    func testRestartRecoversUnconfirmedCarrierMoveFromPersistentIntent() async throws {
        try await initialize()
        let original = engine.state
        var interrupted = original
        interrupted.pending = NativeSpaceTransaction(originalBindings: original.bindings, originalActiveSpaces: ["left": 1, "right": 2], transfers: [NativeWindowTransfer(window: driver.identity(12), source: 2, destination: original.pool!.homes["b"]!.space, sourceUUID: "two")], originalPool: original.pool)
        try engine.store.save(interrupted)
        driver.windows[12] = [original.pool!.homes["b"]!.space]
        engine = try NativeSpaceCoordinator(driver: driver, store: engine.store, attempts: 4)
        try await engine.recover()
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(engine.state.pool, original.pool)
        XCTAssertNil(engine.state.pending)
    }

    func testFullscreenTransferStopsBeforeAllocationAndKeepsFullscreenAssociation() async throws {
        try await initialize()
        let left = driver.snapshot.displays[0]
        driver.snapshot.displays[0] = NativeDisplaySnapshot(uuid: left.uuid, displayID: left.displayID, currentSpace: 9, spaces: left.spaces + [NativeDesktop(id: 9, uuid: "fullscreen", isUser: false)])
        driver.windows[11] = [9]
        driver.actions = []
        do {
            try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12]), request("c", "left", false, [13])], activate: ["left", "right"])
            XCTFail("fullscreen cannot migrate")
        } catch {}
        XCTAssertEqual(driver.windows[11], [9])
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") || $0.hasPrefix("move:") })
    }

    func testBootChangeRetainsGlobalIdentityButDiscardsOwnershipAndTransactions() async throws {
        try await initialize()
        let reloaded = try engine.store.load(bootID: "next-boot")
        XCTAssertEqual(reloaded.pool?.order, engine.state.pool?.order)
        XCTAssertEqual(reloaded.pool?.homes, engine.state.pool?.homes)
        XCTAssertTrue(reloaded.ownedSpaces.isEmpty)
        XCTAssertNil(reloaded.pending)
        XCTAssertEqual(reloaded.bootID, "next-boot")
    }

    func testRekeyAfterRestartPreservesHomesAndGlobalNumbers() async throws {
        try await initialize()
        let homes = engine.state.pool!.homes
        let replacements = Dictionary(uniqueKeysWithValues: engine.state.bindings.values.map { binding in
            let key = "new-" + binding.workspace
            return (key, NativeSpaceBinding(workspace: key, name: binding.name, project: binding.project, display: binding.display, space: binding.space, spaceUUID: binding.spaceUUID, namingStyle: binding.namingStyle))
        })
        try engine.replaceBindings(replacements)
        XCTAssertEqual(try engine.orderedPoolKeys(), ["new-a", "new-c", "new-b"])
        XCTAssertEqual(engine.state.pool?.homes["new-b"]?.spaceUUID, homes["b"]?.spaceUUID)
        XCTAssertEqual(engine.state.pool?.active["right"], "new-b")
        XCTAssertEqual(engine.state.pool?.retained, ["new-a", "new-b", "new-c"])
    }

}
