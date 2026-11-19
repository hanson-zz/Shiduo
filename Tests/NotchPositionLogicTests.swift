import XCTest

/// 刘海暂存架位置：三个位置 × 有刘海 / 没刘海 / 外接屏，面板、虚拟刘海、触发区都在屏幕里且位置对。
final class NotchPositionLogicTests: XCTestCase {
    typealias L = NotchPositionLogic

    /// 14 英寸 MacBook Pro 默认分辨率：刘海约 185 点宽、32 点高。
    let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notchW: CGFloat = 185, notchH: CGFloat = 32
    /// 没有刘海的屏幕：NSScreen.notchWidth 给 200 的虚拟宽度，高度是菜单栏 24。
    let plain = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let plainW: CGFloat = 200, plainH: CGFloat = 24
    /// 外接屏在主屏右边、偏上（原点不是 0）。
    let external = CGRect(x: 1512, y: 120, width: 2560, height: 1440)

    let size = CGSize(width: 400, height: 140)

    func testDefaultIsCenter() {
        UserDefaults.standard.removeObject(forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .center)
        UserDefaults.standard.set("bogus", forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .center)
        UserDefaults.standard.set("right", forKey: NotchShelfPosition.key)
        XCTAssertEqual(NotchShelfPosition.current, .right)
        UserDefaults.standard.removeObject(forKey: NotchShelfPosition.key)
    }

    func testCenterMatchesOldBehavior() {
        for (screen, w, h) in [(notched, notchW, notchH), (plain, plainW, plainH), (external, plainW, plainH)] {
            let anchor = L.anchorFrame(.center, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(anchor, CGRect(x: screen.midX - w / 2, y: screen.maxY - h, width: w, height: h))
            let panel = L.panelFrame(.center, screen: screen, size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel, CGRect(x: screen.midX - 200, y: screen.maxY - 140, width: 400, height: 140))
            let range = L.triggerRange(.center, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(range.lowerBound, screen.midX - w / 2 - 60)
            XCTAssertEqual(range.upperBound, screen.midX + w / 2 + 60)
        }
    }

    func testLeftHugsLeftEdgeAndGrowsRight() {
        for (screen, w, h) in [(notched, notchW, notchH), (plain, plainW, plainH), (external, plainW, plainH)] {
            let anchor = L.anchorFrame(.left, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(anchor.minX, screen.minX + L.sideInset)
            XCTAssertEqual(anchor.maxY, screen.maxY)
            let panel = L.panelFrame(.left, screen: screen, size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel.minX, screen.minX + L.sideInset)
            XCTAssertEqual(panel.maxY, screen.maxY)
            XCTAssertTrue(screen.contains(panel))
            // 不碰真刘海、不碰屏幕中线
            XCTAssertLessThan(panel.maxX, screen.midX - notchW / 2)
            let range = L.triggerRange(.left, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(range.lowerBound, screen.minX + L.sideInset) // 让开苹果菜单 / 左上触发角
            XCTAssertLessThan(range.upperBound, screen.midX - notchW / 2)
        }
    }

    func testRightHugsRightEdgeAndGrowsLeft() {
        for (screen, w, h) in [(notched, notchW, notchH), (plain, plainW, plainH), (external, plainW, plainH)] {
            let anchor = L.anchorFrame(.right, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(anchor.maxX, screen.maxX - L.sideInset)
            let panel = L.panelFrame(.right, screen: screen, size: size, notchWidth: w, notchHeight: h)
            XCTAssertEqual(panel.maxX, screen.maxX - L.sideInset)
            XCTAssertEqual(panel.maxY, screen.maxY)
            XCTAssertTrue(screen.contains(panel))
            XCTAssertGreaterThan(panel.minX, screen.midX + notchW / 2)
            let range = L.triggerRange(.right, screen: screen, notchWidth: w, notchHeight: h)
            XCTAssertEqual(range.upperBound, screen.maxX - L.sideInset)
            XCTAssertGreaterThan(range.lowerBound, screen.midX + notchW / 2)
        }
    }

    func testPanelNeverLeavesScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
        let wide = CGSize(width: 580, height: 150)
        for position in NotchShelfPosition.allCases {
            let panel = L.panelFrame(position, screen: tiny, size: wide, notchWidth: 200, notchHeight: 24)
            XCTAssertGreaterThanOrEqual(panel.minX, tiny.minX, "\(position)")
            XCTAssertLessThanOrEqual(panel.maxX, tiny.maxX, "\(position)")
            let huge = L.panelFrame(position, screen: tiny, size: CGSize(width: 900, height: 150), notchWidth: 200, notchHeight: 24)
            XCTAssertEqual(huge.width, tiny.width, "\(position)")
            XCTAssertEqual(huge.minX, tiny.minX, "\(position)")
        }
    }

    func testTriggerNeedsTopEdge() {
        let top = notched.maxY - 1
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: notched.midX, y: top), position: .center, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: notched.midX, y: notched.maxY - 10), position: .center, screen: notched, notchWidth: notchW, notchHeight: notchH))
        // 左：左上一段顶边触发，中间刘海不再触发（留给码头）
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: 120, y: top), position: .left, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: notched.midX, y: top), position: .left, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: 10, y: top), position: .left, screen: notched, notchWidth: notchW, notchHeight: notchH))
        // 右
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: notched.maxX - 120, y: top), position: .right, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: notched.midX, y: top), position: .right, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isAtTrigger(CGPoint(x: notched.maxX - 10, y: top), position: .right, screen: notched, notchWidth: notchW, notchHeight: notchH))
        // 外接屏（原点不是 0）
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: external.minX + 100, y: external.maxY - 1), position: .left, screen: external, notchWidth: plainW, notchHeight: plainH))
        XCTAssertTrue(L.isAtTrigger(CGPoint(x: external.maxX - 100, y: external.maxY - 1), position: .right, screen: external, notchWidth: plainW, notchHeight: plainH))
    }

    func testClickToOpenOnlyAtCenter() {
        let p = CGPoint(x: notched.midX, y: notched.maxY - 10)
        XCTAssertTrue(L.isClickToOpen(p, position: .center, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isClickToOpen(p, position: .left, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isClickToOpen(CGPoint(x: 120, y: notched.maxY - 10), position: .left, screen: notched, notchWidth: notchW, notchHeight: notchH))
        XCTAssertFalse(L.isClickToOpen(p, position: .right, screen: notched, notchWidth: notchW, notchHeight: notchH))
    }

    func testHeaderGapOnlyUnderRealNotch() {
        XCTAssertEqual(L.headerGap(.center, hasNotch: true, notchWidth: 185), 185)
        XCTAssertEqual(L.headerGap(.center, hasNotch: false, notchWidth: 200), 0)
        XCTAssertEqual(L.headerGap(.left, hasNotch: true, notchWidth: 185), 0)
        XCTAssertEqual(L.headerGap(.right, hasNotch: true, notchWidth: 185), 0)
    }
}
