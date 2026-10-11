import XCTest

final class QueryParserTests: XCTestCase {
    private var parser: QueryParser {
        var p = QueryParser()
        // 2026-10-14 周三 12:00（北京时间）
        p.calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        p.now = Date(timeIntervalSince1970: 1_791_950_400)
        return p
    }

    func testChineseLastWeekPDFOver5MB() {
        let q = parser.parse("上周超过5MB的pdf")
        XCTAssertEqual(q.kinds, [.extensions(["pdf"], label: "PDF")])
        XCTAssertEqual(q.minSize, 5_000_000)
        XCTAssertEqual(q.date?.label, "上周")
        XCTAssertEqual(q.text, "")
        if let date = q.date {
            XCTAssertLessThan(date.start, date.end)
            XCTAssertLessThanOrEqual(date.end, parser.now)
        }
    }

    func testEnglishLargeVideosFromSiteThisMonth() {
        let q = parser.parse("large videos from youtube.com this month")
        XCTAssertEqual(q.kinds, [.category(.videos)])
        XCTAssertEqual(q.minSize, 100_000_000)
        XCTAssertEqual(q.source, "youtube.com")
        XCTAssertEqual(q.date?.label, "本月")
        XCTAssertEqual(q.text, "")
    }

    func testScreenshotsOlderThan30Days() {
        let q = parser.parse("超过30天的截图")
        XCTAssertEqual(q.kinds, [.screenshot])
        XCTAssertNil(q.minSize)
        XCTAssertEqual(q.date?.start, .distantPast)
        XCTAssertEqual(q.text, "")
    }

    func testRecentChineseNumber() {
        let q = parser.parse("最近三天的照片")
        XCTAssertEqual(q.kinds, [.category(.images)])
        XCTAssertNotNil(q.date)
        XCTAssertEqual(q.text, "")
    }

    func testMaxSizeAndExtension() {
        let q = parser.parse("less than 2 gb zip")
        XCTAssertEqual(q.maxSize, 2_000_000_000)
        XCTAssertEqual(q.kinds, [.extensions(["zip"], label: "ZIP")])
    }

    func testKeywordIsKept() {
        let q = parser.parse("截图 发票")
        XCTAssertEqual(q.kinds, [.screenshot])
        XCTAssertEqual(q.text, "发票")
    }

    func testSourceInChinese() {
        let q = parser.parse("从github下载的dmg")
        XCTAssertEqual(q.source, "github")
        XCTAssertEqual(q.kinds, [.extensions(["dmg"], label: "DMG")])
    }

    func testMoreThanDaysIsNotASize() {
        let q = parser.parse("screenshots more than 30 days old")
        XCTAssertNil(q.minSize)
        XCTAssertEqual(q.kinds, [.screenshot])
        XCTAssertNotNil(q.date)
    }

    func testChineseNumbers() {
        XCTAssertEqual(QueryParser.number("三"), 3)
        XCTAssertEqual(QueryParser.number("十"), 10)
        XCTAssertEqual(QueryParser.number("十五"), 15)
        XCTAssertEqual(QueryParser.number("二十"), 20)
        XCTAssertEqual(QueryParser.number("12"), 12)
    }

    func testPlainTextStaysText() {
        let q = parser.parse("年度报告")
        XCTAssertTrue(q.kinds.isEmpty)
        XCTAssertEqual(q.text, "年度报告")
    }
}
