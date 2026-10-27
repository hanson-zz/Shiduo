import XCTest

/// 侧边栏收藏、⌥⌘1…9、起始位置、最近文件夹。
final class FavoritesLogicTests: XCTestCase {
    func testStandardized() {
        XCTAssertEqual(FavoritesLogic.standardized("/Users/a/Documents/../Desktop/"), "/Users/a/Desktop")
        XCTAssertEqual(FavoritesLogic.standardized("/"), "/")
    }

    func testAddingDedupesAndInserts() {
        var list = FavoritesLogic.adding(["/a", "/b"], to: [])
        XCTAssertEqual(list, ["/a", "/b"])
        list = FavoritesLogic.adding(["/a"], to: list)
        XCTAssertEqual(list, ["/a", "/b"], "已经在里面的不重复加")
        list = FavoritesLogic.adding(["/c"], to: list, at: 0)
        XCTAssertEqual(list, ["/c", "/a", "/b"])
        // 拖到指定位置：已有的挪过去
        list = FavoritesLogic.adding(["/b"], to: list, at: 1)
        XCTAssertEqual(list, ["/c", "/b", "/a"])
        list = FavoritesLogic.adding(["/c"], to: list, at: 3)
        XCTAssertEqual(list, ["/b", "/a", "/c"])
        XCTAssertEqual(FavoritesLogic.adding(["/x"], to: ["/a"], at: 99), ["/a", "/x"])
    }

    func testRemoving() {
        XCTAssertEqual(FavoritesLogic.removing("/b/", from: ["/a", "/b", "/c"]), ["/a", "/c"])
    }

    func testMovingMatchesSwiftUISemantics() {
        let list = ["/a", "/b", "/c", "/d"]
        XCTAssertEqual(FavoritesLogic.moving(list, from: [0], to: 2), ["/b", "/a", "/c", "/d"])
        XCTAssertEqual(FavoritesLogic.moving(list, from: [3], to: 0), ["/d", "/a", "/b", "/c"])
        XCTAssertEqual(FavoritesLogic.moving(list, from: [0, 1], to: 4), ["/c", "/d", "/a", "/b"])
        XCTAssertEqual(FavoritesLogic.moving(list, from: [2], to: 2), list)
        var swiftUI = list
        swiftUI.moveForTest(fromOffsets: [1, 3], toOffset: 1)
        XCTAssertEqual(FavoritesLogic.moving(list, from: [1, 3], to: 1), swiftUI)
    }

    func testRenamedFollowsFolderAndChildren() {
        let list = ["/Users/a/项目", "/Users/a/项目/2026", "/Users/a/项目二"]
        XCTAssertEqual(FavoritesLogic.renamed(list, from: "/Users/a/项目", to: "/Users/a/工作"),
                       ["/Users/a/工作", "/Users/a/工作/2026", "/Users/a/项目二"])
        XCTAssertNil(FavoritesLogic.renamed("/x/y", from: "/x/yz", to: "/q"))
    }

    func testShortcutSlots() {
        let list = (1...11).map { "/f\($0)" }
        XCTAssertEqual(FavoritesLogic.shortcutSlot(of: "/f1", in: list), 0)
        XCTAssertEqual(FavoritesLogic.shortcutSlot(of: "/f9", in: list), 8)
        XCTAssertNil(FavoritesLogic.shortcutSlot(of: "/f10", in: list), "只有前 9 个有快捷键")
        XCTAssertNil(FavoritesLogic.shortcutSlot(of: "/nope", in: list))
        XCTAssertEqual(FavoritesLogic.shortcutDisplay(slot: 0), "⌥⌘1")
        XCTAssertEqual(FavoritesLogic.shortcutDisplay(slot: 8), "⌥⌘9")
    }

    func testRecents() {
        var recents: [String] = []
        for i in 0..<12 { recents = FavoritesLogic.noteVisited("/r\(i)", recents: recents) }
        XCTAssertEqual(recents.count, FavoritesLogic.recentLimit)
        XCTAssertEqual(recents.first, "/r11")
        recents = FavoritesLogic.noteVisited("/r5", recents: recents)
        XCTAssertEqual(recents.first, "/r5")
        XCTAssertEqual(recents.filter { $0 == "/r5" }.count, 1)
    }

    func testStartLocation() {
        XCTAssertNil(FavoritesLogic.startLocation(stored: nil, exists: { _ in true }))
        XCTAssertNil(FavoritesLogic.startLocation(stored: "", exists: { _ in true }))
        XCTAssertEqual(FavoritesLogic.startLocation(stored: "/Users/a/工作/", exists: { _ in true }), "/Users/a/工作")
        XCTAssertNil(FavoritesLogic.startLocation(stored: "/Volumes/硬盘/x", exists: { _ in false }), "拔掉的硬盘回到首页")
    }
}

private extension Array {
    /// SwiftUI 的 move(fromOffsets:toOffset:) 的参照实现（不 import SwiftUI）。
    mutating func moveForTest(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.map { self[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moved, at: destination - before)
    }
}
