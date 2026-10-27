import XCTest

/// 命令面板：拼音首字母、全拼、跳着打、排序和分组。
final class CommandPaletteLogicTests: XCTestCase {
    private func item(_ id: String, _ title: String, _ section: PaletteItem.Section = .action, keywords: [String] = []) -> PaletteItem {
        PaletteItem(id: id, title: title, section: section, keywords: keywords)
    }

    private lazy var items: [PaletteItem] = [
        item("newFolder", "新建文件夹"),
        item("zip", "压缩为 ZIP"),
        item("zipEncrypt", "压缩并加密…"),
        item("unzip", "解压到当前文件夹"),
        item("cleanup", "清理", .go, keywords: ["智能清理", "Clean Up"]),
        item("smart", "智能清理", .cleanup),
        item("desktop", "桌面", .go, keywords: ["Desktop"]),
        item("downloads", "下载", .go, keywords: ["Downloads"]),
        item("sortName", "按名称排序", .sort),
        item("settingsGeneral", "设置：通用", .settings),
        item("showInfo", "显示简介", .view),
    ]

    func testPinyinKey() {
        let key = PaletteMatcher.key(for: "智能清理")
        XCTAssertEqual(key.initials, "znql")
        XCTAssertEqual(key.pinyin, "zhinengqingli")
        XCTAssertEqual(PaletteMatcher.key(for: "压缩为 ZIP").initials, "yswz")
        // 缓存：第二次拿到一样的
        XCTAssertEqual(PaletteMatcher.key(for: "智能清理"), key)
    }

    func testInitialsFindChineseTitle() {
        XCTAssertEqual(PaletteMatcher.rank(items, query: "znql").first?.id, "smart")
        let ys = PaletteMatcher.rank(items, query: "ys").map(\.id)
        XCTAssertEqual(Array(ys.prefix(2)).sorted(), ["zip", "zipEncrypt"])
        XCTAssertEqual(PaletteMatcher.rank(items, query: "xjwjj").first?.id, "newFolder")
        XCTAssertEqual(PaletteMatcher.rank(items, query: "ZNQL").first?.id, "smart", "不分大小写")
    }

    func testFullPinyin() {
        XCTAssertEqual(PaletteMatcher.rank(items, query: "qingli").first?.id, "cleanup", "「清理」比「智能清理」短，排前面")
        XCTAssertEqual(PaletteMatcher.rank(items, query: "zhuomian").first?.id, "desktop")
        XCTAssertEqual(PaletteMatcher.rank(items, query: "xiaz").first?.id, "downloads")
    }

    func testChineseAndKeywords() {
        XCTAssertEqual(PaletteMatcher.rank(items, query: "压缩").prefix(2).map(\.id).sorted(), ["zip", "zipEncrypt"])
        XCTAssertEqual(PaletteMatcher.rank(items, query: "desk").first?.id, "desktop")
        XCTAssertEqual(PaletteMatcher.rank(items, query: "clean").first?.id, "cleanup")
        XCTAssertTrue(PaletteMatcher.rank(items, query: "zip").contains { $0.id == "zip" })
    }

    func testMultiWordAndSubsequence() {
        XCTAssertEqual(PaletteMatcher.rank(items, query: "设置 通用").first?.id, "settingsGeneral")
        XCTAssertEqual(PaletteMatcher.rank(items, query: "显简").first?.id, "showInfo", "跳着打汉字")
        XCTAssertTrue(PaletteMatcher.rank(items, query: "qqqq").isEmpty)
    }

    func testRankingPrefersPrefixAndExact() {
        let a = PaletteMatcher.score("下载", title: "下载")!
        let b = PaletteMatcher.score("下载", title: "下载来源")!
        let c = PaletteMatcher.score("下载", title: "打开下载文件夹")!
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
        let initials = PaletteMatcher.score("znql", title: "智能清理")!
        let subsequence = PaletteMatcher.score("znql", title: "zone quality")!
        XCTAssertGreaterThan(initials, subsequence)
    }

    func testEmptyQueryKeepsOrder() {
        XCTAssertEqual(PaletteMatcher.rank(items, query: "  ").map(\.id), items.map(\.id))
        XCTAssertEqual(PaletteMatcher.rank(items, query: "", limit: 3).count, 3)
    }

    func testGroupedKeepsBestSectionFirst() {
        let ranked = PaletteMatcher.rank(items, query: "ql")
        let groups = PaletteMatcher.grouped(ranked)
        XCTAssertEqual(groups.first?.section, ranked.first?.section)
        XCTAssertEqual(groups.flatMap(\.items).count, ranked.count)
        let manual = PaletteMatcher.grouped([item("a", "A", .go), item("b", "B", .action), item("c", "C", .go)])
        XCTAssertEqual(manual.map(\.section), [.go, .action])
        XCTAssertEqual(manual[0].items.map(\.id), ["a", "c"])
    }
}
