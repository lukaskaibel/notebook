#if os(macOS)
import Accelerate
import AppKit
import Observation

/// A colour of the notebook on the app's icon, in 8-bit sRGB.
public struct NotebookColor: Codable, Hashable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    public init(hex: UInt32) {
        self.init(red: Int(hex >> 16 & 0xFF), green: Int(hex >> 8 & 0xFF), blue: Int(hex & 0xFF))
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        self.init(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var components: SIMD3<Double> { SIMD3(Double(red), Double(green), Double(blue)) / 255 }

    init(_ components: SIMD3<Double>) {
        let c = (components.clamped(lowerBound: .zero, upperBound: .one) * 255).rounded(.toNearestOrEven)
        self.init(red: Int(c.x), green: Int(c.y), blue: Int(c.z))
    }

    /// The same hue with its saturation and brightness scaled, as Tools/AppIcon/notebook.py does it.
    func scaled(saturation: Double, brightness: Double) -> NotebookColor {
        var (h, s, v) = hsv
        s = min(s * saturation, 1)
        v = min(v * brightness, 1)
        return NotebookColor(Self.rgb(h: h, s: s, v: v))
    }

    /// Python's colorsys.rgb_to_hsv, so both sides get the same shades.
    private var hsv: (Double, Double, Double) {
        let c = components
        let high = c.max(), low = c.min()
        guard high > 0, high != low else { return (0, 0, high) }
        let s = (high - low) / high
        let r = (high - c.x) / (high - low), g = (high - c.y) / (high - low), b = (high - c.z) / (high - low)
        var h = c.x == high ? b - g : c.y == high ? 2 + r - b : 4 + g - r
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        return (h < 0 ? h + 1 : h, s, high)
    }

    private static func rgb(h: Double, s: Double, v: Double) -> SIMD3<Double> {
        guard s > 0 else { return SIMD3(repeating: v) }
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

/// The notebook on the app's icon: its leather, the ribbon and the elastic band. The cover fills the icon, so there is
/// nothing it lies on; a look saved when there was (its `ground`) still reads, without it.
public struct NotebookLook: Codable, Hashable, Sendable {
    public enum Band: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The band in a dark shade of the leather, like a real notebook's.
        case leather
        case white
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
    }

    public var leather: NotebookColor
    public var ribbon: NotebookColor
    public var band: Band

    public init(leather: NotebookColor, ribbon: NotebookColor, band: Band) {
        self.leather = leather
        self.ribbon = ribbon
        self.band = band
    }

    /// The notebook the app ships with. Notebook/AppIcon.icon is drawn from the same colours (Tools/AppIcon/notebook.py).
    public static let standard = NotebookLook(leather: NotebookColor(hex: 0xA8403F), ribbon: NotebookColor(hex: 0xE9B04A),
                                              band: .leather)

    public struct Swatch: Identifiable, Sendable {
        public let name: String
        public let color: NotebookColor
        public var id: String { name }
        init(_ name: String, _ hex: UInt32) { (self.name, color) = (name, NotebookColor(hex: hex)) }
    }

    public static let leathers = [
        Swatch("Oxblood", 0xA8403F), Swatch("Cognac", 0xC98B4E), Swatch("Tan", 0xD7A56B), Swatch("Red", 0xE04A41),
        Swatch("Plum", 0x7E4A7A), Swatch("Navy", 0x405E9E), Swatch("Forest", 0x3F7D5D), Swatch("Black", 0x4A4C52),
    ]
    public static let ribbons = [
        Swatch("Gold", 0xE9B04A), Swatch("Wine", 0x7E1D22), Swatch("Red", 0xD9443C), Swatch("Cream", 0xF3E3C8),
        Swatch("Navy", 0x2B3E73), Swatch("Green", 0x2E6B4A),
    ]

    /// The cover's gradient from top to bottom: in dark mode a little deeper, to sit with the other dark icons.
    func cover(dark: Bool) -> (NotebookColor, NotebookColor) {
        dark ? (leather.scaled(saturation: 1.0, brightness: 0.9), leather.scaled(saturation: 1.2, brightness: 0.55))
             : (leather, leather.scaled(saturation: 1.18, brightness: 0.64))
    }

    var bandColor: NotebookColor {
        band == .white ? NotebookColor(hex: 0xFFFFFF) : leather.scaled(saturation: 1.25, brightness: 0.45)
    }
}

/// Draws the notebook in any colours. Apple's ictool rendered it once per part in grey with everything else black
/// (Tools/AppIcon/make.sh), so the glass, shadows and grain are the system's own; adding the passes up in linear
/// light, each scaled by its colour, gives the icon: base + Σ colour × (pass − base) / grey.
@MainActor
final class NotebookRenderer {
    static let shared = NotebookRenderer()

    /// The passes' size, in pixels: enough for the Dock at its largest.
    static let size = 512
    /// The albedo each part has in its pass (#B4B4B4), in linear light.
    private static let passGrey = Float(decode(Double(0xB4) / 255))

    private enum Part: String, CaseIterable { case cover, band, ribbon }

    /// Planar linear-light channels of one look's passes: the base, its alpha and each part's difference to the base.
    private struct Passes {
        var base: [[Float]]
        var alpha: [Float]
        var parts: [Part: [[Float]]]
    }

    private var passes: [Bool: Passes] = [:]

    /// The icon as the system draws a full-bleed icon: the rounded square filling the image. Linear Display P3 in
    /// floats; whatever draws it brings it to its own colour space.
    func image(_ look: NotebookLook, dark: Bool) -> CGImage? {
        guard let passes = loadPasses(dark: dark) else { return nil }
        let n = Self.size
        var channels = passes.base
        let rows: [Part: [SIMD3<Float>]] = [
            .cover: gradient(look.cover(dark: dark), from: 0, height: 1024),
            .band: gradient((look.bandColor, look.bandColor), from: 0, height: 1024),
            .ribbon: gradient((look.ribbon, look.ribbon), from: 0, height: 1024),
        ]
        for part in Part.allCases {
            guard let deltas = passes.parts[part], let colours = rows[part] else { continue }
            for channel in 0..<3 {
                deltas[channel].withUnsafeBufferPointer { delta in
                    channels[channel].withUnsafeMutableBufferPointer { out in
                        for row in 0..<n {
                            var scale = colours[row][channel]
                            let at = row * n
                            vDSP_vsma(delta.baseAddress! + at, 1, &scale, out.baseAddress! + at, 1, out.baseAddress! + at, 1, vDSP_Length(n))
                        }
                    }
                }
            }
        }
        var low: Float = 0, high: Float = 1
        for channel in 0..<3 {
            channels[channel].withUnsafeMutableBufferPointer { v in
                vDSP_vclip(v.baseAddress!, 1, &low, &high, v.baseAddress!, 1, vDSP_Length(n * n))
            }
        }
        // Interleaved as RGBA floats with straight alpha.
        var rgba = [Float](repeating: 0, count: n * n * 4)
        var (red, green, blue, alpha) = (channels[0], channels[1], channels[2], passes.alpha)
        let converted: vImage_Error = rgba.withUnsafeMutableBytes { out in
            var dest = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(n), width: vImagePixelCount(n), rowBytes: n * 16)
            // Planes in, in byte order: R, G, B, A.
            return Self.planar(&red) { r in Self.planar(&green) { g in Self.planar(&blue) { b in Self.planar(&alpha) { a in
                vImageConvert_PlanarFtoARGBFFFF(&r, &g, &b, &a, &dest, vImage_Flags(kvImageNoFlags))
            } } } }
        }
        guard converted == kvImageNoError,
              let provider = CGDataProvider(data: rgba.withUnsafeBytes { Data($0) } as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearDisplayP3) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: n, height: n, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: n * 16, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The icon as the Dock wants it: on Apple's icon grid (824 of 1024), with the Dock's soft shadow.
    func dockImage(_ look: NotebookLook, dark: Bool) -> NSImage? {
        guard let icon = image(look, dark: dark) else { return nil }
        let content = CGFloat(Self.size), canvas = (content / 824 * 1024).rounded()
        let inset = ((canvas - content) / 2).rounded()
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = content / 824
        context.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.28))
        context.draw(icon, in: CGRect(x: inset, y: inset, width: content, height: content))
        guard let padded = context.makeImage() else { return nil }
        return NSImage(cgImage: padded, size: NSSize(width: canvas / 2, height: canvas / 2))
    }

    // MARK: - Passes

    private func loadPasses(dark: Bool) -> Passes? {
        if let loaded = passes[dark] { return loaded }
        let look = dark ? "dark" : "light"
        guard let (base, alpha) = Self.load("\(look)-base") else { return nil }
        var parts: [Part: [[Float]]] = [:]
        var scale = 1 / Self.passGrey
        for part in Part.allCases {
            guard var (pass, _) = Self.load("\(look)-\(part.rawValue)") else { return nil }
            for channel in 0..<3 {
                pass[channel].withUnsafeMutableBufferPointer { p in
                    base[channel].withUnsafeBufferPointer { b in
                        let count = vDSP_Length(p.count)
                        vDSP_vsub(b.baseAddress!, 1, p.baseAddress!, 1, p.baseAddress!, 1, count)   // pass − base
                        vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, count)
                    }
                }
            }
            parts[part] = pass
        }
        let loaded = Passes(base: base, alpha: alpha, parts: parts)
        passes[dark] = loaded
        return loaded
    }

    /// A pass as linear-light channels and its alpha. The passes are Display P3 with the sRGB curve; drawing them into
    /// a Display P3 context leaves their values as they are.
    private static func load(_ name: String) -> ([[Float]], [Float])? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "NotebookIcon"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let n = size * size
        var rgba = vImage_Buffer(data: data, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size * 4)
        var (r8, g8, b8, a8) = ([UInt8](repeating: 0, count: n), [UInt8](repeating: 0, count: n),
                                [UInt8](repeating: 0, count: n), [UInt8](repeating: 0, count: n))
        var error = vImageUnpremultiplyData_RGBA8888(&rgba, &rgba, vImage_Flags(kvImageNoFlags))
        if error == kvImageNoError {
            // Planes out, in byte order: R, G, B, A.
            error = planar(&r8) { r in planar(&g8) { g in planar(&b8) { b in planar(&a8) { a in
                vImageConvert_ARGB8888toPlanar8(&rgba, &r, &g, &b, &a, vImage_Flags(kvImageNoFlags))
            } } } }
        }
        let decoded = decodeTable, linear = (0...255).map { Float($0) / 255 }
        var channels: [[Float]] = []
        for (index, var plane) in [r8, g8, b8, a8].enumerated() where error == kvImageNoError {
            var out = [Float](repeating: 0, count: n)
            error = planar(&plane) { source in planar(&out) { dest in
                vImageLookupTable_Planar8toPlanarF(&source, &dest, index == 3 ? linear : decoded, vImage_Flags(kvImageNoFlags))
            } }
            channels.append(out)
        }
        guard error == kvImageNoError, channels.count == 4 else { return nil }
        return (Array(channels.prefix(3)), channels[3])
    }

    /// A vImage buffer over one plane of the icon.
    private static func planar<T, R>(_ plane: inout [T], _ body: (inout vImage_Buffer) -> R) -> R {
        plane.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size),
                                       rowBytes: size * MemoryLayout<T>.stride)
            return body(&buffer)
        }
    }

    // MARK: - Colour

    /// Rows of linear Display P3 colour for a gradient that runs from `from` over `height` on the 1024 canvas,
    /// mixed in sRGB as Icon Composer and the SVG renderer mix them.
    private func gradient(_ colours: (NotebookColor, NotebookColor), from: Double, height: Double) -> [SIMD3<Float>] {
        let n = Self.size, scale = Double(n) / 1024
        let top = colours.0.components, bottom = colours.1.components
        return (0..<n).map { row in
            let t = min(max((Double(row) + 0.5 - from * scale) / (height * scale), 0), 1)
            return Self.linearDisplayP3(top * (1 - t) + bottom * t)
        }
    }

    /// sRGB → linear sRGB → linear Display P3.
    private static func linearDisplayP3(_ srgb: SIMD3<Double>) -> SIMD3<Float> {
        let l = SIMD3(decode(srgb.x), decode(srgb.y), decode(srgb.z))
        return SIMD3(Float(0.8225 * l.x + 0.1774 * l.y),
                     Float(0.0332 * l.x + 0.9669 * l.y),
                     Float(0.0171 * l.x + 0.0724 * l.y + 0.9108 * l.z))
    }

    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static let decodeTable: [Float] = (0...255).map { Float(decode(Double($0) / 255)) }
}

/// The notebook you made in Settings › App Icon. The app shows it in the Dock while it runs, in light or dark with the
/// system; the standard notebook is the app's own icon, so the Dock keeps that one with its glass and tinted looks.
@MainActor
@Observable
public final class AppIconStore {
    public static let shared = AppIconStore()
    static let defaultsKey = "appIcon"

    public var look: NotebookLook {
        didSet {
            guard look != oldValue else { return }
            if let data = try? JSONEncoder().encode(look) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
            renderPreviews()
            scheduleDock()
        }
    }

    /// The notebook as the Dock shows it, for the preview in Settings.
    public private(set) var lightIcon: NSImage?
    public private(set) var darkIcon: NSImage?

    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingDock: Task<Void, Never>?

    private init() {
        look = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(NotebookLook.self, from: $0) } ?? .standard
    }

    /// Puts your notebook in the Dock and keeps it in step with light and dark. Called once at launch.
    public func start() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyToDock() }
        }
        if look != .standard { renderPreviews() }
        applyToDock()
    }

    public func reset() { look = .standard }

    func renderPreviews() {
        lightIcon = NotebookRenderer.shared.dockImage(look, dark: false)
        darkIcon = NotebookRenderer.shared.dockImage(look, dark: true)
    }

    /// While a colour is being dragged in the colour panel, the Dock is updated a moment after it stops.
    private func scheduleDock() {
        pendingDock?.cancel()
        pendingDock = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            applyToDock()
        }
    }

    private func applyToDock() {
        guard look != .standard else {
            NSApp.applicationIconImage = nil
            return
        }
        if lightIcon == nil { renderPreviews() }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = dark ? darkIcon : lightIcon
    }
}
#endif
