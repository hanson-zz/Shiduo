import SwiftUI
import XCTest

/// 拾掇 Pro 自定义快捷键：冲突检测（拾掇别的命令 / 系统和访达 / 没带 ⌘⌃）、交换、清空、恢复默认、存取和导入。
final class ShortcutSettingsTests: XCTestCase {
    private let cmdX = KeyCombo(key: "x", modifiers: [.command])
    private let free = KeyCombo(key: "p", modifiers: [.control, .option, .command])   // ⌃⌥⌘P 没人用

    func testDefaults() {
        let settings = ShortcutSettings()
        XCTAssertEqual(settings.combo(for: .cut), cmdX)
        XCTAssertEqual(settings.combo(for: .cut)?.display, "⌘X")
        XCTAssertEqual(settings.holder(of: cmdX), .cut)
        XCTAssertNil(settings.holder(of: free))
        XCTAssertTrue(settings.isEmpty)
        for s in AppShortcut.allCases { XCTAssertFalse(settings.isCustomized(s)) }
    }

    func testAssignAndConflicts() {
        var settings = ShortcutSettings()
        XCTAssertNil(settings.assign(free, to: .copyPath))
        XCTAssertEqual(settings.combo(for: .copyPath), free)
        XCTAssertTrue(settings.isCustomized(.copyPath))
        // 原来的 ⌥⌘C 空出来了。
        XCTAssertNil(settings.holder(of: KeyCombo(key: "c", modifiers: [.option, .command])))

        // 和拾掇另一个命令重复：不改。
        XCTAssertEqual(settings.assign(cmdX, to: .copyPath), .command(.cut))
        XCTAssertEqual(settings.combo(for: .copyPath), free)
        // 系统 / 访达 / 拾掇别处在用。
        XCTAssertEqual(settings.conflict(KeyCombo(key: "q", modifiers: [.command]), for: .refresh), .reserved(ReservedShortcuts.list["⌘Q"]!))
        if case .reserved? = settings.conflict(KeyCombo(key: "3", modifiers: [.option, .command]), for: .refresh) {} else {
            XCTFail("⌥⌘3 是收藏")
        }
        if case .reserved? = settings.conflict(KeyCombo(key: "k", modifiers: [.shift, .command]), for: .refresh) {} else {
            XCTFail("⇧⌘K 是访达「网络」")
        }
        if case .reserved? = settings.conflict(KeyCombo(key: "space", modifiers: [.command]), for: .refresh) {} else {
            XCTFail("⌘空格 是聚焦")
        }
        // 没带 ⌘ 也没带 ⌃。
        XCTAssertEqual(settings.conflict(KeyCombo(key: "x", modifiers: []), for: .cut), .needsModifier)
        XCTAssertEqual(settings.conflict(KeyCombo(key: "x", modifiers: [.shift, .option]), for: .cut), .needsModifier)
        // 改回它自己现在的组合键不算冲突。
        XCTAssertNil(settings.conflict(cmdX, for: .cut))
        // 改成默认值：等于恢复默认，不再算改过。
        XCTAssertNil(settings.assign(KeyCombo(key: "c", modifiers: [.option, .command]), to: .copyPath))
        XCTAssertFalse(settings.isCustomized(.copyPath))
        XCTAssertTrue(settings.isEmpty)
        XCTAssertFalse(ShortcutConflict.command(.cut).message.isEmpty)
    }

    func testSwap() {
        var settings = ShortcutSettings()
        let copyPathDefault = AppShortcut.copyPath.defaultCombo
        XCTAssertEqual(settings.swap(cmdX, to: .copyPath), .cut)
        XCTAssertEqual(settings.combo(for: .copyPath), cmdX)
        XCTAssertEqual(settings.combo(for: .cut), copyPathDefault)
        XCTAssertEqual(settings.holder(of: cmdX), .copyPath)
        // 每个组合键只有一个命令在用。
        assertNoDuplicates(settings)
        // 不是「和别的命令重复」时不能换。
        XCTAssertNil(settings.swap(KeyCombo(key: "q", modifiers: [.command]), to: .refresh))
        XCTAssertNil(settings.swap(free, to: .refresh))
        XCTAssertEqual(settings.combo(for: .refresh), AppShortcut.refresh.defaultCombo)
        // 自己没有快捷键时换过去：对方变成没有。
        settings.clear(.viewOptions)
        XCTAssertEqual(settings.swap(KeyCombo(key: "r", modifiers: [.option, .command]), to: .viewOptions), .refresh)
        XCTAssertNil(settings.combo(for: .refresh))
        XCTAssertEqual(settings.combo(for: .viewOptions)?.display, "⌥⌘R")
        assertNoDuplicates(settings)
        // 交换过的存起来再读回来不变（两个都改成了对方的默认键，也不算冲突）。
        let back = ShortcutSettings.decode(settings.encoded()!)
        XCTAssertEqual(back, settings)
    }

    func testClearResetAndOverrideWinsOverDefault() {
        var settings = ShortcutSettings()
        let refresh = KeyCombo(key: "r", modifiers: [.option, .command])
        settings.clear(.refresh)
        XCTAssertNil(settings.combo(for: .refresh))
        XCTAssertTrue(settings.isCustomized(.refresh))
        // 空出来的组合键可以给别的命令。
        XCTAssertNil(settings.assign(refresh, to: .viewOptions))
        // 恢复默认：刷新的默认键已经被用户给了别的命令 → 用户改的赢，刷新先没有快捷键（不会两个菜单项同一个键）。
        settings.reset(.refresh)
        XCTAssertFalse(settings.isCustomized(.refresh))
        XCTAssertNil(settings.combo(for: .refresh))
        XCTAssertEqual(settings.combo(for: .viewOptions), refresh)
        assertNoDuplicates(settings)
        settings.reset(.viewOptions)
        XCTAssertEqual(settings.combo(for: .refresh), refresh)
        XCTAssertEqual(settings.combo(for: .viewOptions)?.display, "⌘J")

        // 全部恢复默认：认识的都回去，不认识的（更新版本存的）留着。
        settings.assign(free, to: .search)
        settings.clear(.cut)
        settings.overrides["futureCommand"] = free
        settings.resetAll()
        XCTAssertEqual(settings.overrides, ["futureCommand": free])
        XCTAssertTrue(settings.cleared.isEmpty)
        for s in AppShortcut.allCases { XCTAssertEqual(settings.combo(for: s), s.defaultCombo, "\(s)") }
    }

    func testPersistence() throws {
        let suite = "ShortcutSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ShortcutSettings.load(from: defaults), ShortcutSettings())
        var settings = ShortcutSettings()
        settings.assign(free, to: .copyPath)
        settings.clear(.refresh)
        settings.save(to: defaults)
        XCTAssertNotNil(defaults.data(forKey: ShortcutSettings.defaultsKey))
        let loaded = ShortcutSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.combo(for: .copyPath), free)
        XCTAssertNil(loaded.combo(for: .refresh))
        // 全部恢复默认后存：不留数据。
        var reset = loaded
        reset.resetAll()
        reset.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: ShortcutSettings.defaultsKey))
        // 坏数据：当没改过。
        defaults.set(Data("坏的".utf8), forKey: ShortcutSettings.defaultsKey)
        XCTAssertEqual(ShortcutSettings.load(from: defaults), ShortcutSettings())
    }

    func testDecodeDropsInvalidOverrides() throws {
        let json = """
        {"version": 0,
         "overrides": {
           "copyPath": {"key": "p", "modifiers": 11},
           "refresh": {"key": "q", "modifiers": 8},
           "search": {"key": "z", "modifiers": 4},
           "viewOptions": {"key": "p", "modifiers": 11},
           "toggleSidebar": {"oops": true},
           "futureCommand": {"key": "y", "modifiers": 9}
         },
         "cleared": ["cut", "futureThing"]}
        """
        let settings = try XCTUnwrap(ShortcutSettings.decode(Data(json.utf8)))
        XCTAssertEqual(settings.version, ShortcutSettings.currentVersion)
        // ⌃⌥⌘P 两个命令都要：留排在前面的 viewOptions，copyPath 用回默认；⌘Q 被占用；⇧Z 没带 ⌘⌃；坏条目跳过。
        XCTAssertEqual(settings.combo(for: .viewOptions), free)
        XCTAssertEqual(settings.combo(for: .copyPath), AppShortcut.copyPath.defaultCombo)
        XCTAssertEqual(settings.combo(for: .refresh), AppShortcut.refresh.defaultCombo)
        XCTAssertEqual(settings.combo(for: .search), AppShortcut.search.defaultCombo)
        XCTAssertEqual(settings.combo(for: .toggleSidebar), AppShortcut.toggleSidebar.defaultCombo)
        XCTAssertNil(settings.combo(for: .cut))
        // 不认识的命令留着。
        XCTAssertNotNil(settings.overrides["futureCommand"])
        XCTAssertTrue(settings.cleared.contains("futureThing"))
        assertNoDuplicates(settings)
        XCTAssertNil(ShortcutSettings.decode(Data("[]".utf8)))
    }

    func testExportImport() throws {
        var shortcuts = ShortcutSettings()
        shortcuts.swap(cmdX, to: .copyPath)
        var menu = MenuCatalog.defaultLayout(.file)
        menu.setHidden("zip", true)
        let file = MenuShortcutsExport(shortcuts: shortcuts, fileMenu: menu, backgroundMenu: nil)
        let data = try XCTUnwrap(file.encoded())
        let back = try XCTUnwrap(MenuShortcutsExport.decode(data))
        XCTAssertEqual(back.shortcuts, shortcuts)
        XCTAssertEqual(back.fileMenu, menu)
        XCTAssertNil(back.backgroundMenu)
        // 别的 JSON：不认。
        XCTAssertNil(MenuShortcutsExport.decode(Data(#"{"format":"other","version":1,"shortcuts":{}}"#.utf8)))
        XCTAssertNil(MenuShortcutsExport.decode(Data("{}".utf8)))
    }

    func testKeyFromEvent() {
        XCTAssertEqual(KeyCombo.key(keyCode: 126, characters: nil), "up")
        XCTAssertEqual(KeyCombo.key(keyCode: 51, characters: "\u{7F}"), "delete")
        XCTAssertEqual(KeyCombo.key(keyCode: 48, characters: "\t"), "tab")
        XCTAssertEqual(KeyCombo.key(keyCode: 0, characters: "A"), "a")
        XCTAssertEqual(KeyCombo.key(keyCode: 30, characters: "]"), "]")
        XCTAssertNil(KeyCombo.key(keyCode: 999, characters: "\u{1}"))
        XCTAssertNil(KeyCombo.key(keyCode: 999, characters: nil))
        // 名字和显示
        XCTAssertEqual(KeyCombo(key: "up", modifiers: [.command]).display, "⌘↑")
        XCTAssertEqual(KeyCombo(key: "delete", modifiers: [.option, .command]).display, "⌥⌘⌫")
        XCTAssertEqual(KeyCombo(key: "C", modifiers: [.control, .command]).key, "c")
        XCTAssertEqual(KeyCombo(.tab, [.control, .shift]).display, "⌃⇧⇥")
        XCTAssertEqual(KeyCombo(key: "left", modifiers: [.option]).keyEquivalent, .leftArrow)
    }

    private func assertNoDuplicates(_ settings: ShortcutSettings, file: StaticString = #filePath, line: UInt = #line) {
        var seen: [KeyCombo: AppShortcut] = [:]
        for s in AppShortcut.allCases {
            guard let combo = settings.combo(for: s) else { continue }
            XCTAssertNil(seen[combo], "\(s) 和 \(seen[combo].map { "\($0)" } ?? "") 都是 \(combo.display)", file: file, line: line)
            seen[combo] = s
        }
    }
}
