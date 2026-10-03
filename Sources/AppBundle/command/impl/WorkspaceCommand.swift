import AppKit
import Common
import Foundation

struct WorkspaceCommand: Command {
    let args: WorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let focusedMonitor = focus.workspace.workspaceMonitor
        let activationMonitor: Monitor
        if let description = args.monitorDescription {
            guard let resolved = description.resolveMonitor(sortedMonitors: sortedMonitors) else {
                return io.err("No monitor matches '\(description)'")
            }
            activationMonitor = resolved
        } else {
            activationMonitor = focusedMonitor
        }
        let commandTarget = args.monitorDescription == nil ? args.resolveTargetOrReportError(env, io) : nil
        guard args.monitorDescription != nil || commandTarget != nil else { return false }
        let resolutionWorkspace = commandTarget?.workspace ?? activationMonitor.activeWorkspace
        if let requestedName = args.internalName {
            guard let named = Workspace.existing(byName: requestedName.raw), named.projectId == resolutionWorkspace.projectId else {
                return io.err("Workspace '\(requestedName.raw)' doesn't exist in the active project")
            }
            if args.autoBackAndForth && named == activationMonitor.activeWorkspace {
                return activatePreviousWorkspace(on: activationMonitor)
            }
            return activateWorkspace(named, on: activationMonitor, io: io)
        }
        let focusedWs = resolutionWorkspace
        switch resolveWorkspaceTarget(from: focusedWs, on: activationMonitor, io: io) {
            case .focus(let workspace):
                return activateWorkspace(workspace, on: activationMonitor, io: io)
            case .backAndForth:
                return activatePreviousWorkspace(on: activationMonitor)
            case .error:
                return false
        }
    }

    @MainActor
    private func activateWorkspace(_ workspace: Workspace, on monitor: Monitor, io: CmdIo) -> Bool {
        if workspace == focus.workspace && workspace.visibleMonitor != nil {
            if args.failIfNoop { return false }
            io.err("Workspace '\(workspaceDisplayName(workspace.name))' is already focused. Tip: use --fail-if-noop to exit with non-zero code")
            return true
        }
        guard activateWorkspaceForUser(workspace, on: monitor) else {
            return io.err("Can't activate workspace '\(workspace.name)' on monitor '\(monitor.name)': monitor assignment prevents activation")
        }
        return true
    }

    private enum ResolvedWorkspaceTarget {
        case focus(Workspace)
        case backAndForth
        case error
    }

    @MainActor
    private func resolveWorkspaceTarget(from focusedWs: Workspace, on monitor: Monitor, io: CmdIo) -> ResolvedWorkspaceTarget {
        switch args.target.val {
            case .relative(let nextPrev):
                guard let workspace = getNextPrevWorkspace(
                    current: focusedWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    on: monitor,
                )
                    ?? createNextTransientBlankWorkspaceIfAllowed(
                        from: focusedWs,
                        isNext: nextPrev == .next,
                        wrapAround: args.wrapAround,
                        usesStdin: args.useStdin,
                    ) else {
                    return .error
                }
                return .focus(workspace)
            case .direct(let name):
                return resolveDirectWorkspaceTarget(named: name.raw, from: focusedWs, io: io)
        }
    }

    @MainActor
    private func resolveDirectWorkspaceTarget(named workspaceName: String, from focusedWs: Workspace, io: CmdIo) -> ResolvedWorkspaceTarget {
        if let workspace = findDirectWorkspaceTarget(named: workspaceName, from: focusedWs) {
            return args.autoBackAndForth && workspace == focusedWs ? .backAndForth : .focus(workspace)
        }
        if args.autoBackAndForth && focusedWs.name == workspaceName {
            return .backAndForth
        }
        guard let workspace = createAdjacentTransientBlankWorkspaceIfAllowed(named: workspaceName, from: focusedWs) else {
            _ = io.err("Workspace '\(workspaceName)' doesn't exist")
            return .error
        }
        return .focus(workspace)
    }
}

@MainActor
private func focusOrReportNoop(
    _ workspace: Workspace,
    focusedWorkspace: Workspace,
    io: CmdIo,
    failIfNoop: Bool,
) -> Bool {
    if focusedWorkspace == workspace {
        if !failIfNoop {
            io.err("Workspace '\(workspaceDisplayName(workspace.name))' is already focused. Tip: use --fail-if-noop to exit with non-zero code")
        }
        return !failIfNoop
    }
    return workspace.focusWorkspace()
}

@MainActor
private func createNextTransientBlankWorkspaceIfAllowed(
    from current: Workspace,
    isNext: Bool,
    wrapAround: Bool,
    usesStdin: Bool,
) -> Workspace? {
    guard isNext, !wrapAround, !usesStdin else { return nil }
    let nextWorkspaceIndex = scopedAutomaticDisplayWorkspaces(current: current).count + 1
    return createAdjacentTransientBlankWorkspaceIfAllowed(named: String(nextWorkspaceIndex), from: current)
}

@MainActor
private func findDirectWorkspaceTarget(named workspaceName: String, from current: Workspace) -> Workspace? {
    if let targetIndex = parsePositiveWorkspaceDisplayIndex(workspaceName) {
        if NativeSpacesRuntime.shared.isNative,
           let workspace = NativeSpacesRuntime.shared.workspace(atDesktopIndex: targetIndex, on: current.workspaceMonitor) {
            return workspace
        }
        if let workspace = scopedAutomaticDisplayWorkspaces(current: current).getOrNil(atIndex: targetIndex - 1) {
            return workspace
        }
        guard let workspace = Workspace.existing(byName: workspaceName),
              workspace.projectId == current.projectId,
              isUserFacingWorkspace(workspace, focusedWorkspace: current)
        else {
            return nil
        }
        guard !workspace.usesAutomaticDisplayName else {
            return nil
        }
        return workspace
    }

    guard let workspace = Workspace.existing(byName: workspaceName),
          isUserFacingWorkspace(workspace, focusedWorkspace: current)
    else {
        return nil
    }
    return workspace
}

private struct RelativeWorkspaceNavigation {
    let workspaces: [Workspace]
    let anchorIndex: Int
}

@MainActor
private func resolveRelativeWorkspaceCandidates(current: Workspace, stdin: String?) -> [Workspace] {
    if let stdin {
        var seen: Set<Workspace> = []
        return stdin
            .split(separator: "\n")
            .map { String($0).trim() }
            .filter { !$0.isEmpty }
            .compactMap { workspaceName in
                guard let workspace = Workspace.existing(byName: workspaceName),
                      isUserFacingWorkspace(workspace, focusedWorkspace: current),
                      seen.insert(workspace).inserted
                else {
                    return nil
                }
                return workspace
            }
    }

    return orderedUserFacingWorkspaces(in: current.projectId, focusedWorkspace: current)
}

@MainActor
private func resolveRelativeWorkspaceNavigation(
    workspaces: [Workspace],
    current: Workspace,
    isNext: Bool,
    stdinProvided: Bool,
) -> RelativeWorkspaceNavigation {
    if let anchorIndex = workspaces.firstIndex(of: current) {
        return RelativeWorkspaceNavigation(workspaces: workspaces, anchorIndex: anchorIndex)
    }

    if stdinProvided, workspaces == workspaces.sorted() {
        let anchored = (workspaces + [current]).sorted()
        return RelativeWorkspaceNavigation(
            workspaces: anchored,
            anchorIndex: anchored.firstIndex(of: current).orDie(),
        )
    }

    return isNext
        ? RelativeWorkspaceNavigation(workspaces: [current] + workspaces, anchorIndex: 0)
        : RelativeWorkspaceNavigation(workspaces: workspaces + [current], anchorIndex: workspaces.count)
}

@MainActor
func getNextPrevWorkspace(current: Workspace, isNext: Bool, wrapAround: Bool, stdin: String?, on monitor: Monitor? = nil) -> Workspace? {
    let workspaces = resolveRelativeWorkspaceCandidates(current: current, stdin: stdin).filter { workspace in
        guard let monitor else { return true }
        return workspace == current || workspaceIsAvailableForMonitor(workspace, monitor: monitor)
    }
    guard !workspaces.isEmpty else { return nil }

    let navigation = resolveRelativeWorkspaceNavigation(
        workspaces: workspaces,
        current: current,
        isNext: isNext,
        stdinProvided: stdin != nil,
    )
    let targetIndex = isNext ? navigation.anchorIndex + 1 : navigation.anchorIndex - 1
    return wrapAround
        ? navigation.workspaces.get(wrappingIndex: targetIndex)
        : navigation.workspaces.getOrNil(atIndex: targetIndex)
}
