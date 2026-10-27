import XCTest

/// 拾掇 Pro 自定义右键菜单：排序、隐藏、分组、分隔线、和新版本默认菜单合并、解码老版本 / 新版本存的数据。
final class MenuLayoutTests: XCTestCase {
    private func small() -> MenuLayout {
        MenuLayout(entries: [.item("a"), .item("b"), .separator("s1"), .item("c"), .item("d")])
    }

    private func ids(_ layout: MenuLayout) -> [String] { layout.entries.map(\.id) }

    func testDefaultLayoutMatchesCatalog() {
        for kind in MenuKind.allCases {
            let layout = MenuCatalog.defaultLayout(kind)
            XCTAssertEqual(layout.allItemIDs, MenuCatalog.itemIDs(kind))
            XCTAssertEqual(Set(layout.allItemIDs).count, layout.allItemIDs.count, "\(kind) 里有重复的项目")
            XCTAssertTrue(MenuCatalog.isDefault(layout, kind: kind))
            // 每一项都有名字（不是把 id 原样显示出来）。
            for id in layout.allItemIDs { XCTAssertNotEqual(MenuCatalog.title(id), id, id) }
            // 默认菜单显示出来：分隔线不打头、不收尾、不连着。
            let resolved = layout.resolved(known: MenuCatalog.known(kind))
            XCTAssertNotEqual(resolved.first, .separator)
            XCTAssertNotEqual(resolved.last, .separator)
        }
        XCTAssertEqual(MenuCatalog.defaultLayout(.file).allItemIDs.first, "open")
        XCTAssertEqual(MenuCatalog.defaultLayout(.file).allItemIDs.last, "trash")
    }

    func testMoveLikeSwiftUI() {
        var layout = small()
        layout.move(fromOffsets: [0], toOffset: 3)          // a 移到 s1 后面
        XCTAssertEqual(ids(layout), ["b", "s1", "a", "c", "d"])
        layout.move(fromOffsets: [4], toOffset: 0)          // d 移到最前
        XCTAssertEqual(ids(layout), ["d", "b", "s1", "a", "c"])
        layout.move(fromOffsets: [0, 1], toOffset: 5)       // 多选一起移到最后
        XCTAssertEqual(ids(layout), ["s1", "a", "c", "d", "b"])
        layout.move(fromOffsets: [9], toOffset: 0)          // 越界不动
        XCTAssertEqual(ids(layout), ["s1", "a", "c", "d", "b"])
    }

    func testHideKeepsPositionAndResolvedSkips() {
        var layout = small()
        layout.setHidden("b", true)
        XCTAssertTrue(layout.isHidden("b"))
        XCTAssertEqual(ids(layout), ["a", "b", "s1", "c", "d"])
        let known: Set<String> = ["a", "b", "c", "d"]
        XCTAssertEqual(layout.resolved(known: known), [.item("a"), .separator, .item("c"), .item("d")])
        // 一段全隐藏了：分隔线不留。
        layout.setHidden("a", true)
        XCTAssertEqual(layout.resolved(known: known), [.item("c"), .item("d")])
        layout.setHidden("a", false)
        layout.setHidden("b", false)
        XCTAssertEqual(layout.resolved(known: known).count, 5)
    }

    func testResolvedSkipsUnavailableUnknownAndCollapsesSeparators() {
        let layout = MenuLayout(entries: [
            .separator("s0"), .item("a"), .separator("s1"), .separator("s2"), .item("future"),
            .item("b"), .separator("s3"), .group("g", title: "更多", children: ["c"]), .separator("s4"),
        ])
        let resolved = layout.resolved(known: ["a", "b", "c"]) { $0 != "c" }
        XCTAssertEqual(resolved, [.item("a"), .separator, .item("b")])
        let all = layout.resolved(known: ["a", "b", "c"])
        XCTAssertEqual(all, [.item("a"), .separator, .item("b"), .separator, .submenu(title: "更多", items: ["c"])])
        // 全隐藏：空菜单（界面上会换成「自定义菜单…」）。
        var hidden = layout
        for id in ["a", "b", "c"] { hidden.setHidden(id, true) }
        XCTAssertEqual(hidden.resolved(known: ["a", "b", "c"]), [])
    }

    func testGroupAndUngroup() {
        var layout = small()
        let groupID = layout.group(["d", "b"], title: "  更多  ", newID: "g1")
        XCTAssertEqual(groupID, "g1")
        // 分组在最靠前那一项（b）的位置，里面保持原来的先后。
        XCTAssertEqual(ids(layout), ["a", "g1", "s1", "c"])
        XCTAssertEqual(layout.entries[1].children, ["b", "d"])
        XCTAssertEqual(layout.entries[1].title, "更多")
        XCTAssertEqual(layout.groupID(containing: "d"), "g1")
        XCTAssertEqual(layout.allItemIDs, ["a", "b", "d", "c"])
        XCTAssertEqual(layout.resolved(known: ["a", "b", "c", "d"]),
                       [.item("a"), .submenu(title: "更多", items: ["b", "d"]), .separator, .item("c")])
        // 隐藏分组里的一项。
        layout.setHidden("b", true)
        XCTAssertEqual(layout.resolved(known: ["a", "b", "c", "d"])[1], .submenu(title: "更多", items: ["d"]))
        layout.renameGroup("g1", to: "开发")
        layout.renameGroup("g1", to: "   ")   // 空名字不改
        XCTAssertEqual(layout.entries[1].title, "开发")
        // 分组里排序。
        layout.moveChildren(inGroup: "g1", fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(layout.entries[1].children, ["d", "b"])
        layout.ungroup("g1")
        XCTAssertEqual(ids(layout), ["a", "d", "b", "s1", "c"])
        // 没选中顶层项目：不建分组；名字空：叫「新分组」。
        XCTAssertNil(layout.group(["s1", "nope"], title: "x"))
        layout.group(["c"], title: "", newID: "g2")
        XCTAssertEqual(layout.entries.last?.title, String(localized: "新分组"))
    }

    func testMoveIntoAndOutOfGroup() {
        var layout = small()
        layout.group(["a"], title: "组", newID: "g")
        layout.moveIntoGroup("c", groupID: "g")
        XCTAssertEqual(ids(layout), ["g", "b", "s1", "d"])
        XCTAssertEqual(layout.entries[0].children, ["a", "c"])
        layout.moveOutOfGroup("a")
        XCTAssertEqual(ids(layout), ["g", "a", "b", "s1", "d"])
        // 最后一项拿出来：空分组去掉。
        layout.moveOutOfGroup("c")
        XCTAssertEqual(ids(layout), ["c", "a", "b", "s1", "d"])
    }

    func testSeparators() {
        var layout = small()
        let id = layout.insertSeparator(after: "a", newID: "new")
        XCTAssertEqual(ids(layout), ["a", "new", "b", "s1", "c", "d"])
        layout.insertSeparator(after: nil, newID: "end")
        XCTAssertEqual(layout.entries.last?.id, "end")
        layout.removeSeparator(id)
        layout.removeSeparator("a")   // 项目不能删
        XCTAssertEqual(ids(layout), ["a", "b", "s1", "c", "d", "end"])
        // 分组里的项目后面加：加在分组下面。
        layout.group(["c", "d"], title: "组", newID: "g")
        layout.insertSeparator(after: "d", newID: "afterGroup")
        XCTAssertEqual(ids(layout), ["a", "b", "s1", "g", "afterGroup", "end"])
    }

    func testMergeAddsNewDefaultItemsAtDefaultPosition() {
        let defaults = MenuLayout(entries: [
            .item("a"), .item("new1"), .item("b"), .separator("s0"), .item("new2"), .item("c"), .item("d"), .item("new3"),
        ])
        // 用户把 b 放到最前、c d 收进分组、隐藏了 a。
        var user = MenuLayout(version: 0, entries: [.item("b"), .item("a"), .separator("x"), .group("g", title: "组", children: ["c", "d"])],
                              hidden: ["a"])
        user = user.merged(withDefault: defaults)
        // new1 跟在 a 后面；new2 是一段的开头，放在 c（所在的分组）前面；new3 跟在 d（所在的分组）后面。
        XCTAssertEqual(ids(user), ["b", "a", "new1", "x", "new2", "g", "new3"])
        XCTAssertEqual(user.hidden, ["a"])
        XCTAssertEqual(user.version, MenuLayout.currentVersion)
        // 已经合并过的再合并不变。
        XCTAssertEqual(user.merged(withDefault: defaults), user)
    }

    func testMergeKeepsUnknownFutureItemsAndDedupes() {
        let defaults = MenuLayout(entries: [.item("a"), .item("b")])
        let user = MenuLayout(entries: [.item("fromFuture"), .item("b"), .item("b"), .group("g", title: "", children: ["b"]),
                                        .group("empty", title: "空", children: [])])
        let merged = user.merged(withDefault: defaults)
        // 不认识的留着（不显示）；重复的 b 只留第一个；分组里只剩重复项就整个去掉；a 补回来（默认在 b 前面）。
        XCTAssertEqual(ids(merged), ["fromFuture", "a", "b"])
        XCTAssertEqual(merged.resolved(known: ["a", "b"]), [.item("a"), .item("b")])
    }

    func testDecodeRoundTripAndOldOrBrokenData() throws {
        var layout = MenuCatalog.defaultLayout(.file)
        layout.move(fromOffsets: [layout.entries.count - 1], toOffset: 0)   // 移到废纸篓放最前
        layout.setHidden("zip", true)
        layout.group(["share", "airDrop"], title: "分享", newID: "g-share")
        let data = try XCTUnwrap(MenuCatalog.encode(layout))
        let back = MenuCatalog.decode(data, kind: .file)
        XCTAssertEqual(back, layout)
        XCTAssertEqual(back.entries.first?.id, "trash")
        XCTAssertFalse(MenuCatalog.isDefault(back, kind: .file))

        // 没有数据 / 坏数据：默认菜单。
        XCTAssertEqual(MenuCatalog.decode(nil, kind: .file), MenuCatalog.defaultLayout(.file))
        XCTAssertEqual(MenuCatalog.decode(Data("不是 JSON".utf8), kind: .background), MenuCatalog.defaultLayout(.background))

        // 老版本存的：没有 version、没有 hidden，也没有后来加的项目 → 补齐，原来的顺序不动。
        let old = #"{"entries":[{"kind":"item","id":"copyPath"},{"kind":"item","id":"paste"},{"kind":"separator","id":"x"}]}"#
        let oldLayout = MenuCatalog.decode(Data(old.utf8), kind: .background)
        XCTAssertEqual(Array(oldLayout.allItemIDs.prefix(2)), ["copyPath", "paste"])
        XCTAssertEqual(Set(oldLayout.allItemIDs), MenuCatalog.known(.background))
        XCTAssertEqual(oldLayout.allItemIDs.firstIndex(of: "pasteAndMove"), 2, "粘贴并移动 默认紧跟在 粘贴 后面")
        XCTAssertEqual(oldLayout.entries.filter { $0.kind == .separator }.map(\.id), ["x"])
        XCTAssertEqual(oldLayout.version, MenuLayout.currentVersion)

        // 更新的版本存的：认不出的条目类型跳过，认不出的项目 id 留着。
        let future = #"{"version":7,"hidden":["newFolder"],"entries":[{"kind":"spacer","id":"?"},{"kind":"item","id":"magic"},{"kind":"item","id":"newFolder"}],"extra":1}"#
        let futureLayout = MenuCatalog.decode(Data(future.utf8), kind: .background)
        XCTAssertEqual(futureLayout.entries.first?.id, "magic")
        XCTAssertTrue(futureLayout.isHidden("newFolder"))
        XCTAssertEqual(futureLayout.version, 7)
        XCTAssertFalse(futureLayout.resolved(known: MenuCatalog.known(.background)).contains(.item("magic")))
        XCTAssertFalse(futureLayout.resolved(known: MenuCatalog.known(.background)).contains(.item("newFolder")))
    }
}
