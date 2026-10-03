"""Guard fork-specific isolation when integrating upstream updates."""
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ForkIdentityTests(unittest.TestCase):
    def test_plist_has_no_upstream_update_feed_or_key(self):
        with (ROOT / "resources/WinMux-Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertFalse(info["SUEnableAutomaticChecks"])
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)

    def test_project_generates_only_fork_bundle_identifiers(self):
        project = (ROOT / "project.yml").read_text()
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.gfavaro.winmuxx.native\n", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.gfavaro.winmuxx.native.debug\n", project)
        self.assertNotIn("com.zimengxiong", project)
        self.assertNotIn("SUFeedURL", project)
        self.assertNotIn("SUPublicEDKey", project)

    def test_release_does_not_initialize_sparkle(self):
        app = (ROOT / "Sources/WinMuxApp/WinMuxApp.swift").read_text()
        updater = (ROOT / "Sources/SparkleSupport/AutomaticUpdates.swift").read_text()
        self.assertNotIn("AutomaticUpdates.start()", app)
        self.assertNotIn("AutomaticUpdates.checkForUpdates()", app)
        self.assertNotIn("SPUStandardUpdaterController(", updater)

    def test_native_bootstrap_does_not_discover_virtual_configuration(self):
        config = (ROOT / "Sources/AppBundle/config/ConfigFile.swift").read_text()
        bootstrap = config.split("func ensureBootstrapConfigExistsIfNeeded()", 1)[1].split("func materializeBootstrapConfigIfNeeded", 1)[0]
        self.assertIn("existingLegacyUrls: []", bootstrap)
        self.assertIn("aerospaceImportUrl: nil", bootstrap)
        self.assertNotIn("preferredLegacyConfigImportUrl", bootstrap)
        self.assertNotIn("preferredAerospaceConfigImportUrl", bootstrap)

    def test_native_preferences_and_state_are_explicitly_isolated(self):
        metadata = (ROOT / "Sources/Common/appMetadata.swift").read_text()
        self.assertIn('UserDefaults(suiteName: winMuxAppId)', metadata)
        self.assertIn('winMuxAppSupportDirectoryName = "WinMux-Native"', metadata)
        self.assertIn('workspaceBackendDescription = "native macOS Spaces (bridged SkyLight backend)"', metadata)

    def test_fork_does_not_delete_upstream_login_items(self):
        login = (ROOT / "Sources/AppBundle/config/startAtLogin.swift").read_text()
        self.assertNotIn("removeItem", login)

    def test_cli_name_cannot_overwrite_app_on_case_insensitive_volumes(self):
        build = (ROOT / "script/native-build.sh").read_text()
        self.assertIn('"$fork_app/Contents/MacOS/winmux-native-cli"', build)
        self.assertNotIn('"$fork_app/Contents/MacOS/winmuxx"', build)
        self.assertNotEqual("WinMuxX-Native".casefold(), "winmux-native-cli".casefold())

    def test_fork_build_accepts_a_persistent_local_signing_identity(self):
        build = (ROOT / "script/native-build.sh").read_text()
        self.assertIn('"${CODESIGN_IDENTITY:-}"', build)
        self.assertIn("winmux-native/signing-identity", build)
        self.assertIn('codesign --force --deep --sign "$fork_signing_identity"', build)


if __name__ == "__main__":
    unittest.main()
