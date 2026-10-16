import XCTest

final class SavedSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_950_400) // 2026-10-14

    func testRelativeDateIsRecomputed() {
        let saved = SavedSearch(name: "", text: "上周超过5MB的pdf")
        let first = saved.query(now: now)
        let later = saved.query(now: now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(first.minSize, 5_000_000)
        XCTAssertEqual(first.kinds, [.extensions(["pdf"], label: "PDF")])
        guard let a = first.date, let b = later.date else { return XCTFail("没有日期条件") }
        XCTAssertEqual(b.start.timeIntervalSince(a.start), 7 * 86_400, accuracy: 3_700)
    }

    func testRemovedChipsStayRemoved() {
        let original = QueryParser(now: now).parse("上周超过5MB的pdf")
        let dateKey = original.chipKey(.date)
        let kindKey = original.chipKey(.kind(0))
        XCTAssertEqual(dateKey, "date")
        XCTAssertEqual(kindKey, "kind:PDF")
        let saved = SavedSearch(name: "大 PDF", text: "上周超过5MB的pdf", removed: [dateKey, kindKey])
        let q = saved.query(now: now)
        XCTAssertNil(q.date)
        XCTAssertTrue(q.kinds.isEmpty)
        XCTAssertEqual(q.minSize, 5_000_000)
        XCTAssertEqual(saved.displayName, "大 PDF")
    }

    func testPlainTextAndCodableRoundTrip() throws {
        let saved = SavedSearch(name: "  ", text: "合同草稿")
        XCTAssertEqual(saved.displayName, "合同草稿")
        XCTAssertEqual(saved.query(now: now).text, "合同草稿")
        let data = try JSONEncoder().encode([saved])
        let decoded = try JSONDecoder().decode([SavedSearch].self, from: data)
        XCTAssertEqual(decoded, [saved])
    }
}
