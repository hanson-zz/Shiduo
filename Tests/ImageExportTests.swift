import CoreGraphics
import XCTest

final class ImageExportTests: XCTestCase {
    func testSpaceChoice() {
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .rgb, name: CGColorSpace.displayP3 as String, supportsOutput: true), .source)
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .rgb, name: CGColorSpace.sRGB as String, supportsOutput: true), .source)
        // 嵌入的 ICC（没有名字）照样沿用
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .rgb, name: nil, supportsOutput: true), .source)
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .rgb, name: ImageExportLogic.deviceRGBName, supportsOutput: true), .sRGB)
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .rgb, name: nil, supportsOutput: false), .displayP3)
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .cmyk, name: nil, supportsOutput: true), .displayP3)
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: .monochrome, name: nil, supportsOutput: true), .displayP3)
    }

    func testRealColorSpaces() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: p3.model, name: p3.name as String?, supportsOutput: p3.supportsOutput), .source)
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        XCTAssertEqual(ImageExportLogic.spaceChoice(model: gray.model, name: gray.name as String?, supportsOutput: gray.supportsOutput), .displayP3)
    }

    func testBits() {
        XCTAssertEqual(ImageExportLogic.canvasBits(sourceBits: 8), 8)
        XCTAssertEqual(ImageExportLogic.canvasBits(sourceBits: 16), 16)
        XCTAssertEqual(ImageExportLogic.canvasBits(sourceBits: 32), 16)
        XCTAssertEqual(ImageExportLogic.fileBits(canvasBits: 16, keepsDepth: true), 16)
        XCTAssertEqual(ImageExportLogic.fileBits(canvasBits: 16, keepsDepth: false), 8)
        XCTAssertEqual(ImageExportLogic.fileBits(canvasBits: 8, keepsDepth: true), 8)
        XCTAssertEqual(ImageExportLogic.mergedBits([8, 16, 8]), 16)
        XCTAssertEqual(ImageExportLogic.mergedBits([]), 8)
    }

    func testCommon() {
        XCTAssertEqual(ImageExportLogic.common(["a", "a"]), "a")
        XCTAssertNil(ImageExportLogic.common(["a", "b"]))
        XCTAssertNil(ImageExportLogic.common([String]()))
    }

    private struct Exists: Error {}
    private struct Other: Error {}

    func testWriteAvoidingExisting() throws {
        let taken: Set<String> = ["/a/x.png", "/a/x 2.png"]
        var tried: [String] = []
        var n = 1
        let result = try ImageExportLogic.writeAvoidingExisting(
            URL(fileURLWithPath: "/a/x.png"),
            next: { _ in n += 1; return URL(fileURLWithPath: "/a/x \(n).png") },
            isExists: { $0 is Exists },
            write: { url in
                tried.append(url.path)
                if taken.contains(url.path) { throw Exists() }
            })
        XCTAssertEqual(result.path, "/a/x 3.png")
        XCTAssertEqual(tried, ["/a/x.png", "/a/x 2.png", "/a/x 3.png"])

        // 其他错误直接抛出，不换名字重试
        var count = 0
        XCTAssertThrowsError(try ImageExportLogic.writeAvoidingExisting(
            URL(fileURLWithPath: "/a/y.png"), next: { $0 }, isExists: { $0 is Exists },
            write: { _ in count += 1; throw Other() }))
        XCTAssertEqual(count, 1)

        // 一直被占用：试满次数后失败
        count = 0
        XCTAssertThrowsError(try ImageExportLogic.writeAvoidingExisting(
            URL(fileURLWithPath: "/a/z.png"), attempts: 3, next: { $0 }, isExists: { $0 is Exists },
            write: { _ in count += 1; throw Exists() }))
        XCTAssertEqual(count, 3)
    }
}
