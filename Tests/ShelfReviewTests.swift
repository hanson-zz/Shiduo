import Carbon
import XCTest

// 2026-10-18 暂存架 / 授权 / 搬家 / 快捷键检查的回归测试。

final class LicenseVerdictTests: XCTestCase {
    private func response(_ object: [String: Any], http: Int? = nil) -> LicenseResponse {
        var r = LicenseAPI.parse(object)
        r.httpStatus = http
        return r
    }

    private let product = LicenseConfig.productID

    func testValid() {
        let r = response(["valid": true, "license_key": ["status": "active"], "meta": ["product_id": product]], http: 200)
        XCTAssertEqual(LicenseAPI.verdict(for: r, flag: r.valid), .valid)
    }

    func testValidButOtherProductIsInvalid() {
        let r = response(["valid": true, "license_key": ["status": "active"], "meta": ["product_id": "prod_other"]], http: 200)
        XCTAssertEqual(LicenseAPI.verdict(for: r, flag: r.valid), .invalid)
    }

    func testExplicitInvalid() {
        for error in ["instance not found.", "license_key not found.", "license expired", "license disabled"] {
            let r = response(["valid": false, "error": error], http: 400)
            XCTAssertEqual(LicenseAPI.verdict(for: r, flag: r.valid), .invalid, error)
        }
        let disabled = response(["valid": false, "license_key": ["status": "disabled"]], http: 200)
        XCTAssertEqual(LicenseAPI.verdict(for: disabled, flag: disabled.valid), .invalid)
    }

    /// 新版中转：Creem 5xx / 429 / 网络错误都带 transient，不带 valid。
    func testNewRelayTransient() {
        let r = response(["error": "upstream unavailable", "transient": true], http: 502)
        XCTAssertEqual(LicenseAPI.verdict(for: r, flag: r.valid), .transient)
        let limited = response(["error": "too many requests", "transient": true], http: 429)
        XCTAssertEqual(LicenseAPI.verdict(for: limited, flag: limited.valid), .transient)
    }

    /// 旧版中转把 Creem 的 5xx 说成 valid:false "license error"，把 429 说成 "too many requests"：不能解绑。
    func testOldRelayUpstreamErrorsAreTransient() {
        let old5xx = response(["valid": false, "error": "license error"], http: 400)
        XCTAssertEqual(LicenseAPI.verdict(for: old5xx, flag: old5xx.valid), .transient)
        let old429 = response(["valid": false, "error": "too many requests"], http: 429)
        XCTAssertEqual(LicenseAPI.verdict(for: old429, flag: old429.valid), .transient)
        let misconfigured = response(["error": "server misconfigured"], http: 502)
        XCTAssertEqual(LicenseAPI.verdict(for: misconfigured, flag: misconfigured.valid), .transient)
        let empty = response([:], http: 500)
        XCTAssertEqual(LicenseAPI.verdict(for: empty, flag: empty.valid), .transient)
    }

    func testHTTPDate() {
        let date = LicenseAPI.parseHTTPDate("Sun, 18 Oct 2026 14:36:00 GMT")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_792_334_160)
        XCTAssertNil(LicenseAPI.parseHTTPDate("yesterday"))
    }

    func testRetryBackoff() {
        XCTAssertEqual(LicenseEvaluator.retryDelay(attempt: 1), 60)
        XCTAssertEqual(LicenseEvaluator.retryDelay(attempt: 2), 120)
        XCTAssertEqual(LicenseEvaluator.retryDelay(attempt: 3), 240)
        XCTAssertEqual(LicenseEvaluator.retryDelay(attempt: 50), 3600)
    }
}

final class LicenseClockTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func eval(activated: Bool = false, last: Date? = nil, trialStart: Date? = nil, maxSeen: Date? = nil,
                      now: Date? = nil, session: TimeInterval? = nil) -> LicenseEvaluator.Output {
        LicenseEvaluator.evaluate(.init(activated: activated, lastValidated: last, trialStart: trialStart,
                                        maxSeen: maxSeen, now: now ?? self.now, sessionValidatedAgo: session))
    }

    func testNormalTrialAndPro() {
        XCTAssertEqual(eval().state, .free)
        XCTAssertEqual(eval(trialStart: now.addingTimeInterval(-2 * day)).state, .trial(daysLeft: 5))
        XCTAssertEqual(eval(trialStart: now.addingTimeInterval(-8 * day)).state, .expiredTrial)
        XCTAssertEqual(eval(activated: true, last: now.addingTimeInterval(-3 * day)).state, .pro)
    }

    func testOfflineTooLongNeedsOnlineCheck() {
        let out = eval(activated: true, last: now.addingTimeInterval(-31 * day), trialStart: now.addingTimeInterval(-60 * day))
        XCTAssertEqual(out.state, .expiredTrial)
        XCTAssertTrue(out.needsOnlineCheck)
        // 这次运行里刚联网校验成功（单调时钟）就是 Pro。
        XCTAssertEqual(eval(activated: true, last: now.addingTimeInterval(-31 * day), session: 10).state, .pro)
    }

    /// 把时间调到未来校验一次，再调回来：上次校验在「未来」，不能永远算 Pro，也要马上联网。
    func testLastValidatedInFuture() {
        let future = now.addingTimeInterval(1000 * day)
        let out = eval(activated: true, last: future, maxSeen: future)
        XCTAssertNotEqual(out.state, .pro)
        XCTAssertTrue(out.needsOnlineCheck)
        XCTAssertTrue(LicenseEvaluator.shouldRevalidate(lastValidated: future, now: now, maxSeen: future))
        XCTAssertTrue(LicenseEvaluator.shouldRevalidate(lastValidated: future, now: now, maxSeen: nil))
    }

    /// 把时间往回调到开始试用之前：不能重置成第 0 天。
    func testRollbackDoesNotResetTrial() {
        let start = now.addingTimeInterval(-6 * day)
        let rolledBack = start.addingTimeInterval(-10 * day)
        XCTAssertEqual(eval(trialStart: start, maxSeen: now, now: rolledBack).state, .expiredTrial)
        // 调回一点点（一天以内）不算篡改。
        XCTAssertEqual(eval(trialStart: start, maxSeen: now, now: now.addingTimeInterval(-3600)).state, .trial(daysLeft: 1))
    }

    /// 时钟往回调时，已激活的也不给离线宽限。
    func testRollbackRemovesGrace() {
        let out = eval(activated: true, last: now.addingTimeInterval(-day), maxSeen: now.addingTimeInterval(400 * day))
        XCTAssertNotEqual(out.state, .pro)
        XCTAssertTrue(out.needsOnlineCheck)
    }

    /// 时间往前调不能跳过试用的计时：用见过的最晚时间算。
    func testTrialUsesMaxSeen() {
        let start = now.addingTimeInterval(-2 * day)
        XCTAssertEqual(eval(trialStart: start, maxSeen: now.addingTimeInterval(0.5 * day), now: now).state, .trial(daysLeft: 5))
        XCTAssertEqual(eval(trialStart: start, maxSeen: now, now: now.addingTimeInterval(10 * day)).state, .expiredTrial)
    }

    func testRevalidateInterval() {
        XCTAssertTrue(LicenseEvaluator.shouldRevalidate(lastValidated: nil, now: now, maxSeen: nil))
        XCTAssertFalse(LicenseEvaluator.shouldRevalidate(lastValidated: now.addingTimeInterval(-3600), now: now, maxSeen: now))
        XCTAssertTrue(LicenseEvaluator.shouldRevalidate(lastValidated: now.addingTimeInterval(-2 * day), now: now, maxSeen: now))
    }
}

final class ShortcutLogicTests: XCTestCase {
    func testDefaultFloatingShelfKeyDoesNotConflict() {
        XCTAssertEqual(FloatingShelfHotKey.from(nil), .controlOptionS)
        XCTAssertNil(FloatingShelfHotKey.controlOptionS.conflict)
        XCTAssertNil(FloatingShelfHotKey.optionCommandPeriod.conflict)
        XCTAssertNotNil(FloatingShelfHotKey.optionCommandS.conflict)
        XCTAssertEqual(FloatingShelfHotKey.from("optionCommandS"), .optionCommandS)
    }

    /// 数字键直达的 40 个组合里不能有系统截屏这类已知冲突。
    func testQuickPickAvoidsKnownConflicts() {
        for pathOnly in [false, true] {
            let modifiers = ShortcutLogic.quickPickModifiers(pathOnly: pathOnly)
            XCTAssertEqual(modifiers & UInt32(shiftKey), 0)
            for key in ShortcutLogic.digitKeys {
                XCTAssertNil(ShortcutLogic.conflict(modifiers: modifiers, keyCode: key))
            }
        }
        XCTAssertNotNil(ShortcutLogic.conflict(modifiers: UInt32(cmdKey | shiftKey | controlKey), keyCode: UInt32(kVK_ANSI_4)))
    }
}

final class MoveOutLogicTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoMoveOutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 先解锁再删。
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder(_ name: String, files: [String]) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data(repeating: 7, count: 1000).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    func testRemovesCleanly() throws {
        let source = try makeFolder("src", files: ["a", "b"])
        let target = root.appendingPathComponent("dst")
        try FileManager.default.copyItem(at: source, to: target)
        let outcome = MoveOutLogic.removeSource(source, expectedSize: MoveOutLogic.logicalSize(source), target: target)
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(MoveOutLogic.logicalSize(target), 2000)
    }

    /// 锁定的单个文件改不了名：什么都没动，撤回拷贝。
    func testLockedFileIsUntouched() throws {
        let file = root.appendingPathComponent("locked.txt")
        try Data(repeating: 1, count: 500).write(to: file)
        let target = root.appendingPathComponent("copy.txt")
        try FileManager.default.copyItem(at: file, to: target)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let outcome = MoveOutLogic.removeSource(file, expectedSize: 500, target: target)
        XCTAssertEqual(outcome, .untouched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// 文件夹里有锁定文件：删到一半失败时，目标副本必须完整保留，不能丢任何文件。
    func testFolderWithLockedFileKeepsCopy() throws {
        let source = try makeFolder("work", files: ["1.txt", "2.txt", "3.txt", "4.txt"])
        let locked = source.appendingPathComponent("3.txt")
        let target = root.appendingPathComponent("moved")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let expected = MoveOutLogic.logicalSize(source)
        let outcome = MoveOutLogic.removeSource(source, expectedSize: expected, target: target)
        XCTAssertNotEqual(outcome, .removed)
        // 原位置的名字恢复了（残留或完整）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        if outcome == .leftover {
            XCTAssertEqual(MoveOutLogic.logicalSize(target), expected, "副本必须完整保留")
        } else {
            XCTAssertEqual(MoveOutLogic.logicalSize(source), expected, "撤回拷贝前原文件必须一点没少")
        }
        // 无论哪种结果，每个文件都至少还有一份。
        for name in ["1.txt", "2.txt", "3.txt", "4.txt"] {
            let inSource = FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path)
            let inTarget = FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path)
            XCTAssertTrue(inSource || inTarget, name)
        }
    }
}
