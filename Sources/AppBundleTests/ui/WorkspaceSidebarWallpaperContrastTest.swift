@testable import AppBundle
import AppKit
import ImageIO
import XCTest

final class WorkspaceSidebarWallpaperContrastTest: XCTestCase {
    func testLuminanceUsesLinearSRGB() {
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.luminance(red: 0, green: 0, blue: 0), 0)
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.luminance(red: 1, green: 1, blue: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.luminance(red: 0.5, green: 0.5, blue: 0.5), 0.214, accuracy: 0.001)
    }

    func testLightDarkAndMixedClassification() {
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.classify(luminances: [0, 0.02, 0.05]), .dark)
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.classify(luminances: [0.6, 0.8, 1]), .light)
        XCTAssertEqual(WorkspaceSidebarWallpaperTone.classify(luminances: [0.18]), .light)
        XCTAssertNil(WorkspaceSidebarWallpaperTone.classify(luminances: []))
        XCTAssertNil(WorkspaceSidebarWallpaperTone.classify(luminances: [.nan, .infinity, -1]))
        XCTAssertNotNil(WorkspaceSidebarWallpaperTone.classify(luminances: [0, 0.3, 1]))
    }

    func testPlacementAccountsForFillFitAndCenter() {
        let image = CGSize(width: 200, height: 100)
        let canvas = CGSize(width: 100, height: 100)
        XCTAssertEqual(request().imageRect(imageSize: image, canvas: canvas), CGRect(x: -50, y: 0, width: 200, height: 100))
        XCTAssertEqual(request(clipping: false).imageRect(imageSize: image, canvas: canvas), CGRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertEqual(request(scaling: .scaleNone).imageRect(imageSize: image, canvas: canvas), CGRect(x: -50, y: 0, width: 200, height: 100))
        XCTAssertEqual(request(scaling: .scaleAxesIndependently).imageRect(imageSize: image, canvas: canvas), CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testTransparentPaletteDoesNotFadeSecondaryText() {
        let light = WorkspaceSidebarPalette(appearance: .system, transparentContrast: true, colorScheme: .light)
        let dark = WorkspaceSidebarPalette(appearance: .system, transparentContrast: true, colorScheme: .dark)
        XCTAssertEqual(light.foreground, .black)
        XCTAssertEqual(dark.foreground, .white)
        XCTAssertEqual(light.text(opacity: 0.38), .black.opacity(0.85))
        XCTAssertEqual(dark.text(opacity: 0.38), .white.opacity(0.85))
        XCTAssertEqual(dark.text(opacity: 0), .clear)
    }

    func testSystemSidebarAdaptsContrastAtBothWidths() {
        var configuration = WorkspaceSidebarConfiguration.empty
        configuration.collapsedWidth = 50
        configuration.expandedWidth = 280
        configuration.background = .transparent
        XCTAssertEqual(configuration.transparentExpansionProgress(visibleWidth: 50), 0)
        XCTAssertEqual(configuration.transparentExpansionProgress(visibleWidth: 280), 1)
        XCTAssertEqual(configuration.transparentExpansionProgress(visibleWidth: 400), 1)
        XCTAssertEqual(configuration.transparentExpansionProgress(visibleWidth: 0), 0)
        XCTAssertEqual(configuration.transparentExpansionProgress(visibleWidth: 165), 0.5)
        XCTAssertTrue(configuration.usesWallpaperContrast(visibleWidth: 50, reduceTransparency: false))
        XCTAssertTrue(configuration.usesWallpaperContrast(visibleWidth: 280, reduceTransparency: false))
        XCTAssertFalse(configuration.usesWallpaperContrast(visibleWidth: 50, reduceTransparency: true))
        configuration.appearance = .custom
        XCTAssertFalse(configuration.usesWallpaperContrast(visibleWidth: 50, reduceTransparency: false))
        configuration.appearance = .system
        configuration.background = .menuBar
        XCTAssertTrue(configuration.usesWallpaperContrast(visibleWidth: 50, reduceTransparency: false))
    }

    func testAnalyzerRejectsNonFileAndMissingWallpapers() async {
        let analyzer = WorkspaceSidebarWallpaperAnalyzer()
        let remote = await analyzer.tone(for: request(url: URL(string: "https://example.invalid/wallpaper.png")!))
        XCTAssertNil(remote)
        let missing = await analyzer.tone(for: request(url: URL(filePath: "/private/tmp/winmux-missing-\(UUID().uuidString).png")))
        XCTAssertNil(missing)
    }

    func testLegacyDesktopPlaceholderDoesNotOverrideSystemContrastOnEitherMonitor() async {
        let analyzer = WorkspaceSidebarWallpaperAnalyzer()
        for screen in [CGSize(width: 1710, height: 1112), CGSize(width: 3440, height: 1440)] {
            for width in [44.0, 280.0] {
                var placeholder = request(url: URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic"))
                placeholder = WorkspaceSidebarWallpaperRequest(
                    url: placeholder.url, screenWidth: screen.width, screenHeight: screen.height,
                    sidebarWidth: width, scaling: placeholder.scaling, allowClipping: placeholder.allowClipping,
                    fillRed: 0, fillGreen: 0, fillBlue: 0
                )
                let profile = await analyzer.profile(for: placeholder)
                XCTAssertNil(profile, "Placeholder must not supply a foreground or expanded tint")
            }
        }
    }

    func testMultiImageWallpaperDoesNotGuessActiveVariant() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-wallpaper-variants-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 2, nil))
        for brightness: CGFloat in [1, 0] {
            context.setFillColor(gray: brightness, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let profile = await WorkspaceSidebarWallpaperAnalyzer().profile(for: request(url: url))
        XCTAssertNil(profile)
    }

    func testAnalyzerSamplesSidebarStripNotWholeWallpaper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-wallpaper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallpaper.png")
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let analyzer = WorkspaceSidebarWallpaperAnalyzer()
        let tone = await analyzer.tone(for: request(url: url))
        XCTAssertEqual(tone, .dark)
        var rightRequest = request(url: url)
        rightRequest.position = .right
        let rightTone = await analyzer.tone(for: rightRequest)
        XCTAssertEqual(rightTone, .light)
        let cached = await analyzer.tone(for: request(url: url))
        XCTAssertEqual(cached, .dark)
        let profile = await analyzer.profile(for: request(url: url))
        XCTAssertEqual(try XCTUnwrap(profile).red, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(profile).green, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(profile).blue, 0, accuracy: 0.01)
    }

    func testProfilePreservesWallpaperColorAndInvalidatesCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-wallpaper-color-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallpaper.png")
        func write(red: CGFloat, green: CGFloat, blue: CGFloat) throws {
            let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try write(red: 0.1, green: 0.2, blue: 0.8)
        let analyzer = WorkspaceSidebarWallpaperAnalyzer()
        let first = await analyzer.profile(for: request(url: url))
        let blue = try XCTUnwrap(first)
        XCTAssertEqual(blue.red, 0.1, accuracy: 0.01)
        XCTAssertEqual(blue.green, 0.2, accuracy: 0.01)
        XCTAssertEqual(blue.blue, 0.8, accuracy: 0.01)
        try write(red: 0.9, green: 0.3, blue: 0.4)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        let updated = await analyzer.profile(for: request(url: url))
        let pink = try XCTUnwrap(updated)
        XCTAssertEqual(pink.red, 0.9, accuracy: 0.01)
        XCTAssertEqual(pink.green, 0.3, accuracy: 0.01)
        XCTAssertNotEqual(blue, pink)
    }

    func testWallpaperFillFallbackAndGrayscaleProvideRGBComponents() {
        for source in [nil, NSColor.black, NSColor(white: 0, alpha: 1)] {
            let fill = workspaceSidebarWallpaperFillColor(source)
            XCTAssertEqual(fill.redComponent, 0, accuracy: 0.01)
            XCTAssertEqual(fill.greenComponent, 0, accuracy: 0.01)
            XCTAssertEqual(fill.blueComponent, 0, accuracy: 0.01)
        }
        let white = workspaceSidebarWallpaperFillColor(.white)
        XCTAssertEqual(white.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(white.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(white.blueComponent, 1, accuracy: 0.01)
    }

    private func request(url: URL = URL(filePath: "/private/tmp/fixture.png"), scaling: NSImageScaling = .scaleProportionallyUpOrDown, clipping: Bool = true) -> WorkspaceSidebarWallpaperRequest {
        WorkspaceSidebarWallpaperRequest(url: url, screenWidth: 100, screenHeight: 100, sidebarWidth: 10,
            scaling: scaling.rawValue, allowClipping: clipping, fillRed: 0, fillGreen: 0, fillBlue: 0)
    }
}
