import XCTest

final class SmartCleanupLogicTests: XCTestCase {
    func testNameKeyDropsVersionAndPlatform() {
        XCTAssertEqual(SmartCleanupLogic.nameKey("Google Chrome.app"), "googlechrome")
        XCTAssertEqual(SmartCleanupLogic.nameKey("googlechrome.dmg"), "googlechrome")
        XCTAssertEqual(SmartCleanupLogic.nameKey("Figma-124.5.3-arm64.dmg"), "figma")
        XCTAssertEqual(SmartCleanupLogic.nameKey("Docker (1).dmg"), "docker")
        XCTAssertEqual(SmartCleanupLogic.nameKey("WeChatMac.dmg"), "wechat")
        XCTAssertEqual(SmartCleanupLogic.nameKey("Raycast_v1.83.1_universal.dmg"), "raycast")
        XCTAssertEqual(SmartCleanupLogic.nameKey("网易云音乐.app"), "网易云音乐")
    }

    func testInstalledAppMatch() {
        let apps = ["Google Chrome.app", "Figma.app", "WeChat.app", "QQ.app", "Raycast.app", "网易云音乐.app", "Docker.app"]
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "googlechrome.dmg", appNames: apps), "Google Chrome.app")
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "Figma-124.5.3-arm64.dmg", appNames: apps), "Figma.app")
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "WeChatMac.dmg", appNames: apps), "WeChat.app")
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "QQ_v6.9.50.dmg", appNames: apps), "QQ.app")
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "NeteaseMusic.dmg", appNames: apps), nil)
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "网易云音乐_3.0.dmg", appNames: apps), "网易云音乐.app")
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "Docker.dmg", appNames: apps), "Docker.app")
        // 短名不靠前缀误配：「QQMusic」不算 QQ 已安装。
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "QQMusicMac.dmg", appNames: apps), nil)
        XCTAssertEqual(SmartCleanupLogic.installedApp(forInstaller: "Sketch.dmg", appNames: apps), nil)
    }

    func testScreenRecording() {
        XCTAssertTrue(SmartCleanupLogic.isScreenRecording(name: "Screen Recording 2026-10-01 at 10.00.00.mov"))
        XCTAssertTrue(SmartCleanupLogic.isScreenRecording(name: "屏幕录制2026-10-01 10.00.00.mov"))
        XCTAssertTrue(SmartCleanupLogic.isScreenRecording(name: "录屏_1.mp4"))
        XCTAssertFalse(SmartCleanupLogic.isScreenRecording(name: "旅行 vlog.mov"))
    }

    func testDedupeKeepsFirstCard() {
        let out = SmartCleanupLogic.dedupe([("a", ["/1", "/2"]), ("b", ["/2", "/3"])])
        XCTAssertEqual(out[0].1, ["/1", "/2"])
        XCTAssertEqual(out[1].1, ["/3"])
    }
}
