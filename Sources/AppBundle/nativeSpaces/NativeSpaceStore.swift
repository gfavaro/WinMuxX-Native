import Foundation

@MainActor
final class NativeSpaceStore {
    let url: URL
    var beforeSaveForTests: (() throws -> Void)?

    init(url: URL) { self.url = url }

    func load(bootID: String) throws -> NativeSpaceState {
        guard FileManager.default.fileExists(atPath: url.path) else { return NativeSpaceState(bootID: bootID) }
        let state = try JSONDecoder().decode(NativeSpaceState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw NativeSpaceError.recoveryRequired("unsupported journal version") }
        // IDs and ownership cannot be trusted across a system reboot.
        guard state.bootID == bootID else { return NativeSpaceState(bootID: bootID) }
        return state
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
