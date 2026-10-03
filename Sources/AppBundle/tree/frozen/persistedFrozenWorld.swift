import Common
import Foundation

private let persistedFrozenWorldVersion = 2
private let persistedFrozenWorldFilename = "native-window-state.json"
@MainActor private var pendingPersistedFrozenWorld: FrozenWorld? = nil
@MainActor private var didRestorePersistedFrozenWorldDuringCurrentSession = false
@MainActor private var lastSavedNativeWorldData: Data?

private struct PersistedFrozenWorldEnvelope: Codable {
    let version: Int
    let world: FrozenWorld
}

@MainActor
private func persistedFrozenWorldUrl() throws -> URL {
    let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true,
    )
    let directory = appSupport.appendingPathComponent(winMuxAppSupportDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(persistedFrozenWorldFilename, isDirectory: false)
}

@MainActor
func persistFrozenWorldForRestartIfPossible() {
    do {
        let url = try persistedFrozenWorldUrl()
        let world = snapshotCurrentFrozenWorld()
        guard !world.windowIds.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder.winMuxDefault.encode(
            PersistedFrozenWorldEnvelope(version: persistedFrozenWorldVersion, world: world),
        )
        guard data != lastSavedNativeWorldData || !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
        lastSavedNativeWorldData = data
    } catch {
        // Best effort. Failure to save restart state must not block termination.
    }
}

@discardableResult
@MainActor
func loadPersistedFrozenWorldForStartupIfPresent() -> Bool {
    do {
        let url = try persistedFrozenWorldUrl()
        // A persisted tiling tree would otherwise resize every existing window before the
        // new-window policy gets a chance to keep it floating.
        guard config.automaticallyTileNewWindows else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(PersistedFrozenWorldEnvelope.self, from: data)
        guard envelope.version == persistedFrozenWorldVersion else { return false }
        pendingPersistedFrozenWorld = envelope.world
        didRestorePersistedFrozenWorldDuringCurrentSession = false
        return true
    } catch {
        return false
    }
}

@MainActor
func restorePersistedFrozenWorldIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    guard let pendingPersistedFrozenWorld else { return false }
    let didRestore = try await restoreFrozenWorldIfNeeded(pendingPersistedFrozenWorld, newlyDetectedWindow: newlyDetectedWindow)
    if didRestore {
        // Old restart state may contain tiles roots from before dwindle was enabled.
        if applyDwindleToExistingTiledWorkspaces() { syncClosedWindowsCacheToCurrentWorld() }
        didRestorePersistedFrozenWorldDuringCurrentSession = true
    }
    return didRestore
}

@MainActor
func finalizePersistedFrozenWorldAfterRefresh(aliveWindowIds: Set<UInt32>) {
    guard let world = pendingPersistedFrozenWorld else { return }
    let knownWindowIds = Set(MacWindow.allWindowsMap.keys)
    if world.windowIds.isSubset(of: knownWindowIds) ||
        (didRestorePersistedFrozenWorldDuringCurrentSession &&
            !world.windowIds.isSubset(of: aliveWindowIds))
    {
        pendingPersistedFrozenWorld = nil
        didRestorePersistedFrozenWorldDuringCurrentSession = false
        if !NativeSpacesRuntime.shared.isNative { try? FileManager.default.removeItem(at: persistedFrozenWorldUrl()) }
    }
}
