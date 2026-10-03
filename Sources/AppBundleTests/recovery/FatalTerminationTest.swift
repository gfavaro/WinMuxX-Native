@testable import Common
import Foundation
import XCTest

private struct ProbeTerminationHandler: TerminationHandler {
    let marker: URL

    func beforeTermination() async throws {
        // An actual MainActor suspension makes a blocked main thread observable.
        await Task.yield()
        try Data("cleaned".utf8).write(to: marker)
    }
}

final class FatalTerminationTest: XCTestCase {
    func testFatalCleanupServicesMainActorOnBothThreads() throws {
        if let marker = ProcessInfo.processInfo.environment["WINMUX_FATAL_TEST_MARKER"] {
            isCli = true
            terminationHandler = ProbeTerminationHandler(marker: URL(fileURLWithPath: marker))
            if ProcessInfo.processInfo.environment["WINMUX_FATAL_TEST_THREAD"] == "background" {
                Thread.detachNewThread {
                    runTerminationCleanupBlocking()
                    exit(0)
                }
                RunLoop.current.run()
            } else {
                runTerminationCleanupBlocking()
                exit(0)
            }
            return
        }
        for thread in ["main", "background"] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: marker) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "AppBundleTests.FatalTerminationTest/testFatalCleanupServicesMainActorOnBothThreads", Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["WINMUX_FATAL_TEST_MARKER"] = marker.path
            environment["WINMUX_FATAL_TEST_THREAD"] = thread
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date(timeIntervalSinceNow: 10)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning {
                child.terminate()
                // SIGKILL is necessary if the child has deadlocked its main thread.
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
                XCTFail("Fatal cleanup deadlocked on \(thread) thread")
            } else {
                XCTAssertEqual(child.terminationStatus, 0)
                XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "cleaned")
            }
        }
    }
}
