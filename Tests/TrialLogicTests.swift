import XCTest

/// 试用：从不自动开始；付费页的早鸟价；试用结束只提醒一次。
final class TrialLogicTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testAccessNeverStartsTrialByItself() {
        XCTAssertEqual(ProAccess.of(.free), .offerTrial)
        XCTAssertEqual(ProAccess.of(.trial(daysLeft: 3)), .unlocked)
        XCTAssertEqual(ProAccess.of(.pro), .unlocked)
        XCTAssertEqual(ProAccess.of(.expiredTrial), .trialEnded)
    }

    func testTrialCanOnlyStartOnce() {
        XCTAssertTrue(TrialStartRule.canStart(state: .free, trialStart: nil))
        // 已经开始过（即使状态算出来是免费版，比如时钟异常）：不能再开始。
        XCTAssertFalse(TrialStartRule.canStart(state: .free, trialStart: Date()))
        XCTAssertFalse(TrialStartRule.canStart(state: .trial(daysLeft: 5), trialStart: Date()))
        XCTAssertFalse(TrialStartRule.canStart(state: .expiredTrial, trialStart: Date()))
        XCTAssertFalse(TrialStartRule.canStart(state: .pro, trialStart: nil))
    }

    /// 没点「开始试用」之前，评估结果一直是免费版（打开 Pro 页面不会写 trialStart）。
    func testStateStaysFreeWithoutTrialStart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let out = LicenseEvaluator.evaluate(.init(activated: false, lastValidated: nil, trialStart: nil,
                                                  maxSeen: now, now: now, sessionValidatedAgo: nil))
        XCTAssertEqual(out.state, .free)
        XCTAssertEqual(ProAccess.of(out.state), .offerTrial)
    }

    func testTrialLifecycle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func state(after days: Double) -> LicenseState {
            let now = start.addingTimeInterval(days * day)
            return LicenseEvaluator.evaluate(.init(activated: false, lastValidated: nil, trialStart: start,
                                                   maxSeen: now, now: now, sessionValidatedAgo: nil)).state
        }
        XCTAssertEqual(state(after: 0), .trial(daysLeft: LicenseConfig.trialDays))
        XCTAssertEqual(state(after: Double(LicenseConfig.trialDays) - 0.5), .trial(daysLeft: 1))
        XCTAssertEqual(state(after: Double(LicenseConfig.trialDays)), .expiredTrial)
    }

    func testEarlyBirdOnlyOnLastTrialDay() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ProPricing.earlyBirdActive(state: .trial(daysLeft: 1), trialEnd: end, now: end.addingTimeInterval(-3600)))
        XCTAssertFalse(ProPricing.earlyBirdActive(state: .trial(daysLeft: 3), trialEnd: end, now: end.addingTimeInterval(-3 * day)))
        XCTAssertFalse(ProPricing.earlyBirdActive(state: .expiredTrial, trialEnd: end, now: end.addingTimeInterval(60)))
        XCTAssertFalse(ProPricing.earlyBirdActive(state: .free, trialEnd: nil, now: end))
        XCTAssertFalse(ProPricing.earlyBirdActive(state: .pro, trialEnd: end, now: end.addingTimeInterval(-60)))
        XCTAssertEqual(ProPricing.reminderStart(for: end), end.addingTimeInterval(-day))
    }

    func testExpiryAnnouncedOncePerTrial() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(TrialExpiry.shouldAnnounce(state: .expiredTrial, activated: false, trialStart: start, announced: nil))
        XCTAssertFalse(TrialExpiry.shouldAnnounce(state: .expiredTrial, activated: false, trialStart: start,
                                                  announced: TrialExpiry.marker(for: start)))
        XCTAssertFalse(TrialExpiry.shouldAnnounce(state: .trial(daysLeft: 1), activated: false, trialStart: start, announced: nil))
        XCTAssertFalse(TrialExpiry.shouldAnnounce(state: .expiredTrial, activated: true, trialStart: start, announced: nil))
        XCTAssertFalse(TrialExpiry.shouldAnnounce(state: .expiredTrial, activated: false, trialStart: nil, announced: nil))
    }

    func testStoppedFeaturesList() {
        XCTAssertEqual(TrialExpiry.stopped(.init()), [])
        var usage = TrialExpiry.Usage()
        usage.menuBar = true
        usage.floatingShelf = true
        usage.autoOrganizeRules = 2
        usage.fileReminders = 0
        usage.savedSearches = 1
        XCTAssertEqual(TrialExpiry.stopped(usage), [.menuBar, .floatingShelf, .autoOrganize(rules: 2), .savedSearches(count: 1)])
    }
}
