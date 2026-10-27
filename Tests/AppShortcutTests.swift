import SwiftUI
import XCTest

/// 菜单快捷键：不重复，和访达撞的组合键只做访达那件事。
final class AppShortcutTests: XCTestCase {
    func testNoDuplicateCombos() {
        var seen: [String: AppShortcut] = [:]
        for s in AppShortcut.allCases {
            XCTAssertNil(seen[s.display], "\(s) 和 \(seen[s.display].map { "\($0)" } ?? "") 都是 \(s.display)")
            seen[s.display] = s
        }
    }

    func testFinderCombosKeepFinderMeaning() {
        let byDisplay = Dictionary(uniqueKeysWithValues: AppShortcut.allCases.map { ($0.display, $0) })
        // 访达「前往」菜单里的这些，要么一样，要么不用。
        XCTAssertEqual(byDisplay["⇧⌘H"], .homeFolder)
        XCTAssertEqual(byDisplay["⇧⌘D"], .desktop)
        XCTAssertEqual(byDisplay["⇧⌘O"], .documents)
        XCTAssertEqual(byDisplay["⌥⌘L"], .downloads)
        XCTAssertEqual(byDisplay["⇧⌘N"], .newFolder)
        XCTAssertEqual(byDisplay["⌘["], .back)
        XCTAssertEqual(byDisplay["⌘]"], .forward)
        XCTAssertEqual(byDisplay["⌘↑"], .enclosingFolder)
        XCTAssertEqual(byDisplay["⌃⌘T"], .addToFolderWall)   // 访达：添加到侧边栏
        XCTAssertEqual(byDisplay["⇧⌘G"], .goToFolder)        // 访达：前往文件夹
        XCTAssertEqual(byDisplay["⇧⌘P"], .showPreview)       // 访达：显示预览（命令面板不抢）
        XCTAssertEqual(byDisplay["⌃⌘P"], .commandPalette)
        XCTAssertEqual(byDisplay["⌘L"], .addressBar)
        // 右键菜单补齐：和访达同样的组合键做同样的事。
        XCTAssertEqual(byDisplay["⌘X"], .cut)
        XCTAssertEqual(byDisplay["⌘C"], .copyItems)
        XCTAssertEqual(byDisplay["⌘V"], .paste)
        XCTAssertEqual(byDisplay["⌥⌘V"], .pasteAndMove)
        XCTAssertEqual(byDisplay["⌥⌘C"], .copyPath)
        XCTAssertEqual(byDisplay["⌃⌘N"], .newFolderWithSelection)
        XCTAssertEqual(byDisplay["⌃⌘A"], .makeAlias)
        XCTAssertEqual(byDisplay["⌥⌘⌫"], .deleteImmediately)
        XCTAssertEqual(byDisplay["⌃⌘C"], .copyText)
        XCTAssertEqual(byDisplay["⌘D"], .duplicate)
        // 标签页：⌘T / ⌘W 和访达一样（新建标签页 / 关闭标签页）。
        XCTAssertEqual(byDisplay["⌘T"], .newTab)
        XCTAssertEqual(byDisplay["⌘W"], .closeTab)
        // ⌥⌘1…9 留给收藏（不在这张表里，菜单里按收藏动态生成）
        for digit in 1...9 { XCTAssertNil(byDisplay["⌥⌘\(digit)"]) }
        for finderOnly in ["⇧⌘K", "⇧⌘C", "⌘R", "⌥⌘I", "⌃⌘I", "⇧⌘A", "⇧⌘U", "⇧⌘I", "⇧⌘F", "⇧⌘R", "⌘E"] {
            XCTAssertNil(byDisplay[finderOnly], "\(finderOnly) 在访达里是别的意思")
        }
        // 系统级的组合键不用。
        for system in ["⌃⌘D", "⌃⌘F", "⌃⌘Q", "⌥⌘D", "⌃⌘空格"] {
            XCTAssertNil(byDisplay[system], system)
        }
    }

    func testTabAndPaneShortcuts() {
        XCTAssertEqual(AppShortcut.nextTab.display, "⌃⇥")
        XCTAssertEqual(AppShortcut.previousTab.display, "⌃⇧⇥")
        XCTAssertEqual(AppShortcut.nextTabAlt.display, "⇧⌘]")
        XCTAssertEqual(AppShortcut.previousTabAlt.display, "⇧⌘[")
        XCTAssertEqual(AppShortcut.closeWindow.display, "⇧⌘W")
        XCTAssertEqual(AppShortcut.dualHorizontal.display, "⌘\\")
        XCTAssertEqual(AppShortcut.dualVertical.display, "⌥⌘\\")
        XCTAssertEqual(AppShortcut.focusFirstPane.display, "⌥⌘←")
        XCTAssertEqual(AppShortcut.focusSecondPane.display, "⌥⌘→")
        XCTAssertEqual(AppShortcut.copyToOtherPane.display, "⌥⇧⌘C")
        XCTAssertEqual(AppShortcut.moveToOtherPane.display, "⌥⇧⌘M")
        // 双栏不占系统的 ⌥⌘D（隐藏程序坞），也不占 ⌘1 / ⌘2（为图标 / 为列表）。
        let all = Set(AppShortcut.allCases.map(\.display))
        XCTAssertFalse(all.contains("⌥⌘D"))
        XCTAssertEqual(AppShortcut.asIcons.display, "⌘1")
    }

    /// 出厂快捷键一个都不在「不能用」的表里（设置里改快捷键时也用这张表挡）。
    func testDefaultsAvoidReservedList() {
        for s in AppShortcut.allCases {
            XCTAssertNil(ReservedShortcuts.list[s.display], "\(s) 的 \(s.display) 是 \(ReservedShortcuts.list[s.display] ?? "")")
        }
        // 测试里列过的访达 / 系统组合键都在表里。
        for combo in ["⇧⌘K", "⇧⌘C", "⌘R", "⌥⌘I", "⌃⌘I", "⇧⌘A", "⇧⌘U", "⇧⌘I", "⇧⌘F", "⇧⌘R", "⌘E",
                      "⌃⌘D", "⌃⌘F", "⌃⌘Q", "⌥⌘D", "⌃⌘空格", "⌥⌘1", "⌥⌘9"] {
            XCTAssertNotNil(ReservedShortcuts.list[combo], combo)
        }
    }

    /// KeyCombo 的写法和 AppShortcut.display 一模一样（设置里的表、菜单、悬停提示都对得上）。
    func testDefaultComboMatchesDisplay() {
        for s in AppShortcut.allCases {
            XCTAssertEqual(s.defaultCombo?.display, s.display, "\(s)")
            XCTAssertEqual(s.defaultCombo?.eventModifiers, s.modifiers, "\(s)")
            XCTAssertEqual(s.defaultCombo?.keyEquivalent, s.key, "\(s)")
        }
    }

    func testDisplayOrder() {
        XCTAssertEqual(AppShortcut.addToShelf.display, "⌃⌘B")
        XCTAssertEqual(AppShortcut.refresh.display, "⌥⌘R")
        XCTAssertEqual(AppShortcut.openSelection.display, "⌘↓")
        XCTAssertEqual(AppShortcut.imageTools.display, "⌃⌘E")
        XCTAssertEqual(AppShortcut.home.display, "⌃⌘H")
        XCTAssertEqual(AppShortcut.homeFolder.display, "⇧⌘H")
    }
}
