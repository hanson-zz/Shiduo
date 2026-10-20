import XCTest

/// 返回 ⌘[ / 前进 ⌘]。
final class NavigationHistoryTests: XCTestCase {
    func testBackAndForward() {
        var h = NavigationHistory<String>()
        XCTAssertFalse(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
        h.visit(from: "A")          // A → B
        h.visit(from: "B")          // B → C
        XCTAssertEqual(h.goBack(from: "C"), "B")
        XCTAssertEqual(h.goBack(from: "B"), "A")
        XCTAssertNil(h.goBack(from: "A"))
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.goForward(from: "A"), "B")
        XCTAssertEqual(h.goForward(from: "B"), "C")
        XCTAssertNil(h.goForward(from: "C"))
        XCTAssertEqual(h.back, ["A", "B"])
    }

    func testVisitClearsForward() {
        var h = NavigationHistory<String>()
        h.visit(from: "A")
        XCTAssertEqual(h.goBack(from: "B"), "A")
        XCTAssertTrue(h.canGoForward)
        h.visit(from: "A")          // A → D：前进栈作废（和访达一样）
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.goBack(from: "D"), "A")
    }

    func testNoDuplicateConsecutiveEntriesAndReset() {
        var h = NavigationHistory<Int>()
        h.visit(from: 1)
        h.visit(from: 1)
        XCTAssertEqual(h.back, [1])
        h.reset()
        XCTAssertFalse(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
    }
}
