import AppKit
import Foundation
import NativeSpacesPrivate

/// Read-only local probe. It never creates, switches, moves, destroys, or initializes
/// the application backend, and never requests permissions or changes system settings.
@MainActor
func printNativeSpacesStatus() {
    // NSScreen returns false before NSApplication initializes its connection, even
    // when com.apple.spaces spans-displays is 0. No event loop or UI is started.
    NSApplication.shared.setActivationPolicy(.prohibited)
    let bridge = winmux_native_capabilities()
    let displays = dinky_displays().map { display -> [String: Any] in
        [
            "displayUUID": display.uuid,
            "displayID": display.displayID,
            "currentSpaceID": display.currentSpaceID,
            "spaces": display.spaces.map { space -> [String: Any] in
                ["id": space.spaceID, "uuid": space.uuid, "userDesktop": space.isUser]
            },
        ]
    }
    let output: [String: Any] = [
        "backend": "native macOS Spaces",
        "bridgeSymbolsAvailable": bridge,
        "supportedOS": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
        "displaysHaveSeparateSpaces": NSScreen.screensHaveSeparateSpaces,
        "displays": displays,
        "mutationsPerformed": false,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}
