import XCTest

final class FullDiskAccessLogicTests: XCTestCase {
    private func c(_ outcomes: [FullDiskAccessProbeOutcome]) -> FullDiskAccessStatus {
        FullDiskAccessLogic.combine(outcomes)
    }

    func testErrnoMapping() {
        XCTAssertEqual(FullDiskAccessLogic.outcome(errno: 0), .granted)
        XCTAssertEqual(FullDiskAccessLogic.outcome(errno: EPERM), .denied)
        XCTAssertEqual(FullDiskAccessLogic.outcome(errno: EACCES), .denied)
        XCTAssertEqual(FullDiskAccessLogic.outcome(errno: ENOENT), .inconclusive)
        XCTAssertEqual(FullDiskAccessLogic.outcome(errno: ENOTDIR), .inconclusive)
    }

    func testAnyGrantedWins() {
        XCTAssertEqual(c([.denied, .inconclusive, .granted, .denied]), .granted)
        XCTAssertEqual(c([.granted]), .granted)
    }

    func testDeniedWhenNothingGranted() {
        XCTAssertEqual(c([.inconclusive, .denied, .inconclusive]), .denied)
        XCTAssertFalse(c([.denied]).isGranted)
    }

    func testMissingPathsAreSkipped() {
        // 老的判断只看 TCC.db：它不存在就永远「未开启」。现在不存在只算说不准，别的地方读得到仍是已授权。
        XCTAssertEqual(c([.inconclusive, .inconclusive, .granted]), .granted)
        XCTAssertEqual(c([.inconclusive, .inconclusive]), .unknown)
        XCTAssertEqual(c([]), .unknown)
        XCTAssertFalse(FullDiskAccessStatus.unknown.isGranted)
    }

    func testStopsAtFirstGranted() {
        var evaluated = 0
        let outcomes: [FullDiskAccessProbeOutcome] = [.denied, .granted, .denied, .denied]
        let status = FullDiskAccessLogic.combine(outcomes.lazy.map { o -> FullDiskAccessProbeOutcome in
            evaluated += 1
            return o
        })
        XCTAssertEqual(status, .granted)
        XCTAssertEqual(evaluated, 2)
    }

    func testProbeListUsesHomeAndStartsWithFiles() {
        let probes = FullDiskAccessLogic.probes(home: "/Users/test")
        XCTAssertEqual(probes.first, .file("/Users/test/Library/Application Support/com.apple.TCC/TCC.db"))
        XCTAssertTrue(probes.contains(.directory("/Users/test/Library/Safari")))
        XCTAssertTrue(probes.contains(.directory("/Users/test/Library/Containers/com.apple.stocks")))
        XCTAssertTrue(probes.contains(.file("/Library/Application Support/com.apple.TCC/TCC.db")))
        // 文件探测都排在目录前面（读文件最便宜、不会弹提示）。
        let firstDir = probes.firstIndex { if case .directory = $0 { return true } else { return false } }!
        XCTAssertTrue(probes[..<firstDir].allSatisfy { if case .file = $0 { return true } else { return false } })
    }

    func testRunOnRealPaths() {
        let tmp = NSTemporaryDirectory()
        let file = (tmp as NSString).appendingPathComponent("fda-probe-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertEqual(FullDiskAccessLogic.run(.file(file)), .granted)
        XCTAssertEqual(FullDiskAccessLogic.run(.directory(tmp)), .granted)
        XCTAssertEqual(FullDiskAccessLogic.run(.file("/nonexistent-\(UUID().uuidString)")), .inconclusive)
        XCTAssertEqual(FullDiskAccessLogic.run(.directory("/nonexistent-\(UUID().uuidString)")), .inconclusive)
    }
}
