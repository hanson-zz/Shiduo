import Foundation

// 拾掇 Pro「菜单与快捷键」里右键菜单那一半不碰界面的部分：单元测试直接编译这个文件。
// 右键菜单 = 一串有顺序的「项目 id / 分隔线 / 分组（子菜单）」，再加一份隐藏名单。
// 菜单真正画出来时（Components.swift 的 FileMenuItems / FolderBackgroundMenu）按这份清单一项项摆，
// 每一项能不能出现（单个文件才有「计算哈希」……）仍由各自的条件决定。

/// 哪一个右键菜单。
enum MenuKind: String, Codable, CaseIterable, Identifiable {
    /// 文件 / 文件夹上点右键。
    case file
    /// 文件夹空白处点右键。
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: return String(localized: "文件和文件夹")
        case .background: return String(localized: "空白处")
        }
    }

    /// 存在 UserDefaults 里的 key。
    var defaultsKey: String { "customMenu.\(rawValue)" }
}

/// 菜单里的一项：项目、分隔线或分组。
struct MenuEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case item, separator, group }

    var kind: Kind
    /// 项目：项目 id（「open」「copyPath」……）；分隔线：「sep-…」；分组：「group-…」。
    var id: String
    /// 分组的名字。
    var title: String?
    /// 分组里的项目 id（分组里不再套分组、不放分隔线）。
    var children: [String]?

    static func item(_ id: String) -> MenuEntry { MenuEntry(kind: .item, id: id) }
    static func separator(_ id: String) -> MenuEntry { MenuEntry(kind: .separator, id: id) }
    static func group(_ id: String, title: String, children: [String]) -> MenuEntry {
        MenuEntry(kind: .group, id: id, title: title, children: children)
    }
}

/// 一个菜单真正显示出来的样子（隐藏的、此时不适用的已经拿掉，多余的分隔线已经合并）。
enum ResolvedMenuEntry: Equatable {
    case item(String)
    case separator
    case submenu(title: String, items: [String])
}

/// 用户排过的右键菜单。版本号写在里面；以后版本新加的项目解码时按默认位置补进去，
/// 不认识的项目 id（更新的版本存的）原样留着，只是不显示，退回旧版本再升级也不会丢。
struct MenuLayout: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var entries: [MenuEntry]
    /// 隐藏的项目 id（留在原位，取消勾选就回来）。
    var hidden: Set<String>

    init(version: Int = MenuLayout.currentVersion, entries: [MenuEntry], hidden: Set<String> = []) {
        self.version = version
        self.entries = entries
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case version, entries, hidden }

    /// 宽松解码：缺字段用默认值，认不出的条目（更新版本的新类型）跳过。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        let lossy = (try? c.decode([LossyEntry].self, forKey: .entries)) ?? []
        entries = lossy.compactMap(\.entry)
        hidden = (try? c.decode(Set<String>.self, forKey: .hidden)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entries, forKey: .entries)
        try c.encode(hidden.sorted(), forKey: .hidden)
    }

    private struct LossyEntry: Decodable {
        let entry: MenuEntry?
        init(from decoder: Decoder) throws { entry = try? MenuEntry(from: decoder) }
    }

    // MARK: - 查询

    /// 顶层和分组里所有的项目 id（按显示顺序）。
    var allItemIDs: [String] {
        entries.flatMap { entry -> [String] in
            switch entry.kind {
            case .item: return [entry.id]
            case .group: return entry.children ?? []
            case .separator: return []
            }
        }
    }

    /// 项目在哪个分组里（顶层返回 nil）。
    func groupID(containing itemID: String) -> String? {
        entries.first { $0.kind == .group && ($0.children ?? []).contains(itemID) }?.id
    }

    func isHidden(_ itemID: String) -> Bool { hidden.contains(itemID) }

    // MARK: - 编辑

    /// 顶层拖动排序（和 SwiftUI 的 onMove 一样的参数）。
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.moveElements(fromOffsets: source, toOffset: destination)
    }

    /// 分组里拖动排序。
    mutating func moveChildren(inGroup groupID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let index = entries.firstIndex(where: { $0.id == groupID && $0.kind == .group }) else { return }
        var children = entries[index].children ?? []
        children.moveElements(fromOffsets: source, toOffset: destination)
        entries[index].children = children
    }

    mutating func setHidden(_ itemID: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(itemID) } else { hidden.remove(itemID) }
    }

    /// 把几个顶层项目收进一个分组（子菜单）：分组放在其中最靠前那一项的位置，项目保持原来的先后。
    /// 返回新分组的 id；一个顶层项目都没选中时返回 nil。
    @discardableResult
    mutating func group(_ itemIDs: [String], title: String, newID: String = "group-" + UUID().uuidString) -> String? {
        let wanted = Set(itemIDs)
        let picked = entries.enumerated().filter { $0.element.kind == .item && wanted.contains($0.element.id) }
        guard let firstIndex = picked.first?.offset else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = MenuEntry.group(newID, title: name.isEmpty ? String(localized: "新分组") : name,
                                    children: picked.map { $0.element.id })
        let before = entries[..<firstIndex].filter { !($0.kind == .item && wanted.contains($0.id)) }
        let after = entries[firstIndex...].filter { !($0.kind == .item && wanted.contains($0.id)) }
        entries = Array(before) + [group] + Array(after)
        return newID
    }

    /// 解散分组：里面的项目原样放回分组所在的位置。
    mutating func ungroup(_ groupID: String) {
        guard let index = entries.firstIndex(where: { $0.id == groupID && $0.kind == .group }) else { return }
        let children = entries[index].children ?? []
        entries.replaceSubrange(index...index, with: children.map(MenuEntry.item))
    }

    mutating func renameGroup(_ groupID: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = entries.firstIndex(where: { $0.id == groupID && $0.kind == .group }) else { return }
        entries[index].title = name
    }

    /// 顶层项目放进一个已有的分组（放到最后）。
    mutating func moveIntoGroup(_ itemID: String, groupID: String) {
        guard let from = entries.firstIndex(where: { $0.kind == .item && $0.id == itemID }),
              entries.contains(where: { $0.id == groupID && $0.kind == .group }) else { return }
        entries.remove(at: from)
        if let index = entries.firstIndex(where: { $0.id == groupID }) {
            entries[index].children = (entries[index].children ?? []) + [itemID]
        }
    }

    /// 分组里的项目拿出来，放在分组的下面一项。分组空了就去掉。
    mutating func moveOutOfGroup(_ itemID: String) {
        guard let index = entries.firstIndex(where: { $0.kind == .group && ($0.children ?? []).contains(itemID) }) else { return }
        entries[index].children = (entries[index].children ?? []).filter { $0 != itemID }
        entries.insert(.item(itemID), at: index + 1)
        if entries[index].children?.isEmpty ?? true { entries.remove(at: index) }
    }

    /// 加一条分隔线：放在 entryID 那一项（或它所在的分组）下面；没给就放最后。返回分隔线 id。
    @discardableResult
    mutating func insertSeparator(after entryID: String?, newID: String = "sep-" + UUID().uuidString) -> String {
        var position = entries.count
        if let entryID {
            if let index = entries.firstIndex(where: { $0.id == entryID }) {
                position = index + 1
            } else if let group = groupID(containing: entryID), let index = entries.firstIndex(where: { $0.id == group }) {
                position = index + 1
            }
        }
        entries.insert(.separator(newID), at: position)
        return newID
    }

    /// 删掉一条分隔线（项目不能删，只能隐藏；分组用 ungroup）。
    mutating func removeSeparator(_ id: String) {
        entries.removeAll { $0.kind == .separator && $0.id == id }
    }

    // MARK: - 和新版本的默认菜单合并

    /// 默认菜单里有、这一份里没有的项目（新版本加的）：按默认位置补进来。
    /// 重复出现的项目只留第一次；空分组去掉。
    func merged(withDefault defaults: MenuLayout) -> MenuLayout {
        var result = self
        result.normalize()
        let defaultOrder = defaults.entries
        var present = Set(result.allItemIDs)

        for (offset, entry) in defaultOrder.enumerated() where entry.kind == .item && !present.contains(entry.id) {
            result.entries.insert(.item(entry.id), at: result.insertionIndex(forDefaultAt: offset, in: defaultOrder))
            present.insert(entry.id)
        }
        result.version = max(result.version, MenuLayout.currentVersion)
        return result
    }

    /// 新项目放在哪：默认菜单里紧挨着的上一项是项目、并且这里有它，就放它后面；
    /// 否则紧挨着的下一项在，就放它前面（这样分组开头的新项目不会跑到上一组末尾）；再不行往上找最近的一项；都没有放最后。
    private func insertionIndex(forDefaultAt offset: Int, in defaults: [MenuEntry]) -> Int {
        func topIndex(of itemID: String) -> Int? {
            if let index = entries.firstIndex(where: { $0.kind == .item && $0.id == itemID }) { return index }
            if let group = groupID(containing: itemID) { return entries.firstIndex { $0.id == group } }
            return nil
        }
        if offset > 0, defaults[offset - 1].kind == .item, let index = topIndex(of: defaults[offset - 1].id) {
            return index + 1
        }
        if offset + 1 < defaults.count, defaults[offset + 1].kind == .item, let index = topIndex(of: defaults[offset + 1].id) {
            return index
        }
        for previous in defaults[..<offset].reversed() where previous.kind == .item {
            if let index = topIndex(of: previous.id) { return index + 1 }
        }
        return entries.count
    }

    /// 去掉重复的项目、重复的分隔线 / 分组 id、空分组。
    mutating func normalize() {
        var seenItems = Set<String>()
        var seenIDs = Set<String>()
        var cleaned: [MenuEntry] = []
        for var entry in entries {
            switch entry.kind {
            case .item:
                guard seenItems.insert(entry.id).inserted else { continue }
            case .separator:
                guard seenIDs.insert(entry.id).inserted else { continue }
            case .group:
                guard seenIDs.insert(entry.id).inserted else { continue }
                entry.children = (entry.children ?? []).filter { seenItems.insert($0).inserted }
                if entry.children?.isEmpty ?? true { continue }
                if (entry.title ?? "").isEmpty { entry.title = String(localized: "新分组") }
            }
            cleaned.append(entry)
        }
        entries = cleaned
    }

    // MARK: - 显示

    /// 真正显示出来的菜单：拿掉隐藏的、不认识的（known 里没有）、此时不适用的（isAvailable 为 false），
    /// 分组里一项都不剩就整个不显示；分隔线不打头、不收尾、不连着两条。
    func resolved(known: Set<String>, isAvailable: (String) -> Bool = { _ in true }) -> [ResolvedMenuEntry] {
        func visible(_ id: String) -> Bool { known.contains(id) && !hidden.contains(id) && isAvailable(id) }
        var out: [ResolvedMenuEntry] = []
        for entry in entries {
            switch entry.kind {
            case .item:
                if visible(entry.id) { out.append(.item(entry.id)) }
            case .group:
                let items = (entry.children ?? []).filter(visible)
                if !items.isEmpty { out.append(.submenu(title: entry.title ?? "", items: items)) }
            case .separator:
                if let last = out.last, last != .separator { out.append(.separator) }
            }
        }
        while out.last == .separator { out.removeLast() }
        return out
    }
}

/// 两个菜单里都有哪些项目、默认怎么排、叫什么。
enum MenuCatalog {
    /// 文件 / 文件夹的右键菜单，默认顺序（nil 是分隔线）。和 B5 补齐后的菜单一样。
    static let fileDefaultOrder: [String?] = [
        "open", "openInNewTab", "openInOtherPane", "openWith", "browseArchive", "revealInFinder",
        "openInTerminal", "openInEditor", "quickLook", "showInfo", "computeHash", nil,
        "cut", "copy", "copyPath", "duplicate", "makeAlias", "newFolderWithSelection", nil,
        "tagColors", "tags", "shelf", "remind", "folderWall", "favorite", "startFolder", "libraryScope", nil,
        "rename", "saveAsTemplate", "folderIcon", "restoreFolderIcon", "contextExtras", nil,
        "convertImage", "mediaTools", "zip", nil,
        "copyText", "ocr", "share", "airDrop", nil,
        "moveTo", "copyTo", nil,
        "moveOut", "uninstall", nil,
        "trash",
    ]

    /// 空白处的右键菜单，默认顺序。
    static let backgroundDefaultOrder: [String?] = [
        "newFolder", "newFile", nil,
        "paste", "pasteAndMove", nil,
        "openInTerminal", "openInEditor", "revealInFinder", "copyPath",
    ]

    static func defaultOrder(_ kind: MenuKind) -> [String?] {
        kind == .file ? fileDefaultOrder : backgroundDefaultOrder
    }

    static func itemIDs(_ kind: MenuKind) -> [String] { defaultOrder(kind).compactMap { $0 } }

    static func known(_ kind: MenuKind) -> Set<String> { Set(itemIDs(kind)) }

    /// 默认菜单（分隔线 id 固定为 sep-0、sep-1……，这样默认菜单每次都一样）。
    static func defaultLayout(_ kind: MenuKind) -> MenuLayout {
        var separators = 0
        let entries = defaultOrder(kind).map { id -> MenuEntry in
            if let id { return .item(id) }
            defer { separators += 1 }
            return .separator("sep-\(separators)")
        }
        return MenuLayout(entries: entries)
    }

    /// 从存的数据读出菜单：读不出来用默认菜单；读出来的和这个版本的默认菜单合并（补上新项目）。
    static func decode(_ data: Data?, kind: MenuKind) -> MenuLayout {
        guard let data, let layout = try? JSONDecoder().decode(MenuLayout.self, from: data) else {
            return defaultLayout(kind)
        }
        return layout.merged(withDefault: defaultLayout(kind))
    }

    static func encode(_ layout: MenuLayout) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(layout)
    }

    /// 和默认菜单一样（「恢复默认」按钮是否可点、用不用存）。
    static func isDefault(_ layout: MenuLayout, kind: MenuKind) -> Bool {
        var a = layout
        a.normalize()
        return a.entries.map(\.kind) == defaultLayout(kind).entries.map(\.kind)
            && a.allItemIDs == defaultLayout(kind).allItemIDs
            && a.hidden.isEmpty
    }

    /// 编辑器和预览里的名字（菜单里真正的文字有时随选中的东西变，比如「拷贝 3 个路径」）。
    static func title(_ id: String) -> String {
        switch id {
        case "open": return String(localized: "打开")
        case "openInNewTab": return String(localized: "在新标签页中打开")
        case "openInOtherPane": return String(localized: "在另一栏中打开")
        case "openWith": return String(localized: "打开方式")
        case "browseArchive": return String(localized: "浏览压缩包内容")
        case "revealInFinder": return String(localized: "在访达中显示")
        case "openInTerminal": return String(localized: "在终端打开")
        case "openInEditor": return String(localized: "在编辑器打开")
        case "quickLook": return String(localized: "快速查看")
        case "showInfo": return String(localized: "显示简介")
        case "computeHash": return String(localized: "计算哈希")
        case "cut": return String(localized: "剪切")
        case "copy": return String(localized: "拷贝")
        case "copyPath": return String(localized: "拷贝路径")
        case "duplicate": return String(localized: "复制")
        case "makeAlias": return String(localized: "制作替身")
        case "newFolderWithSelection": return String(localized: "用所选项目新建文件夹")
        case "tagColors": return String(localized: "标签颜色")
        case "tags": return String(localized: "标签")
        case "shelf": return String(localized: "加入暂存架")
        case "remind": return String(localized: "提醒我处理…")
        case "folderWall": return String(localized: "添加到文件夹墙")
        case "favorite": return String(localized: "加入收藏")
        case "startFolder": return String(localized: "设为起始位置")
        case "libraryScope": return String(localized: "不在资料库中显示")
        case "rename": return String(localized: "重命名…")
        case "saveAsTemplate": return String(localized: "把所选存为模板")
        case "folderIcon": return String(localized: "文件夹换装…")
        case "restoreFolderIcon": return String(localized: "还原文件夹图标")
        case "contextExtras": return String(localized: "此处专属项目（如文件夹墙的颜色）")
        case "convertImage": return String(localized: "转换为 JPG / 压缩…")
        case "mediaTools": return String(localized: "转换与图片工具")
        case "zip": return String(localized: "压缩为 ZIP")
        case "copyText": return String(localized: "拷贝文字")
        case "ocr": return String(localized: "识别图中文字…")
        case "share": return String(localized: "共享…")
        case "airDrop": return String(localized: "隔空投送")
        case "moveTo": return String(localized: "移动到…")
        case "copyTo": return String(localized: "拷贝到…")
        case "moveOut": return String(localized: "大文件搬家…")
        case "uninstall": return String(localized: "卸载（连残留一起）…")
        case "trash": return String(localized: "移到废纸篓")
        case "newFolder": return String(localized: "新建文件夹")
        case "newFile": return String(localized: "新建文件")
        case "paste": return String(localized: "粘贴")
        case "pasteAndMove": return String(localized: "粘贴并移动")
        default: return id
        }
    }

    /// 本身就是子菜单的项目（预览里画「▸」）。
    static func isSubmenu(_ id: String) -> Bool {
        ["openWith", "tags", "mediaTools", "newFile"].contains(id)
    }

    /// 只在某些时候出现的项目，编辑器里给一句说明。
    static func note(_ id: String) -> String? {
        switch id {
        case "openInNewTab": return String(localized: "单个文件夹")
        case "openInOtherPane": return String(localized: "双栏时")
        case "browseArchive": return String(localized: "压缩包")
        case "quickLook": return String(localized: "文件列表里")
        case "computeHash": return String(localized: "单个文件")
        case "newFolderWithSelection": return String(localized: "同一文件夹里")
        case "startFolder", "favorite", "libraryScope", "folderIcon": return String(localized: "文件夹")
        case "restoreFolderIcon": return String(localized: "换过装的文件夹")
        case "saveAsTemplate": return String(localized: "文件")
        case "contextExtras": return String(localized: "文件夹墙等")
        case "convertImage", "ocr": return String(localized: "图片")
        case "mediaTools": return String(localized: "视频 / 图片")
        case "copyText": return String(localized: "有文字的文件")
        case "uninstall": return String(localized: "App")
        default: return nil
        }
    }
}

extension Array {
    /// 和 SwiftUI 的 move(fromOffsets:toOffset:) 一样（这个文件不引入 SwiftUI，单元测试也能用）。
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { $0 >= 0 && $0 < count }
        guard !valid.isEmpty else { return }
        let moving = valid.map { self[$0] }
        let before = valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { remove(at: index) }
        let target = Swift.min(Swift.max(destination - before, 0), count)
        insert(contentsOf: moving, at: target)
    }
}
