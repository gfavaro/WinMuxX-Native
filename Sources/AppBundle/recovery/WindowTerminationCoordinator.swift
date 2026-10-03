import Foundation

@MainActor
final class WindowTerminationCoordinator {
    private var task: Task<Void, Never>?

    func run(_ cleanup: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let task = Task { @MainActor in await cleanup() }
        self.task = task
        await task.value
    }
}

/// Failures are retained for the next launch; a failed app must not stop other apps.
@MainActor
func restoreTerminationWindows<Window>(
    _ windows: [Window],
    restore: (Window) async throws -> Void,
    onFailure: (Window, Error) -> Void
) async -> [Window] {
    var failed: [Window] = []
    for window in windows {
        do { try await restore(window) }
        catch {
            failed.append(window)
            onFailure(window, error)
        }
    }
    return failed
}
