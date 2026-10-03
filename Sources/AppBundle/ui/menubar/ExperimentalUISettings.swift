import Common
import SwiftUI

struct ExperimentalUISettings {
    var doubleSidedWindows: Bool {
        get { nativePreferences.bool(forKey: "doubleSidedWindows") }
        set { nativePreferences.set(newValue, forKey: "doubleSidedWindows") }
    }

    var indicator: MenuBarIndicator {
        get { MenuBarIndicator(rawValue: nativePreferences.string(forKey: "menuBarIndicator") ?? "") ?? .icon }
        set { nativePreferences.set(newValue.rawValue, forKey: "menuBarIndicator") }
    }

    var iconAppearance: MenuBarIconAppearance {
        get {
            guard let value = nativePreferences.string(forKey: "iconAppearance") else {
                return .color
            }
            return MenuBarIconAppearance(rawValue: value) ?? .color
        }
        set {
            nativePreferences.setValue(newValue.rawValue, forKey: "iconAppearance")
            nativePreferences.synchronize()
        }
    }
}

enum MenuBarIconAppearance: String, CaseIterable, Identifiable, Equatable, Hashable {
    case color
    case monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
            case .color: "Color"
            case .monochrome: "Monochrome"
        }
    }
}

enum MenuBarIndicator: String, CaseIterable, Identifiable {
    case icon, workspace
    var id: String { rawValue }
    var title: String { self == .icon ? "Icon" : "Workspace" }
}

func menuBarWorkspaceIndicator(label: String?, number: Int) -> String {
    let label = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return label.first.map { String($0).uppercased() } ?? String(number)
}
