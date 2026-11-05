#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BeautifulMermaid
import ImageIO
import QuickLookThumbnailing
import SwiftMath

/// Pictures in notes. Their size comes from the file's header, read at once, so a note is laid out right the first
/// time; the pixels are decoded in the background at the size they are shown.
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    private struct Key: Hashable {
        var path: String
        var modified: Date?
        var width: Int
    }

    private var sizes: [String: (modified: Date?, size: CGSize)] = [:]
    private var images: [Key: NSImage] = [:]
    private var loading: Set<Key> = []
    /// Pictures still being decoded.
    var isBusy: Bool { !loading.isEmpty }

    /// When each picture's file last changed, and when that was asked: layout and drawing ask on every frame a picture
    /// is in, while you type, and the disk is asked again only once the file watcher says it changed (`forget`), or a
    /// few seconds later for files it doesn't watch.
    private var modifications: [String: (date: Date?, asked: CFTimeInterval)] = [:]

    private func modified(_ url: URL) -> Date? {
        let now = CACurrentMediaTime()
        if let known = modifications[url.path], now - known.asked < 3 { return known.date }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        modifications[url.path] = (date, now)
        return date
    }

    /// The files at these paths (or in these folders) changed: their pictures are looked at again when next shown.
    func forget(_ paths: Set<String>) {
        guard !modifications.isEmpty else { return }
        let changed = Set(paths.map(HiddenFolders.withoutPrivate))
        for path in modifications.keys {
            let plain = HiddenFolders.withoutPrivate(path)
            if changed.contains(plain) || changed.contains((plain as NSString).deletingLastPathComponent) { modifications[path] = nil }
        }
    }

    /// The picture's size in points, upright, or nil when the file isn't a picture or isn't there (yet).
    func size(of url: URL) -> CGSize? {
        let date = modified(url)
        if let cached = sizes[url.path], cached.modified == date { return cached.size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let dpi = properties[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let scale = dpi >= 144 ? 2.0 : 1.0
        var size = CGSize(width: width / scale, height: height / scale)
        if orientation >= 5 { size = CGSize(width: size.height, height: size.width) }
        sizes[url.path] = (date, size)
        return size
    }

    /// The picture drawn `width` points wide, if it has been decoded; otherwise it starts decoding and calls `ready`.
    func image(for url: URL, width: CGFloat, ready: @escaping () -> Void) -> NSImage? {
        let scale = Screen.scale
        let pixels = Int((width * scale / 64).rounded(.up) * 64)
        let key = Key(path: url.path, modified: modified(url), width: pixels)
        if let image = images[key] { return image }
        // A decoded picture of another size does until this one is ready.
        let fallback = images.first { $0.key.path == url.path }?.value
        guard !loading.contains(key) else { return fallback }
        loading.insert(key)
        Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            var image: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = NSImage.make(cgImage, scale: scale)
            }
            let decoded = image
            await MainActor.run {
                self.loading.remove(key)
                if let image = decoded {
                    if self.images.count > 120 { self.images.removeAll() }
                    self.images[key] = image
                    ready()
                }
            }
        }
        return fallback
    }
}

/// Quick Look's thumbnails for files shown as cards in a note (PDFs, documents, videos).
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    var isBusy: Bool { !loading.isEmpty }

    func thumbnail(for url: URL, size: CGSize, ready: @escaping () -> Void) -> NSImage? {
        let key = url.path
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: Screen.scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            #if os(macOS)
            let image = representation?.nsImage
            #else
            let image = representation?.uiImage
            #endif
            Task { @MainActor in
                self.loading.remove(key)
                if let image {
                    self.images[key] = image
                    ready()
                }
            }
        }
        return nil
    }
}

/// LaTeX drawn with SwiftMath.
@MainActor
enum MathStore {
    struct Rendered {
        var image: NSImage
        var ascent: CGFloat
        var descent: CGFloat
    }

    private static var cache: [String: Rendered?] = [:]

    static func render(_ tex: String, display: Bool, size: CGFloat, color: NSColor) -> Rendered? {
        #if os(macOS)
        let resolved = color.usingColorSpace(.sRGB) ?? color
        #else
        let resolved = color
        #endif
        let rgba = resolved.rgba
        let key = "\(display)|\(size)|\(rgba.red),\(rgba.green),\(rgba.blue)|\(tex)"
        if let cached = cache[key] { return cached }
        var math = MathImage(latex: tex, fontSize: size, textColor: resolved, labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, info) = math.asImage()
        let rendered: Rendered? = if error == nil, let image, image.size.width > 0 {
            Rendered(image: image, ascent: info?.ascent ?? image.size.height, descent: info?.descent ?? 0)
        } else {
            nil
        }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }
}

/// Mermaid diagrams drawn natively, in the app's colours, as in Issues.
@MainActor
enum DiagramStore {
    private struct Key: Hashable {
        var source: String
        var isDark: Bool
    }

    private static var cache: [Key: NSImage?] = [:]
    private static var pending: Set<Key> = []
    /// Diagrams still being drawn.
    static var isBusy: Bool { !pending.isEmpty }

    /// The diagram, if it is drawn; otherwise nil, and `ready` is called once it is. A diagram that can't be drawn
    /// gives `.some(nil)`.
    static func diagram(_ source: String, isDark: Bool, ready: @escaping () -> Void) -> NSImage?? {
        let key = Key(source: source, isDark: isDark)
        if let cached = cache[key] { return .some(cached) }
        if !pending.contains(key) {
            pending.insert(key)
            let theme = DiagramTheme(
                background: Theme.panel.resolved(dark: isDark),
                foreground: Theme.textBody.resolved(dark: isDark),
                line: Theme.textTertiary.resolved(dark: isDark),
                accent: Theme.accent.resolved(dark: isDark),
                surface: Theme.card.resolved(dark: isDark),
                border: Theme.cardBorder.resolved(dark: isDark),
                font: .systemFont(ofSize: 13),
                transparent: true
            )
            let scale = Screen.scale
            Task.detached(priority: .userInitiated) {
                var result: NSImage?
                if let image = try? MermaidRenderer.renderImage(source: source, theme: theme, scale: scale),
                   let cgImage = image.pixels,
                   let trimmed = trimmed(cgImage) {
                    result = NSImage.make(trimmed, scale: scale)
                }
                let drawn = result
                await MainActor.run {
                    pending.remove(key)
                    if cache.count > 64 { cache.removeAll() }
                    cache[key] = drawn
                    ready()
                }
            }
        }
        return nil
    }

    /// Turned the right way up (BeautifulMermaid 1.0.4 draws Mac images from the bottom; its UIKit ones are upright)
    /// and without the empty margin around the diagram.
    nonisolated private static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        #if os(macOS)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        #endif
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

extension NSColor {
    /// The colour as it is in the light or dark appearance.
    func resolved(dark: Bool) -> NSColor {
        #if os(macOS)
        var result = self
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
        #else
        resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        #endif
    }
}
