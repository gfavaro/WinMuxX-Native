# WinMuxX-Native

Experimental, independent public derivative of [gfavaro/WinMuxX](https://github.com/gfavaro/WinMuxX), preserving its Git ancestry and local recovery and appearance fixes. Earlier WinMux/AeroSpace attribution remains in [LICENSE.txt](LICENSE.txt) and [legal](legal/README.md).

**Preparation stage: the app still uses the virtual workspace backend. Native macOS Spaces are not implemented.** Existing virtual tiling behavior remains. This stage adds no private Spaces calls, Space creation, or native window transfers.

Release identity: `WinMuxX-Native.app`, `com.gfavaro.winmuxx.native`. Debug identity: `WinMuxX-Native-Debug`, `com.gfavaro.winmuxx.native.debug`. The bundled CLI is `winmux-native-cli`; it connects exclusively to `/tmp/com.gfavaro.winmuxx.native-<user>.sock` (debug builds use the `.debug` identity).

Configuration is `${XDG_CONFIG_HOME:-~/.config}/winmux-native/winmux.toml`. First launch generates a starter configuration without importing WinMuxX, WinMux, or AeroSpace settings. `--config-path` remains an explicit override. Data and recovery are in `~/Library/Application Support/WinMux-Native/`; preferences use the experimental bundle ID and login registration belongs to this app.

```sh
make check
make native-build BUILD_NUMBER=1
```

Outputs: `.release-native/WinMuxX-Native.app` and `.release-native/WinMuxX-Native-<version>-<build>.zip`. Builds never install or launch the app. Automatic updates are disabled and no update feed is bundled. A configured `CODESIGN_IDENTITY`, or identity in `${XDG_CONFIG_HOME:-~/.config}/winmux-native/signing-identity`, is preserved; otherwise signing is ad hoc. Builds are not notarized.

See [HACKING.md](HACKING.md) for development, [approved native Spaces plan](docs/NATIVE_SPACES_PLAN.md), and [fixed Dinky reference](docs/DINKY_NATIVE_SPACES_REVIEW.md). Tabs are outside the future native Spaces implementation scope; inherited tab code is still present.
