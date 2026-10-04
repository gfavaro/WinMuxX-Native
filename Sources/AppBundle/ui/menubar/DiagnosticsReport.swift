import AppKit
import Common

@MainActor
func buildDiagnosticsReport() async -> String {
    let io = CmdIo(stdin: .emptyStdin)
    io.out("WinMux doctor — git \(gitShortHash)")
    io.out("")

    io.out("Configuration:")
    io.out("  loaded: \(configUrl.path)")
    io.out("  active mode: \(activeMode ?? "none")")
    io.out("  default root layout: \(config.defaultRootContainerLayout)")
    io.out("  enabled: \(TrayMenuModel.shared.isEnabled)")
    io.out("  crash recovery: \(WindowRecoveryController.shared.diagnosticSummary)")
    let learned = MacWindow.allWindows.filter { !$0.learnedMinimum.isEmpty }
    io.out("  learned minimum sizes: \(learned.count) windows (persisted observations; layout enforcement pending)")
    for window in learned.sorted(by: { $0.windowId < $1.windowId }) {
        let minimum = window.learnedMinimum.size
        io.out("    window \(window.windowId): width=\(minimum.width) height=\(minimum.height)pt (0 = unknown)")
    }
    if !FileManager.default.fileExists(atPath: configUrl.path) {
        io.out("  file validation: WARNING — file is missing; running config retained")
    } else {
        do {
            let text = try String(contentsOf: configUrl, encoding: .utf8)
            let (_, errors) = parseConfig(text)
            io.out(errors.isEmpty ? "  file validation: valid" : "  file validation: ERROR (running config retained)\n" + errors.map(\.description).joined(separator: "\n"))
        } catch {
            io.out("  file validation: ERROR — unable to read file (running config retained): \(error.localizedDescription)")
        }
    }
    if let error = lastConfigReloadError { io.out("  last reload error: \(error)") }
    io.out("")

    let appConflicts = otherTilingManagers(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let daemonConflicts = await runningDaemonTilers()
    let conflicts = Array(Set(appConflicts + daemonConflicts)).sorted()
    for line in NativeSpacesRuntime.shared.poolDiagnostics() { io.out(line) }
    io.out("Other window managers:")
    io.out(conflicts.isEmpty ? "  none detected" : conflicts.map { "  WARNING: \($0) is running; window management may conflict" }.joined(separator: "\n"))
    io.out("  macOS automatically rearranges Spaces: \(dockDiagnosticSetting("mru-spaces"))")
    io.out("  macOS switches to an app's Space on activation: \(dockDiagnosticSetting("workspaces-auto-swoosh"))")
    io.out("  macOS displays have separate Spaces: \(separateSpacesDiagnosticSetting())")
    io.out("  These settings are informational; WinMux does not change them.")
    io.out("")

    io.out("Permissions:")
    io.out("  accessibility: \(AXIsProcessTrusted() ? "granted" : "MISSING (required)")")
    io.out("  screen capture: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing (tab previews / radius estimation degraded)")")
    io.out("")

    io.out("Monitors (system window corner radius: \(systemWindowCornerRadius())pt):")
    for monitor in sortedMonitors {
        let active = monitor.activeWorkspace.name
        io.out("  [\(monitor.monitorAppKitNsScreenScreensId)] \(monitor.name) \(Int(monitor.rect.width))x\(Int(monitor.rect.height))\(monitor.isMain ? " (main)" : "") activeWorkspace=\(active)")
    }
    io.out("")

    let workspaces = Workspace.all
    io.out("State: \(workspaces.count) workspaces, \(MacWindow.allWindows.count) windows, focus=\(focus.windowOrNil?.windowId.description ?? "none") (workspace \(focus.workspace.name))")
    io.out("")

    // Per-app AX latency: time a trivial round-trip to each app's AX thread. Apps near the
    // 1s messaging timeout are the ones that make the whole system feel slow.
    io.out("Per-app AX latency (slowest first):")
    var rows: [(name: String, ms: Double, windows: Int)] = []
    for (_, app) in MacApp.allAppsMap {
        let name = app.nsApp.localizedName ?? app.rawAppBundleId ?? String(app.pid)
        let start = ContinuousClock.now
        let windowCount = (try? await app.getAxWindowsCount()) ?? -1
        let elapsed = start.duration(to: ContinuousClock.now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        rows.append((name, ms, windowCount))
    }
    for row in rows.sorted(by: { $0.ms > $1.ms }) {
        let flag = row.ms > 100 ? "  <-- SLOW" : ""
        let windows = row.windows >= 0 ? "\(row.windows)" : "error"
        io.out("  \(String(format: "%7.1f", row.ms))ms  \(row.name) (\(windows) ax windows)\(flag)")
    }
    return io.stdout.joined(separator: "\n")
}

func otherTilingManagers(_ bundleIds: [String]) -> [String] {
    let names = [
        "com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.RectanglePro": "Rectangle Pro",
        "com.amethyst.Amethyst": "Amethyst", "bobko.aerospace": "AeroSpace", "com.nikitabobko.AeroSpace": "AeroSpace",
        "com.brnbw.dinky": "Dinky",
        "com.hegenberg.BetterTouchTool": "BetterTouchTool",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool", "com.crowdcafe.windowmagnet": "Magnet",
    ]
    return Set(bundleIds.compactMap { names[$0] }).sorted()
}

private func runningDaemonTilers() async -> [String] {
    await Task.detached {
        ["yabai"].filter { name in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch { return false }
        }
    }.value
}

private func dockDiagnosticSetting(_ key: String) -> String {
    guard let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? Bool else {
        return "not explicitly set (macOS default)"
    }
    return value ? "on" : "off"
}

private func separateSpacesDiagnosticSetting() -> String {
    guard let spans = CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? Bool else {
        return "not explicitly set (macOS default)"
    }
    return spans ? "off" : "on"
}
