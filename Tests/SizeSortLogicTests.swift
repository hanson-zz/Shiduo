import XCTest

final class SizeSortLogicTests: XCTestCase {
    /// (名字, 大小)：nil 表示文件夹的大小还没算出来。
    private typealias Row = (name: String, size: Int64?)

    private func names(_ rows: [Row], ascending: Bool) -> [String] {
        SizeSortLogic.sorted(rows, ascending: ascending, size: { $0.size }, name: { $0.name }).map(\.name)
    }

    func testComputedFolderSizeIsUsed() {
        let rows: [Row] = [("b.txt", 10), ("Folder", 2_000_000_000), ("a.txt", 10), ("small", 1)]
        XCTAssertEqual(names(rows, ascending: false), ["Folder", "a.txt", "b.txt", "small"])
        XCTAssertEqual(names(rows, ascending: true), ["small", "a.txt", "b.txt", "Folder"])
    }

    func testUnknownSizesGoAfterKnownInBothDirections() {
        let rows: [Row] = [("Zeta", nil), ("big.mov", 900), ("Alpha", nil), ("tiny.txt", 0), ("Mid", 50)]
        XCTAssertEqual(names(rows, ascending: false), ["big.mov", "Mid", "tiny.txt", "Alpha", "Zeta"])
        XCTAssertEqual(names(rows, ascending: true), ["tiny.txt", "Mid", "big.mov", "Alpha", "Zeta"])
    }

    func testUnknownIsNotTreatedAsZero() {
        // 还没算出来的文件夹不能夹在 0 字节文件中间
        let rows: [Row] = [("Folder", nil), ("empty.txt", 0)]
        XCTAssertEqual(names(rows, ascending: true), ["empty.txt", "Folder"])
        XCTAssertEqual(names(rows, ascending: false), ["empty.txt", "Folder"])
    }

    func testSizeArrivalMovesOnlyThatFolder() {
        var rows: [Row] = [("A", nil), ("B", nil), ("c.txt", 30), ("d.txt", 20)]
        XCTAssertEqual(names(rows, ascending: false), ["c.txt", "d.txt", "A", "B"])
        rows[1].size = 25
        XCTAssertEqual(names(rows, ascending: false), ["c.txt", "B", "d.txt", "A"])
    }

    func testNameTiebreakIsNaturalAndStable() {
        let rows: [Row] = [("f10", 1), ("f2", 1)]
        XCTAssertEqual(names(rows, ascending: true), ["f2", "f10"])
        // 名字、大小都一样时保持原来的先后
        let same: [(String, Int64?, Int)] = [("x", 5, 0), ("x", 5, 1), ("x", 5, 2)]
        let order = SizeSortLogic.sorted(same, ascending: false, size: { $0.1 }, name: { $0.0 }).map(\.2)
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testCompare() {
        XCTAssertEqual(SizeSortLogic.compare(10, "a", 5, "b", ascending: false), .orderedAscending)
        XCTAssertEqual(SizeSortLogic.compare(10, "a", 5, "b", ascending: true), .orderedDescending)
        XCTAssertEqual(SizeSortLogic.compare(0, "a", nil, "b", ascending: true), .orderedAscending)
        XCTAssertEqual(SizeSortLogic.compare(nil, "a", 0, "b", ascending: false), .orderedDescending)
        XCTAssertEqual(SizeSortLogic.compare(nil, "a", nil, "b", ascending: false), .orderedAscending)
        XCTAssertEqual(SizeSortLogic.compare(3, "same", 3, "same", ascending: true), .orderedSame)
    }
}
