#!/bin/bash
# Build the independent experimental app without the upstream identity, update feed, or signing team.
set -euo pipefail
cd "$(dirname "$0")/.."
fork_version="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
fork_build_number="${BUILD_NUMBER:-1}"
fork_signing_identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$fork_signing_identity" ]]; then
  fork_identity_config="${XDG_CONFIG_HOME:-$HOME/.config}/winmux-native/signing-identity"
  if [[ -f "$fork_identity_config" ]]; then
    IFS= read -r fork_signing_identity < "$fork_identity_config" || true
  fi
fi
fork_signing_identity="${fork_signing_identity:--}"
[[ "$fork_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be numeric major.minor.patch' >&2; exit 1; }
[[ "$fork_build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'BUILD_NUMBER must be a positive integer' >&2; exit 1; }
make xcodeproj VERSION="$fork_version" BUILD_NUMBER="$fork_build_number" CODESIGN_IDENTITY="$fork_signing_identity" DEVELOPMENT_TEAM=
mkdir -p .release-native
fork_stage="$(mktemp -d "$PWD/.release-native/fork-build.XXXXXX")"
trap 'echo "Build intermediates retained at: $fork_stage"' EXIT
xcodebuild -project WinMux.xcodeproj -scheme WinMux -configuration Release \
  -derivedDataPath "$PWD/.release-native/fork-derived" CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build > "$fork_stage/xcodebuild.log" 2>&1 || {
    tail -80 "$fork_stage/xcodebuild.log" >&2; exit 1;
  }
fork_app="$PWD/.release-native/fork-derived/Build/Products/Release/WinMuxX-Native.app"
test -d "$fork_app"
source ./script/setup.sh
swift build -c release --product winmux-native-cli
fork_bin="$(swift build -c release --show-bin-path | tail -n 1)"
test -d "$fork_bin"
# Use a distinct CLI name even on case-insensitive volumes.
ditto "$fork_bin/winmux-native-cli" "$fork_app/Contents/MacOS/winmux-native-cli"
codesign --force --deep --sign "$fork_signing_identity" "$fork_app"
codesign --verify --deep --strict "$fork_app"
fork_plist="$fork_app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$fork_plist")" = com.gfavaro.winmuxx.native
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$fork_plist")" = "$fork_build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$fork_plist")" = "$fork_version"
if /usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$fork_plist" >/dev/null 2>&1; then
  echo 'Refusing to package an app with an update feed' >&2; exit 1
fi
test -x "$fork_app/Contents/MacOS/winmux-native-cli"
for fork_update_flag in SUEnableAutomaticChecks SUAllowsAutomaticUpdates SUAutomaticallyUpdate; do
  test "$(/usr/libexec/PlistBuddy -c "Print $fork_update_flag" "$fork_plist")" = false
done
ditto "$fork_app" .release-native/WinMuxX-Native.app
ditto -c -k --sequesterRsrc --keepParent "$fork_app" ".release-native/WinMuxX-Native-$fork_version-$fork_build_number.zip"
echo "Built .release-native/WinMuxX-Native.app (identity: $fork_signing_identity; not notarized)."
