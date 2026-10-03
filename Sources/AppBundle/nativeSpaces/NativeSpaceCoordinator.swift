import Foundation

/// Operates on observed topology, never on Mission Control's mutable numeric indices.
/// The caller serializes sessions. Once dispatch begins it runs in an unstructured task
/// so cancellation of a refresh cannot abandon a half-completed system operation.
@MainActor
final class NativeSpaceCoordinator {
    let driver: any NativeSpaceDriver
    let store: NativeSpaceStore
    private(set) var state: NativeSpaceState
    private(set) var collectionError: String?
    private let attempts: Int

    init(driver: any NativeSpaceDriver, store: NativeSpaceStore, attempts: Int = 80) throws {
        self.driver = driver
        self.store = store
        self.attempts = attempts
        state = try store.load(bootID: driver.bootID)
    }

    func adopt(_ bindings: [NativeSpaceBinding]) throws {
        guard state.pending == nil else { throw NativeSpaceError.recoveryRequired("pending transaction") }
        for binding in bindings { state.bindings[binding.workspace] = binding }
        try store.save(state)
    }

    func replaceBindings(_ bindings: [String: NativeSpaceBinding]) throws {
        guard state.pending == nil else { throw NativeSpaceError.recoveryRequired("pending transaction") }
        state.bindings = bindings
        try store.save(state)
    }

    func synchronize(_ requests: [NativeWorkspaceRequest], activate: Set<String>) async throws {
        if state.pending != nil { try await recover() }
        let topology = try driver.topology()
        guard !topology.displays.isEmpty else { throw NativeSpaceError.topology("no connected displays") }
        // Do not lose global identity simply because macOS moved a desktop to a different display.
        var bindings = state.bindings
        for (key, binding) in bindings {
            if let actual = topology.displayContaining(binding.space),
               binding.spaceUUID.isEmpty || topology.desktop(binding.space)?.uuid == binding.spaceUUID {
                bindings[key]?.display = actual.uuid
            } else {
                bindings.removeValue(forKey: key)
            }
        }
        let wanted = Set(requests.map(\.key))
        bindings = bindings.filter { wanted.contains($0.key) }
        // Stable refreshes neither write a journal nor dispatch a system mutation.
        let needsTransition = bindings != state.bindings || requests.contains { request in
            guard let binding = bindings[request.key] else { return request.visible || !request.windows.isEmpty }
            if binding.display != request.display || binding.name != request.name || binding.project != request.project || binding.namingStyle != request.namingStyle { return true }
            if request.visible && activate.contains(request.display) && topology.display(request.display)?.currentSpace != binding.space { return true }
            return request.windows.contains { window in
                guard (try? driver.isAlive(window)) == true else { return false }
                guard let membership = try? driver.memberships(window.id), membership.count == 1 else { return true }
                // A native fullscreen window stays on its dedicated Space while the rest of its workspace remains bound.
                return membership != [binding.space] && topology.desktop(membership[0])?.isUser != false
            }
        }
        if !needsTransition {
            if state.ownedSpaces.contains(where: { owned in !bindings.values.contains { $0.space == owned.id } }) {
                do { try await collectUnusedOwnedSpaces(); collectionError = nil }
                catch { collectionError = error.localizedDescription }
            }
            return
        }
        let oldBindings = state.bindings
        var changed = false
        state.pending = NativeSpaceTransaction(
            originalBindings: oldBindings,
            originalActiveSpaces: Dictionary(uniqueKeysWithValues: topology.displays.map { ($0.uuid, $0.currentSpace) })
        )
        // Preflight before creating a staging desktop or moving even the first window.
        do {
            for request in requests {
                guard topology.display(request.display) != nil else { throw NativeSpaceError.topology("display \(request.display) disconnected") }
                for window in request.windows where try driver.isAlive(window) {
                    let spaces = try driver.memberships(window.id)
                    guard spaces.count == 1 else { throw NativeSpaceError.unsafeWindow(window.id) }
                    if topology.desktop(spaces[0])?.isUser != true {
                        // Preserve native fullscreen windows on their existing dedicated Space.
                        guard let binding = bindings[request.key], binding.display == request.display else {
                            throw NativeSpaceError.unsafeWindow(window.id)
                        }
                    }
                }
            }
            try store.save(state)
            for (aKey, bKey) in NativeSpacePlanner.swapPairs(requests: requests, bindings: bindings) {
                guard let a = requests.first(where: { $0.key == aKey }),
                      let b = requests.first(where: { $0.key == bKey }),
                      let oldA = bindings[aKey], let oldB = bindings[bKey] else { continue }
                // All source occupants must belong to the respective tree. A foreign or
                // auxiliary window that wasn't registered must never be overwritten.
                let aIDs = Set(a.windows.map(\.id)), bIDs = Set(b.windows.map(\.id))
                guard Set(try driver.occupants(oldA.space)).isSubset(of: aIDs),
                      Set(try driver.occupants(oldB.space)).isSubset(of: bIDs) else {
                    throw NativeSpaceError.topology("swap source contains untracked windows")
                }
                let staging = try await createEmpty(on: oldA.display)
                try await transfer(a.windows, to: staging)
                try assertEmpty(oldA.space)
                try await transfer(b.windows, to: oldA.space)
                try assertEmpty(oldB.space)
                try await transfer(a.windows, to: oldB.space)
                bindings[aKey] = NativeSpaceBinding(workspace: aKey, name: a.name, project: a.project, display: a.display, space: oldB.space, spaceUUID: topology.desktop(oldB.space)?.uuid ?? "", namingStyle: a.namingStyle)
                bindings[bKey] = NativeSpaceBinding(workspace: bKey, name: b.name, project: b.project, display: b.display, space: oldA.space, spaceUUID: topology.desktop(oldA.space)?.uuid ?? "", namingStyle: b.namingStyle)
                changed = true
            }
            for request in requests {
                var binding = bindings[request.key]
                if binding == nil || binding?.display != request.display {
                    // An unbound, hidden, empty N+1 slot stays logical until requested.
                    if binding == nil && !request.visible && request.windows.isEmpty { continue }
                    let destination = try await createEmpty(on: request.display)
                    try await transfer(request.windows, to: destination)
                    binding = NativeSpaceBinding(workspace: request.key, name: request.name, project: request.project, display: request.display, space: destination, spaceUUID: try driver.topology().desktop(destination)?.uuid ?? "", namingStyle: request.namingStyle)
                    changed = true
                } else if let binding {
                    // Covers individual window moves and new windows routed by rules.
                    try await transfer(request.windows, to: binding.space, preserveFullscreen: true)
                }
                if var binding {
                    binding.name = request.name
                    binding.project = request.project
                    binding.namingStyle = request.namingStyle
                    bindings[request.key] = binding
                    if request.visible && activate.contains(request.display) {
                        let current = try driver.topology().display(request.display)?.currentSpace
                        if current == binding.space { continue }
                        try await driver.activate(binding.space, on: request.display)
                        try await wait("activation of Space \(binding.space)") {
                            try self.driver.topology().display(request.display)?.currentSpace == binding.space
                        }
                    }
                }
            }
            // Atomic publication of both swap bindings. The journal remains present
            // throughout every move and activation, including final arrival checks.
            var committed = state
            committed.bindings = bindings
            committed.pending = nil
            try store.save(committed)
            state = committed
        } catch {
            // A failed preflight has no system effects. Persisted or dispatched effects
            // are rolled back from the original per-window source, never assumed undone.
            state.bindings = oldBindings
            do { try await recover() }
            catch { throw NativeSpaceError.recoveryRequired(error.localizedDescription) }
            throw error
        }
        // Collection is independent from a committed transfer: failed collection retains
        // ownership for a later retry; it must not undo a successful workspace switch.
        if changed || state.ownedSpaces.contains(where: { owned in !state.bindings.values.contains { $0.space == owned.id } }) {
            do {
                try await collectUnusedOwnedSpaces()
                collectionError = nil
            } catch {
                collectionError = error.localizedDescription
            }
        }
    }

    private func createEmpty(on display: String) async throws -> UInt64 {
        state.pending?.creatingOnDisplay = display
        try store.save(state)
        let id = try await driver.create(on: display)
        try await wait("creation of Space \(id)") {
            try self.driver.topology().display(display)?.spaces.contains { $0.id == id && $0.isUser } == true
        }
        let topology = try driver.topology()
        guard let desktop = topology.desktop(id), desktop.isUser else { throw NativeSpaceError.topology("created Space missing") }
        let owned = NativeOwnedSpace(id: id, uuid: desktop.uuid, display: display)
        state.ownedSpaces.append(owned)
        state.pending?.createdSpaces.append(owned)
        state.pending?.creatingOnDisplay = nil
        try store.save(state)
        try assertEmpty(id)
        return id
    }

    private func transfer(_ windows: [NativeWindowIdentity], to destination: UInt64, preserveFullscreen: Bool = false) async throws {
        guard try driver.topology().desktop(destination)?.isUser == true else { throw NativeSpaceError.topology("destination is not a desktop") }
        var moving: [UInt32] = []
        var indices: [Int] = []
        for window in windows {
            guard try driver.isAlive(window) else { continue }
            let sources = try driver.memberships(window.id)
            guard sources.count == 1 else { throw NativeSpaceError.unsafeWindow(window.id) }
            let source = sources[0]
            if source == destination { continue }
            if try driver.topology().desktop(source)?.isUser != true {
                if preserveFullscreen { continue }
                throw NativeSpaceError.unsafeWindow(window.id)
            }
            indices.append(state.pending?.transfers.count ?? 0)
            state.pending?.transfers.append(NativeWindowTransfer(window: window, source: source, destination: destination, sourceUUID: try driver.topology().desktop(source)?.uuid ?? ""))
            moving.append(window.id)
        }
        guard !moving.isEmpty else { return }
        try store.save(state) // intent must reach disk before dispatch
        try await driver.move(moving, to: destination)
        for index in indices {
            guard let intent = state.pending?.transfers[index] else { throw NativeSpaceError.recoveryRequired("missing move intent") }
            try await wait("arrival of window \(intent.window.id)") {
                if try !self.driver.isAlive(intent.window) { return true }
                return try self.driver.memberships(intent.window.id) == [destination]
            }
            state.pending?.transfers[index].confirmed = true
            try store.save(state)
        }
    }

    private func assertEmpty(_ space: UInt64) throws {
        guard try driver.occupants(space).isEmpty else { throw NativeSpaceError.topology("destination Space \(space) is occupied") }
    }

    func recover() async throws {
        guard let transaction = state.pending else { return }
        var restored: Set<NativeWindowIdentity> = []
        for intent in transaction.transfers where restored.insert(intent.window).inserted {
            guard try driver.isAlive(intent.window) else { continue } // IDs are checked against PID and launch date.
            guard let original = try driver.topology().desktop(intent.source), original.isUser,
                  intent.sourceUUID.isEmpty || original.uuid == intent.sourceUUID else {
                throw NativeSpaceError.recoveryRequired("original Space \(intent.source) is unavailable; reconnect the original display before retrying")
            }
            let memberships = try driver.memberships(intent.window.id)
            guard memberships.count == 1, try driver.topology().desktop(memberships[0])?.isUser == true else {
                throw NativeSpaceError.unsafeWindow(intent.window.id)
            }
            if memberships != [intent.source] {
                try await driver.move([intent.window.id], to: intent.source)
                try await wait("recovery of window \(intent.window.id)") {
                    try !self.driver.isAlive(intent.window) || self.driver.memberships(intent.window.id) == [intent.source]
                }
            }
        }
        for (display, original) in transaction.originalActiveSpaces {
            let snapshot = try driver.topology()
            // Disconnected displays retain their journal; fullscreen originals are not
            // activated through a desktop-only recovery path.
            guard let connected = snapshot.display(display) else {
                if transaction.transfers.isEmpty { continue }
                throw NativeSpaceError.recoveryRequired("display \(display) disconnected")
            }
            guard connected.currentSpace != original, snapshot.desktop(original)?.isUser == true else { continue }
            try await driver.activate(original, on: display)
            try await wait("recovery activation") { try self.driver.topology().display(display)?.currentSpace == original }
        }
        state.bindings = transaction.originalBindings
        state.pending = nil
        try store.save(state)
    }

    func collectUnusedOwnedSpaces() async throws {
        let topology = try driver.topology()
        // Disappeared or reused IDs are forgotten, never destroyed on the strength of a numeric ID.
        state.ownedSpaces.removeAll { owned in
            guard let desktop = topology.desktop(owned.id) else {
                return topology.display(owned.display) != nil
            }
            return !owned.uuid.isEmpty && desktop.uuid != owned.uuid
        }
        for owned in state.ownedSpaces {
            let snapshot = try driver.topology()
            guard snapshot.desktop(owned.id) != nil, NativeSpacePlanner.canCollect(owned, state: state, topology: snapshot, occupants: try driver.occupants(owned.id)) else { continue }
            state.deleting = owned
            try store.save(state)
            // Recheck immediately before dispatch; never collect an occupied/current/unowned Space.
            guard NativeSpacePlanner.canCollect(owned, state: state, topology: try driver.topology(), occupants: try driver.occupants(owned.id)) else {
                state.deleting = nil
                continue
            }
            try await driver.destroy(owned.id)
            try await wait("removal of Space \(owned.id)") { try self.driver.topology().desktop(owned.id) == nil }
            state.ownedSpaces.removeAll { $0 == owned }
            state.deleting = nil
            try store.save(state)
        }
        state.deleting = nil
        try store.save(state)
    }

    private func wait(_ description: String, until condition: () throws -> Bool) async throws {
        for _ in 0..<attempts {
            if try condition() { return }
            try await driver.pause()
        }
        throw NativeSpaceError.timedOut(description)
    }
}
