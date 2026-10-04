import AppKit
import Darwin
import NativeSpacesPrivate

@MainActor
final class SkyLightSpaceDriver: NativeSpaceDriver {
    let bootID: String

    init() throws {
        var boot = timeval()
        var length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &length, nil, 0) == 0 else {
            throw NativeSpaceError.unavailable("cannot identify system boot")
        }
        bootID = String(boot.tv_sec)
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw NativeSpaceError.unavailable("this bridged backend requires macOS 27 or later; earlier versions have not been validated")
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            throw NativeSpaceError.unavailable("enable Displays have separate Spaces in System Settings and sign in again")
        }
        guard winmux_native_capabilities() else {
            throw NativeSpaceError.unavailable("required SkyLight bridge symbols or selectors are missing")
        }
    }

    func topology() throws -> NativeSpaceTopology {
        let displays = dinky_displays().map { display in
            NativeDisplaySnapshot(
                uuid: display.uuid,
                displayID: display.displayID,
                currentSpace: display.currentSpaceID,
                spaces: display.spaces.map { NativeDesktop(id: $0.spaceID, uuid: $0.uuid, isUser: $0.isUser) }
            )
        }
        guard !displays.isEmpty, displays.allSatisfy({ !$0.uuid.isEmpty && !$0.spaces.isEmpty }) else {
            throw NativeSpaceError.topology("cannot read managed display Spaces")
        }
        return NativeSpaceTopology(displays: displays)
    }

    func memberships(_ window: UInt32) throws -> [UInt64] {
        guard let spaces = winmux_native_window_spaces(window) else { throw NativeSpaceError.unsafeWindow(window) }
        return spaces.map(\.uint64Value)
    }

    func occupants(_ space: UInt64) throws -> [UInt32] {
        guard let windows = winmux_native_all_space_windows(space) else {
            throw NativeSpaceError.topology("cannot enumerate all occupants of Space \(space)")
        }
        // Sticky windows join multiple desktops. They cannot be owned by a single
        // workspace; preserve them on all Spaces and exclude them from empty checks.
        return try windows.map(\.uint32Value).filter { id in
            // Sidebar, settings and warning panels belong to this app, never to
            // a workspace. They remain on their display when its carrier is reused.
            if winmux_native_window_owner_pid(id)?.int32Value == ProcessInfo.processInfo.processIdentifier { return false }
            let memberships = try memberships(id)
            guard !memberships.isEmpty else { throw NativeSpaceError.unsafeWindow(id) }
            return memberships == [space]
        }
    }

    func isAlive(_ window: NativeWindowIdentity) throws -> Bool {
        guard let running = NSRunningApplication(processIdentifier: window.pid), !running.isTerminated,
              running.launchDate == window.launchDate else { return false }
        // CoreGraphics omits records for windows on inactive Spaces. Resolve the
        // WindowServer owner directly so hidden content still participates in moves,
        // while PID + launch date protect against a reused window ID.
        guard let owner = winmux_native_window_owner_pid(window.id) else { return false }
        return owner.int32Value == window.pid
    }

    func create(on display: String) async throws -> UInt64 {
        guard try topology().display(display) != nil else { throw NativeSpaceError.topology("display disconnected before create") }
        let id = dinky_create_space(display as CFString)
        guard id != 0 else { throw NativeSpaceError.unavailable("Space creation dispatcher failed") }
        return id
    }

    func move(_ windows: [UInt32], to space: UInt64) async throws {
        guard try topology().desktop(space)?.isUser == true else { throw NativeSpaceError.topology("move destination disappeared") }
        let dispatched = windows.withUnsafeBufferPointer {
            dinky_move_windows_to_space($0.baseAddress, Int32($0.count), space)
        }
        guard dispatched else { throw NativeSpaceError.unavailable("window transfer dispatcher failed") }
    }

    func activate(_ space: UInt64, on display: String) async throws {
        guard let snapshot = try topology().display(display),
              snapshot.spaces.contains(where: { $0.id == space && $0.isUser }) else {
            throw NativeSpaceError.topology("activation destination disappeared")
        }
        if snapshot.currentSpace == space { return }
        let originalPointer = CGEvent(source: nil)?.location
        let bounds = CGDisplayBounds(snapshot.displayID)
        let warp = originalPointer.map { !bounds.contains($0) } ?? false
        if warp {
            let eventSource = CGEventSource(stateID: .combinedSessionState)
            eventSource?.localEventsSuppressionInterval = 0
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            try await pause()
        }
        defer {
            if warp, let originalPointer {
                // If the user moved the pointer during the operation, don't drag it back.
                let current = CGEvent(source: nil)?.location
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                if let current, hypot(current.x - center.x, current.y - center.y) < 2 {
                    CGWarpMouseCursorPosition(originalPointer)
                }
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
        // Re-observe after each single swipe. This handles reordered Mission Control
        // indices, spaces inserted by fullscreen, and manual switches while in flight.
        for _ in 0..<64 {
            guard let current = try topology().display(display),
                  let from = current.spaces.firstIndex(where: { $0.id == current.currentSpace }),
                  let to = current.spaces.firstIndex(where: { $0.id == space }) else {
                throw NativeSpaceError.topology("display or target changed during switch")
            }
            if from == to { return }
            // The Dock targets the display under the cursor. A real pointer move to
            // another monitor must not make the next swipe affect that other monitor.
            guard let pointer = CGEvent(source: nil)?.location, bounds.contains(pointer) else {
                throw NativeSpaceError.topology("pointer left target display during switch")
            }
            guard winmux_native_post_swipe(to > from) else { throw NativeSpaceError.unavailable("Dock gesture serialization unsupported") }
            var arrived = false
            for _ in 0..<80 {
                try await pause()
                guard let next = try topology().display(display) else { throw NativeSpaceError.topology("display disconnected during switch") }
                if next.currentSpace != current.currentSpace { arrived = true; break }
            }
            guard arrived else { throw NativeSpaceError.timedOut("Dock gesture") }
        }
        throw NativeSpaceError.timedOut("target desktop after repeated topology changes")
    }

    func destroy(_ space: UInt64) async throws {
        let snapshot = try topology()
        guard let display = snapshot.displayContaining(space), snapshot.desktop(space)?.isUser == true,
              display.currentSpace != space, display.spaces.filter(\.isUser).count > 1,
              try occupants(space).isEmpty else { throw NativeSpaceError.topology("Space became occupied/current before collection") }
        guard dinky_destroy_space(space) else { throw NativeSpaceError.unavailable("Space removal dispatcher failed") }
    }

    func pause() async throws { try await Task.sleep(for: .milliseconds(30)) }
}
