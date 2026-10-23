import XCTest

final class DownloadSourceLogicTests: XCTestCase {
    private func binaryPlist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func testParseWhereFromsBinaryPlist() {
        let data = binaryPlist(["https://dl.example.com/a.zip", "https://www.example.com/download", ""])
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(data),
                       ["https://dl.example.com/a.zip", "https://www.example.com/download"])
    }

    func testParseWhereFromsXMLAndSingleStringAndGarbage() {
        let xml = try! PropertyListSerialization.data(fromPropertyList: ["https://mail.google.com/x"], format: .xml, options: 0)
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(xml), ["https://mail.google.com/x"])
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(binaryPlist("https://github.com/a")), ["https://github.com/a"])
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(Data()), [])
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(Data("not a plist".utf8)), [])
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(binaryPlist(["k": "v"])), [])
        // 数组里混了别的类型：只要字符串
        XCTAssertEqual(DownloadSourceLogic.parseWhereFroms(binaryPlist(["https://a.com/x", 3] as [Any])), ["https://a.com/x"])
    }

    func testWhereFromsFeedSourceCatalog() {
        let data = binaryPlist(["https://mail-attachment.googleusercontent.com/x", "https://mail.google.com/mail/u/0/"])
        XCTAssertEqual(SourceCatalog.classify(whereFroms: DownloadSourceLogic.parseWhereFroms(data))?.id, "gmail")
    }

    func testParseQuarantineAgent() {
        XCTAssertEqual(DownloadSourceLogic.parseQuarantineAgent(Data("0083;5f3c1a2b;Safari;F2A1B2C3-0000".utf8)), "Safari")
        XCTAssertEqual(DownloadSourceLogic.parseQuarantineAgent(Data("0081;65000000;Google Chrome;".utf8)), "Google Chrome")
        XCTAssertEqual(DownloadSourceLogic.parseQuarantineAgent(Data("0083;65000000;微信;ABC\0".utf8)), "微信")
        XCTAssertNil(DownloadSourceLogic.parseQuarantineAgent(Data("0083;65000000;;ABC".utf8)))
        XCTAssertNil(DownloadSourceLogic.parseQuarantineAgent(Data("0083;65000000".utf8)))
        XCTAssertNil(DownloadSourceLogic.parseQuarantineAgent(Data()))
    }

    func testAgentToSource() {
        let cases: [(String, String?)] = [
            ("WeChat", "wechat"), ("微信", "wechat"), ("QQ", "qq"), ("QQ浏览器", "qqbrowser"), ("QQBrowser", "qqbrowser"),
            ("飞书", "feishu"), ("Lark", "feishu"), ("Feishu", "feishu"), ("DingTalk", "dingtalk"), ("钉钉", "dingtalk"),
            ("Google Chrome", "chrome"), ("Chromium", "chrome"), ("Safari", "safari"),
            ("Safari Technology Preview", "safari"), ("Microsoft Edge", "edge"), ("Firefox", "firefox"),
            ("Arc", "arc"), ("Brave Browser", "brave"), ("Opera", "opera"), ("Mail", "applemail"),
            ("BaiduNetdisk", "baidupan"), ("Telegram", "telegram"),
            ("Marc Editor", nil), ("Gmail Helper", nil), ("QQMusic", nil), ("Finder", nil), ("", nil),
        ]
        for (agent, expected) in cases {
            XCTAssertEqual(DownloadSourceLogic.sourceID(forAgent: agent), expected, agent)
        }
        XCTAssertNil(DownloadSourceLogic.sourceID(forAgent: nil))
        // 每个认出来的 id 都在 SourceCatalog 里
        for (agent, expected) in cases where expected != nil {
            XCTAssertEqual(SourceCatalog.source(forAgent: agent)?.id, expected, agent)
        }
    }

    func testGroupOrderingAndCounts() {
        let order = DownloadSourceLogic.sortGroups([
            (id: "unrecorded", count: 100), (id: "site:example.com", count: 50),
            (id: "wechat", count: 3), (id: "chrome", count: 7), (id: "site:a.com", count: 50),
        ])
        XCTAssertEqual(order, ["chrome", "wechat", "site:a.com", "site:example.com", "unrecorded"])
        XCTAssertEqual(DownloadSourceLogic.sourceCount(order), 4)
        XCTAssertEqual(SourceCatalog.unrecorded.id, DownloadSourceLogic.unrecordedID)
    }

    func testNewestAndMerge() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let entries: [(String, Date?)] = [("a", base), ("b", base.addingTimeInterval(10)), ("c", nil), ("d", base.addingTimeInterval(5))]
        XCTAssertEqual(DownloadSourceLogic.newest(entries, limit: 2) { $0.1 }.map(\.0), ["b", "d"])
        XCTAssertEqual(DownloadSourceLogic.newest(entries, limit: 0) { $0.1 }.count, 0)
        XCTAssertEqual(DownloadSourceLogic.merge(["/x", "/y"], ["/y", "/z"]) { $0 }, ["/x", "/y", "/z"])
    }
}
