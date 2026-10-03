# Developing WinMuxX-Native

This repository is maintained independently from WinMuxX. The preparation app still uses the virtual backend; native Spaces operations belong to the next stage. Read [the approved plan](docs/NATIVE_SPACES_PLAN.md) before backend work.

Use Xcode and the Swift version in `.swift-version`. Run `make check` for Swift and Python tests and the dependency lock check. `make build` builds SPM debug executables; `make native-build BUILD_NUMBER=N` generates the Xcode project and produces a signed app and ZIP in `.release-native/`. The build does not launch or install anything. `make install` is disabled. Signing uses `CODESIGN_IDENTITY` or the native config directory's `signing-identity` file, falling back to ad hoc signing.

The release CLI product is `winmux-native-cli`; debug builds connect only to the experimental debug socket. Configuration, preferences, recovery and login items belong to WinMuxX-Native. Never add automatic migration from virtual WinMuxX state. `--config-path` is an explicit user override.

## Maintenance

`origin` is https://github.com/gfavaro/WinMuxX-Native.git. `upstream` is https://github.com/gfavaro/WinMuxX.git, with local push URL `DISABLED`. Only `main` and its ancestry were published at bootstrap; contribution branches and old release tags were not copied. Keep main history intact and review any upstream changes explicitly in a feature branch. No scheduled synchronization or release publication workflow is retained.

CI runs checks for pull requests/main and builds native app artifacts on trusted main pushes. CI build artifacts do not install, publish a release, or enable updates. Preserve identity tests when maintaining this derivative. Never commit `.build`, `.deps`, `.release-native`, signing identities, recovery journals, or personal configuration.

The fixed Dinky study is documentation only. Before incorporating any code, copy the pinned MIT copyright/license and retain notices for portions derived from mimi, yabai and other projects; consult each source file's attribution. No Dinky source has been incorporated in this preparation.
