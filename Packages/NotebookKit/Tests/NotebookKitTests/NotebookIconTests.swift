import AppKit
import XCTest
@testable import NotebookKit

/// The notebook on the app icon: its shades match Tools/AppIcon/notebook.py, and adding up the passes gives the
/// icon Apple's ictool draws for Notebook/AppIcon.icon.
@MainActor
final class NotebookIconTests: XCTestCase {
    private func hex(_ value: UInt32) -> NotebookColor { NotebookColor(hex: value) }

    func testShadesMatchTheIconScript() {
        let look = NotebookLook.standard
        XCTAssertEqual(look.cover(dark: false).0, hex(0xA8403F))
        XCTAssertEqual(look.cover(dark: false).1, hex(0x6C1D1C))
        XCTAssertEqual(look.cover(dark: true).0, hex(0x973A39), "a little deeper in dark mode")
        XCTAssertEqual(look.cover(dark: true).1, hex(0x5C1817))
        XCTAssertEqual(look.bandColor, hex(0x4C1111))

        var navy = look
        navy.leather = hex(0x405E9E)
        XCTAssertEqual(navy.cover(dark: false).1, hex(0x1E3565))
        navy.band = .white
        XCTAssertEqual(navy.bandColor, hex(0xFFFFFF))
    }

    func testStandardNotebookLooksLikeTheAppIcon() throws {
        // ictool's own render of Notebook/AppIcon.icon at 512 px: the cover at its middle, near its top and near its
        // bottom, the ribbon and the band.
        let light = try XCTUnwrap(NotebookRenderer.shared.image(.standard, dark: false))
        XCTAssertEqual(light.width, 512)
        assertPixel(light, 256, 256, near: [147, 60, 55])
        assertPixel(light, 384, 100, near: [179, 79, 74])
        assertPixel(light, 256, 480, near: [83, 29, 26])
        assertPixel(light, 120, 40, near: [224, 178, 92], "the ribbon hangs from the top")
        assertPixel(light, 411, 256, near: [69, 21, 19], "the band")
        XCTAssertEqual(pixel(light, 0, 0)[3], 0, "outside the rounded square is clear")

        let dark = try XCTUnwrap(NotebookRenderer.shared.image(.standard, dark: true))
        assertPixel(dark, 256, 256, near: [128, 53, 49])
        assertPixel(dark, 384, 100, near: [159, 70, 66])
        assertPixel(dark, 120, 40, near: [224, 178, 92])
    }

    func testAnyLeatherColours() throws {
        var look = NotebookLook.standard
        look.leather = hex(0x405E9E)
        let navy = try XCTUnwrap(NotebookRenderer.shared.image(look, dark: false))
        let p = pixel(navy, 256, 256)
        XCTAssertGreaterThan(p[2], p[0] + 40, "a navy cover is blue")
        assertPixel(navy, 120, 40, near: [224, 178, 92], "the ribbon stays as it was")
    }

    func testDockImageSitsOnTheIconGrid() throws {
        let image = try XCTUnwrap(NotebookRenderer.shared.dockImage(.standard, dark: false))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 636)
        XCTAssertEqual(pixel(cg, 30, 318)[3], 0, "a margin round the icon, as on Apple's grid")
        XCTAssertEqual(pixel(cg, 318, 318)[3], 255)
    }

    func testLookIsSaved() throws {
        let look = NotebookLook(leather: hex(0x3F7D5D), ribbon: hex(0xF3E3C8), band: .white)
        let decoded = try JSONDecoder().decode(NotebookLook.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(decoded, look)

        // Saved when the notebook still lay on a background: the leather, band and ribbon stay.
        let old = Data(#"{"leather":{"red":63,"green":125,"blue":93},"ribbon":{"red":243,"green":227,"blue":200},"band":"white","ground":{"red":225,"green":233,"blue":242}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NotebookLook.self, from: old), look)
        XCTAssertEqual(NotebookColor(hex(0xE9B04A).nsColor), hex(0xE9B04A), "colours survive the colour panel")
    }

    // MARK: - Pixels

    /// RGBA at a point, top-left origin, in the image's own Display P3 values.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(p[$0]) }
    }

    private func assertPixel(_ image: CGImage, _ x: Int, _ y: Int, near expected: [Int], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let p = pixel(image, x, y)
        for channel in 0..<3 where abs(p[channel] - expected[channel]) > 4 {
            XCTFail("pixel \(x),\(y) is \(Array(p.prefix(3))), expected about \(expected). \(message)", file: file, line: line)
            return
        }
    }
}
