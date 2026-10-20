import XCTest

/// 列表到上限被截断时的提示。
final class ListTruncationTests: XCTestCase {
    func testHiddenTotal() {
        XCTAssertEqual(ListTruncation.hiddenTotal(shown: 3000, total: 12_480, cap: 3000), 12_480)
        // 没到上限、总数和显示的一样、不知道总数或上限：都不算截断。
        XCTAssertNil(ListTruncation.hiddenTotal(shown: 120, total: 120, cap: 3000))
        XCTAssertNil(ListTruncation.hiddenTotal(shown: 3000, total: 3000, cap: 3000))
        XCTAssertNil(ListTruncation.hiddenTotal(shown: 2999, total: 5000, cap: 3000))
        XCTAssertNil(ListTruncation.hiddenTotal(shown: 3000, total: nil, cap: 3000))
        XCTAssertNil(ListTruncation.hiddenTotal(shown: 3000, total: 9000, cap: nil))
        // 搜索结果里补进来的（文字识别、拼音）让显示的比上限多一点，也照样提示。
        XCTAssertEqual(ListTruncation.hiddenTotal(shown: 3012, total: 9000, cap: 3000), 9000)
    }

    func testCountLabel() {
        XCTAssertEqual(ListTruncation.countLabel(120, cap: 3000), "120")
        XCTAssertEqual(ListTruncation.countLabel(3000, cap: 3000), "3000")
        XCTAssertEqual(ListTruncation.countLabel(3001, cap: 3000), "3000+")
        XCTAssertEqual(ListTruncation.countLabel(99_999, cap: nil), "99999")
    }

    func testBannerMentionsCapAndTotal() {
        for order in [ListTruncation.Order.recent, .largest, .name] {
            let text = ListTruncation.bannerText(cap: 3000, total: 12_480, order: order)
            XCTAssertTrue(text.contains("3000") || text.contains("3,000"), text)
            XCTAssertTrue(text.contains("12480") || text.contains("12,480"), text)
        }
    }
}
