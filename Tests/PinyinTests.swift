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
}
