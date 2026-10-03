@testable import AppBundle
import Common
import XCTest

final class ForkIdentityTest: XCTestCase {
    func testForkIdentityDoesNotUseUpstreamSocketOrState() {
        XCTAssertEqual(stableWinMuxAppId, "com.gfavaro.winmuxx.native")
        XCTAssertTrue(winMuxAppId.hasPrefix(stableWinMuxAppId))
        XCTAssertTrue(winMuxAppName.hasPrefix("WinMuxX-Native"))
        XCTAssertTrue(socketPath.contains(winMuxAppId))
        XCTAssertFalse(socketPath.contains("com.zimengxiong"))
        XCTAssertEqual(forkRepositoryURL, "https://github.com/gfavaro/WinMuxX-Native")
    }

    func testForkConfigurationHasAnIndependentOwnedDirectory() {
        XCTAssertEqual(generatedConfigDirectoryName, "winmux-native")
        XCTAssertEqual(generatedConfigFileName, "winmux.toml")
        XCTAssertEqual(generatedConfigUrl().deletingLastPathComponent().lastPathComponent, "winmux-native")
        XCTAssertFalse(socketPath.contains("com.gfavaro.winmuxx-"))
    }

    func testNativeStateHasIndependentDirectory() {
        XCTAssertEqual(winMuxAppSupportDirectoryName, "WinMux-Native")
    }
}
