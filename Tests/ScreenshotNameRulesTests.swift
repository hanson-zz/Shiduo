import XCTest

/// 第三方截图按文件名认：微信、QQ、Snipaste、CleanShot、飞书、钉钉……；系统标记照旧算。
final class ScreenshotNameRulesTests: XCTestCase {
    private let png = ["public.png", "public.image"]

    func testThirdPartyNamesMatch() {
        let names = [
            "微信截图_20241022153000.png",
            "WeChat Image 截图 2024.png",
            "QQ截图20241022153000.png",
            "QQ20241022-153000.png",
            "Snipaste_2024-10-22_15-30-00.png",
            "CleanShot 2024-10-22 at 15.30.00@2x.png",
            "Xnip2024-10-22_15-30-00.jpg",
            "iShot_2024-10-22_15.30.00.png",
            "PixPin_2024-10-22_15-30-00.png",
            "Shottr 2024-10-22.png",
            "截屏2024-10-22 15.30.00.png",
            "截图 2024.png",
            "屏幕截图 2024-10-22 153000.png",
            "屏幕快照 2019-01-01 下午3.00.00.png",
            "Screenshot 2024-10-22 at 15.30.00.png",
            "screenshot.png",
            "ScreenShot_20241022.png",
            "Screen Shot 2019-01-01 at 3.00.00 PM.png",
            "quickshot-20241022.png",
            "Capture_20241022_153000.png",
            "capture 2024-10-22.jpg",
            "Snip20241022_1.png",
            "Snip-2024.png",
            "飞书截图_2024.png",
            "Lark20241022-153000 截图.png",
            "钉钉截图20241022.png",
            "DingTalk20241022153000.png",
            "DingTalk 截图.png",
        ]
        for name in names {
            XCTAssertTrue(ScreenshotNameRules.nameMatches(name), name)
            XCTAssertTrue(ScreenshotNameRules.isScreenshot(name: name, typeTree: png, systemFlag: false), name)
        }
    }

    func testCaseInsensitive() {
        XCTAssertTrue(ScreenshotNameRules.nameMatches("SNIPASTE_2024.PNG"))
        XCTAssertTrue(ScreenshotNameRules.nameMatches("cleanshot 2024.png"))
        XCTAssertTrue(ScreenshotNameRules.nameMatches("qq20241022.png"))
    }

    /// Capture / Snip / QQ / DingTalk 后面不跟日期的不算，免得误认。
    func testAmbiguousPrefixesNeedADate() {
        let names = [
            "Capture.png", "CaptureTheFlag.png", "capture_card.jpg", "Capture_19990101.png",
            "Snippet.png", "snip.png", "Snipe 2024.png", "Snip_2x.png",
            "QQ.png", "QQ音乐封面.png", "QQ_logo.png",
            "DingTalk.png", "DingTalk_logo.png",
            "Lark logo.png", "WeChat 二维码.png",
            "IMG_1234.jpg", "照片 2024.png", "我的截图说明.png", "photo-screenshot.png",
        ]
        for name in names {
            XCTAssertFalse(ScreenshotNameRules.nameMatches(name), name)
        }
    }

    /// 只认图片：同名的视频、PDF 不算截图。
    func testOnlyImages() {
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "Snipaste_2024.pdf", typeTree: ["com.adobe.pdf"], systemFlag: false))
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "CleanShot 2024.mp4", typeTree: ["public.mpeg-4", "public.movie"], systemFlag: false))
        // 没有类型树时按扩展名判断。
        XCTAssertTrue(ScreenshotNameRules.isScreenshot(name: "微信截图_1.jpeg", typeTree: [], systemFlag: false))
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "微信截图_1.zip", typeTree: [], systemFlag: false))
    }

    func testSystemFlagStillCounts() {
        XCTAssertTrue(ScreenshotNameRules.isScreenshot(name: "随便.png", typeTree: png, systemFlag: true))
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "随便.png", typeTree: png, systemFlag: false))
    }

    /// 资料库「图片 › 截图」也认第三方截图；设计稿仍优先。
    func testLibrarySubCategory() {
        XCTAssertEqual(LibrarySub.classify(.init(name: "Snipaste_2024-10-22.png"), in: .images), .screenshot)
        XCTAssertEqual(LibrarySub.classify(.init(name: "微信截图_20241022.png"), in: .images), .screenshot)
        XCTAssertEqual(LibrarySub.classify(.init(name: "Capture.png"), in: .images), .other)
        XCTAssertEqual(LibrarySub.classify(.init(name: "截图.psd"), in: .images), .design)
    }

    /// Spotlight 通配符和规则一一对应，日期类有 4 种写法，全部小写、以 * 结尾。
    func testSpotlightPatterns() {
        let patterns = ScreenshotNameRules.spotlightPatterns
        XCTAssertTrue(patterns.contains("微信截图_*"))
        XCTAssertTrue(patterns.contains("wechat*截图*"))
        XCTAssertTrue(patterns.contains("snipaste_*"))
        XCTAssertTrue(patterns.contains("capture20*"))
        XCTAssertTrue(patterns.contains("capture_20*"))
        XCTAssertTrue(patterns.contains("capture 20*"))
        XCTAssertTrue(patterns.contains("capture-20*"))
        XCTAssertFalse(patterns.contains("capture*"))
        for p in patterns {
            XCTAssertTrue(p.hasSuffix("*"), p)
            XCTAssertEqual(p, p.lowercased(), p)
        }
    }
}
