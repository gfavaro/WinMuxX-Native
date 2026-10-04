# WinMuxX-Native

Experimental, independent public derivative of [gfavaro/WinMuxX](https://github.com/gfavaro/WinMuxX), preserving its Git ancestry and local recovery and appearance fixes. Earlier WinMux/AeroSpace attribution remains in [LICENSE.txt](LICENSE.txt) and [legal](legal/README.md).

**Experimental native Spaces backend implemented.** Global workspaces are associated with real macOS desktops. The main display hosts a fixed home Space for each workspace; secondary displays reuse a presentation Space. Selection restores the outgoing workspace to its home and presents the incoming workspace. Selecting a workspace already visible elsewhere focuses that display; summon relocates it, and override swaps visible workspaces through a temporary secondary Space. Inactive workspaces no longer use virtual corner parking. Inherited inactive-tab behavior is unchanged.

Each secondary display is consolidated to one ordinary desktop after synchronization. Extra manually created desktops are removed once empty; windows are reconciled into the global pool first. Native fullscreen Spaces remain separate, and unidentified occupants defer cleanup with a diagnostic.

Requires macOS 27+, Accessibility permission for the new app identity, and **Displays have separate Spaces** enabled (sign out and back in after changing it). Unsupported capabilities or incomplete recovery pause management; there is no silent virtual fallback. No system setting is changed automatically. Native operations use private interfaces and require interactive validation on your display setup before daily use.

Release identity: `WinMuxX-Native.app`, `com.gfavaro.winmuxx.native`. Debug identity: `WinMuxX-Native-Debug`, `com.gfavaro.winmuxx.native.debug`. The bundled CLI is `winmux-native-cli`; it connects exclusively to `/tmp/com.gfavaro.winmuxx.native-<user>.sock` (debug builds use the `.debug` identity).

Configuration is `${XDG_CONFIG_HOME:-~/.config}/winmux-native/winmux.toml`. First launch generates a starter configuration without importing WinMuxX, WinMux, or AeroSpace settings. `--config-path` remains an explicit override. Data and recovery are in `~/Library/Application Support/WinMux-Native/`; preferences use the experimental bundle ID and login registration belongs to this app.

```sh
make check
make native-build BUILD_NUMBER=1
```

Outputs: `.release-native/WinMuxX-Native.app` and `.release-native/WinMuxX-Native-<version>-<build>.zip`. Builds never install or launch the app. Automatic updates are disabled and no update feed is bundled. A configured `CODESIGN_IDENTITY`, or identity in `${XDG_CONFIG_HOME:-~/.config}/winmux-native/signing-identity`, is preserved; otherwise signing is ad hoc. Builds are not notarized.

The CLI can inspect capabilities and topology without altering Spaces:

```sh
.release-native/WinMuxX-Native.app/Contents/MacOS/winmux-native-cli --native-spaces-status
```

The native association/operation journal is `native-spaces.json`; restart layouts use `native-window-state.json` in the experimental Application Support directory. Pre-existing/user-created desktops are preserved; only confirmed empty, inactive, app-owned desktops may be collected. Fullscreen or shared-window transfers stop conservatively; minimized windows retain their state. Use Enable to retry after resolving a recovery condition. Release/debug instances share an exclusive state lock.

See [global pool live validation](docs/NATIVE_GLOBAL_POOL_VALIDATION.md), [implementation and validation](docs/NATIVE_SPACES_IMPLEMENTATION.md), [HACKING.md](HACKING.md) for development, [approved native Spaces plan](docs/NATIVE_SPACES_PLAN.md), and [fixed Dinky reference](docs/DINKY_NATIVE_SPACES_REVIEW.md). Tabs are outside the future native Spaces implementation scope; inherited tab code is still present.

The workspace pool is global: user desktops on the original main display are workspace homes. Secondary displays reuse one presentation Space, with hidden workspaces parked in their homes. Numeric shortcuts use global pool numbers on every display. See [global pool behavior](docs/NATIVE_GLOBAL_POOL.md).
