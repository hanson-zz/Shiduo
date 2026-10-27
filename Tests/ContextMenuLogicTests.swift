import XCTest

/// 右键菜单补齐：打开方式、终端 / 编辑器、起名、剪切粘贴、直接删除文案。
final class ContextMenuLogicTests: XCTestCase {
    private func app(_ name: String, _ id: String?, path: String? = nil) -> OpenWithLogic.App {
        OpenWithLogic.App(path: path ?? "/Applications/\(name).app", bundleID: id, name: name)
    }

    func testCommonAppsKeepsFirstOrder() {
        let preview = app("预览", "com.apple.Preview")
        let ps = app("Photoshop", "com.adobe.Photoshop")
        let pixel = app("Pixelmator", "com.pixelmator")
        let a = [preview, ps, pixel]
        let b = [pixel, preview]
        XCTAssertEqual(OpenWithLogic.commonApps([a, b]), [preview, pixel])
        XCTAssertEqual(OpenWithLogic.commonApps([a]), a)
        XCTAssertEqual(OpenWithLogic.commonApps([]), [])
        // 同一个 App 装在不同位置也算同一个（按 Bundle ID）。
        let pixelElsewhere = app("Pixelmator", "com.pixelmator", path: "/Users/me/Applications/Pixelmator.app")
        XCTAssertEqual(OpenWithLogic.commonApps([a, [pixelElsewhere]]), [pixel])
    }

    func testCommonDefault() {
        let preview = app("预览", "com.apple.Preview")
        let ps = app("Photoshop", "com.adobe.Photoshop")
        XCTAssertEqual(OpenWithLogic.commonDefault([preview, preview]), preview)
        XCTAssertNil(OpenWithLogic.commonDefault([preview, ps]))
        XCTAssertNil(OpenWithLogic.commonDefault([preview, nil]))
        XCTAssertNil(OpenWithLogic.commonDefault([]))
    }

    func testOthersDedupesSortsAndDropsDefault() {
        let preview = app("预览", "com.apple.Preview")
        let zed = app("Zed", "dev.zed.Zed")
        let code = app("Code", "com.microsoft.VSCode")
        let codeOld = app("Code", "com.microsoft.VSCode", path: "/Applications/Old/Code.app")
        let noID = app("Tool", nil)
        let result = OpenWithLogic.others([zed, preview, code, codeOld, noID], excluding: preview)
        XCTAssertEqual(result.map(\.name), ["Code", "Tool", "Zed"])
        XCTAssertEqual(result.first?.path, code.path)
    }

    func testResolvePreferredTool() {
        let list = ExternalToolCatalog.editors
        // 选了 Zed 且装了：用 Zed。
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: "dev.zed.Zed", installed: ["dev.zed.Zed", "com.apple.TextEdit"], in: list)?.id, "dev.zed.Zed")
        // 选了但卸载了：用第一个装了的。
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: "dev.zed.Zed", installed: ["com.microsoft.VSCode", "com.apple.TextEdit"], in: list)?.id, "com.microsoft.VSCode")
        // 没选：VS Code 排在 Cursor 前面。
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: nil, installed: ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"], in: list)?.id, "com.microsoft.VSCode")
        // Sublime Text 3 的 Bundle ID 也认。
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: "com.sublimetext.4", installed: ["com.sublimetext.3"], in: list)?.id, "com.sublimetext.4")
        XCTAssertNil(ExternalToolCatalog.resolve(preferred: nil, installed: [], in: list))
        // 终端：没有别的就是系统终端。
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: "", installed: ["com.apple.Terminal"], in: ExternalToolCatalog.terminals)?.id, "com.apple.Terminal")
        XCTAssertEqual(ExternalToolCatalog.resolve(preferred: "com.mitchellh.ghostty", installed: ["com.apple.Terminal", "com.mitchellh.ghostty"], in: ExternalToolCatalog.terminals)?.name, "Ghostty")
    }

    func testTerminalFoldersAndEditorTargets() {
        let entries: [(path: String, isDirectory: Bool)] = [
            ("/Users/me/Projects/app", true),
            ("/Users/me/Projects/app/README.md", false),
            ("/Users/me/Projects/app/main.swift", false),
            ("/Users/me/Desktop/a.txt", false),
        ]
        XCTAssertEqual(ExternalToolCatalog.terminalFolders(entries), ["/Users/me/Projects/app", "/Users/me/Desktop"])
        let textEdit = ExternalToolCatalog.editors.first { $0.id == "com.apple.TextEdit" }!
        XCTAssertEqual(ExternalToolCatalog.editorTargets(entries, tool: textEdit).count, 3)
        let code = ExternalToolCatalog.editors[0]
        XCTAssertEqual(ExternalToolCatalog.editorTargets(entries, tool: code).count, 4)
    }

    func testUniqueNaming() {
        let taken: Set<String> = ["未命名", "未命名 2", "报告.pdf 替身"]
        XCTAssertEqual(NewItemNaming.unique("新的", exists: taken.contains), "新的")
        XCTAssertEqual(NewItemNaming.unique("未命名", exists: taken.contains), "未命名 3")
        XCTAssertEqual(NewItemNaming.aliasName(for: "报告.pdf", exists: taken.contains), "报告.pdf 替身 2")
        XCTAssertEqual(NewItemNaming.aliasName(for: "照片", exists: { _ in false }), "照片 替身")
        XCTAssertEqual(NewItemNaming.folderWithItemsName(exists: { _ in false }), "包含项目的新建文件夹")
        XCTAssertEqual(NewItemNaming.folderWithItemsName(exists: { $0 == "包含项目的新建文件夹" }), "包含项目的新建文件夹 2")
    }

    func testPasteMode() {
        XCTAssertEqual(FileClipboardLogic.mode(forceMove: true, cutChangeCount: nil, currentChangeCount: 5), .move)
        XCTAssertEqual(FileClipboardLogic.mode(forceMove: false, cutChangeCount: 5, currentChangeCount: 5), .move)
        // 剪切后剪贴板又被别的内容换掉了：拷贝。
        XCTAssertEqual(FileClipboardLogic.mode(forceMove: false, cutChangeCount: 5, currentChangeCount: 6), .copy)
        XCTAssertEqual(FileClipboardLogic.mode(forceMove: false, cutChangeCount: nil, currentChangeCount: 6), .copy)
    }

    func testPastePlan() {
        let paths = ["/a/b", "/a/b/c.txt", "/x/y.txt", "/a/dest"]
        // 粘贴到 /a/b/dest：/a/b 是目标的上层（不能粘进自己里面）。
        var plan = FileClipboardLogic.plan(paths, into: "/a/b/dest", mode: .copy)
        XCTAssertEqual(plan.paths, ["/a/b/c.txt", "/x/y.txt", "/a/dest"])
        XCTAssertEqual(plan.skippedSelf, 1)
        // 拷贝到同一个文件夹：可以（会起名「名称 2」）；移动到同一个文件夹：跳过。
        plan = FileClipboardLogic.plan(["/a/b/c.txt"], into: "/a/b/", mode: .copy)
        XCTAssertEqual(plan.paths, ["/a/b/c.txt"])
        plan = FileClipboardLogic.plan(["/a/b/c.txt", "/x/y.txt"], into: "/a/b", mode: .move)
        XCTAssertEqual(plan.paths, ["/x/y.txt"])
        XCTAssertEqual(plan.alreadyThere, 1)
        // 文件夹粘到它自己：跳过。
        plan = FileClipboardLogic.plan(["/a/dest"], into: "/a/dest", mode: .copy)
        XCTAssertEqual(plan.paths, [])
        XCTAssertEqual(plan.skippedSelf, 1)
        // 名字只是开头一样的不算上层。
        plan = FileClipboardLogic.plan(["/a/de"], into: "/a/dest", mode: .move)
        XCTAssertEqual(plan.paths, ["/a/de"])
    }

    func testDirectDeleteText() {
        XCTAssertTrue(DirectDeleteLogic.title(count: 1, firstName: "a.txt").contains("a.txt"))
        XCTAssertTrue(DirectDeleteLogic.title(count: 3, firstName: "a.txt").contains("3"))
        let withSize = DirectDeleteLogic.detail(count: 2, bytes: 2_000_000)
        XCTAssertTrue(withSize.contains("2"))
        XCTAssertTrue(withSize.contains("无法撤销"))
        XCTAssertTrue(withSize.contains(ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file)))
        let noSize = DirectDeleteLogic.detail(count: 5, bytes: nil)
        XCTAssertTrue(noSize.contains("5"))
        XCTAssertTrue(noSize.contains("无法撤销"))
    }
}
