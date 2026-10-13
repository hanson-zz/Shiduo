import XCTest

final class ShakeDetectorTests: XCTestCase {
    /// 依次经过这些横坐标，每两个点之间隔 step 秒。
    private func feed(_ detector: inout ShakeDetector, _ xs: [Double], step: TimeInterval, start: TimeInterval = 0) -> Bool {
        var hit = false
        for (i, x) in xs.enumerated() where detector.add(x: x, time: start + Double(i) * step) {
            hit = true
        }
        return hit
    }

    func testQuickShakeIsDetected() {
        var d = ShakeDetector()
        // 右、左、右、左：掉头三次，每段 60 点。
        let xs: [Double] = [0, 30, 60, 30, 0, 30, 60, 30, 0]
        XCTAssertTrue(feed(&d, xs, step: 0.05))
    }

    func testSmallJitterIsIgnored() {
        var d = ShakeDetector()
        let xs: [Double] = [0, 20, 0, 20, 0, 20, 0, 20, 0, 20, 0]
        XCTAssertFalse(feed(&d, xs, step: 0.03))
    }

    func testSlowShakeIsIgnored() {
        var d = ShakeDetector()
        let xs: [Double] = [0, 60, 0, 60, 0]
        // 每段 0.4 秒，三次掉头远远超过 0.6 秒。
        XCTAssertFalse(feed(&d, xs, step: 0.4))
    }

    func testStraightDragIsIgnored() {
        var d = ShakeDetector()
        let xs = stride(from: 0.0, through: 800, by: 25).map { $0 }
        XCTAssertFalse(feed(&d, xs, step: 0.02))
    }
}
