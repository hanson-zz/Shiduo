import XCTest

/// 移到废纸篓什么时候要确认：只有大批量（≥100 个或 ≥5 GB）。
final class TrashConfirmTests: XCTestCase {
    func testSmallBatchesDoNotConfirm() {
        XCTAssertFalse(TrashConfirm.needsConfirm(count: 1, bytes: 1_000))
        XCTAssertFalse(TrashConfirm.needsConfirm(count: 99, bytes: 4_999_999_999))
        XCTAssertFalse(TrashConfirm.needsConfirm(count: 0, bytes: 0))
    }

    func testLargeBatchesConfirm() {
        XCTAssertTrue(TrashConfirm.needsConfirm(count: 100, bytes: 10))
        XCTAssertTrue(TrashConfirm.needsConfirm(count: 3, bytes: 5_000_000_000))
        XCTAssertTrue(TrashConfirm.needsConfirm(count: 500, bytes: 50_000_000_000))
    }

    func testUnknownFolderSizeConfirms() {
        XCTAssertTrue(TrashConfirm.needsConfirm(count: 1, bytes: 0, unknownFolderSize: true))
        XCTAssertFalse(TrashConfirm.needsConfirm(count: 1, bytes: 0, unknownFolderSize: false))
    }
}
