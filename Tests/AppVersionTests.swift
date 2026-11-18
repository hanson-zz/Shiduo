import XCTest

/// 检查更新的版本比较：测试版用户要能收到正式版，正式版用户永远不收测试版。
final class AppVersionTests: XCTestCase {
    private func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testOrdering() {
        XCTAssertGreaterThan(v("0.14.1"), v("0.14.1-beta.10"))
        XCTAssertGreaterThan(v("0.14.1-beta.10"), v("0.14.1-beta.9"))
        XCTAssertGreaterThan(v("0.14.1-beta.11"), v("0.14.1-beta.10"))
        XCTAssertGreaterThan(v("0.14.2-beta.1"), v("0.14.1"))
        XCTAssertGreaterThan(v("0.15.0"), v("0.14.10"))
        XCTAssertGreaterThan(v("0.14.10"), v("0.14.9"))
        XCTAssertGreaterThan(v("1.0.0"), v("0.99.99"))
        XCTAssertGreaterThan(v("0.14.1-rc.1"), v("0.14.1-beta.10"))
        XCTAssertGreaterThan(v("0.14.1-beta"), v("0.14.1-alpha.5"))
        XCTAssertGreaterThan(v("0.14.1-beta.1"), v("0.14.1-beta"))
        XCTAssertGreaterThan(v("0.14.1-beta.x"), v("0.14.1-beta.99"))
    }

    func testEqualityAndParsing() {
        XCTAssertEqual(v("v0.14.1"), v("0.14.1"))
        XCTAssertEqual(v("0.14"), v("0.14.0"))
        XCTAssertEqual(v("0.14.1+77"), v("0.14.1"))
        XCTAssertEqual(v(" v0.14.1-beta.10 ").prerelease, ["beta", "10"])
        XCTAssertTrue(v("0.14.1-beta.10").isPrerelease)
        XCTAssertFalse(v("0.14.1").isPrerelease)
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("0.14.1-"))
        XCTAssertNil(AppVersion("0.14..1"))
        XCTAssertNil(AppVersion("0.14.1-beta..1"))
    }

    // MARK: - 挑选更新

    private func c(_ tag: String, pre: Bool = false, draft: Bool = false) -> UpdateSelection.Candidate {
        .init(tag: tag, isDraft: draft, isPrerelease: pre)
    }

    func testBetaUserGetsOfficialRelease() {
        let list = [c("v0.14.1"), c("v0.14.1-beta.10", pre: true), c("v0.14.0")]
        XCTAssertEqual(UpdateSelection.best(from: list, currentVersion: "0.14.1-beta.10")?.tag, "v0.14.1")
    }

    func testBetaUserGetsNewerBeta() {
        let list = [c("v0.14.1-beta.11", pre: true), c("v0.14.1-beta.10", pre: true), c("v0.14.0")]
        XCTAssertEqual(UpdateSelection.best(from: list, currentVersion: "0.14.1-beta.10")?.tag, "v0.14.1-beta.11")
    }

    func testBetaUserPicksHighest() {
        let list = [c("v0.14.1-beta.11", pre: true), c("v0.14.1"), c("v0.14.2-beta.1", pre: true)]
        XCTAssertEqual(UpdateSelection.best(from: list, currentVersion: "0.14.1-beta.10")?.tag, "v0.14.2-beta.1")
    }

    func testOfficialUserNeverGetsBeta() {
        let list = [c("v0.14.2-beta.1", pre: true), c("v0.14.3-beta.1"), c("v0.14.1")]
        XCTAssertNil(UpdateSelection.best(from: list, currentVersion: "0.14.1"))
        XCTAssertEqual(UpdateSelection.best(from: list + [c("v0.14.2")], currentVersion: "0.14.1")?.tag, "v0.14.2")
    }

    func testDraftsIgnored() {
        let list = [c("v0.14.1-beta.12", pre: true, draft: true), c("v0.14.2", draft: true)]
        XCTAssertNil(UpdateSelection.best(from: list, currentVersion: "0.14.1-beta.10"))
        XCTAssertNil(UpdateSelection.best(from: list, currentVersion: "0.14.1"))
    }

    func testUpToDateAndGarbage() {
        XCTAssertNil(UpdateSelection.best(from: [c("v0.14.1")], currentVersion: "0.14.1"))
        XCTAssertNil(UpdateSelection.best(from: [c("v0.14.0")], currentVersion: "0.14.1"))
        XCTAssertNil(UpdateSelection.best(from: [c("nightly")], currentVersion: "0.14.1-beta.10"))
        XCTAssertNil(UpdateSelection.best(from: [c("v0.15.0")], currentVersion: "garbage"))
    }

    func testWantsPrereleases() {
        XCTAssertTrue(UpdateSelection.wantsPrereleases(currentVersion: "0.14.1-beta.10"))
        XCTAssertFalse(UpdateSelection.wantsPrereleases(currentVersion: "0.14.1"))
        XCTAssertFalse(UpdateSelection.wantsPrereleases(currentVersion: "0"))
    }
}
