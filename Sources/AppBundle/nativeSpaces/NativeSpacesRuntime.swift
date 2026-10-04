import AppKit
import Common
import Darwin

/// One serial lane for model + native transitions. Waiting yields MainActor;
/// a newly requested workspace cannot retarget windows belonging to an in-flight swap.
@MainActor
final class NativeSpaceSessionGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

@MainActor
final class NativeSpacesRuntime {
    static let shared = NativeSpacesRuntime()
    let sessions = NativeSpaceSessionGate()
    private(set) var coordinator: NativeSpaceCoordinator?
    private(set) var failure: String?
    private(set) var isStagingModel = false
    private var lockFD: Int32 = -1
    private var nativeTask: Task<Void, Error>?
    var lastObservedActive: [String: String] = [:]
    private var retainedStartupDesktopUUIDs: Set<String> = []
    private var poolObservationCheckpoint: NativeLogicalCheckpoint?
    private var testWindowIdentities: [UInt32: NativeWindowIdentity] = [:]

    var isNative: Bool { coordinator != nil }
    var shouldSerializeSessions: Bool { (!isUnitTest || coordinator?.state.pool != nil) && !serverArgs.isReadOnly }
    var mayWriteFrames: Bool { isUnitTest || serverArgs.isReadOnly || (isNative && failure == nil && !isStagingModel) }

    func start() async throws {
        guard !isUnitTest, !serverArgs.isReadOnly else { return }
        let driver = try SkyLightSpaceDriver()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(winMuxAppSupportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("native-spaces.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NativeSpaceError.unavailable("cannot open exclusive state lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw NativeSpaceError.unavailable("another native release/debug instance owns the state directory")
        }
        lockFD = fd
        let engine: NativeSpaceCoordinator
        do { engine = try NativeSpaceCoordinator(driver: driver, store: NativeSpaceStore(url: directory.appendingPathComponent("native-spaces.json"))) }
        catch {
            close(lockFD)
            lockFD = -1
            throw error
        }
        coordinator = engine
        let recovery = Task { @MainActor in try await engine.recover() }
        nativeTask = recovery
        defer { nativeTask = nil }
        try await recovery.value
        try restoreWorkspaceBindings()
        try observeTopology(adoptExistingOwnedSpaces: true)
        guard let primary = display(for: mainMonitor, in: try driver.topology()) else { throw NativeSpaceError.topology("cannot identify the main display") }
        try engine.configurePool(on: primary.uuid)
    }

    func installForTests(_ coordinator: NativeSpaceCoordinator?, windows: [NativeWindowIdentity] = []) {
        precondition(isUnitTest)
        poolObservationCheckpoint = nil
        self.coordinator = coordinator
        failure = nil
        isStagingModel = false
        lastObservedActive = [:]
        retainedStartupDesktopUUIDs = []
        testWindowIdentities = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    }

    var hasPoolObservationChanges: Bool { poolObservationCheckpoint != nil }

    func capturePoolObservationCheckpoint() {
        if poolObservationCheckpoint == nil { poolObservationCheckpoint = NativeLogicalCheckpoint() }
    }

    func beginModelChanges() { if isNative { isStagingModel = true } }
    func endModelChanges() { isStagingModel = false }

    func report(_ error: Error) {
        guard !isUnitTest else { return }
        failure = error.localizedDescription
        // The native app never silently resumes virtual corner parking.
        TrayMenuModel.shared.isEnabled = false
        MessageModel.shared.message = Message(description: "Native Spaces Paused", body: error.localizedDescription + "\nWindow management is paused. Resolve the condition and use Enable to retry recovery.")
    }

    func retryRecovery() async throws {
        guard !isUnitTest, !serverArgs.isReadOnly else { return }
        if let coordinator {
            let recovery = Task { @MainActor in try await coordinator.recover() }
            nativeTask = recovery
            defer { nativeTask = nil }
            try await recovery.value
            failure = nil
            try restoreWorkspaceBindings()
            try observeTopology()
        } else {
            try await start()
            failure = nil
        }
    }

    func finishPendingOperation() async {
        if let nativeTask { _ = try? await nativeTask.value }
    }

    /// Recreate the saved logical identities by name, then rekey native associations to
    /// this session's WorkspaceIds. Numeric IDs alone must not bind a different project.
    private func restoreWorkspaceBindings() throws {
        guard let coordinator else { return }
        var restored: [String: NativeSpaceBinding] = [:]
        let topology = try coordinator.driver.topology()
        for saved in coordinator.state.bindings.values.sorted(by: { $0.workspace < $1.workspace }) {
            guard let physical = topology.displayContaining(saved.space),
                  saved.spaceUUID.isEmpty || topology.desktop(saved.space)?.uuid == saved.spaceUUID else {
                // Preserve detached logical workspaces; their trees can return through
                // the native-specific restart snapshot without importing virtual state.
                let workspace = Workspace.get(byName: saved.name)
                workspace.assignProject(WorkspaceProjectId(saved.project))
                if coordinator.state.pool != nil {
                    restored[workspace.id.rawValue] = NativeSpaceBinding(workspace: workspace.id.rawValue, name: saved.name, project: saved.project, display: saved.display, space: saved.space, spaceUUID: saved.spaceUUID, namingStyle: saved.namingStyle)
                }
                continue
            }
            let workspace = Workspace.get(byName: saved.name)
            workspace.assignProject(WorkspaceProjectId(saved.project))
            workspace.restoreNamingStyle(saved.namingStyle)
            if let monitor = monitor(for: physical) { workspace.preferredMonitorPoint = monitor.rect.topLeftCorner }
            restored[workspace.id.rawValue] = NativeSpaceBinding(workspace: workspace.id.rawValue, name: workspace.name, project: workspace.projectId.rawValue, display: physical.uuid, space: saved.space, spaceUUID: topology.desktop(saved.space)?.uuid ?? "", namingStyle: saved.namingStyle)
        }
        try coordinator.replaceBindings(restored)
    }

    func retainsExternalDesktop(_ workspace: Workspace) -> Bool {
        if coordinator?.state.pool?.retained.contains(workspace.id.rawValue) == true { return true }
        // Hidden windows can arrive through AX after startup reconciliation. Do not
        // prune their logical workspace and retire its origin while it still has content.
        if !workspaceHasLifecycleWindows(workspace), let coordinator, let pool = coordinator.state.pool {
            let placements = [coordinator.state.bindings[workspace.id.rawValue], pool.homes[workspace.id.rawValue]].compactMap { $0 }
            guard let topology = try? coordinator.driver.topology() else { return true }
            for placement in placements {
                guard topology.desktop(placement.space)?.uuid == placement.spaceUUID else { continue }
                guard let occupants = try? coordinator.driver.occupants(placement.space) else { return true }
                if !occupants.isEmpty { return true }
            }
        }
        guard let coordinator,
              let binding = coordinator.state.bindings[workspace.id.rawValue],
              (!coordinator.state.ownedSpaces.contains(where: { $0.id == binding.space && $0.uuid == binding.spaceUUID }) || retainedStartupDesktopUUIDs.contains(binding.spaceUUID)),
              let topology = try? coordinator.driver.topology() else { return false }
        return topology.desktop(binding.space)?.isUser == true
    }

    func workspaceForWindow(_ window: UInt32) -> Workspace? {
        guard let coordinator, failure == nil,
              let spaces = try? coordinator.driver.memberships(window), spaces.count == 1,
              let topology = try? coordinator.driver.topology(),
              let binding = coordinator.state.bindings.values.first(where: { $0.space == spaces[0] && ($0.spaceUUID.isEmpty || $0.spaceUUID == topology.desktop(spaces[0])?.uuid) }) ?? coordinator.state.pool?.homes.values.first(where: { $0.space == spaces[0] && $0.spaceUUID == topology.desktop(spaces[0])?.uuid }) else { return nil }
        return Workspace.existing(byName: binding.name)
    }

    /// Follow Mission Control and manual window transfers before deriving desired state.
    /// Fullscreen keeps the underlying workspace and its global layout untouched.
    func observeTopology(adoptExistingOwnedSpaces: Bool = false) throws {
        guard let coordinator, failure == nil, coordinator.state.pending == nil else { return }
        if coordinator.state.pool != nil { try observePoolTopology(isStartup: adoptExistingOwnedSpaces); return }
        let topology = try coordinator.driver.topology()
        if adoptExistingOwnedSpaces {
            retainedStartupDesktopUUIDs.formUnion(topology.displays.flatMap(\.spaces).filter { $0.isUser && !$0.uuid.isEmpty }.map(\.uuid))
        }
        var adopted: [NativeSpaceBinding] = []
        var bound = Set(coordinator.state.bindings.values.map(\.space))
        for display in topology.displays {
            guard let monitor = monitor(for: display) else { throw NativeSpaceError.topology("cannot match physical display to monitor") }
            for desktop in display.spaces where desktop.isUser && !bound.contains(desktop.id) {
                // At startup reuse every desktop, including empty ones and surviving
                // app-owned slots. Refresh must not adopt a retired swap staging Space.
                if adoptExistingOwnedSpaces && display.uuid != self.display(for: mainMonitor, in: topology)?.uuid && desktop.id != display.currentSpace {
                    if try coordinator.driver.occupants(desktop.id).isEmpty { continue }
                }
                let owned = coordinator.state.ownedSpaces.contains { $0.id == desktop.id && $0.uuid == desktop.uuid }
                if owned && !adoptExistingOwnedSpaces { continue }
                let existing: Workspace?
                if desktop.id == display.currentSpace,
                   let candidate = winMuxWorkspaceState.visibleWorkspace(for: monitor),
                   coordinator.state.bindings[candidate.id.rawValue] == nil {
                    existing = candidate
                } else { existing = nil }
                let workspace = existing ?? createBlankWorkspace(projectId: activeWorkspaceProjectId(for: monitor), monitor: monitor)
                workspace.markAsSidebarManaged()
                // Adoption preserves existing ownership; external desktops are never claimed.
                adopted.append(NativeSpaceBinding(workspace: workspace.id.rawValue, name: workspace.name, project: workspace.projectId.rawValue, display: display.uuid, space: desktop.id, spaceUUID: desktop.uuid, namingStyle: workspace.namingStyle))
                bound.insert(desktop.id)
            }
        }
        if !adopted.isEmpty { try coordinator.adopt(adopted) }
        for display in topology.displays {
            guard let monitor = monitor(for: display),
                  let binding = coordinator.state.bindings.values.first(where: { $0.space == display.currentSpace }),
                  let workspace = Workspace.existing(byName: binding.name) else { continue }
            // Restore both visible assignments as one snapshot to avoid transient duplicates
            // when macOS itself relocates desktops between connected displays.
            var viewport = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)] ?? MonitorViewport(id: MonitorViewportId(monitor))
            if viewport.activeWorkspaceId != workspace.id {
                viewport.previousWorkspaceId = viewport.activeWorkspaceId
                viewport.activeWorkspaceId = workspace.id
                viewport.lastActiveWorkspaceByProject[workspace.projectId] = workspace.id
            }
            winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)] = viewport
            lastObservedActive[display.uuid] = workspace.id.rawValue
        }
        // Follow manual moves only when the original desktop still exists. A disconnected
        // source must be reconciled as a global workspace transfer, not merged into its neighbor.
        for window in MacWindow.allWindows {
            guard let source = window.visualWorkspace,
                  let sourceBinding = coordinator.state.bindings[source.id.rawValue],
                  topology.desktop(sourceBinding.space) != nil,
                  let destination = workspaceForWindow(window.windowId), destination !== source else { continue }
            switch window.layoutReason {
                case .standard:
                    if window.isFloating { window.bindAsFloatingWindow(to: destination) }
                    else { window.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
                case .macos:
                    break // Preserve native minimized/fullscreen/hidden state and its remembered owner.
            }
        }
    }

    func synchronize() async throws {
        guard let coordinator, !serverArgs.isReadOnly, TrayMenuModel.shared.isEnabled else { return }
        if let failure { throw NativeSpaceError.recoveryRequired(failure) }
        let topology = try coordinator.driver.topology()
        var requests: [NativeWorkspaceRequest] = []
        var activate: Set<String> = []
        for workspace in Workspace.all {
            let display: NativeDisplaySnapshot?
            if !workspace.isVisible, let pool = coordinator.state.pool,
               let primary = topology.display(pool.preferredDisplay) ?? topology.display(pool.effectiveDisplay) ?? topology.displays.first {
                display = primary
            } else if !workspace.isVisible,
               let binding = coordinator.state.bindings[workspace.id.rawValue],
               let connected = topology.displayContaining(binding.space) {
                // Hidden workspaces retain their actual location until summoned. A layout
                // refresh cannot silently undo the user's previous destination choice.
                display = connected
            } else { display = self.display(for: workspace.workspaceMonitor, in: topology) }
            guard let display else { throw NativeSpaceError.topology("workspace monitor disappeared") }
            let windows = try collectAllWindowIds(workspace: workspace).compactMap { id -> NativeWindowIdentity? in
                if isUnitTest, let identity = testWindowIdentities[id] { return identity }
                guard let window = MacWindow.allWindowsMap[id] else { return nil }
                guard let launch = window.macApp.nsApp.launchDate else { throw NativeSpaceError.unsafeWindow(id) }
                return NativeWindowIdentity(id: id, pid: window.macApp.pid, launchDate: launch)
            }
            requests.append(NativeWorkspaceRequest(key: workspace.id.rawValue, name: workspace.name, project: workspace.projectId.rawValue, display: display.uuid, visible: workspace.isVisible, windows: windows, namingStyle: workspace.namingStyle))
            if workspace.isVisible {
                if topology.desktop(display.currentSpace)?.isUser == true || lastObservedActive[display.uuid] != workspace.id.rawValue {
                    activate.insert(display.uuid)
                }
            }
        }
        let task = Task { @MainActor in
            if !isUnitTest { try await MacApp.finishPendingLayoutBeforeNativeTransition() }
            try await coordinator.synchronize(requests, activate: activate)
        }
        nativeTask = task
        defer { nativeTask = nil }
        do {
            try await task.value
            poolObservationCheckpoint = nil
        } catch {
            poolObservationCheckpoint?.restore()
            poolObservationCheckpoint = nil
            throw error
        }
        for request in requests where request.visible { lastObservedActive[request.display] = request.key }
        // Crash recovery must include the current native tree, not only clean-quit state.
        if !isUnitTest { persistFrozenWorldForRestartIfPossible() }
    }

    /// Desktop numbers follow the observed Mission Control order on each display.
    /// Logical names/IDs remain stable so reordering cannot exchange layout trees.
    func desktopIndex(_ workspace: Workspace) -> Int? {
        if coordinator?.state.pool != nil { return globalPoolKeys().firstIndex(of: workspace.id.rawValue).map { $0 + 1 } }
        guard let coordinator, let binding = coordinator.state.bindings[workspace.id.rawValue],
              let topology = try? coordinator.driver.topology(),
              let display = topology.displayContaining(binding.space),
              topology.desktop(binding.space)?.uuid == binding.spaceUUID else { return nil }
        return display.spaces.filter(\.isUser).firstIndex { $0.id == binding.space }.map { $0 + 1 }
    }

    func workspace(atDesktopIndex index: Int, on monitor: Monitor) -> Workspace? {
        if coordinator?.state.pool != nil {
            guard index > 0, let key = globalPoolKeys().getOrNil(atIndex: index - 1) else { return nil }
            return winMuxWorkspaceState.workspaceById[WorkspaceId(rawValue: key)]
        }
        guard index > 0, let coordinator, let topology = try? coordinator.driver.topology(),
              let display = display(for: monitor, in: topology),
              let desktop = display.spaces.filter(\.isUser).getOrNil(atIndex: index - 1),
              let binding = coordinator.state.bindings.values.first(where: { $0.space == desktop.id && $0.spaceUUID == desktop.uuid }) else { return nil }
        return Workspace.existing(byName: binding.name)
    }

    func orderForPresentation(_ workspaces: [Workspace]) -> [Workspace] {
        guard let coordinator, let topology = try? coordinator.driver.topology() else { return workspaces }
        if coordinator.state.pool != nil {
            let keys = globalPoolKeys()
            let ranks = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
            return workspaces.enumerated().sorted {
                let lhs = ranks[$0.element.id.rawValue] ?? Int.max
                let rhs = ranks[$1.element.id.rawValue] ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
        }
        var ranks: [WorkspaceId: Int] = [:]
        var rank = 0
        for display in topology.displays {
            for desktop in display.spaces where desktop.isUser {
                for workspace in workspaces {
                    if let binding = coordinator.state.bindings[workspace.id.rawValue],
                       binding.space == desktop.id && binding.spaceUUID == desktop.uuid { ranks[workspace.id] = rank }
                }
                rank += 1
            }
        }
        // Preserve project grouping and the stable order of unbound N+1 workspaces.
        var result: [Workspace] = []
        var seen: Set<WorkspaceProjectId> = []
        for workspace in workspaces where seen.insert(workspace.projectId).inserted {
            let members = workspaces.filter { $0.projectId == workspace.projectId }
            result += members.enumerated().sorted {
                let lhs = ranks[$0.element.id] ?? Int.max
                let rhs = ranks[$1.element.id] ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
        }
        return result
    }

    func isActuallyVisible(_ workspace: Workspace) -> Bool {
        guard let coordinator,
              let binding = coordinator.state.bindings[workspace.id.rawValue],
              let snapshot = try? coordinator.driver.topology() else { return false }
        return snapshot.displayContaining(binding.space)?.currentSpace == binding.space && (binding.spaceUUID.isEmpty || snapshot.desktop(binding.space)?.uuid == binding.spaceUUID)
    }

    func monitor(for display: NativeDisplaySnapshot) -> Monitor? {
        if isUnitTest, let monitor = monitors.first(where: { $0.monitorAppKitNsScreenScreensId == Int(display.displayID) }) { return monitor }
        let point = CGDisplayBounds(display.displayID).origin
        return monitors.first { abs($0.rect.minX - point.x) < 1 && abs($0.rect.minY - point.y) < 1 }
    }

    func display(for monitor: Monitor, in topology: NativeSpaceTopology) -> NativeDisplaySnapshot? {
        topology.displays.first { display in self.monitor(for: display)?.rect.topLeftCorner == monitor.rect.topLeftCorner }
    }
}
