import Foundation

@MainActor
final class NativeSpaceStore {
    let url: URL
    var beforeSaveForTests: (() throws -> Void)?

    init(url: URL) { self.url = url }

    func load(bootID: String) throws -> NativeSpaceState {
        guard FileManager.default.fileExists(atPath: url.path) else { return NativeSpaceState(bootID: bootID) }
        let state = try JSONDecoder().decode(NativeSpaceState.self, from: Data(contentsOf: url))
        guard state.version == 1 || state.version == 2 else { throw NativeSpaceError.recoveryRequired("unsupported journal version") }
        if let pool = state.pool {
            let homeUUIDs = pool.homes.values.map(\.spaceUUID)
            guard Set(pool.order).count == pool.order.count,
                  !homeUUIDs.contains(""), Set(homeUUIDs).count == homeUUIDs.count,
                  pool.carriers.values.allSatisfy({ !$0.uuid.isEmpty }),
                  state.bindings.values.allSatisfy({ !$0.spaceUUID.isEmpty }) else {
                throw NativeSpaceError.recoveryRequired("ambiguous global pool identities")
            }
        }
        // IDs and ownership cannot be trusted across a system reboot.
        guard state.bootID == bootID else {
            guard state.pool != nil else { return NativeSpaceState(bootID: bootID) }
            var restarted = state
            restarted.bootID = bootID
            restarted.ownedSpaces = []
            restarted.pending = nil
            restarted.deleting = nil
            return restarted // Resolve UUIDs again; never trust numeric IDs from the old boot.
        }
        return state
    }

    func backupForPoolMigration() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("native-spaces.v1-backup.json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try Data(contentsOf: url).write(to: backup, options: .atomic)
        let handle = try FileHandle(forWritingTo: backup)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func save(_ state: NativeSpaceState) throws {
        try beforeSaveForTests?()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        // Atomic replacement is followed by fsync so a dispatched move doesn't outrun its intent.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
