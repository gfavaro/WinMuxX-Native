import AppKit
import Common

@MainActor
final class WindowRecoveryController {
    static let shared = WindowRecoveryController()
    private var journal: WindowRecoveryJournal?
    private var didInitialize = false
    private var initializationError: String?
    private(set) var isRecovering = false
    private(set) var isGeometryPaused = false

    private(set) var isTerminating = false

    func beginTermination() { isTerminating = true }

    var suppressAutomaticFrameWrites: Bool { isTerminating || (isGeometryPaused && !TrayMenuModel.shared.isEnabled) }

    func resumeTiling() { isGeometryPaused = false }

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true
        guard !isUnitTest, !serverArgs.isReadOnly else { return }
        let application = NSRunningApplication.current
        guard let launchDate = application.launchDate else {
            initializationError = "App launch identity is unavailable; recovery recording disabled."
            return
        }
        let owner = RecoveryJournalOwner(pid: application.processIdentifier, bundleId: application.bundleIdentifier,
                                         applicationLaunchDate: launchDate)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(winMuxAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("recovery-journal.json")
        journal = WindowRecoveryJournal(url: url, owner: owner) { previous in
            guard let running = NSRunningApplication(processIdentifier: previous.pid) else { return false }
            return !running.isTerminated && running.bundleIdentifier == previous.bundleId &&
                running.launchDate == previous.applicationLaunchDate
        }
    }

    func identity(for window: MacWindow) -> RecoveryWindowIdentity? {
        guard let launchDate = window.macApp.nsApp.launchDate else { return nil }
        return RecoveryWindowIdentity(windowId: window.windowId, pid: window.macApp.pid,
                                      bundleId: window.macApp.rawAppBundleId, applicationLaunchDate: launchDate)
    }

    func recordBeforeMutation(_ window: MacWindow, originalRect: Rect?) {
        guard TrayMenuModel.shared.isEnabled, !isRecovering, window.nodeWorkspace != nil,
              let rect = originalRect, let identity = identity(for: window) else { return }
        initializeIfNeeded()
        journal?.record(identity: identity, originalFrame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

    func forget(_ window: MacWindow) {
        guard let identity = identity(for: window) else { return }
        journal?.forget(identity)
    }

    var recoverableEntries: [RecoveryWindowEntry] {
        initializeIfNeeded()
        return journal?.recoverableEntries(liveIdentities: MacWindow.allWindows.compactMap { window in
            window.nodeWorkspace == nil ? nil : identity(for: window)
        }) ?? []
    }

    var diagnosticSummary: String {
        let count = recoverableEntries.count
        let error = initializationError ?? journal?.lastError
        return "\(count) windows from a previous session can be recovered" + (error.map { "; WARNING: \($0)" } ?? "")
    }

    func finishCleanly(preserving identities: [RecoveryWindowIdentity] = []) { journal?.finishCleanly(preserving: identities) }

    /// Explicit user action only. Pausing first prevents the next refresh from undoing
    /// recovered geometry. Never move native Spaces or force-unminimize/fullscreen windows.
    func recoverAfterCrash() async -> String {
        guard !isRecovering else { return "Recovery is already running." }
        guard !serverArgs.isReadOnly else { return "Recovery is unavailable in read-only mode." }
        let entries = recoverableEntries
        guard !entries.isEmpty else { return "No matching windows from a previous session were found." }
        isRecovering = true
        defer { isRecovering = false }
        var restored = 0
        var failures: [String] = []
        do {
            // Keep the managed layout for a later restart before pausing its frame writes.
            let didPause = try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
                persistFrozenWorldForRestartIfPossible()
                let result = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: .off)).run(.defaultEnv, .emptyStdin)
                return result.exitCode == 0
            }
            guard didPause else { return "Unable to pause tiling; no recovery was performed." }
            isGeometryPaused = true
            for entry in entries {
                guard let window = MacWindow.allWindowsMap[entry.identity.windowId], identity(for: window) == entry.identity else {
                    failures.append("Window \(entry.identity.windowId): identity changed")
                    continue
                }
                guard recoveryFrameIntersectsDisplay(entry.originalFrame, displays: sortedMonitors.map {
                    CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height)
                }) else {
                    failures.append("Window \(window.windowId): original display is disconnected")
                    continue
                }
                do {
                    guard try await window.macApp.containsAxWindow(window.windowId) == true else {
                        failures.append("Window \(window.windowId): window is no longer reachable")
                        continue
                    }
                    let fullscreen = try await window.isMacosFullscreen
                    let minimized = try await window.isMacosMinimized
                    guard !fullscreen, !minimized else {
                        failures.append("Window \(window.windowId): native fullscreen or minimized")
                        continue
                    }
                    try await window.setAxFrameBlocking(entry.originalFrame.origin, entry.originalFrame.size)
                    guard let actual = try await window.getAxRect(), recoveryFrameMatches(
                        actual: CGRect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height),
                        expected: entry.originalFrame
                    ) else {
                        failures.append("Window \(window.windowId): app did not accept the original frame")
                        continue
                    }
                    window.lastFloatingSize = entry.originalFrame.size
                    journal?.forget(entry.identity)
                    restored += 1
                } catch { failures.append("Window \(window.windowId): \(error.localizedDescription)") }
            }
        } catch {
            if !TrayMenuModel.shared.isEnabled { isGeometryPaused = true }
            failures.append(error.localizedDescription)
        }
        let status = TrayMenuModel.shared.isEnabled ? "Tiling could not be paused." : "Tiling remains paused; use Enable to resume."
        return "Restored \(restored) of \(entries.count) windows. \(status)\n" +
            (failures.isEmpty ? "" : "Unresolved entries were preserved for another attempt.\n" + failures.joined(separator: "\n"))
    }
}

func recoveryFrameIntersectsDisplay(_ frame: CGRect, displays: [CGRect]) -> Bool {
    displays.contains { $0.intersects(frame) }
}

func recoveryFrameMatches(actual: CGRect, expected: CGRect) -> Bool {
    abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2 &&
        abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
}
