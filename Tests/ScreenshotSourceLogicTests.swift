import XCTest

/// 截图工具的存放文件夹：路径整理、只认专用文件夹、文件夹匹配、读偏好设置和 ini。
final class ScreenshotSourceLogicTests: XCTestCase {
    private let home = "/Users/han"
    private typealias L = ScreenshotSourceLogic

    func testNormalizedPath() {
        XCTAssertEqual(L.normalizedPath("~/Pictures/截图", home: home), "/Users/han/Pictures/截图")
        XCTAssertEqual(L.normalizedPath("/Users/han/Shots/", home: home), "/Users/han/Shots")
        XCTAssertEqual(L.normalizedPath("file:///Users/han/My%20Shots/", home: home), "/Users/han/My Shots")
        XCTAssertEqual(L.normalizedPath("\"~/Shots\"", home: home), "/Users/han/Shots")
        XCTAssertEqual(L.normalizedPath("~", home: home), "/Users/han")
        XCTAssertNil(L.normalizedPath("", home: home))
        XCTAssertNil(L.normalizedPath("Desktop", home: home))
        XCTAssertNil(L.normalizedPath("https://example.com/a", home: home))
    }

    func testOnlyDedicatedFolders() {
        for general in ["/Users/han", "/Users/han/Desktop", "/Users/han/downloads", "/Users/han/Documents",
                        "/Users/han/Pictures", "/Users/han/Library/Mobile Documents/com~apple~CloudDocs",
                        "/", "/Users", "/Volumes"] {
            XCTAssertFalse(L.isDedicated(general, home: home), general)
        }
        for dedicated in ["/Users/han/Pictures/Screenshots", "/Users/han/Desktop/截图",
                          "/Users/han/Library/Application Support/Snapok/History", "/Volumes/Data/Shots"] {
            XCTAssertTrue(L.isDedicated(dedicated, home: home), dedicated)
        }
    }

    func testFolderMatching() {
        let folders = [
            L.Folder(path: "/Users/han/Library/Application Support/Snapok/History", excludedNames: ["thumbnail.png"]),
            L.Folder(path: "/Users/han/Pictures/Shots"),
        ]
        let snap = "/Users/han/Library/Application Support/Snapok/History/7F1C/"
        XCTAssertTrue(L.isInScreenshotFolder(snap + "original.png", folders: folders))
        XCTAssertFalse(L.isInScreenshotFolder(snap + "thumbnail.png", folders: folders))
        XCTAssertFalse(L.isInScreenshotFolder(snap + "Thumbnail.PNG", folders: folders))
        XCTAssertTrue(L.isInScreenshotFolder("/Users/han/pictures/shots/a.png", folders: folders))
        // 名字开头一样的兄弟文件夹不算。
        XCTAssertFalse(L.isInScreenshotFolder("/Users/han/Pictures/Shots2/a.png", folders: folders))
        XCTAssertFalse(L.isInScreenshotFolder("/Users/han/Pictures/Shots", folders: folders))
        XCTAssertFalse(L.isInScreenshotFolder("/Users/han/Pictures/a.png", folders: []))
    }

    func testFolderRuleNeedsImage() {
        let folders = [L.Folder(path: "/Users/han/Pictures/Shots")]
        XCTAssertTrue(ScreenshotNameRules.isScreenshot(name: "a.png", typeTree: ["public.png", "public.image"], systemFlag: false,
                                                       path: "/Users/han/Pictures/Shots/a.png", folders: folders))
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "a.mov", typeTree: ["com.apple.quicktime-movie"], systemFlag: false,
                                                        path: "/Users/han/Pictures/Shots/a.mov", folders: folders))
        XCTAssertFalse(ScreenshotNameRules.isScreenshot(name: "a.png", typeTree: ["public.image"], systemFlag: false,
                                                        path: "/Users/han/Pictures/Other/a.png", folders: folders))
    }

    func testCleanedDropsGeneralDuplicatesAndChildren() {
        let out = L.cleaned([
            L.Folder(path: "/Users/han/Desktop"),
            L.Folder(path: "/Users/han/Pictures/Shots"),
            L.Folder(path: "/Users/han/pictures/shots", excludedNames: ["thumbnail.png"]),
            L.Folder(path: "/Users/han/Pictures/Shots/2024"),
            L.Folder(path: "/Users/han/Shots"),
        ], home: home)
        XCTAssertEqual(out.map(\.path), ["/Users/han/Pictures/Shots", "/Users/han/Shots"])
        XCTAssertEqual(out.first?.excludedNames, ["thumbnail.png"])
    }

    func testPreferencesKnownAndGuessedKeys() {
        let prefs: [String: Any] = [
            "location": "~/Pictures/截图",
            "exportPath": "/Users/han/CleanShot",
            "screenshotSaveFolder": "file:///Users/han/Shots/",
            "lastSaveDirectoryName": 3,          // 不是字符串
            "windowFrame": "{{0, 0}, {10, 10}}", // 键名不像
            "saveFormat": "png",                 // 键名不像存放位置
        ]
        let out = L.folders(fromPreferences: prefs, keys: ["location"], home: home)
        XCTAssertEqual(out.first, "/Users/han/Pictures/截图")
        XCTAssertTrue(out.contains("/Users/han/CleanShot"))
        XCTAssertTrue(out.contains("/Users/han/Shots"))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(L.folders(fromPreferences: ["history.location": "/Users/han/SnapLib"], keys: ["history.location"], home: home),
                       ["/Users/han/SnapLib"])
    }

    func testLooksLikeFolderKey() {
        XCTAssertTrue(L.looksLikeFolderKey("savePath"))
        XCTAssertTrue(L.looksLikeFolderKey("auto_save_dir"))
        XCTAssertTrue(L.looksLikeFolderKey("ScreenshotLocation"))
        XCTAssertFalse(L.looksLikeFolderKey("saveFormat"))
        XCTAssertFalse(L.looksLikeFolderKey("windowLocation"))
    }

    func testParseINI() {
        let ini = """
        ; Snipaste
        [General]
        language=zh_CN
        [Output]
        auto_save_path = ~/Pictures/Snipaste
        quick_save_path=/Users/han/Desktop
        file_name_pattern=Snipaste_$yyyy-MM-dd_HH-mm-ss$

        # comment
        broken line
        """
        let values = L.parseINI(ini)
        XCTAssertEqual(values["general.language"], "zh_CN")
        XCTAssertEqual(values["output.auto_save_path"], "~/Pictures/Snipaste")
        XCTAssertNil(values["broken line"])
        let folders = L.folders(fromINI: ini, home: home)
        XCTAssertEqual(folders, ["/Users/han/Pictures/Snipaste", "/Users/han/Desktop"])
        // 桌面会在 cleaned 里被去掉（不是专用文件夹）。
        XCTAssertEqual(L.cleaned(folders.map { L.Folder(path: $0) }, home: home).map(\.path), ["/Users/han/Pictures/Snipaste"])
    }

    func testKnownToolsIncludeOpenSourceOnes() {
        let snapok = L.tools.first { $0.id == "snapok" }
        XCTAssertEqual(snapok?.bundleIDs.first, "ai.thinkany.snapok")
        XCTAssertEqual(snapok?.excludedNames, ["thumbnail.png"])
        XCTAssertTrue(snapok?.defaultFolders.contains("Library/Application Support/Snapok/History") ?? false)
        XCTAssertEqual(L.tools.first { $0.id == "quickshot" }?.bundleIDs, ["com.quickshot.app"])
        XCTAssertEqual(Set(L.tools.map(\.id)).count, L.tools.count)
    }
}
