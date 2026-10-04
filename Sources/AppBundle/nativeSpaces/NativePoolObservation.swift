import AppKit
import Common

@MainActor
extension NativeSpacesRuntime {
    func globalPoolKeys() -> [String] {
        guard let coordinator, let pool = coordinator.state.pool else { return [] }
        var keys = (try? coordinator.orderedPoolKeys()) ?? pool.order
        keys += Workspace.all.filter { !keys.contains($0.id.rawValue) && isUserFacingWorkspace($0) }
            .sorted().map { $0.id.rawValue }
        return keys
    }

    func observePoolTopology(isStartup: Bool = false) throws {
        guard let coordinator, var pool = coordinator.state.pool else { return }
        let originalBindings = coordinator.state.bindings
        let originalPool = pool
        let topology = try coordinator.driver.topology()
        guard let primary = topology.display(pool.preferredDisplay) ?? display(for: mainMonitor, in: topology) else {
            throw NativeSpaceError.topology("pool has no main display")
        }
        coordinator.fallbackPoolDisplay = primary.uuid
        // Update numeric IDs/display locations only after resolving persistent UUIDs.
        var bindings = coordinator.state.bindings
        for (key, binding) in bindings {
            if let observed = coordinator.poolPlacement(binding, topology: topology) { bindings[key] = observed }
        }
        for (key, home) in pool.homes {
            if let observed = coordinator.poolPlacement(home, topology: topology) { pool.homes[key] = observed }
        }
        for (uuid, carrier) in pool.carriers {
            if let physical = topology.display(uuid), let desktop = physical.spaces.first(where: { $0.uuid == carrier.uuid && $0.isUser }) {
                pool.carriers[uuid]?.id = desktop.id
            }
        }
        coordinator.state.bindings = bindings
        coordinator.state.pool = pool

        if isStartup {
            var used: Set<WorkspaceId> = []
            for physical in topology.displays {
                guard let key = pool.active[physical.uuid],
                      let workspace = winMuxWorkspaceState.workspaceById[WorkspaceId(key)],
                      let target = monitor(for: physical), used.insert(workspace.id).inserted else { continue }
                var viewport = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(target)] ?? MonitorViewport(id: MonitorViewportId(target))
                viewport.activeWorkspaceId = workspace.id
                winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(target)] = viewport
            }
        }
        // Mission Control selecting an empty borrowed home is an explicit override.
        // Handle it before examining carriers, otherwise their old binding would undo the swap.
        if let home = pool.homes.values.first(where: { $0.space == primary.currentSpace && $0.spaceUUID == topology.desktop(primary.currentSpace)?.uuid }),
           let placement = bindings[home.workspace], placement.display != primary.uuid,
           let workspace = Workspace.existing(byName: home.name), let main = monitor(for: primary),
           workspace.visibleMonitor != nil, workspace.visibleMonitor?.rect.topLeftCorner != main.rect.topLeftCorner {
            capturePoolObservationCheckpoint()
            let wasStaging = isStagingModel
            beginModelChanges()
            defer { if !wasStaging { endModelChanges() } }
            guard overrideWorkspaceOnMonitorBySwappingActiveViewports(workspace, targetMonitor: main) else {
                throw NativeSpaceError.topology("borrowed home cannot override this monitor")
            }
            _ = workspace.focusWorkspace()
            return
        }

        var changed = bindings != originalBindings || pool != originalPool
        for physical in topology.displays {
            guard let targetMonitor = monitor(for: physical) else { throw NativeSpaceError.topology("cannot match pool display to monitor") }
            for desktop in physical.spaces where desktop.isUser {
                let knownHome = pool.homes.values.contains { $0.spaceUUID == desktop.uuid }
                let knownPlacement = bindings.values.contains { $0.spaceUUID == desktop.uuid }
                let owned = coordinator.state.ownedSpaces.contains { $0.uuid == desktop.uuid }
                if knownHome || knownPlacement || owned { continue }
                if pool.retiredUUIDs.contains(desktop.uuid) && physical.uuid != primary.uuid { continue }
                // A retired origin that still exists without app ownership is a real
                // principal desktop again. Leaving it out creates a numbering gap.
                // All principal desktops are pool entries. Secondary empty hidden desktops stay external.
                if physical.uuid != primary.uuid && desktop.id != physical.currentSpace {
                    if try coordinator.driver.occupants(desktop.id).isEmpty { continue }
                }
                let workspace = createBlankWorkspace(projectId: activeWorkspaceProjectId(for: targetMonitor), monitor: targetMonitor)
                workspace.markAsSidebarManaged()
                let binding = NativeSpaceBinding(workspace: workspace.id.rawValue, name: workspace.name, project: workspace.projectId.rawValue,
                    display: physical.uuid, space: desktop.id, spaceUUID: desktop.uuid, namingStyle: workspace.namingStyle)
                bindings[binding.workspace] = binding
                pool.order.append(binding.workspace)
                pool.retained.insert(binding.workspace)
                pool.retiredUUIDs.remove(desktop.uuid)
                if physical.uuid == primary.uuid { pool.homes[binding.workspace] = binding }
                changed = true
            }
            // Native fullscreen does not replace the active logical desktop.
            guard physical.spaces.contains(where: { $0.id == physical.currentSpace && $0.isUser }) else { continue }
            let current = bindings.values.first(where: { $0.space == physical.currentSpace && $0.spaceUUID == topology.desktop(physical.currentSpace)?.uuid }) ??
                pool.homes.values.first(where: { $0.space == physical.currentSpace && $0.spaceUUID == topology.desktop(physical.currentSpace)?.uuid })
            guard let current, let workspace = Workspace.existing(byName: current.name) else { continue }
            if physical.uuid != primary.uuid, pool.carriers[physical.uuid]?.uuid != current.spaceUUID {
                if let previous = pool.carriers[physical.uuid] { pool.retiredUUIDs.insert(previous.uuid) }
                pool.carriers[physical.uuid] = NativeSpaceReference(id: current.space, uuid: current.spaceUUID, display: physical.uuid)
                changed = true
            }
            let viewportId = MonitorViewportId(targetMonitor)
            var viewport = winMuxWorkspaceState.monitorViewportsById[viewportId] ?? MonitorViewport(id: viewportId)
            if viewport.activeWorkspaceId != workspace.id {
                viewport.previousWorkspaceId = viewport.activeWorkspaceId
                viewport.activeWorkspaceId = workspace.id
                viewport.lastActiveWorkspaceByProject[workspace.projectId] = workspace.id
                winMuxWorkspaceState.monitorViewportsById[viewportId] = viewport
            }
            lastObservedActive[physical.uuid] = workspace.id.rawValue
        }
        coordinator.state.bindings = bindings
        coordinator.state.pool = pool
        if changed { try coordinator.store.save(coordinator.state) }
        // Manual window moves may change their owner only when they reach a known occupied
        // placement. Empty reserved origins must not silently pull borrowed workspaces home.
        for window in MacWindow.allWindows {
            guard let source = window.visualWorkspace,
                  let sourcePlacement = bindings[source.id.rawValue],
                  topology.desktop(sourcePlacement.space) != nil,
                  let spaces = try? coordinator.driver.memberships(window.windowId), spaces.count == 1,
                  let destinationBinding = bindings.values.first(where: { $0.space == spaces[0] && $0.spaceUUID == topology.desktop(spaces[0])?.uuid }) ?? pool.homes.values.first(where: { $0.space == spaces[0] && $0.spaceUUID == topology.desktop(spaces[0])?.uuid }),
                  let destination = Workspace.existing(byName: destinationBinding.name), destination !== source else { continue }
            switch window.layoutReason {
                case .standard:
                    if window.isFloating { window.bindAsFloatingWindow(to: destination) }
                    else { window.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
                case .macos: break
            }
        }
    }

    func poolDiagnostics() -> [String] {
        guard let coordinator, let pool = coordinator.state.pool else { return [] }
        var lines = ["Global workspace pool:", "  preferred display: \(pool.preferredDisplay)", "  effective display: \(pool.effectiveDisplay)"]
        let keys = (try? coordinator.orderedPoolKeys()) ?? pool.order
        for (index, key) in keys.enumerated() {
            let home = pool.homes[key]
            let placement = coordinator.state.bindings[key]
            let name = placement?.name ?? home?.name ?? key
            let origin = home.map { String($0.space) + "@" + $0.display } ?? "not materialized"
            let current = placement.map { String($0.space) + "@" + $0.display } ?? "unbound"
            lines.append("  \(index + 1) [\(name)]: home=\(origin); current=\(current)")
        }
        lines.append("  carriers: \(pool.carriers.count); recovery pending: \(coordinator.state.pending != nil)")
        if let error = coordinator.collectionError { lines.append("  deferred collection: \(error)") }
        lines.append("")
        return lines
    }

}
