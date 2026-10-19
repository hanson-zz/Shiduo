import XCTest

private struct Entry: TodayAddable {
    var path: String
    var name: String { (path as NSString).lastPathComponent }
    var size: Int64 = 100
    var typeTree: [String] = []
    var added: Date?
    var isDirectory = false
}

final class TodayAddedTests: XCTestCase {
    private let home = "/Users/me"
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 2026-10-19 13:00 上海时间。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 13))!
    }

    private func at(_ hour: Int, day: Int = 19) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testDayRangeIsLocalCalendarDay() {
        let range = TodayAddedLogic.dayRange(containing: now, calendar: calendar)
        XCTAssertEqual(range.start, at(0))
        XCTAssertEqual(range.end, at(0, day: 20))
        XCTAssertEqual(TodayAddedLogic.nextMidnight(after: now, calendar: calendar), at(0, day: 20))
    }

    func testFilterKeepsTodayUserFilesNewestFirst() {
        let range = TodayAddedLogic.dayRange(containing: now, calendar: calendar)
        let items = [
            Entry(path: home + "/Downloads/报价单.pdf", typeTree: ["com.adobe.pdf"], added: at(11)),
            Entry(path: home + "/Desktop/截图.png", typeTree: ["public.png", "public.image"], added: at(12)),
            Entry(path: home + "/Downloads/昨天.pdf", typeTree: ["com.adobe.pdf"], added: at(23, day: 18)),
            Entry(path: home + "/Downloads/.hidden.png", typeTree: ["public.image"], added: at(9)),
            Entry(path: home + "/Library/Caches/x.png", typeTree: ["public.image"], added: at(9)),
            Entry(path: home + "/Downloads/Folder", added: at(9), isDirectory: true),
            Entry(path: home + "/Desktop/Foo.app/Contents/Resources/icon.png", typeTree: ["public.image"], added: at(9)),
            Entry(path: home + "/Downloads/a/node_modules/b.png", typeTree: ["public.image"], added: at(9)),
            Entry(path: home + "/Downloads/报价单.pdf", typeTree: ["com.adobe.pdf"], added: at(11)),
            Entry(path: "/Applications/Tool.app", typeTree: ["com.apple.application-bundle"], added: at(10)),
            Entry(path: "/System/x.png", typeTree: ["public.image"], added: at(10)),
        ]
        let result = TodayAddedLogic.filter(items, home: home, range: range).map(\.name)
        XCTAssertEqual(result, ["截图.png", "报价单.pdf", "Tool.app"])
    }

    func testOtherFilesOnlyDirectlyInDownloadsOrDesktop() {
        let range = TodayAddedLogic.dayRange(containing: now, calendar: calendar)
        let items = [
            Entry(path: home + "/Downloads/notes.txt", typeTree: ["public.plain-text"], added: at(10)),
            Entry(path: home + "/Desktop/设计稿.sketch", typeTree: [], added: at(10)),
            Entry(path: home + "/Developer/repo/main.swift", typeTree: ["public.swift-source"], added: at(10)),
            Entry(path: home + "/Downloads/repo/README.md2", typeTree: [], added: at(10)),
        ]
        XCTAssertEqual(Set(TodayAddedLogic.filter(items, home: home, range: range).map(\.name)), ["notes.txt", "设计稿.sketch"])
    }

    func testKindsAndSummary() {
        XCTAssertEqual(TodayAddedLogic.kind(name: "Setup.dmg", typeTree: ["com.apple.disk-image-udif", "public.disk-image"]), .installers)
        XCTAssertEqual(TodayAddedLogic.kind(name: "a.pkg", typeTree: []), .installers)
        XCTAssertEqual(TodayAddedLogic.kind(name: "a.zip", typeTree: ["public.zip-archive", "public.archive"]), .archives)
        XCTAssertEqual(TodayAddedLogic.kind(name: "a.heic", typeTree: ["public.heic", "public.image"]), .images)
        XCTAssertEqual(TodayAddedLogic.kind(name: "a.mov", typeTree: ["com.apple.quicktime-movie", "public.movie"]), .videos)
        XCTAssertEqual(TodayAddedLogic.kind(name: "Tool.app", typeTree: []), .apps)
        XCTAssertEqual(TodayAddedLogic.kind(name: "a.txt", typeTree: ["public.plain-text"]), .other)

        let items = [
            Entry(path: "/a.png", size: 10, typeTree: ["public.image"]),
            Entry(path: "/b.png", size: 20, typeTree: ["public.image"]),
            Entry(path: "/c.pdf", size: 30, typeTree: ["com.adobe.pdf"]),
            Entry(path: "/d.dmg", size: 40, typeTree: ["public.disk-image"]),
            Entry(path: "/e.mov", size: -1, typeTree: ["public.movie"]),
        ]
        let summary = TodayAddedLogic.summary(items)
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.bytes, 100)
        XCTAssertEqual(summary.kinds.map(\.kind), [.images, .documents, .installers, .videos])
        XCTAssertEqual(summary.kinds.map(\.count), [2, 1, 1, 1])
        XCTAssertEqual(TodayAddedLogic.items(items, of: .images).map(\.name), ["a.png", "b.png"])
        XCTAssertEqual(TodayAddedLogic.items(items, of: nil).count, 5)
        XCTAssertTrue(TodayAddedLogic.summary([Entry]()).kinds.isEmpty)
    }

    func testLocation() {
        XCTAssertEqual(TodayAddedLogic.location(of: home + "/Downloads/a.pdf", home: home), .downloads)
        XCTAssertEqual(TodayAddedLogic.location(of: home + "/Downloads/sub/a.pdf", home: home), .downloads)
        XCTAssertEqual(TodayAddedLogic.location(of: home + "/Desktop/a.png", home: home), .desktop)
        XCTAssertEqual(TodayAddedLogic.location(of: home + "/a.png", home: home), .home)
        XCTAssertEqual(TodayAddedLogic.location(of: home + "/Projects/Site/a.png", home: home), .folder("Site"))
        XCTAssertEqual(TodayAddedLogic.location(of: "/Applications/Tool.app", home: home), .applications)
    }
}
