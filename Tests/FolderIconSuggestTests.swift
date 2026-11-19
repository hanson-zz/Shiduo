import AppKit
import XCTest

final class FolderIconSuggestTests: XCTestCase {
    private func topic(_ name: String) -> String? { FolderIconSuggest.matches(for: name).first?.topic }
    private func topics(_ name: String) -> [String] { FolderIconSuggest.matches(for: name).map(\.topic) }

    func testUserExamples() {
        let shots = FolderIconSuggest.suggestions(for: "截图")
        XCTAssertEqual(shots.first?.topic, "screenshot")
        XCTAssertEqual(shots.first?.style.overlay, .symbol("camera.viewfinder"))
        XCTAssertEqual(shots.first?.keyword, "截图")

        let design = FolderIconSuggest.suggestions(for: "设计素材")
        XCTAssertEqual(design.first?.topic, "design")
        XCTAssertTrue(design.contains { $0.topic == "assets" }, "设计素材 也要推荐素材库图标")
    }

    func testCommonNamesInEveryLanguage() {
        let expected: [String: String] = [
            "截图": "screenshot", "截屏": "screenshot", "Screenshots": "screenshot", "screenshot": "screenshot",
            "jietu": "screenshot", "jt": "screenshot", "Screen Shots": "screenshot", "ScreenShots": "screenshot",
            "Screen-Shot 2026": "screenshot", "SCREENSHOT": "screenshot",
            "设计": "design", "设计素材": "design", "design": "design", "UI": "design", "Figma": "design", "PSD": "design",
            "sheji": "design", "素材": "assets", "assets": "assets", "sucai": "assets",
            "照片": "photos", "图片": "photos", "photos": "photos", "Pictures": "photos", "tupian": "photos",
            "下载": "downloads", "Downloads": "downloads", "xiazai": "downloads",
            "文档": "documents", "docs": "documents", "Documents": "documents", "wendang": "documents",
            "合同": "contract", "hetong": "contract", "发票": "finance", "财务": "finance", "invoice": "finance",
            "Invoices": "finance", "fapiao": "finance",
            "视频": "videos", "movies": "videos", "Videos": "videos", "Movies": "videos",
            "音乐": "music", "Music": "music", "项目": "projects", "projects": "projects", "My Projects": "projects",
            "MyProjects": "projects", "code": "code", "开发": "code", "Developer": "code",
            "备份": "backup", "Backup": "backup", "Time Machine": "backup",
            "客户": "clients", "clients": "clients", "经销商": "clients", "kehu": "clients",
            "归档": "archive", "Archive": "archive", "桌面": "desktop", "Desktop": "desktop",
            "字体": "fonts", "Fonts": "fonts", "工作": "work", "work": "work", "学习": "study", "课程": "study",
            "旅行": "travel", "旅行-日本": "travel", "家庭": "family", "宠物": "pets", "猫咪": "cat", "熊猫": "panda",
            "烘焙": "baking", "蛋糕": "baking", "星空": "space", "苹果": "apple", "游戏": "games", "AI": "ai",
            "ChatGPT": "ai", "壁纸": "wallpaper", "笔记": "notes", "Public": "share", "Applications": "apps",
            "发票2025": "finance", "pictures_2024": "photos", "homework": "study", "Photoshop素材": "design",
        ]
        for (name, want) in expected {
            XCTAssertEqual(topic(name), want, "「\(name)」")
        }
    }

    func testMixedNames() {
        XCTAssertEqual(topics("2026 设计素材 final").prefix(2), ["design", "assets"])
        let mixed = topics("客户-截图")
        XCTAssertTrue(mixed.contains("clients") && mixed.contains("screenshot"), "\(mixed)")
        let both = FolderIconSuggest.suggestions(for: "客户-截图")
        XCTAssertTrue(both.prefix(2).contains { $0.topic == "clients" } && both.prefix(2).contains { $0.topic == "screenshot" },
                      "两个主题都对得上时轮流各取一款")
        XCTAssertEqual(Set(topics("宝宝照片").prefix(2)), ["baby", "photos"])
        XCTAssertEqual(topics("shejisucai").prefix(2), ["design", "assets"])
        XCTAssertEqual(topics("backup_old").first, "backup")
    }

    func testFullwidthAndTraditional() {
        XCTAssertEqual(topic("ＳＣＲＥＥＮＳＨＯＴ"), "screenshot")
        XCTAssertEqual(topic("截圖"), "screenshot")
        XCTAssertEqual(topic("設計素材"), "design")
    }

    func testNoFalsePositives() {
        for name in ["未命名文件夹", "未命名文件夹 2", "包含项目的新建文件夹", "untitled folder", "Untitled Folder 3", "New Folder",
                     "network", "symbolic", "钢琴", "2026", "---", "", "   ", "abc", "final v2"] {
            XCTAssertTrue(FolderIconSuggest.suggestions(for: name).isEmpty, "「\(name)」不该有推荐：\(topics(name))")
        }
        XCTAssertFalse(topics("Photoshop素材").contains("photos"), "photoshop 不算 photos")
        XCTAssertEqual(topics("汪总客户"), ["clients"])
    }

    func testLimitAndUniqueStyles() {
        for name in ["截图", "客户-截图", "2026 设计素材 final", "旅行照片视频音乐文档", "猫咪宠物狗狗"] {
            let list = FolderIconSuggest.suggestions(for: name)
            XCTAssertLessThanOrEqual(list.count, FolderIconSuggest.defaultLimit, name)
            XCTAssertEqual(Set(list.map(\.style)).count, list.count, "\(name) 推荐不重复")
            XCTAssertFalse(list.isEmpty, name)
            XCTAssertTrue(list.allSatisfy { !$0.reason.isEmpty })
        }
        XCTAssertEqual(FolderIconSuggest.suggestions(for: "旅行照片视频音乐文档").count, FolderIconSuggest.defaultLimit)
        XCTAssertEqual(FolderIconSuggest.suggestions(for: "截图", limit: 2).count, 2)
        XCTAssertTrue(FolderIconSuggest.suggestions(for: "截图", limit: 0).isEmpty)
        XCTAssertEqual(FolderIconSuggest.best(for: "Downloads")?.topic, "downloads")
        XCTAssertNil(FolderIconSuggest.best(for: "未命名文件夹"))
    }

    func testParentFallback() {
        let inside = FolderIconSuggest.suggestions(for: "2026-11", parentName: "截图")
        XCTAssertEqual(inside.first?.topic, "screenshot")
        XCTAssertTrue(inside.first?.reason.contains("截图") == true)
        // 名字自己认得出来时不看上层
        XCTAssertEqual(FolderIconSuggest.suggestions(for: "发票", parentName: "截图").first?.topic, "finance")
        XCTAssertTrue(FolderIconSuggest.suggestions(for: "2026-11", parentName: nil).isEmpty)
    }

    func testThemedSuggestionsUseRealThemes() {
        XCTAssertEqual(FolderIconSuggest.suggestions(for: "熊猫").first?.style.theme, "animal/panda")
        XCTAssertEqual(FolderIconSuggest.suggestions(for: "蛋糕").first?.style.theme, "food/cake")
        XCTAssertTrue(FolderIconSuggest.suggestions(for: "旅行").contains { $0.style.theme == "building/eiffel" })
    }

    /// 表里每一行都解析得出来、主题图标和 SF 符号都真的存在。
    func testTableIntegrity() throws {
        let lines = FolderIconSuggest.table.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(FolderIconSuggest.topics.count, lines.count, "每一行都要解析成功（6 栏、至少一款能用的样式）")
        XCTAssertEqual(Set(FolderIconSuggest.topics.map(\.id)).count, FolderIconSuggest.topics.count, "主题 ID 不重复")
        XCTAssertGreaterThan(FolderIconSuggest.keywordCount, 800)
        for line in lines {
            let presets = line.split(separator: "|", omittingEmptySubsequences: false).last?.split(separator: " ") ?? []
            for preset in presets {
                XCTAssertNotNil(FolderIconSuggest.style(from: String(preset)), "\(preset) 认不出来")
            }
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for topic in FolderIconSuggest.topics {
            for style in topic.styles {
                if let theme = style.theme {
                    XCTAssertTrue(FolderThemeCatalog.allThemes.contains(theme), theme)
                    let path = resources.appendingPathComponent(FolderThemeCatalog.resourcePath(theme) ?? "?").path
                    XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
                }
                if case .symbol(let name) = style.overlay {
                    XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "SF 符号 \(name) 不存在")
                }
            }
        }
    }
}
