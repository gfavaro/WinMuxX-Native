import AppKit
import Common
import Foundation
import os

let signposter = OSSignposter(subsystem: winMuxAppId, category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"

@MainActor
private let terminationCoordinator = WindowTerminationCoordinator()
@MainActor
private var terminationSignals: [DispatchSourceSignal] = []

@MainActor
func interceptTermination(_ number: Int32) {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            defer { exit(number) }
            do { try await terminationHandler.performTerminationCleanup() }
            catch { NSLog("WinMux termination: %@", String(describing: error)) }
        }
    }
    terminationSignals.append(source)
    source.resume()
}

@MainActor
func initTerminationHandler() {
    terminationHandler = AppServerTerminationHandler()
    interceptTermination(SIGINT)
    interceptTermination(SIGTERM)
}

private struct AppServerTerminationHandler: TerminationHandler {
    func beforeTermination() async throws {
        await terminationCoordinator.run {
            WindowRecoveryController.shared.beginTermination()
            await NativeSpacesRuntime.shared.finishPendingOperation()
            persistFrozenWorldForRestartIfPossible()
            if NativeSpacesRuntime.shared.isNative {
                WindowRecoveryController.shared.finishCleanly()
                return
            }
            for app in MacApp.allAppsMap.values { app.cancelPendingFrameWrites() }
            let pending = await makeAllWindowsVisibleAndRestoreSize()
            WindowRecoveryController.shared.finishCleanly(preserving: pending)
            await toggleReleaseServerIfDebug(.on)
        }
    }
}

func terminationFrame(visibleFrame: CGRect, floatingSize: CGSize?) -> CGRect {
    let proposed = floatingSize ?? visibleFrame.size
    let size = CGSize(
        width: proposed.width.isFinite && proposed.width > 0 ? min(proposed.width, visibleFrame.width) : visibleFrame.width,
        height: proposed.height.isFinite && proposed.height > 0 ? min(proposed.height, visibleFrame.height) : visibleFrame.height
    )
    return CGRect(x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
                  y: visibleFrame.minY + (visibleFrame.height - size.height) / 2,
                  width: size.width, height: size.height)
}

@MainActor
private func makeAllWindowsVisibleAndRestoreSize() async -> [RecoveryWindowIdentity] {
    guard !serverArgs.isReadOnly else { return [] }
    // Snapshot without accessing the tree: an internal error may leave windows unbound.
    let failed = await restoreTerminationWindows(Array(MacWindow.allWindowsMap.values)) { window in
        guard try await !window.isMacosFullscreen, try await !window.isMacosMinimized else {
            throw WindowTerminationError.nativeState
        }
        let monitor = (try? await window.getCenter())?.monitorApproximation ?? mainMonitor
        let rect = monitor.visibleRect
        let frame = terminationFrame(visibleFrame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                                     floatingSize: window.lastFloatingSize)
        try await window.setAxFrameBlocking(frame.origin, frame.size)
        guard let actual = try await window.getAxRect(), recoveryFrameMatches(
            actual: CGRect(x: actual.minX, y: actual.minY, width: actual.width, height: actual.height), expected: frame
        ) else { throw WindowTerminationError.frameRejected }
    } onFailure: { window, error in
        NSLog("WinMux: unable to restore window %u: %@", window.windowId, String(describing: error))
    }
    return failed.compactMap { WindowRecoveryController.shared.identity(for: $0) }
}

private enum WindowTerminationError: Error { case frameRejected, nativeState }

@MainActor
public final class WinMuxApplicationDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            do { try await terminationHandler.performTerminationCleanup() }
            catch { NSLog("WinMux termination: %@", String(describing: error)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
func terminateApp() {
    NSApplication.shared.terminate(nil)
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(self, forType: .string)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: ConvenienceCopyable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        if rect.contains(self) {
            return 0
        }
        let list: [CGFloat] =
            (rect.minY.until(excl: rect.maxY)?.contains(y) == true ? [abs(rect.minX - x), abs(rect.maxX - x)] : []) +
            (rect.minX.until(excl: rect.maxX)?.contains(x) == true ? [abs(rect.minY - y), abs(rect.maxY - y)] : []) +
            [
                distance(to: rect.topLeftCorner),
                distance(to: rect.bottomRightCorner),
                distance(to: rect.topRightCorner),
                distance(to: rect.bottomLeftCorner),
            ]
        return list.minOrDie()
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    func distance(to point: CGPoint) -> Double { (self - point).vectorLength }

    var monitorApproximation: Monitor {
        monitors.first { $0.rect.contains(self) } ?? monitors.minByOrDie { distance(toOuterFrame: $0.rect) }
    }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

extension CGPoint: @retroactive Hashable { // todo migrate to self written Point
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

#if DEBUG
    let isDebug = true
#else
    let isDebug = false
#endif

func debugFocusLog(_ message: @autoclosure () -> String) {
    guard isDebug else { return }
    fputs("[focus-debug] \(Date()) \(message())\n", stderr)
}

func debugWorkspaceSidebarRenameLog(_ message: @autoclosure () -> String) {
    guard isDebug else { return }
    fputs("[sidebar-rename-debug] \(Date()) \(message())\n", stderr)
}

func debugWorkspaceSidebarHoverLog(_ message: @autoclosure () -> String) {
    guard isDebug, ProcessInfo.processInfo.environment["WINMUX_DEBUG_SIDEBAR_HOVER"] == "1" else { return }
    fputs("[sidebar-hover-debug] \(Date()) \(message())\n", stderr)
}

func debugWorkspaceSidebarEdgeTrapLog(_ message: @autoclosure () -> String) {
    guard isDebug, ProcessInfo.processInfo.environment["WINMUX_DEBUG_SIDEBAR_EDGE_TRAP"] == "1" else { return }
    fputs("[sidebar-edge-trap-debug] \(Date()) \(message())\n", stderr)
}

func debugWorkspaceSidebarProjectLog(_ message: @autoclosure () -> String) {
    guard isDebug, ProcessInfo.processInfo.environment["WINMUX_DEBUG_SIDEBAR_PROJECT"] == "1" else { return }
    fputs("[sidebar-project-debug] \(Date()) \(message())\n", stderr)
}

@inlinable
func checkCancellation() throws(CancellationError) {
    if Task.isCancelled {
        throw CancellationError()
    }
}
