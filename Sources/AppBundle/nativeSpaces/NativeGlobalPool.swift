import Foundation

@MainActor
extension NativeSpaceCoordinator {
    func configurePool(on preferredDisplay: String) throws {
        guard state.pool == nil else { return }
        guard state.pending == nil else { throw NativeSpaceError.recoveryRequired("migration has a pending operation") }
        try store.backupForPoolMigration()
        let topology = try driver.topology()
        guard let display = topology.display(preferredDisplay) else { throw NativeSpaceError.topology("pool display unavailable") }
        let desktops = topology.displays.flatMap(\.spaces).filter(\.isUser)
        guard desktops.allSatisfy({ !$0.uuid.isEmpty }), Set(desktops.map(\.uuid)).count == desktops.count else {
            throw NativeSpaceError.topology("ambiguous desktop identities during migration")
        }
        var homes: [String: NativeSpaceBinding] = [:]
        var order: [String] = []
        for desktop in display.spaces where desktop.isUser {
            if var binding = state.bindings.values.first(where: { $0.space == desktop.id }) {
                binding.spaceUUID = desktop.uuid
                homes[binding.workspace] = binding
                order.append(binding.workspace)
            }
        }
        order += state.bindings.keys.filter { !order.contains($0) }.sorted {
            state.bindings[$0]!.name.localizedStandardCompare(state.bindings[$1]!.name) == .orderedAscending
        }
        var carriers: [String: NativeSpaceReference] = [:]
        for secondary in topology.displays where secondary.uuid != preferredDisplay {
            if let desktop = secondary.spaces.first(where: { $0.id == secondary.currentSpace && $0.isUser }),
               state.bindings.values.contains(where: { $0.space == desktop.id }) {
                carriers[secondary.uuid] = NativeSpaceReference(id: desktop.id, uuid: desktop.uuid, display: secondary.uuid)
            }
        }
        var migrated = state
        migrated.version = 2
        migrated.pool = NativeGlobalPool(preferredDisplay: preferredDisplay, effectiveDisplay: preferredDisplay,
                                        order: order, homes: homes, carriers: carriers, retained: Set(order))
        migrated.pool?.active = Dictionary(uniqueKeysWithValues: topology.displays.compactMap { display in
            state.bindings.values.first(where: { $0.space == display.currentSpace }).map { (display.uuid, $0.workspace) }
        })
        try store.save(migrated)
        state = migrated
    }

    func rekeyPool(to bindings: [String: NativeSpaceBinding]) {
        guard var pool = state.pool else { return }
        var keys: [String: String] = [:]
        for (old, binding) in state.bindings {
            if let replacement = bindings.values.first(where: { $0.name == binding.name && $0.project == binding.project }) {
                keys[old] = replacement.workspace
            }
        }
        pool.order = pool.order.map { keys[$0] ?? $0 }
        pool.retained = Set(pool.retained.map { keys[$0] ?? $0 })
        pool.active = pool.active.mapValues { keys[$0] ?? $0 }
        var homes: [String: NativeSpaceBinding] = [:]
        for (old, home) in pool.homes {
            let key = keys[old] ?? old
            homes[key] = NativeSpaceBinding(workspace: key, name: home.name, project: home.project,
                                           display: home.display, space: home.space, spaceUUID: home.spaceUUID, namingStyle: home.namingStyle)
        }
        pool.homes = homes
        state.pool = pool
    }

    func orderedPoolKeys() throws -> [String] {
        guard let pool = state.pool else { return [] }
        let topology = try driver.topology()
        guard let display = topology.display(pool.effectiveDisplay) else { return pool.order }
        let byUUID = Dictionary(uniqueKeysWithValues: pool.homes.map { ($0.value.spaceUUID, $0.key) })
        let observed = display.spaces.filter(\.isUser).compactMap { byUUID[$0.uuid] }
        return observed + pool.order.filter { !observed.contains($0) }
    }

    func poolPlacement(_ binding: NativeSpaceBinding, topology: NativeSpaceTopology) -> NativeSpaceBinding? {
        guard let physical = topology.displays.first(where: { $0.spaces.contains { $0.uuid == binding.spaceUUID && $0.isUser } }),
              let desktop = physical.spaces.first(where: { $0.uuid == binding.spaceUUID }) else { return nil }
        var observed = binding
        observed.display = physical.uuid
        observed.space = desktop.id
        return observed
    }

    private func poolIsStable(_ requests: [NativeWorkspaceRequest], activate: Set<String>, topology: NativeSpaceTopology) throws -> Bool {
        guard let pool = state.pool else { return false }
        let desiredPool = topology.display(pool.preferredDisplay)?.uuid ?? fallbackPoolDisplay.flatMap { topology.display($0)?.uuid } ?? topology.displays.first?.uuid
        guard desiredPool == pool.effectiveDisplay, Set(requests.filter { $0.visible || !$0.windows.isEmpty || pool.homes[$0.key] != nil || pool.retained.contains($0.key) }.map(\.key)) == Set(state.bindings.keys) else { return false }
        for request in requests {
            if pool.homes[request.key] == nil && !request.visible && request.windows.isEmpty && !pool.retained.contains(request.key) { continue }
            guard let home = pool.homes[request.key], let origin = poolPlacement(home, topology: topology), origin.display == desiredPool,
                  let binding = state.bindings[request.key], let current = poolPlacement(binding, topology: topology),
                  current == binding, binding.name == request.name, binding.project == request.project,
                  binding.namingStyle == request.namingStyle else { return false }
            let destination: UInt64
            if !request.visible || request.display == pool.effectiveDisplay { destination = origin.space }
            else {
                guard let carrier = pool.carriers[request.display],
                      topology.display(request.display)?.spaces.contains(where: { $0.uuid == carrier.uuid && $0.id == carrier.id && $0.isUser }) == true else { return false }
                destination = carrier.id
            }
            if binding.space != destination { return false }
            if request.visible && activate.contains(request.display) && topology.display(request.display)?.currentSpace != destination { return false }
            for window in request.windows where try driver.isAlive(window) {
                let membership = try driver.memberships(window.id)
                if membership == [destination] { continue }
                if membership.count == 1 && topology.desktop(membership[0])?.isUser == false { continue }
                return false
            }
        }
        return true
    }

    func synchronizePool(_ requests: [NativeWorkspaceRequest], activate: Set<String>) async throws {
        if state.pending != nil { try await recover() }
        let topology = try driver.topology()
        guard var pool = state.pool, !topology.displays.isEmpty else { throw NativeSpaceError.topology("pool has no connected display") }
        if try poolIsStable(requests, activate: activate, topology: topology) {
            pool.active = Dictionary(uniqueKeysWithValues: requests.filter(\.visible).map { ($0.display, $0.key) })
            pool.order = try orderedPoolKeys()
            if pool != state.pool {
                var observed = state
                observed.pool = pool
                try store.save(observed)
                state = observed
            }
            if state.ownedSpaces.contains(where: { owned in
                !state.bindings.values.contains { $0.spaceUUID == owned.uuid } &&
                    !pool.homes.values.contains { $0.spaceUUID == owned.uuid } && !pool.carriers.values.contains { $0.uuid == owned.uuid }
            }) {
                do { try await collectUnusedOwnedSpaces(); collectionError = nil }
                catch { collectionError = error.localizedDescription }
            }
            return
        }
        let original = state
        state.pending = NativeSpaceTransaction(originalBindings: state.bindings,
            originalActiveSpaces: Dictionary(uniqueKeysWithValues: topology.displays.map { display in
                let previous = pool.active[display.uuid].flatMap { state.bindings[$0] }.flatMap { poolPlacement($0, topology: topology) }
                return (display.uuid, previous?.display == display.uuid ? previous!.space : display.currentSpace)
            }), originalPool: pool)
        do {
            // Validate identities and memberships before even allocating replacement homes.
            let visible = requests.filter(\.visible)
            guard Set(visible.map(\.display)).count == visible.count else { throw NativeSpaceError.topology("two workspaces requested on one display") }
            for request in requests {
                for window in request.windows where try driver.isAlive(window) {
                    let spaces = try driver.memberships(window.id)
                    guard spaces.count == 1 else { throw NativeSpaceError.unsafeWindow(window.id) }
                    if topology.desktop(spaces[0])?.isUser != true {
                        guard let binding = state.bindings[request.key], request.visible,
                              binding.display == request.display else { throw NativeSpaceError.unsafeWindow(window.id) }
                    }
                }
            }
            try store.save(state)
            pool.effectiveDisplay = topology.display(pool.preferredDisplay)?.uuid ?? fallbackPoolDisplay.flatMap { topology.display($0)?.uuid } ?? topology.displays[0].uuid
            let wanted = Set(requests.map(\.key))
            for (key, home) in pool.homes where !wanted.contains(key) {
                pool.retiredUUIDs.insert(home.spaceUUID)
                pool.homes.removeValue(forKey: key)
            }
            pool.retained.formIntersection(wanted)
            pool.order.removeAll { !wanted.contains($0) }
            var destinations: [String: NativeSpaceBinding] = [:]
            let ranks = Dictionary(uniqueKeysWithValues: pool.order.enumerated().map { ($0.element, $0.offset) })
            let allocationOrder = requests.enumerated().sorted {
                let lhs = ranks[$0.element.key] ?? Int.max
                let rhs = ranks[$1.element.key] ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
            for request in allocationOrder {
                // An unbound empty N+1 remains logical until it is activated.
                if pool.homes[request.key] == nil && !request.visible && request.windows.isEmpty && !pool.retained.contains(request.key) { continue }
                var home = pool.homes[request.key].flatMap { poolPlacement($0, topology: topology) }
                if home?.display != pool.effectiveDisplay {
                    if let old = pool.homes[request.key] { pool.retiredUUIDs.insert(old.spaceUUID) }
                    let id = try await createEmpty(on: pool.effectiveDisplay)
                    guard let desktop = try driver.topology().desktop(id) else { throw NativeSpaceError.topology("new origin disappeared") }
                    home = NativeSpaceBinding(workspace: request.key, name: request.name, project: request.project,
                        display: pool.effectiveDisplay, space: id, spaceUUID: desktop.uuid, namingStyle: request.namingStyle)
                }
                guard var origin = home else { throw NativeSpaceError.recoveryRequired("workspace origin unavailable") }
                origin.name = request.name
                origin.project = request.project
                origin.namingStyle = request.namingStyle
                pool.homes[request.key] = origin
                if !pool.order.contains(request.key) { pool.order.append(request.key) }
                if !request.visible || request.display == pool.effectiveDisplay {
                    destinations[request.key] = origin
                } else {
                    guard let display = try driver.topology().display(request.display) else { throw NativeSpaceError.topology("target display disconnected") }
                    var carrier = pool.carriers[display.uuid]
                    if let old = carrier, !display.spaces.contains(where: { $0.uuid == old.uuid && $0.isUser }) {
                        pool.retiredUUIDs.insert(old.uuid)
                        carrier = nil
                    }
                    if carrier == nil {
                        if let desktop = display.spaces.first(where: { $0.id == display.currentSpace && $0.isUser }),
                           !pool.homes.values.contains(where: { $0.spaceUUID == desktop.uuid }) {
                            carrier = NativeSpaceReference(id: desktop.id, uuid: desktop.uuid, display: display.uuid)
                        } else {
                            let id = try await createEmpty(on: display.uuid)
                            guard let desktop = try driver.topology().desktop(id) else { throw NativeSpaceError.topology("new carrier disappeared") }
                            carrier = NativeSpaceReference(id: id, uuid: desktop.uuid, display: display.uuid)
                        }
                    }
                    guard var slot = carrier else { throw NativeSpaceError.recoveryRequired("display carrier unavailable") }
                    slot.id = display.spaces.first(where: { $0.uuid == slot.uuid })?.id ?? slot.id
                    pool.carriers[display.uuid] = slot
                    destinations[request.key] = NativeSpaceBinding(workspace: request.key, name: request.name, project: request.project,
                        display: display.uuid, space: slot.id, spaceUUID: slot.uuid, namingStyle: request.namingStyle)
                }
            }
            // Pool migration may turn the former pool's active desktop into a carrier.
            for (display, carrier) in pool.carriers where display == pool.effectiveDisplay || topology.display(display) == nil {
                if !pool.homes.values.contains(where: { $0.spaceUUID == carrier.uuid }) { pool.retiredUUIDs.insert(carrier.uuid) }
                pool.carriers.removeValue(forKey: display)
            }
            let allWindows = Set(requests.flatMap(\.windows).map(\.id))
            guard Set(destinations.values.map(\.space)).count == destinations.count else { throw NativeSpaceError.topology("pool destinations overlap") }
            for destination in destinations.values {
                // An unchanged placement may contain auxiliary AX windows that the
                // tiling model intentionally excludes. Guard slots before reassigning
                // them to a different workspace; never move or delete those occupants.
                if original.bindings[destination.workspace]?.spaceUUID == destination.spaceUUID { continue }
                guard Set(try driver.occupants(destination.space)).isSubset(of: allWindows) else {
                    throw NativeSpaceError.topology("pool destination contains untracked windows")
                }
            }
            // Explicit visible swaps keep the original three-leg protocol, with a
            // temporary secondary Space; the fixed homes themselves never change owner.
            for (a, b) in NativeSpacePlanner.swapPairs(requests: requests, bindings: original.bindings) {
                let participants = requests.filter { $0.key == a || $0.key == b }
                for request in participants {
                    if let placement = original.bindings[request.key] {
                        guard Set(try driver.occupants(placement.space)).isSubset(of: Set(request.windows.map(\.id))) else {
                            throw NativeSpaceError.topology("swap source contains untracked windows")
                        }
                    }
                }
                guard let secondary = participants.first(where: { original.bindings[$0.key]?.display != pool.effectiveDisplay }),
                      let source = original.bindings[secondary.key] else { continue }
                let temporary = try await createEmpty(on: source.display)
                try await transfer(secondary.windows, to: temporary)
                try assertEmpty(source.space)
            }
            // Resolve other dependency cycles by staging one participant. No origins are exchanged.
            var remaining = requests.filter { destinations[$0.key] != nil }
            var staged = false
            while !remaining.isEmpty {
                let movingIDs = Dictionary(uniqueKeysWithValues: remaining.flatMap { request in request.windows.map { ($0.id, request.key) } })
                let ready = try remaining.first { request in
                    let destination = destinations[request.key]!.space
                    return try !driver.occupants(destination).contains { id in movingIDs[id].map { $0 != request.key } ?? false }
                }
                if let request = ready {
                    let destination = destinations[request.key]!
                    let unchangedPlacement = state.bindings[request.key]?.spaceUUID == destination.spaceUUID
                    try await transfer(request.windows, to: destination.space, preserveFullscreen: unchangedPlacement)
                    remaining.removeAll { $0.key == request.key }
                    staged = false
                } else {
                    guard !staged else { throw NativeSpaceError.topology("unresolved transfer cycle") }
                    let request = remaining.first(where: { state.bindings[$0.key]?.display != pool.effectiveDisplay }) ?? remaining[0]
                    let source = request.windows.compactMap { try? driver.memberships($0.id).first }.first
                    let sourceDisplay = source.flatMap { try? driver.topology().displayContaining($0)?.uuid }
                    guard let secondary = sourceDisplay.flatMap({ $0 == pool.effectiveDisplay ? nil : $0 }) ?? topology.displays.first(where: { $0.uuid != pool.effectiveDisplay })?.uuid else {
                        throw NativeSpaceError.topology("swap requires a secondary display")
                    }
                    let temporary = try await createEmpty(on: secondary)
                    try await transfer(request.windows, to: temporary)
                    staged = true
                }
            }
            for request in requests where request.visible && activate.contains(request.display) {
                guard let destination = destinations[request.key] else { continue }
                if try driver.topology().display(request.display)?.currentSpace != destination.space {
                    try await driver.activate(destination.space, on: request.display)
                    try await wait("pool activation") { try self.driver.topology().display(request.display)?.currentSpace == destination.space }
                }
            }
            let observed = try driver.topology()
            let homeKeys = Dictionary(uniqueKeysWithValues: pool.homes.map { ($0.value.spaceUUID, $0.key) })
            let order = observed.display(pool.effectiveDisplay)?.spaces.filter(\.isUser).compactMap { homeKeys[$0.uuid] } ?? []
            pool.order = order + pool.order.filter { !order.contains($0) }
            pool.active = Dictionary(uniqueKeysWithValues: requests.filter(\.visible).map { ($0.display, $0.key) })
            var committed = state
            committed.pool = pool
            committed.bindings = destinations
            committed.pending = nil
            try store.save(committed)
            state = committed
        } catch {
            state.bindings = original.bindings
            do { try await recover() }
            catch { throw NativeSpaceError.recoveryRequired(error.localizedDescription) }
            throw error
        }
        do { try await collectUnusedOwnedSpaces(); collectionError = nil }
        catch { collectionError = error.localizedDescription }
    }
}
