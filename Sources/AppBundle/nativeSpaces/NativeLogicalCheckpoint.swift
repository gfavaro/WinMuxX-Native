import AppKit
import Common

/// Keeps original objects and bindings alive while a native transition is staged.
/// A partial move is recovered physically by the journal before these logical links
/// and both viewport histories are restored together.
@MainActor
struct NativeLogicalCheckpoint {
    private let state: WinMuxWorkspaceState
    private let focus: RefreshSessionFocusSnapshot
    private let placements: [(TreeNode, BindingData)]
    private let workspaceMetadata: [(Workspace, WorkspaceProjectId, CGPoint?, WorkspaceLifecycle)]
    private let containerLayouts: [(TilingContainer, Orientation, Layout, [CGFloat], Orientation?)]
    private let recentChildren: [(TreeNode, [TreeNode])]
    private let windowReasons: [(Window, LayoutReason)]

    init() {
        state = winMuxWorkspaceState
        focus = captureRefreshSessionFocusSnapshot()
        workspaceMetadata = Workspace.all.map { ($0, $0.projectId, $0.preferredMonitorPoint, $0.lifecycle) }
        var placements: [(TreeNode, BindingData)] = []
        func collect(_ node: TreeNode) {
            if let binding = node.bindingDataSnapshot { placements.append((node, binding)) }
            for child in node.children { collect(child) }
        }
        for workspace in Workspace.all {
            for child in workspace.children { collect(child) }
        }
        for child in macosMinimizedWindowsContainer.children { collect(child) }
        for child in macosPopupWindowsContainer.children { collect(child) }
        self.placements = placements
        containerLayouts = placements.compactMap { node, _ in
            (node as? TilingContainer).map { ($0, $0.orientation, $0.layout, $0.dwindleSplitRatios, $0.dwindleOrientation) }
        }
        recentChildren = (Workspace.all.map { $0 as TreeNode } + placements.map { $0.0 }).map { ($0, $0.childrenByMostRecentUse) }
        windowReasons = placements.compactMap { node, _ in (node as? Window).map { ($0, $0.layoutReason) } }
    }

    func restore() {
        // Clear generated roots first; restoring original placements cannot leave two roots.
        for workspace in Workspace.all {
            for child in workspace.children { _ = child.unbindFromParent() }
        }
        for (node, _) in placements where node.isBound { _ = node.unbindFromParent() }
        winMuxWorkspaceState = state
        for (workspace, project, monitor, lifecycle) in workspaceMetadata {
            workspace.projectId = project
            workspace.preferredMonitorPoint = monitor
            workspace.lifecycle = lifecycle
        }
        for (node, binding) in placements {
            // Closed windows are not resurrected during a rollback.
            if let window = node as? MacWindow, MacWindow.allWindowsMap[window.windowId] !== window { continue }
            node.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: min(binding.index, binding.parent.children.count))
        }
        for (container, orientation, layout, ratios, dwindle) in containerLayouts {
            container.restoreNativeCheckpointLayout(orientation, layout, ratios, dwindle)
        }
        for (node, order) in recentChildren { node.restoreMostRecentChildren(order) }
        for (window, reason) in windowReasons { window.layoutReason = reason }
        syncClosedWindowsCacheToCurrentWorld()
        restoreFocusAfterNativeFailure(focus)
    }
}
