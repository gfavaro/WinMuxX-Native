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

// Explicit suite also isolates the unbundled SPM debug executable.
nonisolated(unsafe) public let nativePreferences = UserDefaults(suiteName: winMuxAppId)!
