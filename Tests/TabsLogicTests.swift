import XCTest

/// 标签页与双栏的纯逻辑：开 / 关 / 换位置 / 切换、分栏状态、记住和恢复的编码。
final class TabsLogicTests: XCTestCase {
    // MARK: 标签栏

    func testOpenInsertsAfterSelectedAndSelects() {
        var strip = TabStrip(first: "a")
        strip.open("b")
        XCTAssertEqual(strip.ids, ["a", "b"])
        XCTAssertEqual(strip.selected, "b")
        strip.select("a")
        strip.open("c")
        XCTAssertEqual(strip.ids, ["a", "c", "b"], "新标签放在当前标签后面")
        XCTAssertEqual(strip.selected, "c")
    }

    func testOpenInBackgroundKeepsSelection() {
        var strip = TabStrip(first: "a")
        strip.open("b", select: false)
        XCTAssertEqual(strip.ids, ["a", "b"])
        XCTAssertEqual(strip.selected, "a")
        // 同一个 id 不会开两次
        strip.open("b")
        XCTAssertEqual(strip.ids, ["a", "b"])
        XCTAssertEqual(strip.selected, "b")
    }

    func testCloseSelectsRightNeighbourThenLeft() {
        var strip = TabStrip(first: "a")
        strip.open("b")
        strip.open("c")
        strip.select("b")
        XCTAssertTrue(strip.close("b"))
        XCTAssertEqual(strip.ids, ["a", "c"])
        XCTAssertEqual(strip.selected, "c", "关掉当前标签选右边那个")
        XCTAssertTrue(strip.close("c"))
        XCTAssertEqual(strip.selected, "a", "右边没有了选左边那个")
    }

    func testCloseLastTabRefuses() {
        var strip = TabStrip(first: "a")
        XCTAssertFalse(strip.close("a"), "最后一个标签不关，由窗口自己关掉")
        XCTAssertEqual(strip.ids, ["a"])
    }

    func testCloseOtherTabKeepsSelection() {
        var strip = TabStrip(first: "a")
        strip.open("b")
        strip.open("c")
        strip.select("a")
        XCTAssertTrue(strip.close("c"))
        XCTAssertEqual(strip.selected, "a")
        XCTAssertFalse(strip.close("zzz"))
    }

    func testNextPreviousWrapAround() {
        var strip = TabStrip(first: 1)
        strip.open(2)
        strip.open(3)
        XCTAssertEqual(strip.selected, 3)
        strip.selectNext()
        XCTAssertEqual(strip.selected, 1)
        strip.selectPrevious()
        XCTAssertEqual(strip.selected, 3)
        strip.selectPrevious()
        XCTAssertEqual(strip.selected, 2)
    }

    func testMoveOntoTarget() {
        var strip = TabStrip(first: "a")
        strip.open("b")
        strip.open("c")
        strip.open("d")
        strip.move("a", onto: "c")
        XCTAssertEqual(strip.ids, ["b", "c", "a", "d"], "往右拖放在目标后面")
        strip.move("d", onto: "b")
        XCTAssertEqual(strip.ids, ["d", "b", "c", "a"], "往左拖放在目标前面")
        strip.move("d", onto: "d")
        XCTAssertEqual(strip.ids, ["d", "b", "c", "a"])
        strip.move("b", to: 99)
        XCTAssertEqual(strip.ids, ["d", "c", "a", "b"])
        XCTAssertEqual(strip.selected, "d", "换位置不改选中")
    }

    func testRestoreStrip() {
        let strip = TabStrip(ids: ["x", "y", "z"], selectedIndex: 2)
        XCTAssertEqual(strip?.selected, "z")
        XCTAssertEqual(TabStrip(ids: ["x"], selectedIndex: 5)?.selected, "x")
        XCTAssertNil(TabStrip<String>(ids: [], selectedIndex: 0))
    }

    // MARK: 分栏

    func testLayoutNeedsSecondPane() {
        var state = PaneLayoutState()
        XCTAssertEqual(state.visible, [0])
        XCTAssertNil(state.other)
        XCTAssertTrue(state.setLayout(.horizontal), "还没有第二栏：要先建")
        XCTAssertEqual(state.layout, .single)
        state.addedSecondPane(layout: .horizontal)
        XCTAssertEqual(state.layout, .horizontal)
        XCTAssertEqual(state.visible, [0, 1])
        XCTAssertEqual(state.other, 1)
        XCTAssertFalse(state.setLayout(.vertical), "已经有第二栏：直接换")
        XCTAssertEqual(state.layout, .vertical)
    }

    func testSingleShowsFocusedPaneAndKeepsSecond() {
        var state = PaneLayoutState()
        _ = state.setLayout(.horizontal)
        state.addedSecondPane(layout: .horizontal)
        state.focus(1)
        XCTAssertEqual(state.other, 0)
        XCTAssertFalse(state.setLayout(.single))
        XCTAssertEqual(state.visible, [1], "单栏显示当前栏")
        XCTAssertEqual(state.paneCount, 2, "第二栏留着，再打开双栏时回到原来的位置")
        XCTAssertFalse(state.setLayout(.horizontal))
        XCTAssertEqual(state.visible, [0, 1])
    }

    func testToggleAndSwapAndFocusBounds() {
        var state = PaneLayoutState(layout: .horizontal, paneCount: 2, focused: 0)
        XCTAssertEqual(state.toggled(.horizontal), .single, "同一个布局再选一次回到单栏")
        XCTAssertEqual(state.toggled(.vertical), .vertical)
        state.swap()
        XCTAssertEqual(state.focused, 1, "交换两栏：当前栏跟着原来那一栏走")
        state.focus(5)
        XCTAssertEqual(state.focused, 1, "越界的栏不理")
        let fixed = PaneLayoutState(layout: .vertical, paneCount: 1, focused: 3)
        XCTAssertEqual(fixed.layout, .single, "只有一栏不能是双栏")
        XCTAssertEqual(fixed.focused, 0)
    }

    func testRatioClampAndDrag() {
        XCTAssertEqual(PaneRatio.clamp(0.05), 0.2)
        XCTAssertEqual(PaneRatio.clamp(0.95), 0.8)
        XCTAssertEqual(PaneRatio.clamp(.nan), PaneRatio.defaultValue)
        XCTAssertEqual(PaneRatio.dragged(start: 500, delta: 100, total: 1000), 0.6, accuracy: 0.0001)
        XCTAssertEqual(PaneRatio.dragged(start: 500, delta: -450, total: 1000), 0.2, accuracy: 0.0001)
        XCTAssertEqual(PaneRatio.dragged(start: 0, delta: 0, total: 0), PaneRatio.defaultValue)
    }

    // MARK: 记住 / 恢复

    func testSavedTabsRoundTrip() throws {
        let saved = SavedWindowTabs(tabs: [
            SavedTab(panes: [.folder("/Users/me/下载")]),
            SavedTab(panes: [.folder("/Volumes/移动硬盘/归档/2026"), .page("category:images")], layout: .horizontal, focused: 1),
            SavedTab(panes: [.home]),
        ], selected: 1)
        let data = try XCTUnwrap(saved.encoded())
        XCTAssertEqual(SavedWindowTabs.decode(data), saved)
    }

    func testDecodeNormalizesBadValues() throws {
        let json = """
        {"tabs":[{"panes":[],"layout":"vertical","focused":7},
                 {"panes":[{"kind":"folder","value":"/a"},{"kind":"page","value":"shelf"},{"kind":"home"}],"layout":"horizontal","focused":1},
                 {"panes":[{"kind":"what"}],"layout":"single","focused":0}],
         "selected":9}
        """
        let decoded = try XCTUnwrap(SavedWindowTabs.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.selected, 0, "越界的选中回到第一个")
        XCTAssertEqual(decoded.tabs[0], SavedTab(panes: [.home]), "空的标签补成首页单栏")
        XCTAssertEqual(decoded.tabs[1].panes, [.folder("/a"), .page("shelf")], "最多两栏")
        XCTAssertEqual(decoded.tabs[1].layout, .horizontal)
        XCTAssertEqual(decoded.tabs[1].focused, 1)
        XCTAssertEqual(decoded.tabs[2].panes, [.home], "认不出的位置回到首页")
    }

    func testDecodeGarbageAndEmpty() {
        XCTAssertNil(SavedWindowTabs.decode(nil))
        XCTAssertNil(SavedWindowTabs.decode(Data("not json".utf8)))
        XCTAssertNil(SavedWindowTabs.decode(Data(#"{"tabs":[],"selected":0}"#.utf8)))
        XCTAssertNil(SavedWindowTabs.decode(Data(#"{"tabs":[{"panes":[],"layout":"diagonal","focused":0}],"selected":0}"#.utf8)),
                     "认不出的布局整份不用（不会恢复出奇怪的状态）")
    }

    func testMaxTabs() {
        let many = SavedWindowTabs(tabs: (0..<50).map { SavedTab(panes: [.folder("/f\($0)")]) }, selected: 40)
        let normalized = many.normalized
        XCTAssertEqual(normalized?.tabs.count, SavedWindowTabs.maxTabs)
        XCTAssertEqual(normalized?.selected, 0)
    }

    func testTabBarVisibility() {
        XCTAssertFalse(TabBarLogic.showsBar(tabCount: 1, alwaysShow: false))
        XCTAssertTrue(TabBarLogic.showsBar(tabCount: 2, alwaysShow: false))
        XCTAssertTrue(TabBarLogic.showsBar(tabCount: 1, alwaysShow: true))
    }
}
