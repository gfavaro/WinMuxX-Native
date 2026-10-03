import Foundation

struct NativeDesktop: Equatable, Codable, Sendable {
    let id: UInt64
    let uuid: String
    let isUser: Bool
}

struct NativeDisplaySnapshot: Equatable, Sendable {
    let uuid: String
    let displayID: UInt32
    let currentSpace: UInt64
    let spaces: [NativeDesktop]
}

struct NativeSpaceTopology: Equatable, Sendable {
    var displays: [NativeDisplaySnapshot]

    func display(_ uuid: String) -> NativeDisplaySnapshot? { displays.first { $0.uuid == uuid } }
    func desktop(_ id: UInt64) -> NativeDesktop? { displays.flatMap(\.spaces).first { $0.id == id } }
    func displayContaining(_ id: UInt64) -> NativeDisplaySnapshot? { displays.first { $0.spaces.contains { $0.id == id } } }
}

struct NativeWindowIdentity: Hashable, Codable, Sendable {
    let id: UInt32
    let pid: Int32
    let launchDate: Date
}

struct NativeWorkspaceRequest: Sendable {
    let key: String
    let name: String
    let project: String
    let display: String
    let visible: Bool
    let windows: [NativeWindowIdentity]
    var namingStyle: WorkspaceNamingStyle = .automatic
}

struct NativeSpaceBinding: Equatable, Codable, Sendable {
    let workspace: String
    var name: String
    var project: String
    var display: String
    var space: UInt64
    var spaceUUID: String = ""
    var namingStyle: WorkspaceNamingStyle = .automatic
}

struct NativeOwnedSpace: Equatable, Codable, Sendable {
    let id: UInt64
    let uuid: String
    let display: String
}

struct NativeWindowTransfer: Equatable, Codable, Sendable {
    let window: NativeWindowIdentity
    let source: UInt64
    let destination: UInt64
    var confirmed: Bool = false
    var sourceUUID: String = ""
}

struct NativeSpaceTransaction: Codable, Sendable {
    var originalBindings: [String: NativeSpaceBinding]
    var originalActiveSpaces: [String: UInt64]
    var transfers: [NativeWindowTransfer] = []
    // Persist before dispatching create; a crash before receiving its ID must never claim
    // an arbitrary new desktop as owned. Such an orphan is left for the user.
    var creatingOnDisplay: String?
    var createdSpaces: [NativeOwnedSpace] = []
}

struct NativeSpaceState: Codable, Sendable {
    var version = 1
    var bootID: String
    var bindings: [String: NativeSpaceBinding] = [:]
    var ownedSpaces: [NativeOwnedSpace] = []
    var pending: NativeSpaceTransaction?
    var deleting: NativeOwnedSpace?
}

enum NativeSpaceError: LocalizedError {
    case unavailable(String)
    case topology(String)
    case timedOut(String)
    case unsafeWindow(UInt32)
    case recoveryRequired(String)

    var errorDescription: String? {
        switch self {
            case .unavailable(let message): "Native Spaces unavailable: \(message)"
            case .topology(let message): "Native Spaces topology changed: \(message)"
            case .timedOut(let message): "Native Spaces did not confirm \(message)."
            case .unsafeWindow(let id): "Window \(id) has unknown, shared, or fullscreen Space membership; transfer stopped."
            case .recoveryRequired(let message): "Native Spaces recovery required: \(message)"
        }
    }
}

@MainActor
protocol NativeSpaceDriver: AnyObject {
    var bootID: String { get }
    func topology() throws -> NativeSpaceTopology
    func memberships(_ window: UInt32) throws -> [UInt64]
    func occupants(_ space: UInt64) throws -> [UInt32]
    func isAlive(_ window: NativeWindowIdentity) throws -> Bool
    func create(on display: String) async throws -> UInt64
    func move(_ windows: [UInt32], to space: UInt64) async throws
    func activate(_ space: UInt64, on display: String) async throws
    func destroy(_ space: UInt64) async throws
    func pause() async throws
}

// Only reverse migrations of two visible workspaces are swaps. Ordinary hidden
// transfers always get their own empty destination and preserve the outgoing desktop.
enum NativeSpacePlanner {
    static func swapPairs(requests: [NativeWorkspaceRequest], bindings: [String: NativeSpaceBinding]) -> [(String, String)] {
        var used: Set<String> = []
        var result: [(String, String)] = []
        for a in requests.sorted(by: { $0.key < $1.key }) where a.visible && !used.contains(a.key) {
            guard let oldA = bindings[a.key], oldA.display != a.display,
                  let b = requests.first(where: {
                      guard $0.visible, $0.key != a.key, !used.contains($0.key), let oldB = bindings[$0.key] else { return false }
                      return oldB.display == a.display && oldB.display != $0.display && $0.display == oldA.display
                  }) else { continue }
            used.formUnion([a.key, b.key])
            result.append((a.key, b.key))
        }
        return result
    }

    static func canCollect(_ owned: NativeOwnedSpace, state: NativeSpaceState, topology: NativeSpaceTopology, occupants: [UInt32]) -> Bool {
        guard !owned.uuid.isEmpty,
              let desktop = topology.desktop(owned.id), desktop.isUser, desktop.uuid == owned.uuid,
              let display = topology.displayContaining(owned.id), display.uuid == owned.display,
              display.currentSpace != owned.id,
              display.spaces.filter(\.isUser).count > 1,
              !state.bindings.values.contains(where: { $0.space == owned.id }),
              occupants.isEmpty,
              state.pending == nil else { return false }
        return true
    }
}
