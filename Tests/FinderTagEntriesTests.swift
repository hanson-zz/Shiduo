import XCTest

final class FinderTagEntriesTests: XCTestCase {
    func testAddKeepsOtherColors() {
        let start = ["项目A\n4", "Red\n6"]
        XCTAssertEqual(FinderTagEntries.adding("橙色", color: 7, to: start), ["项目A\n4", "Red\n6", "橙色\n7"])
        // 已经有了就不动（不改它原来的颜色）
        XCTAssertEqual(FinderTagEntries.adding("项目A", color: 2, to: start), start)
        XCTAssertEqual(FinderTagEntries.adding("", color: 2, to: start), start)
    }

    func testRemoveOnlyTarget() {
        let start = ["项目A\n4", "Red\n6", "旧标签"]
        XCTAssertEqual(FinderTagEntries.removing("Red", from: start), ["项目A\n4", "旧标签"])
        XCTAssertEqual(FinderTagEntries.removing("旧标签", from: start), ["项目A\n4", "Red\n6"])
        XCTAssertEqual(FinderTagEntries.removing("没有", from: start), start)
    }

    func testRecolorAndRename() {
        let start = ["项目A\n4", "Red\n6"]
        XCTAssertEqual(FinderTagEntries.recoloring("项目A", to: 2, in: start), ["项目A\n2", "Red\n6"])
        XCTAssertEqual(FinderTagEntries.recoloring("没有", to: 2, in: start), start)
        XCTAssertEqual(FinderTagEntries.renaming("项目A", to: "项目B", color: 4, in: start), ["项目B\n4", "Red\n6"])
        // 文件上已经有新名字：旧的去掉，不留两条
        XCTAssertEqual(FinderTagEntries.renaming("项目A", to: "Red", color: 6, in: start), ["Red\n6"])
        XCTAssertEqual(FinderTagEntries.renaming("没有", to: "X", color: 1, in: start), start)
    }

    func testParseEntry() {
        XCTAssertEqual(FinderTagEntries.name(of: "工作\n5"), "工作")
        XCTAssertEqual(FinderTagEntries.color(of: "工作\n5"), 5)
        XCTAssertEqual(FinderTagEntries.color(of: "工作"), 0)
        XCTAssertEqual(FinderTagEntries.color(of: "工作\n42"), 0)
        XCTAssertEqual(FinderTagEntries.entry("红色", color: 6), "红色\n6")
    }

    func testDecodeRefusesGarbage() throws {
        let good = try XCTUnwrap(FinderTagEntries.encode(["A\n1", "B\n0"]))
        XCTAssertEqual(FinderTagEntries.decode(good), ["A\n1", "B\n0"])
        XCTAssertEqual(FinderTagEntries.decode(Data()), [])
        XCTAssertNil(FinderTagEntries.decode(Data([0x01, 0x02, 0x03])))
        let dict = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        XCTAssertNil(FinderTagEntries.decode(dict))
    }

    func testCoverage() {
        XCTAssertEqual(FinderTagEntries.coverage(of: "A", in: [["A"], ["A", "B"]]), .all)
        XCTAssertEqual(FinderTagEntries.coverage(of: "A", in: [["A"], ["B"]]), .some)
        XCTAssertEqual(FinderTagEntries.coverage(of: "A", in: [["B"], []]), .none)
        XCTAssertEqual(FinderTagEntries.coverage(of: "A", in: []), .none)
    }

    func testDistinctTags() {
        let files = [
            ["工作\n4", "Red\n6"],
            ["工作\n4", "旅行"],
            ["工作\n2", "旅行\n0", " \n3"],
            ["家庭\n0", "家庭\n5"],
        ]
        let found = FinderTagEntries.distinctTags(files)
        XCTAssertEqual(Set(found.map(\.name)), ["工作", "Red", "旅行", "家庭"])
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.color) })
        XCTAssertEqual(byName["工作"], 4) // 出现最多的颜色
        XCTAssertEqual(byName["旅行"], 0) // 都没颜色
        XCTAssertEqual(byName["家庭"], 5) // 有颜色的优先
        XCTAssertEqual(byName["Red"], 6)
        // 同样多：取先出现的
        XCTAssertEqual(FinderTagEntries.distinctTags([["A\n3"], ["A\n2"]]), [.init(name: "A", color: 3)])
        XCTAssertEqual(FinderTagEntries.distinctTags([]), [])
    }

    func testImportable() {
        let found: [FinderTagEntries.FoundTag] = [.init(name: "工作", color: 4), .init(name: "红色", color: 6), .init(name: "旅行", color: 0)]
        let result = FinderTagEntries.importable(found, existing: ["工作"], reserved: ["红色"])
        XCTAssertEqual(result, [.init(name: "旅行", color: 0)])
    }
}
