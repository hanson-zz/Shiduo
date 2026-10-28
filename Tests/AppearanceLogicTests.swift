import XCTest

/// 设置 › 外观 的纯逻辑：设置存取（容错）、字号范围、主题色、缩略图规则、透视文件夹挑最新几张、备选应用图标。
final class AppearanceLogicTests: XCTestCase {

    // MARK: 存取

    func testDefaults() {
        let d = AppearanceSettings.defaults
        XCTAssertEqual(d.accent, .system)
        XCTAssertEqual(d.listFontSize, 13)
        XCTAssertTrue(d.sidebarColorIcons)
        XCTAssertEqual(d.sidebarIconSize, .medium)
        XCTAssertTrue(d.alwaysPreviewMedia)
        XCTAssertEqual(d.thumbnailStartSize, .any)
        XCTAssertFalse(d.peekFolders, "透视文件夹默认关")
        XCTAssertNil(d.appIcon)
    }

    func testRoundTrip() throws {
        var s = AppearanceSettings()
        s.accent = .pink
        s.listFontSize = 15
        s.sidebarColorIcons = false
        s.sidebarIconSize = .large
        s.alwaysPreviewMedia = false
        s.thumbnailStartSize = .p64
        s.peekFolders = true
        s.appIcon = "navy"
        let data = try XCTUnwrap(s.encoded())
        XCTAssertEqual(AppearanceSettings.decode(data), s)
    }

    func testMissingDataGivesDefaults() {
        XCTAssertEqual(AppearanceSettings.decode(nil), .defaults)
        XCTAssertEqual(AppearanceSettings.decode(Data("not json".utf8)), .defaults)
        XCTAssertEqual(AppearanceSettings.decode(Data("{}".utf8)), .defaults)
    }

    func testPartialAndUnknownValuesFallBackPerField() {
        let json = """
        {"accent":"rainbow","listFontSize":40,"sidebarIconSize":"huge","thumbnailStartSize":17,
         "peekFolders":true,"sidebarColorIcons":"yes","appIcon":"../evil","futureKey":1}
        """
        let s = AppearanceSettings.decode(Data(json.utf8))
        XCTAssertEqual(s.accent, .system, "认不出的颜色用默认")
        XCTAssertEqual(s.listFontSize, 16, "字号拉回范围")
        XCTAssertEqual(s.sidebarIconSize, .medium)
        XCTAssertEqual(s.thumbnailStartSize, .any)
        XCTAssertTrue(s.peekFolders, "认得的项目照常读")
        XCTAssertTrue(s.sidebarColorIcons, "类型不对的那一项用默认，不影响别的")
        XCTAssertNil(s.appIcon, "不合规的图标 id 丢掉")
    }

    func testEncodedFontSizeIsClamped() throws {
        var s = AppearanceSettings()
        s.listFontSize = 3
        let data = try XCTUnwrap(s.encoded())
        XCTAssertEqual(AppearanceSettings.decode(data).listFontSize, 11)
    }

    // MARK: 字号

    func testFontSizeClamp() {
        XCTAssertEqual(ListFontSize.clamp(10), 11)
        XCTAssertEqual(ListFontSize.clamp(11), 11)
        XCTAssertEqual(ListFontSize.clamp(13.4), 13)
        XCTAssertEqual(ListFontSize.clamp(13.6), 14)
        XCTAssertEqual(ListFontSize.clamp(16), 16)
        XCTAssertEqual(ListFontSize.clamp(99), 16)
        XCTAssertEqual(ListFontSize.clamp(.nan), 13)
        XCTAssertEqual(ListFontSize.clamp(.infinity), 13)
    }

    func testDerivedSizesKeepOldLookAtDefault() {
        XCTAssertEqual(ListFontSize.listIconSide(13), 20, "13 号时列表图标还是以前的 20 点")
        XCTAssertEqual(ListFontSize.gridNameSize(13), 12, "13 号时图标视图文件名还是以前的 .callout（12）")
        XCTAssertEqual(ListFontSize.listIconSide(16), 23)
        XCTAssertEqual(ListFontSize.gridNameSize(11), 10)
    }

    // MARK: 主题色

    func testAccentMapping() {
        XCTAssertNil(AccentChoice.system.rgb, "默认跟随系统")
        XCTAssertNil(AccentChoice.system.hex)
        XCTAssertEqual(AccentChoice.allCases.count, 9, "默认 + 8 种颜色")
        let colors = AccentChoice.allCases.filter { $0 != .system }
        XCTAssertEqual(colors.count, 8)
        XCTAssertEqual(Set(colors.compactMap(\.hex)).count, 8, "8 种颜色互不相同")
        for c in colors {
            guard let rgb = c.rgb else {
                XCTFail("\(c) 没有颜色")
                continue
            }
            let unit: ClosedRange<Double> = 0...1
            XCTAssertTrue(unit.contains(rgb.red) && unit.contains(rgb.green) && unit.contains(rgb.blue))
        }
        XCTAssertEqual(AccentChoice.blue.hex, "0A7AFF")
        XCTAssertEqual(AccentChoice(rawValue: "green"), .green)
    }

    // MARK: 缩略图

    func testThumbnailPolicyDefaultsLoadEverything() {
        let d = AppearanceSettings.defaults
        XCTAssertTrue(ThumbnailPolicy.loadsThumbnail(isMedia: true, iconSide: 16, folderItemCount: 50_000, settings: d))
        XCTAssertTrue(ThumbnailPolicy.loadsThumbnail(isMedia: false, iconSide: 16, folderItemCount: 50_000, settings: d),
                      "默认「不限」，和以前一样")
    }

    func testThumbnailStartSize() {
        var s = AppearanceSettings()
        s.thumbnailStartSize = .p32
        XCTAssertFalse(ThumbnailPolicy.loadsThumbnail(isMedia: false, iconSide: 20, folderItemCount: 10, settings: s), "小于起始尺寸：通用图标")
        XCTAssertTrue(ThumbnailPolicy.loadsThumbnail(isMedia: false, iconSide: 32, folderItemCount: 10, settings: s))
        XCTAssertTrue(ThumbnailPolicy.loadsThumbnail(isMedia: true, iconSide: 20, folderItemCount: 10, settings: s), "总是预览图片和视频")
    }

    func testAlwaysPreviewOffUsesGenericIconsInBigFolders() {
        var s = AppearanceSettings()
        s.alwaysPreviewMedia = false
        XCTAssertTrue(ThumbnailPolicy.loadsThumbnail(isMedia: true, iconSide: 120, folderItemCount: 1000, settings: s))
        XCTAssertFalse(ThumbnailPolicy.loadsThumbnail(isMedia: true, iconSide: 120, folderItemCount: 1001, settings: s))
        XCTAssertFalse(ThumbnailPolicy.loadsThumbnail(isMedia: false, iconSide: 512, folderItemCount: 50_000, settings: s))
        s.thumbnailStartSize = .p64
        XCTAssertFalse(ThumbnailPolicy.loadsThumbnail(isMedia: true, iconSide: 48, folderItemCount: 10, settings: s), "关掉后图片也按起始尺寸")
    }

    // MARK: 透视文件夹

    private func entry(_ name: String, _ minutesAgo: Double, media: Bool = true, dir: Bool = false) -> PeekFolderLogic.Entry {
        PeekFolderLogic.Entry(name: name, isMedia: media, isDirectory: dir, date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    func testPickNewestMediaOnly() {
        let entries = [
            entry("旧.jpg", 100),
            entry("说明.pdf", 0, media: false),
            entry("新.png", 1),
            entry(".隐藏.jpg", 0),
            entry("素材", 0, dir: true),
            entry("片段.mov", 5),
            entry("中间.heic", 50),
        ]
        XCTAssertEqual(PeekFolderLogic.pickNewest(entries).map(\.name), ["新.png", "片段.mov", "中间.heic"])
        XCTAssertEqual(PeekFolderLogic.pickNewest(entries, limit: 2).map(\.name), ["新.png", "片段.mov"])
        XCTAssertEqual(PeekFolderLogic.pickNewest(entries, limit: 0), [])
    }

    func testPickNewestStableOnTies() {
        let entries = [entry("img10.jpg", 0), entry("img2.jpg", 0), entry("IMG1.jpg", 0)]
        XCTAssertEqual(PeekFolderLogic.pickNewest(entries).map(\.name), ["IMG1.jpg", "img2.jpg", "img10.jpg"], "同一时间按访达规则排名字")
    }

    func testPickNewestFewerThanLimit() {
        XCTAssertEqual(PeekFolderLogic.pickNewest([entry("a.jpg", 1)]).count, 1)
        XCTAssertEqual(PeekFolderLogic.pickNewest([entry("a.txt", 1, media: false)]).count, 0)
    }

    func testMediaNames() {
        XCTAssertTrue(PeekFolderLogic.isMediaName("海报.JPG"))
        XCTAssertTrue(PeekFolderLogic.isMediaName("clip.mp4"))
        XCTAssertTrue(PeekFolderLogic.isMediaName("设计稿.psd"))
        XCTAssertFalse(PeekFolderLogic.isMediaName("歌.mp3"), "音频不算")
        XCTAssertFalse(PeekFolderLogic.isMediaName("jpg"))
        XCTAssertFalse(PeekFolderLogic.isMediaName("readme"))
    }

    // MARK: 备选应用图标

    func testAltIconIDsOrderAndFiltering() {
        let names = ["cobalt.png", "zebra.png", "navy.png", "violet.png", "Bad Name.png", "default.png", "notes.txt", "alpha.PNG", "navy.png"]
        XCTAssertEqual(AltAppIconLogic.ids(fromFileNames: names), ["violet", "navy", "cobalt", "alpha", "zebra"])
    }

    func testAltIconValidIDs() {
        XCTAssertTrue(AltAppIconLogic.isValidID("navy"))
        XCTAssertTrue(AltAppIconLogic.isValidID("dark-2_b"))
        XCTAssertFalse(AltAppIconLogic.isValidID(nil))
        XCTAssertFalse(AltAppIconLogic.isValidID(""))
        XCTAssertFalse(AltAppIconLogic.isValidID("../x"))
        XCTAssertFalse(AltAppIconLogic.isValidID("Navy"))
        XCTAssertFalse(AltAppIconLogic.isValidID("紫色"))
    }

    func testAltIconResolve() {
        let available = ["violet", "navy"]
        XCTAssertEqual(AltAppIconLogic.resolve("navy", available: available, isPro: true), "navy")
        XCTAssertNil(AltAppIconLogic.resolve("navy", available: available, isPro: false), "没解锁 Pro 用默认图标")
        XCTAssertNil(AltAppIconLogic.resolve("gone", available: available, isPro: true), "文件不在了用默认图标")
        XCTAssertNil(AltAppIconLogic.resolve(nil, available: available, isPro: true))
    }

    func testBundledAltIconsMatchBuiltInOrder() {
        XCTAssertEqual(AltAppIconLogic.ids(fromFileNames: ["navy.png", "cobalt.png", "violet.png"]), AltAppIconLogic.builtInOrder)
    }
}
