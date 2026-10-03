import AppKit
import ImageIO
import SwiftUI

enum WorkspaceSidebarWallpaperTone: Sendable {
    case light, dark

    var colorScheme: ColorScheme { self == .light ? .light : .dark }

    /// Compare the weaker contrast at each end of the sampled luminance distribution.
    /// A mixed image still needs a contrasting text halo; no single color fits every pixel.
    static func classify(luminances: [Double]) -> Self? {
        let samples = luminances.filter { $0.isFinite && (0...1).contains($0) }.sorted()
        guard !samples.isEmpty else { return nil }
        let lower = samples[Int(Double(samples.count - 1) * 0.1)]
        let upper = samples[Int(Double(samples.count - 1) * 0.9)]
        let blackContrast = (lower + 0.05) / 0.05
        let whiteContrast = 1.05 / (upper + 0.05)
        return blackContrast >= whiteContrast ? .light : .dark
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

struct WorkspaceSidebarWallpaperRequest: Sendable, Hashable {
    let url: URL
    let screenWidth: Double
    let screenHeight: Double
    let sidebarWidth: Double
    let scaling: UInt
    let allowClipping: Bool
    let fillRed: Double
    let fillGreen: Double
    let fillBlue: Double
    var position: WorkspaceSidebarPosition = .left

    func imageRect(imageSize: CGSize, canvas: CGSize) -> CGRect {
        let sx = canvas.width / imageSize.width
        let sy = canvas.height / imageSize.height
        let scale: CGFloat
        switch NSImageScaling(rawValue: scaling) {
            case .scaleAxesIndependently:
                return CGRect(origin: .zero, size: canvas)
            case .scaleNone:
                scale = canvas.width / screenWidth
            case .scaleProportionallyDown:
                scale = min(min(sx, sy), canvas.width / screenWidth)
            default:
                scale = allowClipping ? max(sx, sy) : min(sx, sy)
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }
}

struct WorkspaceSidebarWallpaperSample: Sendable, Equatable {
    let tone: WorkspaceSidebarWallpaperTone
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

/// Image I/O and downsampling stay off the UI actor. No screenshots, network access,
/// wallpaper copies, or persistent brightness history are used.
actor WorkspaceSidebarWallpaperAnalyzer {
    static let shared = WorkspaceSidebarWallpaperAnalyzer()
    private var cache: [WorkspaceSidebarWallpaperRequest: (Date?, WorkspaceSidebarWallpaperSample)] = [:]

    func tone(for request: WorkspaceSidebarWallpaperRequest) -> WorkspaceSidebarWallpaperTone? {
        profile(for: request)?.tone
    }

    func profile(for request: WorkspaceSidebarWallpaperRequest) -> WorkspaceSidebarWallpaperSample? {
        guard request.url.isFileURL, request.screenWidth > 0, request.screenHeight > 0 else { return nil }
        // NSWorkspace can return this legacy placeholder for modern/dynamic wallpapers.
        // Its Golden Gate image is unrelated to the rendered desktop. Returning nil
        // keeps both text contrast and the expanded tint on the system-theme fallback.
        guard request.url.standardizedFileURL.path != "/System/Library/CoreServices/DefaultDesktop.heic" else { return nil }
        // URL resource values can retain a stale modification date for the same URL.
        // Read fresh filesystem metadata so replacing a wallpaper invalidates the cache.
        let modified = (try? FileManager.default.attributesOfItem(atPath: request.url.path)[.modificationDate]) as? Date
        if let cached = cache[request], cached.0 == modified { return cached.1 }
        let result = sample(request)
        if cache.count >= 8 { cache.removeAll() }
        // Failed reads are retried, e.g. when a dynamic wallpaper becomes available.
        if let result { cache[request] = (modified, result) }
        return result
    }

    private func sample(_ request: WorkspaceSidebarWallpaperRequest) -> WorkspaceSidebarWallpaperSample? {
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
              // ImageIO index zero does not identify the variant currently rendered by
              // macOS. Do not guess contrast from a multi-image wallpaper.
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let width = max(32, min(512, Int(96 * request.screenWidth / request.screenHeight)))
        let height = 96
        let canvas = CGSize(width: width, height: height)
        // Placement must use the original dimensions for Center / Fit scaling modes.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var originalWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
        var originalHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber, (5...8).contains(orientation.intValue) {
            swap(&originalWidth, &originalHeight)
        }
        guard originalWidth > 0, originalHeight > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.setFillColor(red: request.fillRed, green: request.fillGreen, blue: request.fillBlue, alpha: 1)
            context.fill(CGRect(origin: .zero, size: canvas))
            context.draw(image, in: request.imageRect(imageSize: CGSize(width: originalWidth, height: originalHeight), canvas: canvas))
            let sampleWidth = max(1, min(width, Int(ceil(Double(width) * request.sidebarWidth / request.screenWidth))))
            let data = bytes.bindMemory(to: UInt8.self)
            var luminances: [Double] = []
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            for y in 0..<height {
                for x in (request.position == .left ? 0 : width - sampleWidth)..<(request.position == .left ? sampleWidth : width) {
                    let offset = (y * width + x) * 4
                    red += Double(data[offset]) / 255
                    green += Double(data[offset + 1]) / 255
                    blue += Double(data[offset + 2]) / 255
                    luminances.append(WorkspaceSidebarWallpaperTone.luminance(
                        red: Double(data[offset]) / 255, green: Double(data[offset + 1]) / 255, blue: Double(data[offset + 2]) / 255
                    ))
                }
            }
            guard let tone = WorkspaceSidebarWallpaperTone.classify(luminances: luminances) else { return nil }
            let count = Double(luminances.count)
            return WorkspaceSidebarWallpaperSample(tone: tone, red: red / count, green: green / count, blue: blue / count)
        }
    }
}

struct WorkspaceSidebarWallpaperContrast: ViewModifier {
    let snapshot: WorkspaceSidebarSnapshot
    @State private var compactSample: WorkspaceSidebarWallpaperSample?
    @State private var expandedSample: WorkspaceSidebarWallpaperSample?
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var enabled: Bool {
        snapshot.configuration.usesWallpaperContrast(visibleWidth: snapshot.visibleWidth, reduceTransparency: reduceTransparency)
    }

    private var samplingEnabled: Bool {
        snapshot.configuration.appearance == .system && !reduceTransparency
    }

    private var resolvedColorScheme: ColorScheme {
        guard enabled else { return systemColorScheme }
        let isCompact = snapshot.visibleWidth <= snapshot.configuration.collapsedWidth + 8
        return (isCompact ? compactSample : expandedSample)?.tone.colorScheme ?? systemColorScheme
    }

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, resolvedColorScheme)
            .environment(\.workspaceSidebarWallpaperSample, samplingEnabled ? expandedSample : nil)
            .task(id: "\(samplingEnabled)-\(snapshot.targetMonitorScopeId)-\(snapshot.configuration.collapsedWidth)-\(snapshot.configuration.expandedWidth)-\(snapshot.configuration.position.rawValue)-\(snapshot.configuration.frostedTint == .automatic)") {
                compactSample = nil
                expandedSample = nil
                guard samplingEnabled else { return }
                while !Task.isCancelled {
                    if let request = request(width: snapshot.configuration.collapsedWidth) {
                        let result = await WorkspaceSidebarWallpaperAnalyzer.shared.profile(for: request)
                        guard !Task.isCancelled else { return }
                        compactSample = result
                    } else {
                        compactSample = nil
                    }
                    if let request = request(width: snapshot.configuration.expandedWidth) {
                        let result = await WorkspaceSidebarWallpaperAnalyzer.shared.profile(for: request)
                        guard !Task.isCancelled else { return }
                        expandedSample = result
                    } else {
                        expandedSample = nil
                    }
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
    }

    @MainActor
    private func request(width: CGFloat) -> WorkspaceSidebarWallpaperRequest? {
        guard let monitor = workspaceSidebarMonitor(forScopeId: snapshot.targetMonitorScopeId) else { return nil }
        let screens = NSScreen.screens
        let index = monitor.monitorAppKitNsScreenScreensId - 1
        guard screens.indices.contains(index) else { return nil }
        let screen = screens[index]
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = workspaceSidebarWallpaperFillColor(options[.fillColor] as? NSColor)
        return WorkspaceSidebarWallpaperRequest(
            url: url, screenWidth: screen.frame.width, screenHeight: screen.frame.height,
            sidebarWidth: width,
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            allowClipping: options[.allowClipping] as? Bool ?? true,
            fillRed: fill.redComponent, fillGreen: fill.greenComponent, fillBlue: fill.blueComponent,
            position: snapshot.configuration.position
        )
    }
}

/// Component access requires an RGB color space; NSColor.black can be grayscale.
func workspaceSidebarWallpaperFillColor(_ color: NSColor?) -> NSColor {
    color?.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
}
