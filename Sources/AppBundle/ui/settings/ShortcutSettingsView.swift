import AppKit
import Common
import MASShortcut
import SwiftUI

// Measured from System Settings on macOS 27: fixed width, vertically resizable.
let settingsWindowWidth: CGFloat = 757
let settingsWindowMinimumHeight: CGFloat = 470

public let shortcutSettingsWindowId = "\(winMuxAppName).shortcutSettings"

@MainActor
public func getShortcutSettingsWindow(model: ShortcutSettingsModel) -> some Scene {
    SwiftUI.Window("WinMuxX-Native Settings", id: shortcutSettingsWindowId) {
        ShortcutSettingsView(model: model)
            .frame(minWidth: settingsWindowWidth, maxWidth: settingsWindowWidth,
                   minHeight: settingsWindowMinimumHeight, maxHeight: .infinity)
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
            }
    }
    .defaultSize(width: settingsWindowWidth, height: 700)
    .windowResizability(.contentSize)
}

@MainActor
public func openShortcutSettingsWindow(_ openWindow: OpenWindowAction) {
    ShortcutSettingsModel.shared.reload()
    if let existingWindow = shortcutSettingsWindow() {
        presentShortcutSettingsWindow(existingWindow)
    } else {
        openWindow(id: shortcutSettingsWindowId)
        DispatchQueue.main.async {
            if let createdWindow = shortcutSettingsWindow() {
                presentShortcutSettingsWindow(createdWindow)
            }
        }
    }
}

enum SettingsSidebarItem: Hashable, Identifiable, CaseIterable {
    case general
    case shortcuts
    case workspaces
    case appearance
    case windows
    case automation
    case configuration
    case reference

    var id: Self { self }

    var label: String {
        switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .workspaces: "Workspaces"
            case .windows: "Windows"
            case .appearance: "Sidebar & Appearance"
            case .automation: "Automation"
            case .configuration: "Configuration"
            case .reference: "Configuration Reference"
        }
    }

    var icon: String {
        switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .workspaces: "rectangle.3.group"
            case .windows: "macwindow.on.rectangle"
            case .appearance: "sidebar.left"
            case .automation: "gearshape.2"
            case .configuration: "doc.text"
            case .reference: "book"
        }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @State private var selectedItem: SettingsSidebarItem? = .general

    private let sidebarItems = SettingsSidebarItem.allCases

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedItem) {
                ForEach(sidebarItems) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            Group {
                switch selectedItem {
                    case .general:
                        ShortcutGeneralSettingsView(model: model)
                    case .shortcuts:
                        ShortcutSettingsShortcutsView(model: model)
                    case .workspaces:
                        ShortcutSettingsWorkspacePane(model: model)
                    case .windows:
                        ShortcutBehaviorSettingsView(model: model)
                    case .appearance:
                        ShortcutAppearanceSettingsView(model: model)
                            .id(model.settingsRevision)
                    case .automation:
                        ShortcutAutomationSettingsView(model: model)
                    case .configuration:
                        ShortcutAdvancedView(model: model)
                    case .reference:
                        ShortcutConfigurationReferenceView()
                    case nil:
                        Text("Select an item")
                }
            }
            .id(model.failedSaveRevision)
            .navigationTitle(selectedItem?.label ?? "")
        }
    }
}

struct ShortcutSettingsShortcutsView: View {
    @ObservedObject var model: ShortcutSettingsModel

    var body: some View {
        ShortcutCategoryView(model: model, category: .managed)
    }
}

struct ShortcutSettingsWorkspacePane: View {
    @ObservedObject var model: ShortcutSettingsModel

    var body: some View {
        ShortcutCategoryView(model: model, category: .common)
    }
}

struct ShortcutCategoryView: View {
    @ObservedObject var model: ShortcutSettingsModel
    let category: ShortcutSettingsModel.Category
    @State private var shortcutsPreset = config.shortcutsPreset.rawValue
    @State private var projectDeletionAction = config.workspaceSidebar.projectDeletionAction
    @State private var persistentWorkspaces = config.persistentWorkspaces.joined(separator: ", ")

    var body: some View {
        Form {
            if let error = model.errorMessage {
                Section("Could not save setting") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if category == .common {
                Section("Workspace availability") {
                    SettingsTextField("Persistent workspaces", text: $persistentWorkspaces,
                        help: "Comma-separated names of workspaces that remain available when empty.") {
                        persistSettingsConfig(section: nil, key: "persistent-workspaces",
                            renderedValue: tomlCommaSeparatedStringArray(persistentWorkspaces), model: model)
                    }
                    Picker("Deleting projects", selection: $projectDeletionAction) {
                        Text("Close project windows").tag(WorkspaceProjectDeletionAction.closeWindows)
                        Text("Move windows elsewhere").tag(WorkspaceProjectDeletionAction.moveWindowsToFallback)
                    }
                    .onChange(of: projectDeletionAction) { value in
                        persistSettingsConfig(section: "workspace-sidebar", key: "project-deletion-action",
                            renderedValue: "'\(value.rawValue)'", model: model)
                    }
                }
            }

            if category == .managed {
                Section("Shortcut preset") {
                    Picker("Preset", selection: $shortcutsPreset) {
                        Text("Custom").tag("none")
                        Text("Rectangle").tag("rectangle")
                    }
                    .onChange(of: shortcutsPreset) { value in
                        persistSettingsConfig(section: nil, key: "shortcuts-preset",
                            renderedValue: "'\(value)'", model: model)
                    }
                }
            }

            let sections = model.sections.filter { $0.category == category && $0.id != "managed-move" }
            ForEach(sections) { section in
                ShortcutSectionView(model: model, section: section)
            }
        }
        .formStyle(.grouped)
        .id(model.settingsRevision)
    }
}

struct ShortcutSectionView: View {
    @ObservedObject var model: ShortcutSettingsModel
    let section: ShortcutSettingsModel.Section

    var body: some View {
        Section {
            if section.id == "managed-focus" {
                ManagedDirectionalShortcutsView(model: model)
            } else if section.id == "managed-move" {
                EmptyView()
            } else if section.id == "managed-splits" {
                CompassPad(model: model, title: "Split", prefix: "split") {
                    SplitDemoView()
                }
            } else if section.id == "workspaces" {
                WorkspaceShortcutSectionView(model: model)
            } else {
                ForEach(section.actions) { action in
                    ShortcutRow(model: model, action: action)
                }
            }
        } header: {
            if section.id != "managed-focus" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                    if let summary = section.summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}


struct ShortcutRow: View {
    @ObservedObject var model: ShortcutSettingsModel
    let action: ShortcutSettingsModel.Action

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(
                shortcut: .init(get: { model.shortcutValue(for: action.id) },
                                set: { model.setShortcutValue($0, for: action.id) }),
                onChange: { _ in }
            )
            .frame(width: 140, height: 22)
        }
        .padding(.vertical, 6)
    }
}
