@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class FakeNativeSpaceDriver: NativeSpaceDriver {
    let bootID = "test-boot"
    var snapshot = NativeSpaceTopology(displays: [
        NativeDisplaySnapshot(uuid: "left", displayID: 1, currentSpace: 1, spaces: [NativeDesktop(id: 1, uuid: "one", isUser: true), NativeDesktop(id: 3, uuid: "three", isUser: true)]),
        NativeDisplaySnapshot(uuid: "right", displayID: 2, currentSpace: 2, spaces: [NativeDesktop(id: 2, uuid: "two", isUser: true)]),
    ])
    var windows: [UInt32: [UInt64]] = [11: [1], 12: [2], 13: [3]]
    var identities: [UInt32: NativeWindowIdentity] = [:]
    var actions: [String] = []
    var nextID: UInt64 = 100
    var moveCount = 0
    var failMoveNumber: Int?
    var acknowledgeWithoutMoving = false
    var delayedMoves = false
    var queued: [([UInt32], UInt64)] = []
    var beforeMove: (() throws -> Void)?
    var beforeDestroy: (() -> Void)?
    var activationFailure: UInt64?
    var onPause: (() -> Void)?

    init() {
        for id: UInt32 in [11, 12, 13] { identities[id] = identity(id) }
    }

    func identity(_ id: UInt32) -> NativeWindowIdentity { NativeWindowIdentity(id: id, pid: Int32(id + 100), launchDate: Date(timeIntervalSince1970: 1)) }
    func topology() throws -> NativeSpaceTopology { snapshot }
    func memberships(_ window: UInt32) throws -> [UInt64] { windows[window] ?? [] }
    func occupants(_ space: UInt64) throws -> [UInt32] { windows.filter { $0.value == [space] }.map(\.key) }
    func isAlive(_ window: NativeWindowIdentity) throws -> Bool { identities[window.id] == window && windows[window.id] != nil }

    func create(on display: String) async throws -> UInt64 {
        actions.append("create:\(display)")
        let id = nextID
        nextID += 1
        snapshot.displays = snapshot.displays.map { item in
            guard item.uuid == display else { return item }
            return NativeDisplaySnapshot(uuid: item.uuid, displayID: item.displayID, currentSpace: item.currentSpace,
                                         spaces: item.spaces + [NativeDesktop(id: id, uuid: "created-\(id)", isUser: true)])
        }
        return id
    }

    func move(_ ids: [UInt32], to space: UInt64) async throws {
        try beforeMove?()
        moveCount += 1
        actions.append("move:\(ids.map(String.init).joined(separator: ","))->\(space)")
        if failMoveNumber == moveCount {
            // A dispatcher can report failure after moving only part of a batch.
            if let first = ids.first { windows[first] = [space] }
            throw NativeSpaceError.timedOut("simulated partial move")
        }
        if acknowledgeWithoutMoving { return }
        if delayedMoves { queued.append((ids, space)); return }
        for id in ids { windows[id] = [space] }
    }

    func activate(_ space: UInt64, on display: String) async throws {
        if activationFailure == space { throw NativeSpaceError.timedOut("simulated activation") }
        actions.append("activate:\(space)@\(display)")
        snapshot.displays = snapshot.displays.map { item in
            guard item.uuid == display else { return item }
            return NativeDisplaySnapshot(uuid: item.uuid, displayID: item.displayID, currentSpace: space, spaces: item.spaces)
        }
    }

    func destroy(_ space: UInt64) async throws {
        beforeDestroy?()
        actions.append("destroy:\(space)")
        snapshot.displays = snapshot.displays.map { item in
            NativeDisplaySnapshot(uuid: item.uuid, displayID: item.displayID, currentSpace: item.currentSpace, spaces: item.spaces.filter { $0.id != space })
        }
    }

    func pause() async throws {
        onPause?()
        await Task.yield()
        if !queued.isEmpty {
            let (ids, space) = queued.removeFirst()
            for id in ids { windows[id] = [space] }
        }
    }
}

@MainActor
private final class NativeGateCounter { var active = 0; var maximum = 0 }

@MainActor
final class NativeSpaceCoordinatorTest: XCTestCase {
    private var activeCount = 0
    private var maxCount = 0
    private var directory: URL!
    private var driver: FakeNativeSpaceDriver!
    private var store: NativeSpaceStore!
    private var engine: NativeSpaceCoordinator!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        driver = FakeNativeSpaceDriver()
        store = NativeSpaceStore(url: directory.appendingPathComponent("native-spaces.json"))
        engine = try NativeSpaceCoordinator(driver: driver, store: store, attempts: 4)
        try engine.adopt([
            binding("a", "left", 1), binding("b", "right", 2), binding("c", "left", 3),
        ])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func binding(_ key: String, _ display: String, _ space: UInt64) -> NativeSpaceBinding {
        NativeSpaceBinding(workspace: key, name: key.uppercased(), project: "default", display: display, space: space)
    }
    private func request(_ key: String, _ display: String, _ visible: Bool, _ ids: [UInt32]) -> NativeWorkspaceRequest {
        NativeWorkspaceRequest(key: key, name: key.uppercased(), project: "default", display: display, visible: visible, windows: ids.map { driver.identity($0) })
    }
    private var baseline: [NativeWorkspaceRequest] {
        [request("a", "left", true, [11]), request("b", "right", true, [12]), request("c", "left", false, [13])]
    }

    func testHiddenTransferGetsEmptyDestinationAndPreservesOtherWorkspaces() async throws {
        try await engine.synchronize([request("a", "left", true, [11]), request("b", "right", false, [12]), request("c", "right", true, [13])], activate: ["right"])
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(driver.windows[13], [100])
        XCTAssertEqual(engine.state.bindings["c"]?.display, "right")
        XCTAssertEqual(driver.snapshot.display("right")?.currentSpace, 100)
        XCTAssertNotNil(driver.snapshot.desktop(3)) // unowned source preserved
        XCTAssertNil(engine.state.pending)
    }

    func testSwapUsesThreeConfirmedLegsAndPublishesBothBindingsTogether() async throws {
        driver.delayedMoves = true
        var observedBindings: [(UInt64?, UInt64?)] = []
        driver.onPause = { observedBindings.append((self.engine.state.bindings["a"]?.space, self.engine.state.bindings["b"]?.space)) }
        try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12]), request("c", "left", false, [13])], activate: ["left", "right"])
        XCTAssertEqual(Array(driver.actions.filter { $0.hasPrefix("move:") }.prefix(3)), ["move:11->100", "move:12->1", "move:11->2"])
        XCTAssertTrue(observedBindings.allSatisfy { $0.0 == 1 && $0.1 == 2 })
        XCTAssertEqual(engine.state.bindings["a"]?.space, 2)
        XCTAssertEqual(engine.state.bindings["b"]?.space, 1)
        XCTAssertEqual(driver.windows[11], [2])
        XCTAssertEqual(driver.windows[12], [1])
        XCTAssertTrue(driver.actions.contains("destroy:100"))
    }

    func testPartialSwapRollsEveryWindowBackToOriginalSource() async throws {
        driver.failMoveNumber = 2
        do {
            try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12]), request("c", "left", false, [13])], activate: ["left", "right"])
            XCTFail("partial move must fail")
        } catch {}
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertEqual(driver.windows[12], [2])
        XCTAssertEqual(engine.state.bindings["a"]?.space, 1)
        XCTAssertEqual(engine.state.bindings["b"]?.space, 2)
        XCTAssertNil(engine.state.pending)
        XCTAssertNotNil(driver.snapshot.desktop(100)) // retain until safe collection
    }

    func testAcknowledgementWithoutArrivalDoesNotCommitDestination() async throws {
        driver.acknowledgeWithoutMoving = true
        do {
            try await engine.synchronize([request("c", "right", true, [13])], activate: ["right"])
            XCTFail("unconfirmed move must time out")
        } catch {}
        XCTAssertEqual(driver.windows[13], [3])
        XCTAssertEqual(engine.state.bindings["c"]?.space, 3)
        XCTAssertNil(engine.state.pending)
    }

    func testJournalContainsIntentBeforeMoveIsDispatched() async throws {
        driver.beforeMove = {
            let persisted = try self.store.load(bootID: self.driver.bootID)
            XCTAssertNotNil(persisted.pending)
            XCTAssertTrue(persisted.pending!.transfers.contains { $0.window.id == 13 && $0.source == 3 && !$0.confirmed })
        }
        try await engine.synchronize([request("c", "right", true, [13])], activate: ["right"])
    }

    func testRestartRecoversDispatchedButUnconfirmedMove() async throws {
        var state = engine.state
        state.pending = NativeSpaceTransaction(originalBindings: state.bindings, originalActiveSpaces: ["left": 1, "right": 2], transfers: [NativeWindowTransfer(window: driver.identity(11), source: 1, destination: 3)])
        try store.save(state)
        driver.windows[11] = [3]
        let restarted = try NativeSpaceCoordinator(driver: driver, store: store)
        try await restarted.recover()
        XCTAssertEqual(driver.windows[11], [1])
        XCTAssertNil(try store.load(bootID: driver.bootID).pending)
    }

    func testRecoveryDoesNotMoveReusedWindowIDFromAnotherAppLaunch() async throws {
        var state = engine.state
        state.pending = NativeSpaceTransaction(originalBindings: state.bindings, originalActiveSpaces: [:], transfers: [NativeWindowTransfer(window: driver.identity(11), source: 1, destination: 3)])
        try store.save(state)
        driver.identities[11] = NativeWindowIdentity(id: 11, pid: 999, launchDate: Date())
        driver.windows[11] = [3]
        let restarted = try NativeSpaceCoordinator(driver: driver, store: store)
        try await restarted.recover()
        XCTAssertEqual(driver.windows[11], [3])
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
    }

    func testDisconnectedRecoverySourceRetainsJournalAndDoesNotGuessTarget() async throws {
        var state = engine.state
        state.pending = NativeSpaceTransaction(originalBindings: state.bindings, originalActiveSpaces: [:], transfers: [NativeWindowTransfer(window: driver.identity(11), source: 1, destination: 2)])
        try store.save(state)
        driver.snapshot.displays.removeAll { $0.uuid == "left" }
        driver.windows[11] = [2]
        let restarted = try NativeSpaceCoordinator(driver: driver, store: store)
        do { try await restarted.recover(); XCTFail("missing source must retain recovery") } catch {}
        XCTAssertNotNil(try store.load(bootID: driver.bootID).pending)
        XCTAssertTrue(driver.actions.isEmpty)
    }

    func testFullscreenTransferRejectedBeforeCreatingAnyDesktop() async throws {
        driver.snapshot.displays.append(NativeDisplaySnapshot(uuid: "full", displayID: 3, currentSpace: 50, spaces: [NativeDesktop(id: 50, uuid: "full", isUser: false)]))
        driver.windows[13] = [50]
        do { try await engine.synchronize([request("c", "right", true, [13])], activate: ["right"]); XCTFail("fullscreen transfer must stop") } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") || $0.hasPrefix("move:") })
    }

    func testSharedWindowMembershipNeverMovesWindowToOneWorkspace() async throws {
        driver.windows[13] = [1, 3]
        do { try await engine.synchronize(baseline, activate: []); XCTFail("shared membership must stop") } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("move:") })
    }

    func testUnknownAuxiliaryOccupantPreventsSwap() async throws {
        driver.windows[99] = [1]
        do {
            try await engine.synchronize([request("a", "right", true, [11]), request("b", "left", true, [12])], activate: ["left", "right"])
            XCTFail("foreign occupant must block swap")
        } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") || $0.hasPrefix("move:") })
        XCTAssertEqual(driver.windows[99], [1])
    }

    func testUnboundHiddenNPlusOneDoesNotCreateDesktopUntilVisible() async throws {
        var requests = baseline + [request("new", "left", false, [])]
        try await engine.synchronize(requests, activate: [])
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") })
        requests[3] = request("new", "left", true, [])
        try await engine.synchronize(requests, activate: ["left"])
        XCTAssertEqual(engine.state.bindings["new"]?.space, 100)
    }

    func testLeavingUnusedOwnedNPlusOneCollectsItWithoutDeletingExternalDesktops() async throws {
        try await engine.synchronize(baseline + [request("new", "left", true, [])], activate: ["left"])
        try await engine.synchronize(baseline, activate: ["left"])
        XCTAssertNil(driver.snapshot.desktop(100))
        for id: UInt64 in [1, 2, 3] { XCTAssertNotNil(driver.snapshot.desktop(id)) }
    }

    func testOccupiedOwnedDesktopIsRetained() async throws {
        let id = try await driver.create(on: "left")
        var state = engine.state
        state.ownedSpaces = [NativeOwnedSpace(id: id, uuid: "created-100", display: "left")]
        try store.save(state)
        driver.windows[90] = [id]
        let restarted = try NativeSpaceCoordinator(driver: driver, store: store)
        try await restarted.collectUnusedOwnedSpaces()
        XCTAssertNotNil(driver.snapshot.desktop(id))
        XCTAssertFalse(driver.actions.contains("destroy:100"))
    }

    func testReusedSpaceIDNeverGetsDeletedFromOldOwnershipRecord() async throws {
        var state = engine.state
        state.bindings = [:]
        state.ownedSpaces = [NativeOwnedSpace(id: 3, uuid: "other-uuid", display: "left")]
        try store.save(state)
        let restarted = try NativeSpaceCoordinator(driver: driver, store: store)
        try await restarted.collectUnusedOwnedSpaces()
        XCTAssertNotNil(driver.snapshot.desktop(3))
        XCTAssertTrue(restarted.state.ownedSpaces.isEmpty)
    }

    func testSystemRebootInvalidatesSpaceOwnershipAndPendingMoves() throws {
        var state = engine.state
        state.bootID = "older-boot"
        state.ownedSpaces = [NativeOwnedSpace(id: 3, uuid: "three", display: "left")]
        state.pending = NativeSpaceTransaction(originalBindings: state.bindings, originalActiveSpaces: [:])
        try store.save(state)
        let reloaded = try store.load(bootID: driver.bootID)
        XCTAssertTrue(reloaded.ownedSpaces.isEmpty)
        XCTAssertTrue(reloaded.bindings.isEmpty)
        XCTAssertNil(reloaded.pending)
    }

    func testStorageFailurePreventsNativeDispatch() async throws {
        store.beforeSaveForTests = { throw NativeSpaceError.unavailable("disk full") }
        do { try await engine.synchronize([request("c", "right", true, [13])], activate: ["right"]); XCTFail("write failure must stop") } catch {}
        XCTAssertFalse(driver.actions.contains { $0.hasPrefix("create:") || $0.hasPrefix("move:") })
    }

    func testCurrentOrLastDesktopCannotBeCollected() {
        var state = engine.state
        state.bindings = [:]
        let left = NativeOwnedSpace(id: 1, uuid: "one", display: "left")
        XCTAssertFalse(NativeSpacePlanner.canCollect(left, state: state, topology: driver.snapshot, occupants: []))
        let right = NativeOwnedSpace(id: 2, uuid: "two", display: "right")
        XCTAssertFalse(NativeSpacePlanner.canCollect(right, state: state, topology: driver.snapshot, occupants: []))
    }

    func testCancellingRequestDoesNotCancelShieldedNativeTransaction() async throws {
        driver.delayedMoves = true
        let requests = [request("c", "right", true, [13])]
        let task = Task { @MainActor in
            let operation = Task { @MainActor in try await self.engine.synchronize(requests, activate: ["right"]) }
            try await operation.value
        }
        task.cancel()
        try await task.value
        XCTAssertEqual(driver.windows[13], [100])
        XCTAssertNil(engine.state.pending)
    }

    func testSessionGateRunsQueuedRequestsInOrderWithoutOverlapping() async {
        let gate = NativeSpaceSessionGate()
        let counter = NativeGateCounter()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<5 {
            tasks.append(Task { @MainActor in
                await gate.acquire()
                counter.active += 1
                counter.maximum = max(counter.maximum, counter.active)
                await Task.yield()
                counter.active -= 1
                gate.release()
            })
        }
        for task in tasks { await task.value }
        XCTAssertEqual(counter.maximum, 1)
    }
}
