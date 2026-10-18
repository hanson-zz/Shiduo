import XCTest

final class PinyinTests: XCTestCase {
    func testFullPinyin() {
        XCTAssertTrue(Pinyin.matches("年报.pdf", query: "nianbao"))
        XCTAssertTrue(Pinyin.matches("2025年度报告.docx", query: "niandubaogao"))
    }

    func testInitials() {
        XCTAssertTrue(Pinyin.matches("年报.pdf", query: "nb"))
        XCTAssertTrue(Pinyin.matches("2025年度报告.docx", query: "ndbg"))
    }

    func testMixedAndPartial() {
        XCTAssertTrue(Pinyin.matches("年报.pdf", query: "nianb"))
        XCTAssertTrue(Pinyin.matches("年报.pdf", query: "nbao"))
        XCTAssertTrue(Pinyin.matches("年报.pdf", query: "nia"))
        XCTAssertTrue(Pinyin.matches("项目年报.pdf", query: "nb"))
    }

    func testNoMatch() {
        XCTAssertFalse(Pinyin.matches("年报.pdf", query: "bn"))
        XCTAssertFalse(Pinyin.matches("report.pdf", query: "nb"))
        XCTAssertFalse(Pinyin.matches("发票.pdf", query: "nb"))
    }

    func testLooksLikePinyin() {
        XCTAssertTrue(Pinyin.looksLikePinyin("nianbao"))
        XCTAssertFalse(Pinyin.looksLikePinyin("n"))
        XCTAssertFalse(Pinyin.looksLikePinyin("年报"))
        XCTAssertFalse(Pinyin.looksLikePinyin("5mb"))
    }

    func testPlausiblePinyin() {
        XCTAssertTrue(Pinyin.isPlausiblePinyin("nianbao"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("nianb"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("niandubaogao"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("zhuangxiu"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("nb"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("ndbg"))
        XCTAssertTrue(Pinyin.isPlausiblePinyin("fapiao"))
        XCTAssertFalse(Pinyin.isPlausiblePinyin("invoice"))
        XCTAssertFalse(Pinyin.isPlausiblePinyin("report"))
        XCTAssertFalse(Pinyin.isPlausiblePinyin("screenshot"))
        XCTAssertFalse(Pinyin.isPlausiblePinyin("年报"))
    }

    func testShouldSupplement() {
        // 英文单词：第一次搜到很多结果就不再把整个个人文件夹过一遍。
        XCTAssertFalse(Pinyin.shouldSupplement("invoice", firstResultCount: 50))
        XCTAssertTrue(Pinyin.shouldSupplement("invoice", firstResultCount: 3))
        XCTAssertTrue(Pinyin.shouldSupplement("nianbao", firstResultCount: 50))
        XCTAssertFalse(Pinyin.shouldSupplement("nianbao", firstResultCount: 5000))
        XCTAssertFalse(Pinyin.shouldSupplement("5mb", firstResultCount: 0))
    }
}
