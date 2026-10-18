import XCTest

final class OCRCacheKeysTests: XCTestCase {
    func testKeyRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.7)
        let key = OCRCacheKeys.key(path: "/Users/me/a|b.png", modified: date)
        XCTAssertEqual(key, "/Users/me/a|b.png|1700000000")
        let parts = OCRCacheKeys.split(key)
        XCTAssertEqual(parts?.path, "/Users/me/a|b.png")
        XCTAssertEqual(parts?.seconds, "1700000000")
    }

    func testLatestPerPath() {
        let texts = [
            "/a.png|100": "旧的手机号 13800000000",
            "/a.png|200": "涂掉以后",
            "/b.png|50": "b",
        ]
        let result = OCRCacheKeys.latestPerPath(texts)
        XCTAssertEqual(result, ["/a.png|200": "涂掉以后", "/b.png|50": "b"])
    }

    func testSecondsKeyMatchesCacheKey() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.9996)
        let stamp = FileStamp(modified: date, size: 1)
        XCTAssertEqual(OCRCacheKeys.key(path: "/x", modified: date), "/x|" + stamp.secondsKey)
    }
}
