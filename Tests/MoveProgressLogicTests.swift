import XCTest

final class MoveProgressLogicTests: XCTestCase {
    func testShowOnlyWhenSlowOrMovingData() {
        XCTAssertFalse(MoveProgressLogic.shouldShow(elapsed: 0.2, movesData: false, finished: false))
        XCTAssertTrue(MoveProgressLogic.shouldShow(elapsed: 0.5, movesData: false, finished: false))
        XCTAssertTrue(MoveProgressLogic.shouldShow(elapsed: 0, movesData: true, finished: false), "跨盘马上显示")
        XCTAssertFalse(MoveProgressLogic.shouldShow(elapsed: 10, movesData: true, finished: true))
    }

    func testFractionByBytesOrItems() {
        XCTAssertEqual(MoveProgressLogic.fraction(bytesMode: true, itemsDone: 1, itemCount: 4, bytesDone: 2_100, bytesTotal: 5_400),
                       2_100.0 / 5_400.0, accuracy: 1e-9)
        XCTAssertEqual(MoveProgressLogic.fraction(bytesMode: false, itemsDone: 32, itemCount: 128, bytesDone: 0, bytesTotal: 0),
                       0.25, accuracy: 1e-9)
        // 按字节但都是空文件：退回按项目
        XCTAssertEqual(MoveProgressLogic.fraction(bytesMode: true, itemsDone: 1, itemCount: 2, bytesDone: 0, bytesTotal: 0),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(MoveProgressLogic.fraction(bytesMode: false, itemsDone: 0, itemCount: 0, bytesDone: 0, bytesTotal: 0), 0)
        XCTAssertEqual(MoveProgressLogic.fraction(bytesMode: true, itemsDone: 0, itemCount: 1, bytesDone: 9, bytesTotal: 5), 1)
    }

    func testRemainingEstimate() {
        XCTAssertNil(MoveProgressLogic.remainingSeconds(elapsed: 1, fraction: 0.5), "刚开始不估")
        XCTAssertNil(MoveProgressLogic.remainingSeconds(elapsed: 10, fraction: 0.01))
        XCTAssertNil(MoveProgressLogic.remainingSeconds(elapsed: 10, fraction: 1))
        XCTAssertEqual(MoveProgressLogic.remainingSeconds(elapsed: 30, fraction: 0.25) ?? -1, 90, accuracy: 1e-9)
    }

    func testRemainingTextBuckets() {
        let lessThanMinute = MoveProgressLogic.remainingText(20)
        let minute = MoveProgressLogic.remainingText(70)
        let minutes = MoveProgressLogic.remainingText(5 * 60)
        let hours = MoveProgressLogic.remainingText(2 * 3600)
        XCTAssertTrue(minute.contains("1"), minute)
        XCTAssertTrue(minutes.contains("5"), minutes)
        XCTAssertTrue(hours.contains("2"), hours)
        XCTAssertEqual(Set([lessThanMinute, minute, minutes, hours]).count, 4)
    }

    func testDestinationLabel() {
        XCTAssertEqual(MoveProgressLogic.destinationLabel(folderName: "归档", volumeName: "移动硬盘", isVolumeRoot: false),
                       "移动硬盘 / 归档")
        XCTAssertEqual(MoveProgressLogic.destinationLabel(folderName: "移动硬盘", volumeName: "移动硬盘", isVolumeRoot: true),
                       "移动硬盘")
        XCTAssertEqual(MoveProgressLogic.destinationLabel(folderName: "归档", volumeName: nil, isVolumeRoot: false), "归档")
        XCTAssertEqual(MoveProgressLogic.destinationLabel(folderName: "归档", volumeName: "", isVolumeRoot: false), "归档")
    }

    func testDetailText() {
        let bytes = MoveProgressLogic.detailText(bytesMode: true, itemsDone: 3, itemCount: 128, bytesDone: 2_100_000_000,
                                                 bytesTotal: 5_400_000_000, remaining: 70, currentName: "KV-横版.psd")
        let parts = bytes.components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 3, bytes)
        XCTAssertTrue(parts[0].contains(" / "), bytes)
        XCTAssertTrue(parts[2].contains("KV-横版.psd"), bytes)

        let items = MoveProgressLogic.detailText(bytesMode: false, itemsDone: 37, itemCount: 128, bytesDone: 0,
                                                 bytesTotal: 0, remaining: nil, currentName: "")
        XCTAssertFalse(items.contains(" · "), items)
        XCTAssertTrue(items.contains("37") && items.contains("128"), items)
        // 完成数不超过总数
        let over = MoveProgressLogic.detailText(bytesMode: false, itemsDone: 200, itemCount: 128, bytesDone: 0,
                                                bytesTotal: 0, remaining: nil, currentName: "")
        XCTAssertFalse(over.contains("200"), over)
    }

    func testThrottle() {
        var throttle = MoveProgressLogic.Throttle(interval: 0.1)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        XCTAssertTrue(throttle.shouldEmit(now: t0))
        XCTAssertFalse(throttle.shouldEmit(now: t0.addingTimeInterval(0.05)))
        XCTAssertTrue(throttle.shouldEmit(now: t0.addingTimeInterval(0.06), force: true), "开始 / 结束总是放行")
        XCTAssertFalse(throttle.shouldEmit(now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(throttle.shouldEmit(now: t0.addingTimeInterval(0.17)))
    }
}
