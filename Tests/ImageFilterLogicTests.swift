import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// 图片筛选：方向、尺寸、主色提取（用生成的图片测）。
final class ImageFilterLogicTests: XCTestCase {
    // MARK: 生成测试图片

    /// 画一张图：stripes 是从上到下的色带（颜色, 占的比例）。
    private func makeImage(width: Int, height: Int, stripes: [(RGBColor, Double)], alpha: UInt8 = 255) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = 0
        for (index, stripe) in stripes.enumerated() {
            let h = index == stripes.count - 1 ? height - y : Int((Double(height) * stripe.1).rounded())
            let a = CGFloat(alpha) / 255
            context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(stripe.0.r) / 255, CGFloat(stripe.0.g) / 255,
                                                                         CGFloat(stripe.0.b) / 255, a])!)
            context.fill(CGRect(x: 0, y: y, width: width, height: h))
            y += h
        }
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, orientation: Int? = nil, type: UTType = .png) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiduo-imgtest-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let red = RGBColor(r: 230, g: 40, b: 40)
    private let blue = RGBColor(r: 30, g: 90, b: 220)
    private let yellow = RGBColor(r: 245, g: 215, b: 40)

    private func close(_ a: RGBColor, _ b: RGBColor, tolerance: Int = 12, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(Int(a.r) - Int(b.r)), tolerance, "\(a.hex) vs \(b.hex)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(a.g) - Int(b.g)), tolerance, "\(a.hex) vs \(b.hex)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(a.b) - Int(b.b)), tolerance, "\(a.hex) vs \(b.hex)", file: file, line: line)
    }

    // MARK: 颜色

    func testHex() {
        XCTAssertEqual(RGBColor(r: 26, g: 43, b: 60).hex, "#1A2B3C")
        XCTAssertEqual(RGBColor(hex: "#1A2B3C"), RGBColor(r: 26, g: 43, b: 60))
        XCTAssertEqual(RGBColor(hex: "ffffff"), RGBColor(r: 255, g: 255, b: 255))
        XCTAssertNil(RGBColor(hex: "#12345"))
        XCTAssertNil(RGBColor(hex: "zzzzzz"))
    }

    func testSwatchClassification() {
        // 每个色块自己的显示颜色归到它自己。
        for swatch in ColorSwatch.allCases {
            XCTAssertEqual(ColorSwatch.classify(swatch.display), swatch, swatch.rawValue)
        }
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 0, g: 0, b: 0)), .black)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 255, g: 255, b: 255)), .white)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 128, g: 128, b: 130)), .gray)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 255, g: 0, b: 0)), .red)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 0, g: 200, b: 0)), .green)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 0, g: 0, b: 255)), .blue)
        XCTAssertEqual(ColorSwatch.classify(RGBColor(r: 255, g: 0, b: 255)), .pink)
    }

    // MARK: 取主色

    func testQuantizerSolidAndTransparent() {
        var pixels: [UInt8] = []
        for _ in 0..<100 { pixels += [200, 30, 30, 255] }
        for _ in 0..<300 { pixels += [0, 255, 0, 0] }   // 全透明：不算
        let colors = ColorQuantizer.dominantColors(rgba: pixels, count: 5)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].color, RGBColor(r: 200, g: 30, b: 30))
        XCTAssertEqual(colors[0].weight, 1, accuracy: 0.0001)
        XCTAssertTrue(ColorQuantizer.dominantColors(rgba: [], count: 5).isEmpty)
        XCTAssertTrue(ColorQuantizer.dominantColors(rgba: [1, 2, 3, 0], count: 5).isEmpty)
    }

    func testQuantizerMergesNearbyShadesAndOrdersByShare() {
        var pixels: [UInt8] = []
        // 70% 两种很接近的蓝（应该并成一个），30% 黄。
        for i in 0..<700 { pixels += i % 2 == 0 ? [30, 90, 220, 255] : [36, 96, 214, 255] }
        for _ in 0..<300 { pixels += [245, 215, 40, 255] }
        let colors = ColorQuantizer.dominantColors(rgba: pixels, count: 5)
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[0].weight, 0.7, accuracy: 0.001)
        XCTAssertEqual(colors[1].weight, 0.3, accuracy: 0.001)
        close(colors[0].color, RGBColor(r: 33, g: 93, b: 217), tolerance: 2)
        XCTAssertEqual(colors[1].color, yellow)
        // 结果确定：再算一次一样。
        XCTAssertEqual(ColorQuantizer.dominantColors(rgba: pixels, count: 5), colors)
        // 最多给 count 个。
        XCTAssertEqual(ColorQuantizer.dominantColors(rgba: pixels, count: 1).count, 1)
    }

    func testReadGeneratedImage() throws {
        let image = makeImage(width: 400, height: 200, stripes: [(blue, 0.75), (yellow, 0.25)])
        let url = try writePNG(image)
        let meta = try XCTUnwrap(ImageMetaReader.read(url))
        XCTAssertEqual(meta.width, 400)
        XCTAssertEqual(meta.height, 200)
        XCTAssertEqual(meta.orientation, .landscape)
        XCTAssertGreaterThanOrEqual(meta.colors.count, 2)
        close(meta.colors[0].color, blue)
        XCTAssertEqual(meta.colors[0].weight, 0.75, accuracy: 0.06)
        close(meta.colors[1].color, yellow)
        XCTAssertEqual(ColorSwatch.classify(meta.colors[0].color), .blue)
        XCTAssertEqual(ColorSwatch.classify(meta.colors[1].color), .yellow)
        // 筛选：蓝色、黄色（占 25% > 12%）都能筛到，红色不行。
        XCTAssertTrue(ImageFilter(color: .blue).matches(meta))
        XCTAssertTrue(ImageFilter(color: .yellow).matches(meta))
        XCTAssertFalse(ImageFilter(color: .red).matches(meta))
    }

    func testExifRotationSwapsSize() throws {
        // EXIF 方向 6（顺时针转 90°）：存的是横图，看到的是竖图。
        let image = makeImage(width: 300, height: 100, stripes: [(red, 1)])
        let url = try writePNG(image, orientation: 6, type: .jpeg)
        let meta = try XCTUnwrap(ImageMetaReader.read(url))
        XCTAssertEqual(meta.width, 100)
        XCTAssertEqual(meta.height, 300)
        XCTAssertEqual(meta.orientation, .portrait)
        close(meta.colors[0].color, red)
    }

    func testSemiTransparentKeepsColor() throws {
        let image = makeImage(width: 64, height: 64, stripes: [(red, 1)], alpha: 200)
        let url = try writePNG(image)
        let meta = try XCTUnwrap(ImageMetaReader.read(url))
        close(meta.colors[0].color, red, tolerance: 16)
    }

    func testUnreadableFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shiduo-not-image-\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ImageMetaReader.read(url))
    }

    // MARK: 方向和尺寸

    func testOrientation() {
        XCTAssertEqual(ImageOrientation.of(width: 1920, height: 1080), .landscape)
        XCTAssertEqual(ImageOrientation.of(width: 1080, height: 1920), .portrait)
        XCTAssertEqual(ImageOrientation.of(width: 1000, height: 1000), .square)
        XCTAssertEqual(ImageOrientation.of(width: 1000, height: 980), .square)   // 差 2%
        XCTAssertEqual(ImageOrientation.of(width: 1000, height: 900), .landscape)
    }

    func testSizeAndOrientationFilter() {
        let big = ImageMeta(width: 4032, height: 3024, colors: [])
        let phone = ImageMeta(width: 1170, height: 2532, colors: [])
        let icon = ImageMeta(width: 512, height: 512, colors: [])
        let broken = ImageMeta(width: 0, height: 0, colors: [])

        XCTAssertFalse(ImageFilter().isActive)
        XCTAssertTrue(ImageFilter().matches(icon))

        let atLeast2K = ImageFilter(size: .atLeast2000)
        XCTAssertTrue(atLeast2K.matches(big))
        XCTAssertTrue(atLeast2K.matches(phone))     // 长边 2532
        XCTAssertFalse(atLeast2K.matches(icon))
        XCTAssertFalse(atLeast2K.matches(broken))

        let fourK = ImageFilter(size: .atLeast4000)
        XCTAssertTrue(fourK.matches(big))
        XCTAssertFalse(fourK.matches(phone))

        var custom = ImageFilter(size: .custom)
        custom.customMinWidth = 1000
        custom.customMinHeight = 2000
        XCTAssertTrue(custom.matches(big))          // 宽 4032 ≥ 1000，高 3024 ≥ 2000
        XCTAssertTrue(custom.matches(phone))
        XCTAssertFalse(custom.matches(icon))

        XCTAssertTrue(ImageFilter(orientation: .portrait).matches(phone))
        XCTAssertFalse(ImageFilter(orientation: .portrait).matches(big))
        XCTAssertTrue(ImageFilter(orientation: .square).matches(icon))

        // 条件叠加：竖 + ≥2K。
        let combo = ImageFilter(size: .atLeast2000, orientation: .portrait)
        XCTAssertTrue(combo.matches(phone))
        XCTAssertFalse(combo.matches(big))
        XCTAssertFalse(combo.matches(icon))
    }

    func testColorFilterNeedsEnoughShare() {
        let mostlyGray = ImageMeta(width: 100, height: 100, colors: [
            WeightedColor(color: RGBColor(r: 128, g: 128, b: 128), weight: 0.9),
            WeightedColor(color: RGBColor(r: 230, g: 40, b: 40), weight: 0.05),
        ])
        XCTAssertTrue(ImageFilter(color: .gray).matches(mostlyGray))
        XCTAssertFalse(ImageFilter(color: .red).matches(mostlyGray))   // 只占 5%
    }

    func testSummary() {
        var filter = ImageFilter(size: .atLeast2000, orientation: .landscape, color: .red)
        XCTAssertEqual(filter.summary, "横 · ≥2K · 红")
        filter = ImageFilter(size: .custom, customMinWidth: 800, customMinHeight: 600)
        XCTAssertEqual(filter.summary, "≥800×600")
    }
}
