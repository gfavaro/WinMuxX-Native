import AppKit
import Combine
import Common

@MainActor
public func installNativeMenuBar(checkForUpdates: (() -> Void)? = nil) {
    NativeActionMenu.shared.install(checkForUpdates: checkForUpdates)
}

@MainActor
final class NativeActionMenu: NSObject, NSMenuDelegate {
    static let shared = NativeActionMenu()
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    private var checkForUpdates: (() -> Void)?
    private var bindings = ActionMenuBindings(mode: nil)
    private var lastIconState: (enabled: Bool, appearance: MenuBarIconAppearance, indicator: MenuBarIndicator, text: String, name: String)?

    func install(checkForUpdates: (() -> Void)?) {
        guard statusItem == nil else { return }
        self.checkForUpdates = checkForUpdates
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
        observation = TrayMenuModel.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let model = TrayMenuModel.shared
        let state = (enabled: model.isEnabled, appearance: model.experimentalUISettings.iconAppearance, indicator: model.experimentalUISettings.indicator, text: model.menuBarWorkspaceIndicator, name: model.menuBarWorkspaceName)
        if let previous = lastIconState, previous.enabled == state.enabled, previous.appearance == state.appearance, previous.indicator == state.indicator, previous.text == state.text, previous.name == state.name { return }
        lastIconState = state
        if model.isEnabled && state.indicator == .workspace {
            statusItem?.length = NSStatusItem.variableLength
            statusItem?.button?.image = nil
            statusItem?.button?.title = state.text
            statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            statusItem?.button?.toolTip = "WinMux · \(state.name) · Focused display"
            statusItem?.button?.setAccessibilityLabel("WinMux, workspace \(state.name), focused display")
            return
        }
        statusItem?.length = NSStatusItem.squareLength
        statusItem?.button?.title = ""
        statusItem?.button?.setAccessibilityLabel(model.isEnabled ? "WinMux" : "WinMux disabled")
        let image: NSImage?
        if model.isEnabled {
            let monochrome = model.experimentalUISettings.iconAppearance != .color
            image = NSImage(named: monochrome ? "MenuBarIconMonochrome" : "MenuBarIcon")?.copy() as? NSImage
            image?.isTemplate = monochrome
        } else {
            image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "WinMux disabled")
        }
        image?.size = NSSize(width: 18, height: 18)
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "WinMux"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        bindings = ActionMenuBindings(mode: activeMode.flatMap { config.modes[$0] })
        menu.addItem(NSMenuItem(title: "WinMux v\(winMuxAppVersion) · \(workspaceDisplayName(focus.workspace.name))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Mode: \(activeMode ?? "none")", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        for section in buildShortcutSections() where !section.actions.isEmpty {
            addSubmenu(section.title, to: menu) { submenu in
                for action in section.actions { addCommand(action.title, script: action.commandScript, to: submenu) }
            }
        }
        addSubmenu("Workspaces", to: menu) { submenu in
            addCommand("Previous", script: "workspace prev", to: submenu)
            addCommand("Next", script: "workspace next", to: submenu)
            addCommand("Back and Forth", script: "workspace-back-and-forth", to: submenu)
            for (workspace, target) in menuWorkspaceTargets() {
                let item = addCommand(workspaceDisplayName(workspace.name), args: ["workspace", target], to: submenu)
                item?.state = workspace == focus.workspace ? .on : .off
            }
        }
        addSubmenu("Move Window and Follow", to: menu) { submenu in
            addCommand("Previous", script: "move-node-to-workspace --focus-follows-window prev", to: submenu)
            addCommand("Next", script: "move-node-to-workspace --focus-follows-window next", to: submenu)
            for (workspace, target) in menuWorkspaceTargets() {
                addCommand(workspaceDisplayName(workspace.name), args: ["move-node-to-workspace", "--focus-follows-window", target], to: submenu)
            }
        }
        addSubmenu("Move Window to Workspace", to: menu) { submenu in
            addCommand("Previous", script: "move-node-to-workspace prev", to: submenu)
            addCommand("Next", script: "move-node-to-workspace next", to: submenu)
            for (workspace, target) in menuWorkspaceTargets() {
                addCommand(workspaceDisplayName(workspace.name), args: ["move-node-to-workspace", target], to: submenu)
            }
        }
        addSubmenu("Bring Workspace Here", to: menu) { submenu in
            for (workspace, _) in menuWorkspaceTargets() {
                addCommand(workspaceDisplayName(workspace.name), args: ["summon-workspace", workspace.name], to: submenu)
            }
        }
        addSubmenu("Projects", to: menu) { submenu in
            addCommand("Previous", script: "project prev", to: submenu)
            addCommand("Next", script: "project next", to: submenu)
            for (index, project) in workspaceProjects().enumerated() {
                addCommand(project.name, script: "project \(index + 1)", to: submenu)
                addCommand("Move Window to \(project.name)", script: "move-node-to-project \(index + 1)", to: submenu)
            }
        }
        addSubmenu("Monitors", to: menu) { submenu in
            addCommand("Focus Previous", script: "focus-monitor prev", to: submenu)
            addCommand("Focus Next", script: "focus-monitor next", to: submenu)
            addCommand("Focus Main", script: "focus-monitor main", to: submenu)
            addCommand("Focus Secondary", script: "focus-monitor secondary", to: submenu)
            addCommand("Move Workspace to Main", script: "move-workspace-to-monitor main", to: submenu)
            addCommand("Move Workspace to Secondary", script: "move-workspace-to-monitor secondary", to: submenu)
            for (index, monitor) in sortedMonitors.enumerated() {
                let target = String(index + 1)
                addCommand("Focus \(monitor.name)", args: ["focus-monitor", target], to: submenu)
                addCommand("Move Window to \(monitor.name)", args: ["move-node-to-monitor", target], to: submenu)
                addCommand("Move Workspace to \(monitor.name)", args: ["move-workspace-to-monitor", target], to: submenu)
            }
        }
        addSubmenu("Modes", to: menu) { submenu in
            for mode in config.modes.keys.sorted() {
                let item = addCommand(mode, args: ["mode", mode], to: submenu)
                item?.state = mode == activeMode ? .on : .off
            }
        }
        addCommand("Reload Config", script: "reload-config", to: menu, requiresWindow: false, allowDisabled: true)
        addCommand(TrayMenuModel.shared.isEnabled ? "Disable" : "Enable", script: "enable toggle", to: menu, requiresWindow: false, allowDisabled: true)
        let others = bindings.unshown
        if !others.isEmpty {
            addSubmenu("Other Key Bindings", to: menu) { submenu in
                for binding in others {
                    let item = commandItem(binding.commands.prettyDescription, commands: binding.commands)
                    applyBindings([binding], to: item)
                    submenu.addItem(item)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(callbackItem("Settings…", #selector(openSettings)))
        menu.addItem(callbackItem("Copy Version", #selector(copyVersion)))
        menu.addItem(callbackItem("Open Config", #selector(openConfig)))
        menu.addItem(callbackItem("Diagnostics…", #selector(openDiagnostics)))
        if MacWindow.allWindows.contains(where: { !$0.learnedMinimum.isEmpty }) {
            menu.addItem(callbackItem("Reset Learned Minimum Sizes…", #selector(resetMinimumSizes)))
        }
        let recoverableCount = WindowRecoveryController.shared.recoverableEntries.count
        if recoverableCount > 0 {
            let item = callbackItem("Recover \(recoverableCount) Windows from Previous Session…", #selector(recoverWindows))
            item.isEnabled = !WindowRecoveryController.shared.isRecovering
            menu.addItem(item)
        }
        if checkForUpdates != nil { menu.addItem(callbackItem("Check for Updates…", #selector(checkUpdates))) }
        menu.addItem(callbackItem("GitHub Repository", #selector(openRepository)))
        menu.addItem(callbackItem("File an Issue…", #selector(openIssue)))
        menu.addItem(callbackItem("Quit WinMux", #selector(quit)))
    }

    private func addSubmenu(_ title: String, to menu: NSMenu, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        build(submenu)
        item.submenu = submenu
        menu.addItem(item)
    }

    @discardableResult
    private func addCommand(_ title: String, script: String, to menu: NSMenu, requiresWindow: Bool? = nil, allowDisabled: Bool = false) -> NSMenuItem? {
        guard case .cmd(let command) = parseCommand(script) else { return nil }
        return addCommand(title, command: command, to: menu, requiresWindow: requiresWindow, allowDisabled: allowDisabled)
    }

    @discardableResult
    private func addCommand(_ title: String, args: [String], to menu: NSMenu) -> NSMenuItem? {
        guard case .cmd(let command) = parseCommand(args) else { return nil }
        return addCommand(title, command: command, to: menu)
    }

    private func addCommand(_ title: String, command: any Command, to menu: NSMenu, requiresWindow: Bool? = nil, allowDisabled: Bool = false) -> NSMenuItem {
        let item = commandItem(title, commands: [command])
        let needsWindow = requiresWindow ?? menuCommandRequiresWindow(command)
        item.isEnabled = (allowDisabled || TrayMenuModel.shared.isEnabled) && (!needsWindow || focus.windowOrNil != nil)
        applyBindings(bindings.bindings(for: command), to: item)
        menu.addItem(item)
        return item
    }

    private func commandItem(_ title: String, commands: [any Command]) -> NSMenuItem {
        let displayTitle = title.count > 140 ? String(title.prefix(140)) + "…" : title
        let item = callbackItem(displayTitle, #selector(runCommand(_:)))
        item.representedObject = MenuCommandPayload(commands: commands)
        item.toolTip = commands.prettyDescription
        item.isEnabled = TrayMenuModel.shared.isEnabled && (!commands.contains(where: menuCommandRequiresWindow) || focus.windowOrNil != nil)
        return item
    }

    private func applyBindings(_ matches: [ActionMenuBinding], to item: NSMenuItem) {
        if matches.count == 1, let binding = matches.first, let key = binding.keyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = binding.modifiers
        } else if !matches.isEmpty {
            item.title += "  [\(matches.map(\.notation).joined(separator: ", "))]"
        }
    }

    private func callbackItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuCommandPayload else { return }
        var environment = CmdEnv.defaultEnv
        if payload.commands.count == 1, payload.commands.first is CloseAllWindowsButCurrentCommand {
            environment = environment.withFocus(focus)
            let alert = NSAlert()
            alert.messageText = "Close other windows in this workspace?"
            alert.informativeText = "Applications may ask you to save unsaved changes. The focused window will stay open."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Close Other Windows")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let commandEnvironment = environment
        Task {
            do {
                guard let token = RunSessionGuard.isServerEnabled(orIsEnableCommand: payload.commands.first) ?? (payload.commands.first is ReloadConfigCommand ? .forceRun : nil) else { return }
                try await runLightSession(.menuBarButton, token, shouldSchedulePostRefresh: !payload.commands.canSkipPostCommandRefresh) {
                    let result = try await payload.commands.runCmdSeq(commandEnvironment, .emptyStdin)
                    if result.exitCode != 0 {
                        MessageModel.shared.message = Message(description: "Menu Command Error", body: (result.stderr + result.stdout).joined(separator: "\n"))
                    }
                }
            } catch {
                MessageModel.shared.message = Message(description: "Menu Command Error", body: String(describing: error))
            }
        }
    }

    @objc private func openSettings() { ShortcutSettingsModel.shared.requestWindowOpen() }
    @objc private func copyVersion() { "\(winMuxAppName) v\(winMuxAppVersion) \(gitHash)".copyToClipboard() }
    @objc private func openConfig() {
        NSWorkspace.shared.open(findCustomConfigUrl().urlOrNil ?? ((try? ensureBootstrapConfigExistsIfNeeded()) ?? preferredEditableConfigUrl()))
    }
    @objc private func openDiagnostics() { DiagnosticsWindowController.shared.show() }
    @objc private func resetMinimumSizes() {
        let alert = NSAlert()
        alert.messageText = "Reset learned minimum window sizes?"
        alert.informativeText = "This clears session-local observations only. Window positions and your configuration are unchanged."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        for window in MacWindow.allWindows { window.resetLearnedMinimum() }
    }
    @objc private func recoverWindows() {
        let alert = NSAlert()
        alert.messageText = "Recover windows from a previous session?"
        alert.informativeText = "WinMux will pause tiling and restore their original positions and sizes. Windows whose app identity changed or whose original display is disconnected will be skipped."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Pause Tiling and Recover")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            let report = await WindowRecoveryController.shared.recoverAfterCrash()
            MessageModel.shared.message = Message(description: "Window Recovery", body: report)
        }
    }
    @objc private func checkUpdates() { checkForUpdates?() }
    @objc private func openRepository() { NSWorkspace.shared.open(URL(string: forkRepositoryURL)!) }
    @objc private func openIssue() { NSWorkspace.shared.open(URL(string: forkRepositoryURL + "/issues/new")!) }
    @objc private func quit() { terminateApp() }

}

final class MenuCommandPayload {
    let commands: [any Command]
    init(commands: [any Command]) { self.commands = commands }
}

func menuCommandRequiresWindow(_ command: any Command) -> Bool {
    switch command {
        case is FocusCommand, is MoveCommand, is JoinWithCommand, is StackWithCommand,
             is SwapCommand, is ResizeCommand, is LayoutCommand, is FullscreenCommand,
             is MoveNodeToWorkspaceCommand, is MoveNodeToMonitorCommand, is MoveNodeToProjectCommand,
             is SplitCommand, is CloseCommand, is CloseAllWindowsButCurrentCommand,
             is MacosNativeMinimizeCommand, is MacosNativeFullscreenCommand: true
        default: false
    }
}

@MainActor
func menuWorkspaceTargets() -> [(workspace: Workspace, target: String)] {
    userFacingWorkspaces(orderedWorkspacesForPresentation(), focusedWorkspace: focus.workspace)
        .filter { $0.projectId == focus.workspace.projectId }
        .map { workspace in
            let target = workspace.usesAutomaticDisplayName
                ? automaticWorkspaceDisplayIndex(workspace, focusedWorkspace: focus.workspace).map(String.init) ?? workspace.name
                : workspace.name
            return (workspace, target)
        }
}
