@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class WindowRecoveryJournalTest: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("recovery-journal.json") }
    private let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let owner = RecoveryJournalOwner(pid: 4000, bundleId: "test.winmux", applicationLaunchDate: Date(timeIntervalSince1970: 100))
    private let identity = RecoveryWindowIdentity(windowId: 10, pid: 5000, bundleId: "test.editor", applicationLaunchDate: Date(timeIntervalSince1970: 50))

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WinMuxRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func journal(isOwnerAlive: Bool = false) -> WindowRecoveryJournal {
        WindowRecoveryJournal(url: url, owner: owner, isOwnerAlive: { _ in isOwnerAlive })
    }

    func testOriginalFrameIsPersistedBeforeMutationAndNotReplaced() throws {
        let store = journal()
        store.record(identity: identity, originalFrame: frame)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.record(identity: identity, originalFrame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let restarted = journal()
        XCTAssertEqual(restarted.recoverableEntries(liveIdentities: [identity]).first?.originalFrame, frame)
    }

    func testCurrentSessionDoesNotOfferItsOwnEntriesAsCrashRecovery() {
        let store = journal()
        store.record(identity: identity, originalFrame: frame)
        XCTAssertTrue(store.recoverableEntries(liveIdentities: [identity]).isEmpty)
    }

    func testProcessAndWindowIdReuseDoesNotRecoverAnotherApp() {
        journal().record(identity: identity, originalFrame: frame)
        let restarted = journal()
        let differentApp = RecoveryWindowIdentity(windowId: identity.windowId, pid: 6000, bundleId: "test.other", applicationLaunchDate: identity.applicationLaunchDate)
        let restartedApp = RecoveryWindowIdentity(windowId: identity.windowId, pid: identity.pid, bundleId: identity.bundleId, applicationLaunchDate: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(restarted.recoverableEntries(liveIdentities: [differentApp, restartedApp]).isEmpty)
        XCTAssertEqual(restarted.recoverableEntries(liveIdentities: [identity]).count, 1)
    }

    func testNewOwnerOfReusedWindowIdGetsNewOriginalFrame() {
        journal().record(identity: identity, originalFrame: frame)
        let restarted = journal()
        let newIdentity = RecoveryWindowIdentity(windowId: identity.windowId, pid: 6000, bundleId: "test.other", applicationLaunchDate: identity.applicationLaunchDate)
        let newFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        restarted.record(identity: newIdentity, originalFrame: newFrame)
        XCTAssertEqual(restarted.entries[identity.windowId]?.originalFrame, newFrame)
        XCTAssertTrue(restarted.carriedIds.isEmpty)
    }

    func testLiveSessionJournalIsNeverOverwritten() throws {
        journal().record(identity: identity, originalFrame: frame)
        let previousData = try Data(contentsOf: url)
        let otherSession = journal(isOwnerAlive: true)
        XCTAssertFalse(otherSession.canWrite)
        otherSession.record(identity: identity, originalFrame: .zero)
        otherSession.finishCleanly()
        XCTAssertEqual(try Data(contentsOf: url), previousData)
    }

    func testCorruptJournalIsPreserved() throws {
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let store = journal()
        XCTAssertFalse(store.canWrite)
        XCTAssertNotNil(store.lastError)
        store.record(identity: identity, originalFrame: frame)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnsupportedVersionIsPreserved() throws {
        journal().record(identity: identity, originalFrame: frame)
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        file["version"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: file)
        try unsupported.write(to: url)
        let store = journal()
        XCTAssertFalse(store.canWrite)
        store.finishCleanly()
        XCTAssertEqual(try Data(contentsOf: url), unsupported)
    }

    func testOnlySuccessfulOrClosedWindowsAreForgotten() {
        journal().record(identity: identity, originalFrame: frame)
        let restarted = journal()
        let staleIdentity = RecoveryWindowIdentity(windowId: identity.windowId, pid: 6000, bundleId: "test.other", applicationLaunchDate: identity.applicationLaunchDate)
        restarted.forget(staleIdentity)
        XCTAssertEqual(restarted.recoverableEntries(liveIdentities: [identity]).count, 1)
        restarted.forget(identity)
        XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanQuitKeepsUnresolvedPreviousCrashButDropsCurrentEntries() {
        journal().record(identity: identity, originalFrame: frame)
        let restarted = journal()
        let current = RecoveryWindowIdentity(windowId: 11, pid: identity.pid, bundleId: identity.bundleId, applicationLaunchDate: identity.applicationLaunchDate)
        restarted.record(identity: current, originalFrame: frame)
        restarted.finishCleanly()
        let next = journal()
        XCTAssertEqual(next.recoverableEntries(liveIdentities: [identity, current]).map { $0.identity.windowId }, [10])
    }

    func testCleanQuitPreservesFailedCurrentWindowAndOlderEntries() {
        journal().record(identity: identity, originalFrame: frame)
        let store = journal()
        let failed = RecoveryWindowIdentity(windowId: 11, pid: 5000, bundleId: "test.editor", applicationLaunchDate: identity.applicationLaunchDate)
        let restored = RecoveryWindowIdentity(windowId: 12, pid: 5000, bundleId: "test.editor", applicationLaunchDate: identity.applicationLaunchDate)
        store.record(identity: failed, originalFrame: frame)
        store.record(identity: restored, originalFrame: frame)
        store.finishCleanly(preserving: [failed])
        XCTAssertEqual(journal().recoverableEntries(liveIdentities: [identity, failed, restored]).map(\.identity.windowId), [10, 11])
    }

    func testInvalidOriginalFrameIsNotJournaled() {
        let store = journal()
        store.record(identity: identity, originalFrame: .zero)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisconnectedDisplayIsSkippedWithoutChangingOriginalGeometry() {
        let original = CGRect(x: -1800, y: 50, width: 800, height: 600)
        XCTAssertFalse(recoveryFrameIntersectsDisplay(original, displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]))
        XCTAssertTrue(recoveryFrameIntersectsDisplay(original, displays: [CGRect(x: -1920, y: 0, width: 1920, height: 1080)]))
    }

    func testReadbackMustMatchOriginalFrame() {
        XCTAssertTrue(recoveryFrameMatches(actual: frame.offsetBy(dx: 1, dy: -1), expected: frame))
        XCTAssertFalse(recoveryFrameMatches(actual: CGRect(x: 100, y: 200, width: 400, height: 600), expected: frame))
    }
}
