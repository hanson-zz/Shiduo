import XCTest

final class PathLogicTests: XCTestCase {
    func testSameOrInside() {
        XCTAssertTrue(PathLogic.isSameOrInside("/a/b", "/a"))
        XCTAssertTrue(PathLogic.isSameOrInside("/a", "/a"))
        XCTAssertTrue(PathLogic.isSameOrInside("/a/b", "/a/"))
        XCTAssertFalse(PathLogic.isSameOrInside("/ab", "/a"))
        XCTAssertFalse(PathLogic.isSameOrInside("/a", "/a/b"))
    }

    func testRewrite() {
        XCTAssertEqual(PathLogic.rewrite("/Docs/PDF", from: "/Docs/PDF", to: "/Docs/资料"), "/Docs/资料")
        XCTAssertEqual(PathLogic.rewrite("/Docs/PDF/2025", from: "/Docs/PDF", to: "/Docs/资料"), "/Docs/资料/2025")
        XCTAssertNil(PathLogic.rewrite("/Docs/PDFs", from: "/Docs/PDF", to: "/Docs/资料"))
        XCTAssertNil(PathLogic.rewrite("/Other", from: "/Docs/PDF", to: "/Docs/资料"))
    }

    func testRemovedIncludesChildren() {
        let removed = PathLogic.Removed(["/Users/me/Desktop/X", "/Users/me/a.txt"])
        XCTAssertTrue(removed.contains("/Users/me/Desktop/X"))
        XCTAssertTrue(removed.contains("/Users/me/Desktop/X/sub/file.png"))
        XCTAssertTrue(removed.contains("/Users/me/a.txt"))
        XCTAssertFalse(removed.contains("/Users/me/Desktop/XY/file.png"))
        XCTAssertFalse(removed.contains("/Users/me/Desktop"))
        XCTAssertFalse(PathLogic.Removed([]).contains("/x"))
    }

    func testFileStamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: file)
        let first = FileStamp(url: file)
        XCTAssertTrue(first.exists)
        XCTAssertEqual(first.size, 3)
        try Data("three".utf8).write(to: file)
        XCTAssertNotEqual(FileStamp(url: file), first)
        XCTAssertFalse(FileStamp(url: dir.appendingPathComponent("missing")).exists)
    }

    func testIgnoreListKeepsNewest() {
        var list: [String] = []
        list = OrganizeIgnoreList.adding(["/a", "/b", "/c"], to: list, limit: 3)
        XCTAssertEqual(list, ["/a", "/b", "/c"])
        // 再加一个：最旧的 /a 被去掉，不是随便丢一个。
        list = OrganizeIgnoreList.adding(["/d"], to: list, limit: 3)
        XCTAssertEqual(list, ["/b", "/c", "/d"])
        // 重新加入已有的：移到最新。
        list = OrganizeIgnoreList.adding(["/b"], to: list, limit: 3)
        XCTAssertEqual(list, ["/c", "/d", "/b"])
        XCTAssertEqual(OrganizeIgnoreList.adding(["/x", "/x"], to: [], limit: 5), ["/x"])
    }
}
