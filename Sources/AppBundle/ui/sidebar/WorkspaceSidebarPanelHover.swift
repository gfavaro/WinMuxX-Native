import AppKit
import Common
import CoreGraphics
import SwiftUI

extension WorkspaceSidebarPanel {
    func setHovering(_ isHovering: Bool) {
        let expandedWidth = CGFloat(config.workspaceSidebar.width)
        let collapsedWidth = workspaceSidebarRestingWidth(config.workspaceSidebar)
        if viewModel.workspaceSidebarVisibleWidth > collapsedWidth + 0.5 || pendingCollapse != nil {
            debugWorkspaceSidebarHoverLog("setHovering panel=\(monitorScopeId) isHovering=\(isHovering) visible=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
        }
        if isHovering {
            handleHoverEnter(
                expandedWidth: max(expandedWidth, viewModel.workspaceSidebarVisibleWidth),
                collapsedWidth: collapsedWidth
            )
        } else {
            handleHoverExit(collapsedWidth: collapsedWidth)
        }
    }

    func shouldLockExpansionForSidebarDrag() -> Bool {
        shouldLockWorkspaceSidebarExpansion(
            hasDropPreview: TrayMenuModel.shared.workspaceSidebarDropPreview != nil,
            hasPinnedDraggedWindow: hasPinnedDraggedWindow(),
            isSidebarDragInProgress: getCurrentMouseManipulationKind() == .move && getCurrentMouseDragStartedInSidebar(),
            hasActiveEditor: isMenuTrackingOrInGracePeriod() || shouldKeepSidebarOpenForInlineTextEditing(),
        ) || isMouseWindowDragInProgress() || overrideConfirmationLocksCollapse
    }

    func shouldKeepSidebarOpenForInlineTextEditing() -> Bool {
        commandExpansionLocksCollapse || (inlineTextEditingActive && inlineTextEditingLocksExpansion)
    }
}

extension WorkspaceSidebarPanel {
    func showHoverCue(cueWidth: CGFloat, expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth < cueWidth {
            animateVisibleSidebarWidth(
                cueWidth,
                animation: .spring(response: hoverCueAnimationResponse, dampingFraction: 0.72),
            )
        } else {
            updateMousePassthrough()
        }

        guard isMouseDeepEnoughToExpand() else {
            pendingExpand?.cancel()
            pendingExpand = nil
            return
        }
        scheduleHoverExpansion(expandedWidth: expandedWidth, collapsedWidth: collapsedWidth)
    }

    func scheduleHoverExpansion(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        guard pendingExpand == nil else { return }
        let expand = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingExpand = nil
            guard self.isMouseInsideHoverRegion(),
                  self.isMouseDeepEnoughToExpand()
            else { return }
            self.expandSidebar(to: expandedWidth)
        }
        pendingExpand = expand
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: expand)
    }
}

extension WorkspaceSidebarPanel {
    func handleHoverEnter(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        let cueWidth = workspaceSidebarHoverCueWidth(collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let isExpansionLocked = shouldLockExpansionForSidebarDrag()
        let isExternalWindowDrag = isMouseWindowDragInProgress()
        let isSidebarOriginatedDrag = getCurrentMouseDragStartedInSidebar()
        let shouldSuppressDragExpansion = shouldSuppressWorkspaceSidebarHoverExpansionForDrag(
            isSidebarItemDragActive: isWorkspaceSidebarItemDragActive(),
            isSidebarOriginatedDrag: isSidebarOriginatedDrag,
        )
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
        if shouldSuppressDragExpansion {
            pendingExpand?.cancel()
            pendingExpand = nil
            updateMousePassthrough()
            return
        }

        if isExternalWindowDrag && !isSidebarOriginatedDrag && isMousePushedAgainstDisplayEdge() {
            showCollapsedSidebarDuringExternalDrag(
                collapsedWidth: workspaceSidebarHoverActivationWidth(config.workspaceSidebar)
            )
            return
        }
        if !shouldDelayWorkspaceSidebarExpansion(
            isExpanded: viewModel.isWorkspaceSidebarExpanded,
            isExpansionLocked: isExpansionLocked,
            isMouseWindowDragInProgress: isExternalWindowDrag,
        ) {
            expandSidebar(to: expandedWidth)
            return
        }
        showHoverCue(cueWidth: cueWidth, expandedWidth: expandedWidth, collapsedWidth: collapsedWidth)
    }

    func showCollapsedSidebarDuringExternalDrag(collapsedWidth: CGFloat) {
        pendingExpand?.cancel()
        pendingExpand = nil
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth != collapsedWidth {
            animateVisibleSidebarWidth(collapsedWidth, animation: .easeInOut(duration: animationDuration))
        } else {
            updateMousePassthrough()
        }
    }
}

extension WorkspaceSidebarPanel {
    func handleHoverExit(collapsedWidth: CGFloat) {
        debugWorkspaceSidebarHoverLog("handleHoverExit panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) expanded=\(viewModel.isWorkspaceSidebarExpanded) suppressActive=\(Date() < splitBrowseCollapseSuppressedUntil) mouse=\(NSEvent.mouseLocation)")
        pendingExpand?.cancel()
        pendingExpand = nil
        guard !config.workspaceSidebar.alwaysExpanded else {
            cancelExpansionWork()
            expandSidebar(to: CGFloat(config.workspaceSidebar.width))
            return
        }
        guard Date() >= splitBrowseCollapseSuppressedUntil else {
            debugWorkspaceSidebarHoverLog("handleHoverExit suppressed panel=\(monitorScopeId)")
            return
        }
        guard !shouldLockExpansionForSidebarDrag() else {
            debugWorkspaceSidebarHoverLog("handleHoverExit locked panel=\(monitorScopeId)")
            return
        }
        let needsCollapse =
            viewModel.isWorkspaceSidebarExpanded ||
            viewModel.workspaceSidebarVisibleWidth != collapsedWidth
        guard needsCollapse, pendingCollapse == nil else {
            debugWorkspaceSidebarHoverLog("handleHoverExit noop panel=\(monitorScopeId) needsCollapse=\(needsCollapse) pendingCollapse=\(pendingCollapse != nil)")
            return
        }
        scheduleCollapse(collapsedWidth: collapsedWidth)
    }

    func scheduleCollapse(collapsedWidth: CGFloat) {
        guard !config.workspaceSidebar.alwaysExpanded else { return }
        debugWorkspaceSidebarHoverLog("scheduleCollapse panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) mouse=\(NSEvent.mouseLocation)")
        NotificationCenter.default.post(name: workspaceSidebarWillCollapseNotification, object: self)
        let collapse = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapse = nil
            guard !config.workspaceSidebar.alwaysExpanded else { return }
            debugWorkspaceSidebarHoverLog("collapseFire panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.splitBrowseCollapseSuppressedUntil)")
            guard Date() >= self.splitBrowseCollapseSuppressedUntil else {
                debugWorkspaceSidebarHoverLog("collapseFire suppressed panel=\(self.monitorScopeId)")
                return
            }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFire cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            self.animateVisibleSidebarWidth(collapsedWidth, animation: .easeInOut(duration: self.animationDuration))
            self.scheduleCollapseFinalize()
        }
        pendingCollapse = collapse
        let collapseDelay: TimeInterval = viewModel.isWorkspaceSidebarExpanded ? 0.08 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: collapse)
    }

    func scheduleCollapseFinalize() {
        let finalize = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapseFinalize = nil
            guard !config.workspaceSidebar.alwaysExpanded else { return }
            debugWorkspaceSidebarHoverLog("collapseFinalize panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.splitBrowseCollapseSuppressedUntil)")
            guard Date() >= self.splitBrowseCollapseSuppressedUntil else { return }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFinalize cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            viewModel.isWorkspaceSidebarExpanded = false
            self.updateMousePassthrough()
        }
        pendingCollapseFinalize = finalize
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration, execute: finalize)
    }
}

extension WorkspaceSidebarPanel {
    /// Hover state is a pure function of the mouse position and the panel geometry, so it is
    /// driven by the global/local pointer-event monitors (mouse position changes) plus explicit
    /// rechecks at the points where the panel itself appears or resizes (geometry changes).
    /// This used to be a permanent CVDisplayLink subscription polling at 30Hz, which kept the
    /// display link running and woke the main actor every vsync even when the machine was idle.
    static func noteHoverPointerActivityForVisiblePanels(timestamp: TimeInterval) {
        for panel in visiblePanels {
            panel.noteHoverPointerActivity(timestamp: timestamp)
        }
    }

    /// For lock-release points that arrive without pointer movement (drag ends on mouse-up
    /// with a stationary cursor): the expansion locks cleared, so hover must be re-evaluated
    /// even though no pointer event will fire.
    static func scheduleHoverRecheckForVisiblePanels() {
        for panel in visiblePanels {
            panel.scheduleHoverRecheckSoon()
        }
    }

    /// Rate-limited to `hoverPollInterval`, with a trailing recheck so the final position of an
    /// event burst is always evaluated (a leading-edge-only throttle could drop the last event
    /// and leave hover state stale until the next mouse move).
    private func noteHoverPointerActivity(timestamp: TimeInterval) {
        if timestamp - lastHoverMonitorTimestamp >= hoverPollInterval {
            lastHoverMonitorTimestamp = timestamp
            updateHoverStateFromMousePosition()
        } else if !hasPendingHoverRecheck {
            hasPendingHoverRecheck = true
            let delay = max(hoverPollInterval - (timestamp - lastHoverMonitorTimestamp), 0.001)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.hasPendingHoverRecheck = false
                self.lastHoverMonitorTimestamp = ProcessInfo.processInfo.systemUptime
                self.updateHoverStateFromMousePosition()
            }
        }
    }

    /// Deferred (not inline) so hover reevaluation can be requested from inside
    /// expansion/collapse/refresh paths without re-entering them synchronously.
    func scheduleHoverRecheckSoon() {
        guard !hasPendingHoverRecheck else { return }
        hasPendingHoverRecheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingHoverRecheck = false
            self.updateHoverStateFromMousePosition()
        }
    }

    func updateHoverStateFromMousePosition() {
        guard isVisible else { return }
        updateMousePassthrough()
        setHovering(isMouseInsideHoverRegion())
    }
}
