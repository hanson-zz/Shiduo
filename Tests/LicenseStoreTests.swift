import CryptoKit
import XCTest

/// 授权文件：签名校验、手改检测、试用 / 激活过的合并规则、从钥匙串迁移时读哪些项。
final class LicenseStoreTests: XCTestCase {
    private let key = LicenseStoreLogic.deriveKey(hardwareUUID: "11111111-2222-3333-4444-555555555555")
    private let values = ["licenseKey": "ABCD-EFGH-1234", "instanceID": "ins_1", "trialStart": "1800000000.5"]

    func testRoundTripVerifies() throws {
        let data = try XCTUnwrap(LicenseStoreLogic.encode(values, key: key))
        XCTAssertEqual(LicenseStoreLogic.decode(data, key: key), .valid(values))
        XCTAssertEqual(LicenseStoreLogic.decode(try XCTUnwrap(LicenseStoreLogic.encode([:], key: key)), key: key), .valid([:]))
    }

    func testHandEditIsDetected() throws {
        let data = try XCTUnwrap(LicenseStoreLogic.encode(values, key: key))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let edited = text.replacingOccurrences(of: "1800000000.5", with: "1900000000.5")
        XCTAssertNotEqual(text, edited)
        XCTAssertEqual(LicenseStoreLogic.decode(Data(edited.utf8), key: key), .tampered)
    }

    func testRemovingAFieldIsDetected() throws {
        // 删掉 trialStart 并重新排版：签名对不上。
        var body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(LicenseStoreLogic.encode(values, key: key))) as? [String: Any])
        var v = try XCTUnwrap(body["values"] as? [String: String])
        v["trialStart"] = nil
        body["values"] = v
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertEqual(LicenseStoreLogic.decode(data, key: key), .tampered)
    }

    func testOtherMacOrGarbageIsTampered() throws {
        let data = try XCTUnwrap(LicenseStoreLogic.encode(values, key: key))
        let otherMac = LicenseStoreLogic.deriveKey(hardwareUUID: "99999999-2222-3333-4444-555555555555")
        XCTAssertEqual(LicenseStoreLogic.decode(data, key: otherMac), .tampered)
        let otherApp = LicenseStoreLogic.deriveKey(bundleID: "com.example.other",
                                                   hardwareUUID: "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(LicenseStoreLogic.decode(data, key: otherApp), .tampered)
        XCTAssertEqual(LicenseStoreLogic.decode(Data("not json".utf8), key: key), .tampered)
        XCTAssertEqual(LicenseStoreLogic.decode(Data(), key: key), .tampered)
    }

    func testCanonicalPayloadIgnoresInsertionOrderButNotSeparatorsInValues() {
        let a = LicenseStoreLogic.signature(["a": "1", "b": "2"], key: key)
        let b = LicenseStoreLogic.signature(["b": "2", "a": "1"], key: key)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(LicenseStoreLogic.signature(["a": "1b2"], key: key),
                          LicenseStoreLogic.signature(["a": "1", "b": "2"], key: key))
    }

    func testTrialStartTakesEarliest() {
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        let late = early.addingTimeInterval(86_400)
        XCTAssertEqual(LicenseStoreLogic.mergeTrialStart(file: late, backup: early), early)
        XCTAssertEqual(LicenseStoreLogic.mergeTrialStart(file: early, backup: late), early)
        XCTAssertEqual(LicenseStoreLogic.mergeTrialStart(file: nil, backup: late), late)
        XCTAssertEqual(LicenseStoreLogic.mergeTrialStart(file: late, backup: nil), late)
        XCTAssertNil(LicenseStoreLogic.mergeTrialStart(file: nil, backup: nil))
    }

    func testEverActivatedIsSticky() {
        XCTAssertTrue(LicenseStoreLogic.mergeEverActivated(file: true, backup: false))
        XCTAssertTrue(LicenseStoreLogic.mergeEverActivated(file: false, backup: true))
        XCTAssertFalse(LicenseStoreLogic.mergeEverActivated(file: false, backup: false))
    }

    /// 只删文件：UserDefaults 里的备份把试用开始时间和激活过找回来。
    func testDeletingFileDoesNotResetTrial() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let out = LicenseStoreLogic.resolve(fileValues: [:], tampered: false,
                                            backupTrialStart: start, backupEverActivated: true)
        XCTAssertEqual(LicenseStoreLogic.date(from: out["trialStart"]), start)
        XCTAssertEqual(out["everActivated"], "1")
        XCTAssertFalse(TrialStartRule.canStart(state: .free, trialStart: LicenseStoreLogic.date(from: out["trialStart"])))
    }

    /// 新用户：什么都没有，就什么都不加，可以开始试用。
    func testFreshInstallStaysEmpty() {
        let out = LicenseStoreLogic.resolve(fileValues: [:], tampered: false,
                                            backupTrialStart: nil, backupEverActivated: false)
        XCTAssertTrue(out.isEmpty)
    }

    /// 文件被改过、又不知道试用时间：不给新的试用（算成很早以前开始过，已结束）。
    func testTamperedWithoutTrialInfoGrantsNoNewTrial() {
        let out = LicenseStoreLogic.resolve(fileValues: [:], tampered: true,
                                            backupTrialStart: nil, backupEverActivated: false)
        let start = LicenseStoreLogic.date(from: out["trialStart"])
        XCTAssertEqual(start, LicenseStoreLogic.tamperedTrialStart)
        XCTAssertFalse(TrialStartRule.canStart(state: .free, trialStart: start))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eval = LicenseEvaluator.evaluate(.init(activated: false, lastValidated: nil, trialStart: start,
                                                   maxSeen: now, now: now, sessionValidatedAgo: nil))
        XCTAssertEqual(eval.state, .expiredTrial)
    }

    /// 文件被改过但备份里有试用时间：用备份的，不用假的「很早以前」。
    func testTamperedUsesBackupTrialStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let out = LicenseStoreLogic.resolve(fileValues: [:], tampered: true,
                                            backupTrialStart: start, backupEverActivated: false)
        XCTAssertEqual(LicenseStoreLogic.date(from: out["trialStart"]), start)
        let ever = LicenseStoreLogic.resolve(fileValues: [:], tampered: true,
                                             backupTrialStart: nil, backupEverActivated: true)
        XCTAssertNil(ever["trialStart"])
        XCTAssertEqual(ever["everActivated"], "1")
    }

    /// 合并不会丢掉文件里的其他项，也不会把试用时间往后挪。
    func testResolveKeepsOtherValuesAndEarliestStart() {
        let file = ["licenseKey": "K", "instanceID": "I", "trialStart": "1800086400.0"]
        let out = LicenseStoreLogic.resolve(fileValues: file, tampered: false,
                                            backupTrialStart: Date(timeIntervalSince1970: 1_800_000_000),
                                            backupEverActivated: false)
        XCTAssertEqual(out["licenseKey"], "K")
        XCTAssertEqual(out["instanceID"], "I")
        XCTAssertEqual(LicenseStoreLogic.date(from: out["trialStart"]), Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// 迁移时最多读两项，尽量少弹窗。
    func testMigrationReadsAtMostTwoItems() {
        let all: Set<String> = ["licenseKey", "instanceID", "lastValidated", "trialStart", "maxSeen", "everActivated"]
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: all), ["licenseKey", "instanceID"])
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: ["licenseKey", "trialStart"]), ["licenseKey"])
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: ["everActivated", "trialStart", "maxSeen"]), ["everActivated"])
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: ["trialStart", "maxSeen"]), ["trialStart"])
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: ["maxSeen", "lastValidated"]), [])
        XCTAssertEqual(LicenseStoreLogic.migrationOrder(present: []), [])
        for present in [all, ["trialStart"], ["licenseKey"]] as [Set<String>] {
            XCTAssertLessThanOrEqual(LicenseStoreLogic.migrationOrder(present: present).count, 2)
        }
    }
}
