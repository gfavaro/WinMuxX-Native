import Foundation

public let stableWinMuxAppId: String = "com.gfavaro.winmuxx.native"
public let forkRepositoryURL = "https://github.com/gfavaro/WinMuxX-Native"
public let winMuxAppSupportDirectoryName = "WinMux-Native"
#if DEBUG
    public let winMuxAppId: String = "com.gfavaro.winmuxx.native.debug"
    public let winMuxAppName: String = "WinMuxX-Native-Debug"
#else
    public let winMuxAppId: String = stableWinMuxAppId
    public let winMuxAppName: String = "WinMuxX-Native"
#endif

public let workspaceBackendDescription = "native macOS Spaces (bridged SkyLight backend)"

// Bundled apps already have their own isolated standard domain. An explicit
// suite isolates unbundled SPM executables, whose main bundle has no app ID.
nonisolated(unsafe) public let nativePreferences: UserDefaults = {
    if Bundle.main.bundleIdentifier == winMuxAppId { return .standard }
    return UserDefaults(suiteName: winMuxAppId) ?? .standard
}()
