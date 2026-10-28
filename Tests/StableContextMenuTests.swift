import AppKit
import SwiftUI
import XCTest

/// beta.5 真机崩溃（macOS 27.2）：右键菜单开着时 SwiftUI 重算 `.contextMenu` 内容 → -[NSMenu setItemArray:]
/// → AppKit 布局断言。这里守住修法的三件事：
/// 1. 只有右键 / Control-点按才被透明层接住；
/// 2. 菜单在右键那一刻取一次快照，宿主之后重画（换 makeMenu）不碰已经弹出的菜单；
/// 3. 文件 / 文件夹右键菜单都走 stableContextMenu，菜单内容不订阅会变的单例。
@MainActor
final class StableContextMenuTests: XCTestCase {

    // MARK: 1. 哪些事件弹菜单

    func testOnlyRightClickAndControlClickOpenMenu() {
        XCTAssertTrue(StableContextMenuLogic.opensMenu(type: .rightMouseDown, modifiers: []))
        XCTAssertTrue(StableContextMenuLogic.opensMenu(type: .rightMouseDown, modifiers: [.command]))
        XCTAssertTrue(StableContextMenuLogic.opensMenu(type: .leftMouseDown, modifiers: [.control]))
        XCTAssertTrue(StableContextMenuLogic.opensMenu(type: .leftMouseDown, modifiers: [.control, .shift]))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .leftMouseDown, modifiers: []))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .leftMouseDown, modifiers: [.command]))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .leftMouseDragged, modifiers: [.control]))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .mouseMoved, modifiers: []))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .otherMouseDown, modifiers: []))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .scrollWheel, modifiers: []))
        XCTAssertFalse(StableContextMenuLogic.opensMenu(type: .rightMouseUp, modifiers: []))
    }

    // MARK: 2. 菜单是快照

    private final class Box { var value = 1 }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.update()
        return menu.items.map(\.title).filter { !$0.isEmpty }
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOpenMenuIsNotRewrittenWhenHostRerenders() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("NSHostingMenu 需要 macOS 15") }
        _ = NSApplication.shared
        let box = Box()
        let view = StableContextMenuView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        // 宿主第一次渲染：菜单闭包读的是右键那一刻的值。
        view.makeMenu = { [value = box.value] in
            AnyView(Group {
                Button("项目 \(value)") {}
                Divider()
                Button("另一项") {}
            })
        }
        let menu = try XCTUnwrap(view.buildMenu())
        XCTAssertEqual(view.builtCount, 1)
        spin()
        let before = titles(menu)
        // CI 只把带「PERF|」的行打到日志里：借这个前缀说明快照测试是真跑了还是跳过了（不是性能数据）。
        print("PERF| 右键菜单快照测试（非性能）：NSHostingMenu 生成了 \(before.count) 项 \(before)")
        if before.isEmpty { throw XCTSkip("这个环境里 NSHostingMenu 没有生成菜单项（无窗口服务器）") }
        XCTAssertEqual(before, ["项目 1", "另一项"])
        let itemsBefore = menu.items

        // 菜单「开着」的时候宿主重画了几次（状态变了）：只换 makeMenu。
        for next in 2...5 {
            box.value = next
            view.makeMenu = { [value = box.value] in
                AnyView(Group {
                    Button("项目 \(value)") {}
                    Button("新多出来的一项") {}
                })
            }
            spin(0.05)
        }
        spin()

        // 已经弹出的菜单一项都没动（AppKit 不会在跟踪期间收到 setItemArray）。
        XCTAssertEqual(titles(menu), ["项目 1", "另一项"])
        XCTAssertEqual(menu.items.count, itemsBefore.count)
        for (a, b) in zip(menu.items, itemsBefore) { XCTAssertTrue(a === b) }
        XCTAssertEqual(view.builtCount, 1, "宿主重画不能自己去重建菜单")

        // 下一次右键才拿到新内容。
        let fresh = try XCTUnwrap(view.buildMenu())
        spin()
        XCTAssertEqual(titles(fresh), ["项目 5", "新多出来的一项"])
        XCTAssertEqual(view.builtCount, 2)
    }

    func testNoMenuWithoutContent() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("NSHostingMenu 需要 macOS 15") }
        let view = StableContextMenuView(frame: .zero)
        XCTAssertNil(view.buildMenu())
        XCTAssertEqual(view.builtCount, 0)
    }

    // MARK: 3. 源码守卫

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [(String, String)] {
        let root = sourcesRoot
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("读不到源码目录 \(root.path)")
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        if out.isEmpty { throw XCTSkip("源码目录是空的 \(root.path)") }
        return out
    }

    /// 文件 / 文件夹的右键菜单（FileContextMenu、空白处 FolderBackgroundMenu、文件夹墙卡片）不能再用 SwiftUI 的 .contextMenu。
    func testFileMenusUseStableContextMenu() throws {
        var offenders: [String] = []
        for (name, text) in try swiftSources() where name != "StableContextMenu.swift" {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(".contextMenu {") || line.contains(".contextMenu(forSelectionType") {
                // 这一行和后面几行里出现文件菜单就算违规（forSelectionType 的列表视图另说，见下）。
                let window = lines[i..<min(lines.count, i + 4)].joined(separator: "\n")
                if line.contains("forSelectionType") { continue }
                if window.contains("FileContextMenu(") || window.contains("FolderBackgroundMenu(")
                    || line.contains(".contextMenu { menu }") || line.contains(".contextMenu { menu(for: item) }") {
                    offenders.append("\(name):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "这些地方的文件右键菜单还在用 .contextMenu，菜单开着时内容会被 SwiftUI 重写（macOS 27 崩溃）")
    }

    /// 菜单内容不订阅单例：FileMenuItems / FolderBackgroundMenu 里不能有 @ObservedObject。
    func testFileMenuItemsDoNotObserveSingletons() throws {
        let sources = try swiftSources()
        let components = try XCTUnwrap(sources.first { $0.0 == "Components.swift" }?.1)
        for marker in ["private struct FileMenuItems", "struct FolderBackgroundMenu"] {
            let start = try XCTUnwrap(components.range(of: marker), marker)
            let rest = components[start.upperBound...]
            // 到 body 为止就是属性声明区。
            let end = rest.range(of: "var body: some View")?.lowerBound ?? rest.endIndex
            let header = rest[..<end]
            XCTAssertFalse(header.contains("@ObservedObject"), "\(marker) 不能订阅会变的单例")
            XCTAssertFalse(header.contains("@StateObject"), "\(marker) 不能订阅会变的单例")
        }
    }

    // MARK: 4. 2026-10-28 复查补的：列表视图 / 压缩包 / 刘海面板 / 其他零散菜单

    /// 除了 StableContextMenu.swift 自己（macOS 14 退路），源码里不再有 SwiftUI 的 `.contextMenu {`；
    /// 列表视图 / 压缩包浏览的 contextMenu(forSelectionType:) 只留 primaryAction，macOS 15+ 菜单内容是空的。
    func testNoSwiftUIContextMenusLeft() throws {
        var offenders: [String] = []
        for (name, text) in try swiftSources() where name != "StableContextMenu.swift" {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains(".contextMenu {") { offenders.append("\(name):\(i + 1)") }
                if code.contains(".contextMenu(forSelectionType") {
                    let window = lines[i..<min(lines.count, i + 4)].joined(separator: "\n")
                    if !window.contains("#available(macOS 15.0, *)") { offenders.append("\(name):\(i + 1) forSelectionType") }
                }
            }
        }
        XCTAssertEqual(offenders, [], "这些地方还在用 SwiftUI 的右键菜单，菜单开着时内容会被重写（macOS 27 崩溃）")
    }

    /// 右键菜单里会用到的子菜单也不能订阅、不能要环境对象（NSHostingMenu 那棵树里没有，取不到直接崩）。
    func testSubmenusUsedInsideMenusDoNotObserve() throws {
        let sources = Dictionary(try swiftSources(), uniquingKeysWith: { a, _ in a })
        let checks: [(file: String, marker: String)] = [
            ("TagViews.swift", "private struct TagMenuContent"),
            ("TagViews.swift", "struct TagMenu: View"),
            ("FileTemplates.swift", "struct NewFileMenuContent"),
            ("Components.swift", "struct CustomizeMenuButton"),
        ]
        for check in checks {
            let text = try XCTUnwrap(sources[check.file], check.file)
            let start = try XCTUnwrap(text.range(of: check.marker), check.marker)
            let rest = text[start.upperBound...]
            let end = rest.range(of: "var body: some View")?.lowerBound ?? rest.endIndex
            let header = rest[..<end]
            for wrapper in ["@ObservedObject", "@StateObject", "@EnvironmentObject", "@Environment("] {
                XCTAssertFalse(header.contains(wrapper), "\(check.marker) 不能用 \(wrapper)")
            }
        }
    }

    private final class RowsSource: NSObject, NSTableViewDataSource {
        let rows: Int
        init(rows: Int) { self.rows = rows }
        func numberOfRows(in tableView: NSTableView) -> Int { rows }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "\(row)" }
    }

    /// 列表视图空白处的透明层：点在行上、表头上不接（交给行自己的菜单），点在最后一行下面才接；没有表格时不判断。
    func testTableEmptyAreaDetection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.rowHeight = 20
        let source = RowsSource(rows: 3)
        table.dataSource = source
        scroll.documentView = table
        root.addSubview(scroll)
        table.reloadData()
        root.layoutSubtreeIfNeeded()

        let first = table.rect(ofRow: 0)
        let onRow = table.convert(NSPoint(x: first.midX, y: first.midY), to: nil)
        XCTAssertEqual(StableTableHitLogic.isEmptyArea(in: root, windowPoint: onRow), false)

        let last = table.rect(ofRow: 2)
        // 表格是翻转坐标：maxY 往下。
        let below = table.convert(NSPoint(x: last.midX, y: last.maxY + 60), to: nil)
        XCTAssertTrue(scroll.convert(scroll.bounds, to: nil).contains(below))
        XCTAssertEqual(StableTableHitLogic.isEmptyArea(in: root, windowPoint: below), true)

        if let header = table.headerView, header.window != nil {
            let onHeader = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
            XCTAssertEqual(StableTableHitLogic.isEmptyArea(in: root, windowPoint: onHeader), false)
        }
        XCTAssertNil(StableTableHitLogic.isEmptyArea(in: root, windowPoint: NSPoint(x: 900, y: 900)))
        withExtendedLifetime(source) {}
    }

    /// 刘海面板这种「整块面板」的菜单：点到卡片（更小的菜单层）上让给卡片，点到空地方自己接。
    func testPanelMenuDefersToInnerMenus() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("StableContextMenuView 需要 macOS 15") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = root
        let card = StableContextMenuView(frame: NSRect(x: 10, y: 10, width: 60, height: 60))
        let panel = StableContextMenuView(frame: root.bounds)
        panel.claim = .deferToInner
        root.addSubview(card)
        root.addSubview(panel)
        let onCard = card.convert(NSPoint(x: 30, y: 30), to: nil)
        let empty = root.convert(NSPoint(x: 200, y: 200), to: nil)
        XCTAssertTrue(StableInnerMenuLogic.hasInnerMenu(in: root, windowPoint: onCard, excluding: panel))
        XCTAssertFalse(StableInnerMenuLogic.hasInnerMenu(in: root, windowPoint: empty, excluding: panel))
        // 卡片自己不会让给更大的面板。
        XCTAssertFalse(StableInnerMenuLogic.hasInnerMenu(in: root, windowPoint: onCard, excluding: card))
    }
}
