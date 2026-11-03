import XCTest

final class MarqueeSelectionLogicTests: XCTestCase {
    private let frames: [Int: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 100, height: 100),
        2: CGRect(x: 110, y: 0, width: 100, height: 100),
        3: CGRect(x: 0, y: 110, width: 100, height: 100),
        4: CGRect(x: 110, y: 110, width: 100, height: 100),
    ]

    func testHitsUseInsetAndIgnoreGaps() {
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: CGRect(x: 50, y: 50, width: 120, height: 20)), [1, 2])
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: CGRect(x: 50, y: 50, width: 120, height: 120)), [1, 2, 3, 4])
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: CGRect(x: 102, y: 0, width: 6, height: 300)), [], "格子之间的空隙不算")
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: CGRect(x: 97, y: 97, width: 1, height: 1)), [], "刚擦到边不算")
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: CGRect(x: 97, y: 97, width: 1, height: 1), inset: 0), [1],
                       "不留边时擦到就算")
        XCTAssertEqual(MarqueeSelectionLogic.hits(frames, rect: .zero), [])
    }

    func testRectAndClick() {
        let r = MarqueeSelectionLogic.rect(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 50, y: 10))
        XCTAssertEqual(r, CGRect(x: 50, y: 10, width: 150, height: 140), "往左上拖也一样")
        XCTAssertTrue(MarqueeSelectionLogic.isClick(from: .zero, to: CGPoint(x: 2, y: 1)))
        XCTAssertFalse(MarqueeSelectionLogic.isClick(from: .zero, to: CGPoint(x: 3, y: 0)))
        XCTAssertFalse(MarqueeSelectionLogic.isVisible(CGRect(x: 0, y: 0, width: 2, height: 2)))
        XCTAssertTrue(MarqueeSelectionLogic.isVisible(CGRect(x: 0, y: 0, width: 0, height: 5)))
    }

    func testFinderDragReplacesShiftAddsCommandToggles() {
        let current: Set<Int> = [1, 9]
        let hit: Set<Int> = [1, 2]
        // 普通拖动：只留框到的
        var base = MarqueeSelectionLogic.base(current: current, style: .finder, shift: false, command: false)
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: base, hit: hit, command: false), [1, 2])
        // ⇧ 拖动：加选
        base = MarqueeSelectionLogic.base(current: current, style: .finder, shift: true, command: false)
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: base, hit: hit, command: false), [1, 2, 9])
        // ⌘ 拖动：反选
        base = MarqueeSelectionLogic.base(current: current, style: .finder, shift: false, command: true)
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: base, hit: hit, command: true), [2, 9])
        // 什么都没框到：⌘ 拖动不动原来的
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: base, hit: [], command: true), [1, 9])
    }

    func testChecklistDragKeepsExistingChecks() {
        let current: Set<Int> = [9]
        let base = MarqueeSelectionLogic.base(current: current, style: .checklist, shift: false, command: false)
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: base, hit: [1, 2], command: false), [1, 2, 9], "勾选页：拖动只加勾")
        XCTAssertEqual(MarqueeSelectionLogic.selection(base: [1, 9], hit: [1, 2], command: true), [2, 9], "⌘ 拖动反选")
    }

    func testEmptyClick() {
        XCTAssertTrue(MarqueeSelectionLogic.clearsOnEmptyClick(style: .finder, shift: false, command: false))
        XCTAssertFalse(MarqueeSelectionLogic.clearsOnEmptyClick(style: .finder, shift: true, command: false))
        XCTAssertFalse(MarqueeSelectionLogic.clearsOnEmptyClick(style: .finder, shift: false, command: true))
        XCTAssertFalse(MarqueeSelectionLogic.clearsOnEmptyClick(style: .checklist, shift: false, command: false),
                       "勾选页点空白处不清掉已勾的")
    }

    func testRange() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(MarqueeSelectionLogic.range(ids, anchor: "b", target: "d"), ["b", "c", "d"])
        XCTAssertEqual(MarqueeSelectionLogic.range(ids, anchor: "d", target: "a"), ["a", "b", "c", "d"])
        XCTAssertEqual(MarqueeSelectionLogic.range(ids, anchor: nil, target: "c"), ["c"])
        XCTAssertEqual(MarqueeSelectionLogic.range(ids, anchor: "gone", target: "e"), ["e"])
        XCTAssertEqual(MarqueeSelectionLogic.range(ids, anchor: "a", target: "gone"), [])
    }

    func testFinderClick() {
        let ids = ["a", "b", "c", "d", "e"]
        // 普通点按：只选它，起点换成它
        var r = MarqueeSelectionLogic.click("c", in: ids, selection: ["a", "b"], anchor: "a", shift: false, command: false, style: .finder)
        XCTAssertEqual(r.selection, ["c"]); XCTAssertEqual(r.anchor, "c")
        // ⌘ 点按：加选 / 取消
        r = MarqueeSelectionLogic.click("d", in: ids, selection: ["c"], anchor: "c", shift: false, command: true, style: .finder)
        XCTAssertEqual(r.selection, ["c", "d"]); XCTAssertEqual(r.anchor, "d")
        r = MarqueeSelectionLogic.click("d", in: ids, selection: ["c", "d"], anchor: "c", shift: false, command: true, style: .finder)
        XCTAssertEqual(r.selection, ["c"])
        // ⇧ 点按：从起点连选，起点不变
        r = MarqueeSelectionLogic.click("e", in: ids, selection: ["b"], anchor: "b", shift: true, command: false, style: .finder)
        XCTAssertEqual(r.selection, ["b", "c", "d", "e"]); XCTAssertEqual(r.anchor, "b")
        r = MarqueeSelectionLogic.click("a", in: ids, selection: r.selection, anchor: r.anchor, shift: true, command: false, style: .finder)
        XCTAssertEqual(r.selection, ["a", "b"], "反复 ⇧ 点按调整范围")
        // ⇧⌘：把这一段加到原来的选中上
        r = MarqueeSelectionLogic.click("e", in: ids, selection: ["a"], anchor: "d", shift: true, command: true, style: .finder)
        XCTAssertEqual(r.selection, ["a", "d", "e"])
        // 没有起点的 ⇧ 点按：只选它，从它开始
        r = MarqueeSelectionLogic.click("c", in: ids, selection: [], anchor: nil, shift: true, command: false, style: .finder)
        XCTAssertEqual(r.selection, ["c"]); XCTAssertEqual(r.anchor, "c")
    }

    func testChecklistClick() {
        let ids = ["a", "b", "c", "d"]
        var r = MarqueeSelectionLogic.click("b", in: ids, selection: ["a"], anchor: nil, shift: false, command: false, style: .checklist)
        XCTAssertEqual(r.selection, ["a", "b"], "勾选页普通点按是切换，不清掉别的")
        r = MarqueeSelectionLogic.click("a", in: ids, selection: r.selection, anchor: r.anchor, shift: false, command: false, style: .checklist)
        XCTAssertEqual(r.selection, ["b"])
        r = MarqueeSelectionLogic.click("d", in: ids, selection: r.selection, anchor: "b", shift: true, command: false, style: .checklist)
        XCTAssertEqual(r.selection, ["b", "c", "d"], "⇧ 点按把这一段都勾上")
    }

    func testFirstSelected() {
        XCTAssertEqual(MarqueeSelectionLogic.firstSelected(["a", "b", "c"], in: ["c", "b"]), "b")
        XCTAssertNil(MarqueeSelectionLogic.firstSelected(["a"], in: ["z"]))
    }
}
