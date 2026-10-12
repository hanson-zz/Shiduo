import XCTest

final class PhotoConceptsTests: XCTestCase {
    func testSingleCharacterNeedsWholeWord() {
        XCTAssertEqual(PhotoConcepts.match("猫")?.labels.first, "cat")
        XCTAssertEqual(PhotoConcepts.match("山")?.labels.first, "mountain")
        XCTAssertEqual(PhotoConcepts.match("有猫的照片")?.labels.first, "cat")
        // 「上海」「个人简历」不能被当成「海」「人」。
        XCTAssertNil(PhotoConcepts.match("上海"))
        XCTAssertNil(PhotoConcepts.match("个人简历"))
    }

    func testMultiCharacterWordsMatchInside() {
        XCTAssertEqual(PhotoConcepts.match("去年海边")?.word, "海边")
        XCTAssertEqual(PhotoConcepts.match("猫咪")?.word, "猫咪")
        XCTAssertEqual(PhotoConcepts.match("发票")?.labels.first, "receipt")
        XCTAssertEqual(PhotoConcepts.match("夜景")?.labels.first, "night_sky")
    }

    func testEnglishWords() {
        XCTAssertEqual(PhotoConcepts.match("dog")?.labels.first, "dog")
        XCTAssertEqual(PhotoConcepts.match("photos of cats")?.labels.first, "cat")
        XCTAssertNil(PhotoConcepts.match("catalog"))
        XCTAssertNil(PhotoConcepts.match(""))
    }

    func testLabelMatchingByComponent() {
        XCTAssertTrue(PhotoConcepts.label("cat", matches: "cat"))
        XCTAssertTrue(PhotoConcepts.label("sunset_sunrise", matches: "sunset"))
        XCTAssertTrue(PhotoConcepts.label("night_sky", matches: "night_sky"))
        XCTAssertFalse(PhotoConcepts.label("catamaran", matches: "cat"))
        XCTAssertFalse(PhotoConcepts.label("hotdog", matches: "dog"))
    }
}

final class LicenseResponseTests: XCTestCase {
    func testParseActivate() {
        let json: [String: Any] = [
            "activated": true,
            "error": NSNull(),
            "license_key": ["id": 1, "status": "active", "key": "38b1460a-5104-4067-a91d-77b872934d51"],
            "instance": ["id": "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17", "name": "Test"],
            "meta": ["store_id": 1234, "product_id": 5678],
        ]
        let r = LicenseAPI.parse(json)
        XCTAssertEqual(r.activated, true)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.instanceID, "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17")
        XCTAssertEqual(r.status, "active")
        XCTAssertEqual(r.storeID, 1234)
        XCTAssertEqual(r.productID, 5678)
    }

    func testParseError() {
        let r = LicenseAPI.parse(["activated": false, "error": "license_key not found."])
        XCTAssertEqual(r.activated, false)
        XCTAssertEqual(r.error, "license_key not found.")
        XCTAssertNil(r.instanceID)
    }
}
