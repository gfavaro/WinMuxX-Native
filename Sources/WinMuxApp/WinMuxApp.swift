import AppBundle
import SwiftUI

// This file is shared between SPM and xcode project

@main
struct WinMuxApp: App {
    @NSApplicationDelegateAdaptor(WinMuxApplicationDelegate.self) var applicationDelegate
    @StateObject var viewModel = TrayMenuModel.shared
    @StateObject var messageModel = MessageModel.shared
    @StateObject var shortcutSettingsModel = ShortcutSettingsModel.shared
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    init() {
        initAppBundle()
        // Fork builds intentionally have no updater until a separately signed feed exists.
        installNativeMenuBar()
    }

    var body: some Scene {
        getShortcutSettingsWindow(model: shortcutSettingsModel)
            .onChange(of: shortcutSettingsModel.openRequestId) { _ in
                openShortcutSettingsWindow(openWindow)
            }
        getMessageWindow(messageModel: messageModel)
            .onChange(of: messageModel.message) { message in
                if message != nil {
                    openWindow(id: messageWindowId)
                }
            }
    }
}
