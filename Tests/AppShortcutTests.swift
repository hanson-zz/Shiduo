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
        XCTAssertEqual(byDisplay["⇧⌘D"], .desktop)
        XCTAssertEqual(byDisplay["⇧⌘O"], .documents)
        XCTAssertEqual(byDisplay["⌥⌘L"], .downloads)
        XCTAssertEqual(byDisplay["⇧⌘N"], .newFolder)
        XCTAssertEqual(byDisplay["⌘["], .back)
        XCTAssertEqual(byDisplay["⌘]"], .forward)
        XCTAssertEqual(byDisplay["⌘↑"], .enclosingFolder)
        XCTAssertEqual(byDisplay["⌃⌘T"], .addToFolderWall)   // 访达：添加到侧边栏
        for finderOnly in ["⇧⌘K", "⇧⌘C", "⌘R", "⌥⌘I", "⇧⌘A", "⇧⌘G"] {
            XCTAssertNil(byDisplay[finderOnly], "\(finderOnly) 在访达里是别的意思")
        }
        // 系统级的组合键不用。
        for system in ["⌃⌘D", "⌃⌘F", "⌃⌘Q", "⌥⌘D"] {
            XCTAssertNil(byDisplay[system], system)
        }
    }

    func testDisplayOrder() {
        XCTAssertEqual(AppShortcut.addToShelf.display, "⌃⌘B")
        XCTAssertEqual(AppShortcut.refresh.display, "⌥⌘R")
        XCTAssertEqual(AppShortcut.openSelection.display, "⌘↓")
    }
}
