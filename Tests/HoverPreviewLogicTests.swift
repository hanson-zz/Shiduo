import XCTest

/// 悬停预览：哪种文件弹哪种预览、延迟、信息行；文件夹级联菜单：排序、隐藏文件、上限、修饰键。
final class HoverPreviewLogicTests: XCTestCase {
    typealias L = HoverPreviewLogic

    func testKindByTypeTree() {
        XCTAssertEqual(L.kind(typeTree: ["public.jpeg", "public.image"], ext: "jpg", isDirectory: false), .image)
        XCTAssertEqual(L.kind(typeTree: ["com.apple.quicktime-movie", "public.movie"], ext: "mov", isDirectory: false), .video)
        XCTAssertEqual(L.kind(typeTree: ["public.mp3", "public.audio"], ext: "mp3", isDirectory: false), .audio)
        XCTAssertEqual(L.kind(typeTree: ["com.adobe.pdf"], ext: "pdf", isDirectory: false), .document)
        XCTAssertEqual(L.kind(typeTree: ["public.plain-text", "public.text"], ext: "txt", isDirectory: false), .document)
    }

    func testKindByExtensionWhenTypeUnknown() {
        XCTAssertEqual(L.kind(typeTree: [], ext: "HEIC", isDirectory: false), .image)
        XCTAssertEqual(L.kind(typeTree: [], ext: "mp4", isDirectory: false), .video)
        XCTAssertEqual(L.kind(typeTree: [], ext: "flac", isDirectory: false), .audio)
        XCTAssertEqual(L.kind(typeTree: [], ext: "", isDirectory: false), .document)
    }

    func testFoldersGetNoPreview() {
        XCTAssertEqual(L.kind(typeTree: ["public.folder"], ext: "", isDirectory: true), .none)
        // 名字像图片的文件夹也不弹
        XCTAssertEqual(L.kind(typeTree: [], ext: "png", isDirectory: true), .none)
    }

    func testDelay() {
        XCTAssertEqual(L.delayChoices, [0.3, 0.5, 1.0])
        XCTAssertEqual(L.normalizedDelay(0.5), 0.5)
        XCTAssertEqual(L.normalizedDelay(0.35), 0.3)
        XCTAssertEqual(L.normalizedDelay(5), 1.0)
        XCTAssertEqual(L.normalizedDelay(-1), 0.3)
        XCTAssertEqual(L.normalizedDelay(.nan), L.defaultDelay)
        XCTAssertEqual(L.effectiveDelay(stored: 1.0, shiftHeld: true), 0)
        XCTAssertEqual(L.effectiveDelay(stored: 1.0, shiftHeld: false), 1.0)
    }

    func testInfoLineAndTimes() {
        XCTAssertEqual(L.infoLine(["JPEG", nil, " ", "3.2 MB"]), "JPEG · 3.2 MB")
        XCTAssertEqual(L.infoLine([]), "")
        XCTAssertEqual(L.pixelText(width: 4032, height: 3024), "4032 × 3024")
        XCTAssertNil(L.pixelText(width: 0, height: 10))
        XCTAssertEqual(L.timeText(16.9), "0:16")
        XCTAssertEqual(L.timeText(725), "12:05")
        XCTAssertEqual(L.timeText(3723), "1:02:03")
        XCTAssertEqual(L.timeText(.nan), "0:00")
        XCTAssertEqual(L.timeText(-3), "0:00")
    }

    func testMenuEntriesSortFoldersFirstAndSkipHidden() {
        let entries = [
            L.Entry(name: "b.txt", path: "/x/b.txt", isDirectory: false),
            L.Entry(name: "文件10", path: "/x/文件10", isDirectory: true),
            L.Entry(name: ".DS_Store", path: "/x/.DS_Store", isDirectory: false),
            L.Entry(name: "A.png", path: "/x/A.png", isDirectory: false),
            L.Entry(name: "文件2", path: "/x/文件2", isDirectory: true),
            L.Entry(name: "Icon\r", path: "/x/Icon\r", isDirectory: false, isHidden: true),
        ]
        let result = L.menuEntries(entries)
        XCTAssertEqual(result.shown.map(\.name), ["文件2", "文件10", "A.png", "b.txt"])
        XCTAssertEqual(result.remaining, 0)
    }

    func testMenuEntriesCap() {
        let entries = (0..<250).map { L.Entry(name: "f\($0)", path: "/x/f\($0)", isDirectory: false) }
        let result = L.menuEntries(entries)
        XCTAssertEqual(result.shown.count, 200)
        XCTAssertEqual(result.remaining, 50)
        XCTAssertEqual(result.shown.first?.name, "f0")
        XCTAssertEqual(result.shown.last?.name, "f199")
        let small = L.menuEntries(entries, cap: 3)
        XCTAssertEqual(small.shown.count, 3)
        XCTAssertEqual(small.remaining, 247)
    }

    func testMenuActions() {
        XCTAssertEqual(L.action(isDirectory: true, command: false, option: false), .navigate)
        XCTAssertEqual(L.action(isDirectory: false, command: false, option: false), .openFile)
        XCTAssertEqual(L.action(isDirectory: true, command: true, option: false), .openInNewFinderWindow)
        XCTAssertEqual(L.action(isDirectory: false, command: true, option: false), .revealInFinder)
        XCTAssertEqual(L.action(isDirectory: true, command: false, option: true), .revealInFinder)
        XCTAssertEqual(L.action(isDirectory: false, command: true, option: true), .revealInFinder)
    }

    func testPanelOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 300, height: 200)
        // 右边放得下：贴在格子右边，垂直居中
        XCTAssertEqual(L.panelOrigin(cell: CGRect(x: 100, y: 100, width: 100, height: 100), size: size, screen: screen),
                       CGPoint(x: 210, y: 50))
        // 右边放不下：放左边
        XCTAssertEqual(L.panelOrigin(cell: CGRect(x: 800, y: 300, width: 100, height: 100), size: size, screen: screen),
                       CGPoint(x: 490, y: 250))
        // 贴着屏幕底：往上挪
        XCTAssertEqual(L.panelOrigin(cell: CGRect(x: 100, y: 0, width: 100, height: 100), size: size, screen: screen).y, 10)
        // 贴着屏幕顶：往下挪
        XCTAssertEqual(L.panelOrigin(cell: CGRect(x: 100, y: 700, width: 100, height: 100), size: size, screen: screen).y, 590)
    }
}
