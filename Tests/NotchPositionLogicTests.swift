import XCTest

/// 刘海暂存架位置：刘海正中（和以前一样）/ 屏幕左侧竖版 / 屏幕右侧竖版 × 有刘海 / 没刘海 / 外接屏 / 小屏 / 程序坞在侧边。
final class NotchPositionLogicTests: XCTestCase {
    typealias L = NotchPositionLogic

    /// 14 英寸 MacBook Pro 默认分辨率：刘海约 185 点宽、32 点高；程序坞在底部。
    let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notchedVisible = CGRect(x: 0, y: 70, width: 1512, height: 880)
    let notchW: CGFloat = 185, notchH: CGFloat = 32
    /// 没有刘海的屏幕：NSScreen.notchWidth 给 200 的虚拟宽度，高度是菜单栏 24。
    let plain = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let plainVisible = CGRect(x: 0, y: 0, width: 1440, height: 876)
    let plainW: CGFloat = 200, plainH: CGFloat = 24
    /// 外接屏在主屏右边、偏上（原点不是 0）。
    let external = CGRect(x: 1512, y: 120, width: 2560, height: 1440)
    let externalVisible = CGRect(x: 1512, y: 120, width: 2560, height: 1415)
    /// 很小的屏幕。
    let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
    let tinyVisible = CGRect(x: 0, y: 0, width: 600, height: 376)

    let size = CGSize(width: 400, height: 140)

    private var screens: [(CGRect, CGRect, CGFloat, CGFloat)] {
        [(notched, notchedVisible, notchW, notchH), (plain, plainVisible, plainW, plainH),
         (external, externalVisible, plainW, plainH), (tiny, tinyVisible, plainW, plainH)]
    }

    // MARK: 设置值

    func testDefaultAndLegacyMigration() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .center)
        defaults.set("bogus", forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .center)
        // beta.12 的「屏幕顶部左侧 / 右侧」读成现在的左侧 / 右侧竖版
        defaults.set("left", forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .left)
        NotchShelfPosition.migrateLegacy(defaults)
        XCTAssertEqual(defaults.string(forKey: NotchShelfPosition.key), "leftEdge")
        defaults.set("right", forKey: NotchShelfPosition.key)
        NotchShelfPosition.migrateLegacy(defaults)
        XCTAssertEqual(defaults.string(forKey: NotchShelfPosition.key), "rightEdge")
        XCTAssertEqual(NotchShelfPosition.current, .right)
        // 新值、默认值不动
        defaults.set("center", forKey: NotchShelfPosition.key)
        NotchShelfPosition.migrateLegacy(defaults)
        XCTAssertEqual(defaults.string(forKey: NotchShelfPosition.key), "center")
        defaults.removeObject(forKey: NotchShelfPosition.key)
        NotchShelfPosition.migrateLegacy(defaults)
        XCTAssertNil(defaults.string(forKey: NotchShelfPosition.key))
        XCTAssertFalse(NotchShelfPosition.center.isSide)
        XCTAssertTrue(NotchShelfPosition.left.isSide)
        XCTAssertTrue(NotchShelfPosition.right.isSide)
    }

    // MARK: 刘海正中：和改之前一模一样

    func testCenterMatchesOldBehavior() {
        for (screen, visible, w, h) in screens where screen.width >= 1000 {
            let anchor = L.anchorFrame(.center, screen: screen, visible: visible, notchWidth: w, notchHeight: h)
            XCTAssertEqual(anchor, CGRect(x: screen.midX - w / 2, y: screen.maxY - h, width: w, height: h))
            let panel = L.panelFrame(.center, screen: screen, visible: visible, size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel, CGRect(x: screen.midX - 200, y: screen.maxY - 140, width: 400, height: 140))
            let range = L.triggerRange(screen: screen, notchWidth: w)
            XCTAssertEqual(range.lowerBound, screen.midX - w / 2 - 60)
            XCTAssertEqual(range.upperBound, screen.midX + w / 2 + 60)
            let top = screen.maxY - 1
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: screen.midX, y: top), position: .center, screen: screen, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.midX, y: screen.maxY - 10), position: .center, screen: screen, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.minX, y: screen.midY), position: .center, screen: screen, notchWidth: w, notchHeight: h))
            XCTAssertTrue(L.isClickToOpen(CGPoint(x: screen.midX, y: screen.maxY - 10), position: .center, screen: screen, notchWidth: w, notchHeight: h))
        }
    }

    func testCenterPanelClampedOnTinyScreen() {
        let huge = L.panelFrame(.center, screen: tiny, size: CGSize(width: 900, height: 150), notchWidth: 200, notchHeight: 24)
        XCTAssertEqual(huge.width, tiny.width)
        XCTAssertEqual(huge.minX, tiny.minX)
    }

    // MARK: 左右两侧（竖版）

    func testSidePanelIsTallAndNarrow() {
        for (_, visible, _, _) in screens {
            let s = L.sidePanelSize(visible: visible)
            XCTAssertLessThanOrEqual(s.width, L.sidePanelWidth)
            XCTAssertLessThanOrEqual(s.height, visible.height)
            XCTAssertLessThanOrEqual(s.height, max(visible.height * L.sideHeightRatio, min(L.sideMinHeight, visible.height)))
            if visible.height > 600 { XCTAssertGreaterThan(s.height, s.width, "竖版：高大于宽") }
        }
        XCTAssertEqual(L.sidePanelSize(visible: notchedVisible).width, 340)
        XCTAssertEqual(L.sidePanelSize(visible: notchedVisible).height, 880 * 0.7, accuracy: 0.01)
        XCTAssertEqual(L.sidePanelSize(visible: externalVisible).height, L.sideMaxHeight) // 大屏夹到 640
        XCTAssertEqual(L.sidePanelSize(visible: tinyVisible).height, 376 * 0.7, accuracy: 0.01)
        XCTAssertEqual(L.sidePanelSize(visible: CGRect(x: 0, y: 0, width: 600, height: 300)).height, L.sideMinHeight) // 很矮也至少 260
        XCTAssertEqual(L.sidePanelSize(visible: CGRect(x: 0, y: 0, width: 600, height: 200)).height, 200) // 再矮就不超出可用区域
        XCTAssertEqual(L.sidePanelSize(visible: notchedVisible, locked: true).width, 360)
    }

    func testLeftHugsLeftEdge() {
        for (screen, visible, w, h) in screens {
            let size = L.sidePanelSize(visible: visible)
            let panel = L.panelFrame(.left, screen: screen, visible: visible, dockOrientation: "bottom", size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel.minX, screen.minX)
            XCTAssertEqual(panel.midY, visible.midY, accuracy: 0.01)
            XCTAssertTrue(visible.contains(panel), "不压菜单栏、不压底部程序坞")
            if screen.width >= 1000 { XCTAssertLessThan(panel.maxX, screen.midX - notchW / 2, "离刘海远远的") }
            let handle = L.anchorFrame(.left, screen: screen, visible: visible, dockOrientation: "bottom", notchWidth: w, notchHeight: h)
            XCTAssertEqual(handle.minX, screen.minX)
            XCTAssertEqual(handle.width, L.handleThickness)
            XCTAssertEqual(handle.midY, visible.midY, accuracy: 0.01)
            XCTAssertGreaterThan(handle.height, handle.width)
        }
    }

    func testRightHugsRightEdge() {
        for (screen, visible, w, h) in screens {
            let size = L.sidePanelSize(visible: visible)
            let panel = L.panelFrame(.right, screen: screen, visible: visible, dockOrientation: "bottom", size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel.maxX, screen.maxX)
            XCTAssertEqual(panel.midY, visible.midY, accuracy: 0.01)
            XCTAssertTrue(visible.contains(panel))
            if screen.width >= 1000 { XCTAssertGreaterThan(panel.minX, screen.midX + notchW / 2) }
            let handle = L.anchorFrame(.right, screen: screen, visible: visible, dockOrientation: "bottom", notchWidth: w, notchHeight: h)
            XCTAssertEqual(handle.maxX, screen.maxX)
            XCTAssertEqual(handle.width, L.handleThickness)
        }
    }

    func testDockOnSameSideSitsBesideDock() {
        // 程序坞在左边，占 70 点
        let screen = plain
        let dockLeft = CGRect(x: 70, y: 0, width: 1370, height: 876)
        let size = L.sidePanelSize(visible: dockLeft)
        let panel = L.panelFrame(.left, screen: screen, visible: dockLeft, dockOrientation: "left", size: size, notchWidth: plainW, notchHeight: plainH)
        XCTAssertEqual(panel.minX, 70)
        XCTAssertEqual(L.anchorFrame(.left, screen: screen, visible: dockLeft, dockOrientation: "left", notchWidth: plainW, notchHeight: plainH).minX, 70)
        XCTAssertEqual(L.sideTriggerRect(.left, screen: screen, visible: dockLeft, dockOrientation: "left").minX, 70)
        // 读不到程序坞设置时，按可用区域推断
        XCTAssertEqual(L.panelFrame(.left, screen: screen, visible: dockLeft, dockOrientation: nil, size: size, notchWidth: plainW, notchHeight: plainH).minX, 70)
        // 程序坞在左，右侧竖版照样贴屏幕右边
        XCTAssertEqual(L.panelFrame(.right, screen: screen, visible: dockLeft, dockOrientation: "left", size: size, notchWidth: plainW, notchHeight: plainH).maxX, screen.maxX)

        // 程序坞在右边
        let dockRight = CGRect(x: 0, y: 0, width: 1370, height: 876)
        let right = L.panelFrame(.right, screen: screen, visible: dockRight, dockOrientation: "right", size: size, notchWidth: plainW, notchHeight: plainH)
        XCTAssertEqual(right.maxX, 1370)
        XCTAssertEqual(L.anchorFrame(.right, screen: screen, visible: dockRight, dockOrientation: "right", notchWidth: plainW, notchHeight: plainH).maxX, 1370)
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: 1368, y: 438), position: .right, screen: screen, visible: dockRight, dockOrientation: "right", notchWidth: plainW, notchHeight: plainH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: 1439, y: 438), position: .right, screen: screen, visible: dockRight, dockOrientation: "right", notchWidth: plainW, notchHeight: plainH), "屏幕边那里是程序坞，不抢")
    }

    func testSideTriggerStripAvoidsCornersAndNotch() {
        for (screen, visible, w, h) in screens {
            let span = L.sideTriggerSpan(visible: visible)
            XCTAssertGreaterThanOrEqual(span.lowerBound, visible.minY)
            XCTAssertLessThanOrEqual(span.upperBound, visible.maxY)
            if visible.height >= 2 * L.sideCornerInset + L.handleLength {
                XCTAssertEqual(span.lowerBound, visible.minY + 80)
                XCTAssertEqual(span.upperBound, visible.maxY - 80)
            }
            let midY = visible.midY
            // 左：贴左边触发，离开几点就不触发
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: screen.minX, y: midY), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: screen.minX + 3, y: midY), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.minX + 12, y: midY), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            // 左上 / 左下角（触发角）不触发
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.minX, y: screen.maxY - 1), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.minX, y: screen.minY + 1), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            // 刘海不再触发（留给码头），右边也不触发
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.midX, y: screen.maxY - 1), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.maxX - 1, y: midY), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            // 右
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: screen.maxX - 1, y: midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: screen.maxX, y: midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.maxX - 12, y: midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.maxX - 1, y: screen.maxY - 1), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isAtTrigger(CGPoint(x: screen.midX, y: screen.maxY - 1), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
        }
    }

    func testClickToOpenOnHandleOnly() {
        for (screen, visible, w, h) in screens {
            let leftHandle = L.handleFrame(.left, screen: screen, visible: visible, dockOrientation: nil)
            XCTAssertTrue(L.isClickToOpen(CGPoint(x: leftHandle.midX, y: leftHandle.midY), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isClickToOpen(CGPoint(x: leftHandle.midX, y: leftHandle.maxY + 20), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isClickToOpen(CGPoint(x: screen.midX, y: screen.maxY - 10), position: .left, screen: screen, visible: visible, notchWidth: w, notchHeight: h), "点刘海不展开（留给码头）")
            let rightHandle = L.handleFrame(.right, screen: screen, visible: visible, dockOrientation: nil)
            XCTAssertTrue(L.isClickToOpen(CGPoint(x: rightHandle.midX, y: rightHandle.midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            XCTAssertFalse(L.isClickToOpen(CGPoint(x: leftHandle.midX, y: leftHandle.midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
            // 把手在触发条里（悬停把手也能展开）
            XCTAssertTrue(L.isAtTrigger(CGPoint(x: rightHandle.midX, y: rightHandle.midY), position: .right, screen: screen, visible: visible, notchWidth: w, notchHeight: h))
        }
    }

    func testOpenAnimationStartsFromHandleAtEdge() {
        // 展开从边上的小把手长出来：把手和面板贴同一条边、上下中心一致
        for position in [NotchShelfPosition.left, .right] {
            for (screen, visible, w, h) in screens {
                let start = L.anchorFrame(position, screen: screen, visible: visible, notchWidth: w, notchHeight: h)
                let end = L.panelFrame(position, screen: screen, visible: visible, size: L.sidePanelSize(visible: visible), notchWidth: w, notchHeight: h)
                if position == .left { XCTAssertEqual(start.minX, end.minX) } else { XCTAssertEqual(start.maxX, end.maxX) }
                XCTAssertEqual(start.midY, end.midY, accuracy: 0.01)
                XCTAssertTrue(end.contains(start))
            }
        }
    }

    func testSidePanelNeverLeavesScreen() {
        let huge = CGSize(width: 900, height: 900)
        for position in [NotchShelfPosition.left, .right] {
            for (screen, visible, w, h) in screens {
                let panel = L.panelFrame(position, screen: screen, visible: visible, size: huge, notchWidth: w, notchHeight: h)
                XCTAssertGreaterThanOrEqual(panel.minX, screen.minX)
                XCTAssertLessThanOrEqual(panel.maxX, screen.maxX)
                XCTAssertGreaterThanOrEqual(panel.minY, visible.minY)
                XCTAssertLessThanOrEqual(panel.maxY, visible.maxY)
            }
        }
    }

    // MARK: 顶栏 / 落点

    func testHeaderGapOnlyUnderRealNotch() {
        XCTAssertEqual(L.headerGap(.center, hasNotch: true, notchWidth: 185), 185)
        XCTAssertEqual(L.headerGap(.center, hasNotch: false, notchWidth: 200), 0)
        XCTAssertEqual(L.headerGap(.left, hasNotch: true, notchWidth: 185), 0)
        XCTAssertEqual(L.headerGap(.right, hasNotch: true, notchWidth: 185), 0)
    }

    func testDropIndexByAxis() {
        let frame = CGRect(x: 10, y: 40, width: 300, height: 600)
        // 横版：按横坐标三等分（和以前一样）
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 20, y: 500), in: frame, vertical: false), 0)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 160, y: 50), in: frame, vertical: false), 1)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 305, y: 50), in: frame, vertical: false), 2)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: -50, y: 50), in: frame, vertical: false), 0)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 900, y: 50), in: frame, vertical: false), 2)
        // 竖版：按纵坐标从上往下三等分
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 300, y: 50), in: frame, vertical: true), 0)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 20, y: 340), in: frame, vertical: true), 1)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 20, y: 630), in: frame, vertical: true), 2)
        XCTAssertEqual(L.dropIndex(at: CGPoint(x: 20, y: 0), in: frame, vertical: true), 0)
        XCTAssertEqual(L.dropIndex(at: .zero, in: .zero, vertical: true), 0)
    }
}
