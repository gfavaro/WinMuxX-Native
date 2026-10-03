import SwiftUI

struct ShortcutAutomationSettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @State private var startupCommands = ""
    @State private var workspaceCommands = ""
    @State private var focusCommands = ""
    @State private var monitorCommands = ""
    @State private var modeCommands = ""

    var body: some View {
        SettingsScrollView {
            if let error = model.errorMessage {
                SettingsSection("Could not save setting") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            SettingsSection("Event actions") {
                SettingsMultilineField("On workspace change", text: $workspaceCommands, help: "One command per line. Commands run after changing workspaces.", savedValue: config.execOnWorkspaceChange.joined(separator: "\n")) { onSaved in saveCommands("exec-on-workspace-change", workspaceCommands, onSaved: onSaved) }
                SettingsMultilineField("On focus change", text: $focusCommands, help: "One command per line. Commands run after the focused window changes.", savedValue: config.onFocusChanged.map { $0.args.description }.joined(separator: "\n")) { onSaved in saveCommands("on-focus-changed", focusCommands, onSaved: onSaved) }
                SettingsMultilineField("On focused monitor change", text: $monitorCommands, help: "One command per line. Commands run after the active display changes.", savedValue: config.onFocusedMonitorChanged.map { $0.args.description }.joined(separator: "\n")) { onSaved in saveCommands("on-focused-monitor-changed", monitorCommands, onSaved: onSaved) }
                SettingsMultilineField("On mode change", text: $modeCommands, help: "One command per line. Commands run after a mode changes.", savedValue: config.onModeChanged.map { $0.args.description }.joined(separator: "\n")) { onSaved in saveCommands("on-mode-changed", modeCommands, onSaved: onSaved) }
            }
            SettingsSection("Startup") {
                SettingsMultilineField(
                    "After startup",
                    text: $startupCommands,
                    help: "One command per line. Commands run after WinMuxX-Native finishes starting.",
                    savedValue: config.afterStartupCommand.map { $0.args.description }.joined(separator: "\n")
                ) { onSaved in
                    saveCommands("after-startup-command", startupCommands, onSaved: onSaved)
                }
            }
        }
        .navigationTitle("Automation")
        .task { loadCommands() }
        .onChange(of: modeCommands) { model.automationDrafts["on-mode-changed"] = $0 }
        .onChange(of: monitorCommands) { model.automationDrafts["on-focused-monitor-changed"] = $0 }
        .onChange(of: focusCommands) { model.automationDrafts["on-focus-changed"] = $0 }
        .onChange(of: workspaceCommands) { model.automationDrafts["exec-on-workspace-change"] = $0 }
        .onChange(of: startupCommands) { model.automationDrafts["after-startup-command"] = $0 }
        .id(model.settingsRevision)
    }

    private func loadCommands() {
        workspaceCommands = model.automationDrafts["exec-on-workspace-change"] ?? config.execOnWorkspaceChange.joined(separator: "\n")
        startupCommands = model.automationDrafts["after-startup-command"] ?? config.afterStartupCommand.map { $0.args.description }.joined(separator: "\n")
        focusCommands = model.automationDrafts["on-focus-changed"] ?? config.onFocusChanged.map { $0.args.description }.joined(separator: "\n")
        monitorCommands = model.automationDrafts["on-focused-monitor-changed"] ?? config.onFocusedMonitorChanged.map { $0.args.description }.joined(separator: "\n")
        modeCommands = model.automationDrafts["on-mode-changed"] ?? config.onModeChanged.map { $0.args.description }.joined(separator: "\n")
    }

    private func saveCommands(_ key: String, _ commands: String, onSaved: @escaping () -> Void) {
        persistSettingsConfig(section: nil, key: key, renderedValue: tomlStringArray(commands), model: model) {
            if model.automationDrafts[key] == commands { model.automationDrafts.removeValue(forKey: key) }
            onSaved()
        }
    }

}
