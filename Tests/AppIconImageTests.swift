import AppKit
import XCTest

/// 备选应用图标交给程序坞 / setIcon 之前的整理：重画成标准 RGBA 位图，透明边保留、尺寸不变。
/// 顺带打印一行诊断（PERF|APPICON …，CI 日志里能看到）：原图是不是索引色、原图和整理后的图各自能不能被 setIcon 写进一个临时文件夹。
final class AppIconImageTests: XCTestCase {
    private func iconURL(_ id: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AltAppIcons/\(id).png")
    }

    private func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.colorAt(x: x, y: y)?.alphaComponent
    }

    func testPalettePNGBecomesRGBA() throws {
        let raw = try XCTUnwrap(NSImage(contentsOf: iconURL("panda-cream")), "图标文件读不到")
        let normalized = try XCTUnwrap(AppIconImage.normalized(raw))
        XCTAssertFalse(AppIconImage.isIndexedColor(normalized))
        let cg = try XCTUnwrap(normalized.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 1024)
        XCTAssertEqual(cg.height, 1024)
        XCTAssertEqual(cg.colorSpace?.model, .rgb)
        XCTAssertEqual(normalized.size, NSSize(width: 1024, height: 1024))
        // 四角是透明边，中间是图标本体。
        XCTAssertEqual(try XCTUnwrap(alpha(normalized, x: 2, y: 2)), 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(alpha(normalized, x: 512, y: 512)), 0.9)
    }

    func testSmallerLosslessIconKeepsItsSize() throws {
        let raw = try XCTUnwrap(NSImage(contentsOf: iconURL("mac-rainbow-pro")))
        XCTAssertEqual(AppIconImage.pixelSide(of: raw), 768)
        let normalized = try XCTUnwrap(AppIconImage.normalized(raw))
        let cg = try XCTUnwrap(normalized.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 768)
    }

    func testEveryBundledIconNormalizes() throws {
        let folder = iconURL("x").deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(names.count, 28)
        var indexed = 0
        for name in names {
            let raw = try XCTUnwrap(NSImage(contentsOf: folder.appendingPathComponent(name)), name)
            if AppIconImage.isIndexedColor(raw) { indexed += 1 }
            let normalized = try XCTUnwrap(AppIconImage.normalized(raw), name)
            XCTAssertFalse(AppIconImage.isIndexedColor(normalized), name)
        }
        print("PERF|APPICON bundled=\(names.count) indexedColor=\(indexed)")
    }

    /// 诊断：原图（调色板）和整理后的图分别 setIcon 到临时文件夹。只打印，不判断（CI 机器上 setIcon 本身可能受限）。
    func testSetIconDiagnostic() throws {
        let raw = try XCTUnwrap(NSImage(contentsOf: iconURL("panda-cream")))
        let normalized = try XCTUnwrap(AppIconImage.normalized(raw))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AppIconImageTests-\(UUID().uuidString)")
        let a = base.appendingPathComponent("raw")
        let b = base.appendingPathComponent("normalized")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let rawOK = NSWorkspace.shared.setIcon(raw, forFile: a.path, options: [])
        let normalizedOK = NSWorkspace.shared.setIcon(normalized, forFile: b.path, options: [])
        let rawFile = FileManager.default.fileExists(atPath: a.appendingPathComponent("Icon\r").path)
        let normalizedFile = FileManager.default.fileExists(atPath: b.appendingPathComponent("Icon\r").path)
        print("PERF|APPICON rawIndexed=\(AppIconImage.isIndexedColor(raw)) setIconRaw=\(rawOK) iconFileRaw=\(rawFile) setIconNormalized=\(normalizedOK) iconFileNormalized=\(normalizedFile)")
    }
}
