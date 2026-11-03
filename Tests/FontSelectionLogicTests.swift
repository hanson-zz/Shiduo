import XCTest

/// 字体库多选：框选矩形命中、⌘ 反选、⇧ 连选；拖进窗口安装时认哪些文件。
final class FontSelectionLogicTests: XCTestCase {
    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 100, height: 100),
        "b": CGRect(x: 120, y: 0, width: 100, height: 100),
        "c": CGRect(x: 0, y: 120, width: 100, height: 100),
        "d": CGRect(x: 120, y: 120, width: 100, height: 100),
    ]

    func testMarqueeHitsIntersectingCards() {
        XCTAssertEqual(FontSelectionLogic.hits(frames, rect: CGRect(x: 50, y: 50, width: 120, height: 20)), ["a", "b"])
        XCTAssertEqual(FontSelectionLogic.hits(frames, rect: CGRect(x: 50, y: 50, width: 120, height: 120)), ["a", "b", "c", "d"])
        XCTAssertEqual(FontSelectionLogic.hits(frames, rect: CGRect(x: 104, y: 0, width: 12, height: 300)), [], "卡片之间的空隙不算")
        XCTAssertEqual(FontSelectionLogic.hits(frames, rect: CGRect(x: 98, y: 98, width: 1, height: 1)), [], "刚擦到边不算")
        XCTAssertEqual(FontSelectionLogic.hits(frames, rect: .zero), [])
    }

    func testRectFromAnyDirection() {
        let r = FontSelectionLogic.rect(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 50, y: 10))
        XCTAssertEqual(r, CGRect(x: 50, y: 10, width: 150, height: 140))
    }

    func testMarqueeReplaceAndToggle() {
        XCTAssertEqual(FontSelectionLogic.marqueeSelection(base: ["a", "x"], hit: ["a", "b"], toggle: false), ["a", "b"],
                       "普通拖动：只留框到的")
        XCTAssertEqual(FontSelectionLogic.marqueeSelection(base: ["a", "x"], hit: ["a", "b"], toggle: true), ["b", "x"],
                       "⌘ 拖动：反选框到的")
        XCTAssertEqual(FontSelectionLogic.marqueeSelection(base: ["a"], hit: [], toggle: true), ["a"])
    }

    func testShiftRange() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: "b", target: "d"), ["b", "c", "d"])
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: "d", target: "a"), ["a", "b", "c", "d"], "往前连选")
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: "c", target: "c"), ["c"])
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: nil, target: "c"), ["c"], "没有起点只选这一款")
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: "gone", target: "e"), ["e"], "起点被筛掉了")
        XCTAssertEqual(FontSelectionLogic.range(ids, anchor: "a", target: "gone"), [])
    }

    func testFontFileFilter() {
        for name in ["/Users/me/Desktop/思源黑体.otf", "/tmp/A.TTF", "/tmp/b.ttc", "/tmp/c.otc", "/tmp/d.dfont"] {
            XCTAssertTrue(FontDropLogic.isFontFile(name), name)
        }
        for name in ["/tmp/readme.txt", "/tmp/font.zip", "/tmp/.hidden.ttf", "/tmp/otf", "/tmp/a/../b.ttf", "/tmp/woff.woff2"] {
            XCTAssertFalse(FontDropLogic.isFontFile(name), name)
        }
    }

    func testDropSummary() {
        XCTAssertFalse(FontDropLogic.summary(installed: 3, skipped: 2).isEmpty)
        XCTAssertNotEqual(FontDropLogic.summary(installed: 0, skipped: 0), FontDropLogic.summary(installed: 0, skipped: 2))
    }

    func testNarrowWindowLayout() {
        XCTAssertEqual(FontLayoutLogic.gridMinimum(size: 48, available: 1200), 312, "宽窗口按字号算")
        XCTAssertEqual(FontLayoutLogic.gridMinimum(size: 120, available: 500), 500, "不超过能用的宽度")
        XCTAssertEqual(FontLayoutLogic.gridMinimum(size: 48, available: 60), 120, "再窄也有个底")
        XCTAssertEqual(FontLayoutLogic.gridMinimum(size: 20, available: 0), 240, "还没量到宽度")
        XCTAssertEqual(FontLayoutLogic.detailWidth(total: 1400), 440)
        XCTAssertEqual(FontLayoutLogic.detailWidth(total: 700), 350)
        XCTAssertEqual(FontLayoutLogic.detailWidth(total: 300), 260)
    }
}
