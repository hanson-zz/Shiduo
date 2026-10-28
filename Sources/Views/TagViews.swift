import AppKit
import SwiftUI

/// 访达标签：用系统自己的颜色标签名（跟随系统语言，例如“红色”“Red”）。
struct FinderTag: Identifiable, Hashable {
    let name: String
    let color: Color
    /// 访达的颜色编号：0 无、1 灰、2 绿、3 紫、4 蓝、5 黄、6 红、7 橙。
    var colorIndex = 0
    /// 用户自己建的标签（不是系统的七个颜色标签）。
    var isCustom = false
    var id: String { name }

    /// 访达只支持这几种颜色（按侧边栏顺序）+ 无颜色。
    static let colorOrder = [6, 7, 5, 2, 4, 3, 1]

    static func color(_ index: Int) -> Color {
        let colors = NSWorkspace.shared.fileLabelColors
        guard index > 0, colors.indices.contains(index) else { return Color.secondary.opacity(0.5) }
        return Color(nsColor: colors[index])
    }

    static func colorName(_ index: Int) -> String {
        let names = NSWorkspace.shared.fileLabels
        guard index > 0, names.indices.contains(index) else { return String(localized: "无颜色") }
        return names[index]
    }

    /// 系统的七个颜色标签 + 自己建的标签。
    @MainActor static var allTags: [FinderTag] {
        colorTags + CustomTagStore.shared.tags.map {
            FinderTag(name: $0.name, color: color($0.color), colorIndex: $0.color, isCustom: true)
        }
    }

    /// 系统的七个颜色标签，按访达侧边栏的顺序（红橙黄绿蓝紫灰）。
    static var colorTags: [FinderTag] {
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        // fileLabels 的顺序：无、灰、绿、紫、蓝、黄、红、橙。
        return colorOrder.compactMap { index in
            guard names.indices.contains(index), colors.indices.contains(index) else { return nil }
            return FinderTag(name: names[index], color: Color(nsColor: colors[index]), colorIndex: index)
        }
    }

    /// 文件上现在的标签名字。优先读扩展属性（不走 URL 资源缓存），没有再退回系统的 tagNames（老的访达颜色标记）。
    static func tags(of url: URL) -> [String] {
        switch readEntries(url) {
        case .success(let entries?): return FinderTagEntries.names(entries)
        default: return (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }
    }

    /// 一批文件改标签的结果。
    struct WriteResult {
        var changed = 0
        /// 原来的标签读不懂、或者写不进去的文件（没动它们）。
        var failed: [URL] = []

        mutating func add(_ other: WriteResult) {
            changed += other.changed
            failed += other.failed
        }
    }

    /// 给文件加上或去掉一个标签。color 是访达颜色编号（系统颜色标签也要传它自己的编号）。
    @discardableResult
    static func set(_ name: String, on: Bool, for urls: [URL], color: Int = 0) -> WriteResult {
        update(urls) { entries in
            on ? FinderTagEntries.adding(name, color: color, to: entries) : FinderTagEntries.removing(name, from: entries)
        }
    }

    /// 对每个文件执行同一个改动。
    static func update(_ urls: [URL], transform: ([String]) -> [String]) -> WriteResult {
        var result = WriteResult()
        var changed = Set<String>()
        for url in urls {
            switch writeTags(url, transform: transform) {
            case .success(true):
                result.changed += 1
                changed.insert(url.standardizedFileURL.path)
            case .success(false): break
            case .failure: result.failed.append(url)
            }
        }
        if !changed.isEmpty {
            // 网格 / 列表上的标签小圆点跟着更新。
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: FinderTag.didChange, object: nil, userInfo: ["paths": changed])
            }
        }
        return result
    }

    /// 文件上的标签改了（userInfo["paths"]：Set<String>）。
    static let didChange = Notification.Name("FinderTag.didChange")

    enum TagWriteError: Error {
        /// 扩展属性存在但读不懂：不覆盖，免得把别的标签（和颜色）抹掉。
        case unreadable
        case writeFailed(Int32)
    }

    private static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// 读原始条目。没有这个扩展属性返回 .success(nil)；读到了但不是字符串数组返回失败。
    static func readEntries(_ url: URL) -> Result<[String]?, TagWriteError> {
        let path = url.path
        let length = getxattr(path, tagsAttribute, nil, 0, 0, 0)
        if length < 0 {
            return errno == ENOATTR ? .success(nil) : .failure(.unreadable)
        }
        if length == 0 { return .success([]) }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, tagsAttribute, $0.baseAddress, length, 0, 0) }
        guard read == length, let entries = FinderTagEntries.decode(data) else { return .failure(.unreadable) }
        return .success(entries)
    }

    /// 所有标签写入都走这里：读出原始的「名字\n颜色」条目，交给 transform 只改目标那一条，其他原样写回。
    /// 原来的扩展属性读不懂时放弃（返回失败），不用名字兜底覆盖。返回 true 表示真的改了。
    static func writeTags(_ url: URL, transform: ([String]) -> [String]) -> Result<Bool, TagWriteError> {
        let path = url.path
        let current: [String]
        /// 只有老式的访达颜色标记（FinderInfo），没有标签扩展属性。
        var legacyOnly = false
        switch readEntries(url) {
        case .failure(let error): return .failure(error)
        case .success(let entries?): current = entries
        case .success(nil):
            // 没有扩展属性，但可能有老式的访达颜色标记：把系统认出来的名字带上，免得写完反而少了
            let legacy = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            legacyOnly = !legacy.isEmpty
            current = legacy.map { name in
                let index = colorTags.first(where: { $0.name == name })?.colorIndex ?? 0
                return FinderTagEntries.entry(name, color: index)
            }
        }
        let next = transform(current)
        guard next != current else { return .success(false) }
        // 清空、或者只有老式颜色标记时，先让系统按名字写一遍：它会顺带清掉 / 更新 FinderInfo 里的颜色，
        // 不然只删扩展属性后访达又会从 FinderInfo 里把颜色读回来。这两种情况下都没有自定义颜色可丢。
        if next.isEmpty || legacyOnly {
            do {
                try (url as NSURL).setResourceValue(FinderTagEntries.names(next), forKey: .tagNamesKey)
            } catch {
                return .failure(.writeFailed(0))
            }
            if next.isEmpty { return finish(path) }
        }
        guard let data = FinderTagEntries.encode(next) else { return .failure(.writeFailed(0)) }
        let status = data.withUnsafeBytes { setxattr(path, tagsAttribute, $0.baseAddress, data.count, 0, 0) }
        guard status == 0 else { return .failure(.writeFailed(errno)) }
        return finish(path)
    }

    private static func finish(_ path: String) -> Result<Bool, TagWriteError> {
        NSWorkspace.shared.noteFileSystemChanged(path)
        return .success(true)
    }
}

/// 自己建的标签（名字 + 访达颜色），存在 UserDefaults。
@MainActor
final class CustomTagStore: ObservableObject {
    static let shared = CustomTagStore()

    struct Tag: Codable, Equatable, Identifiable {
        var name: String
        var color: Int
        var id: String { name }
    }

    @Published private(set) var tags: [Tag] = []
    private let key = "customTags"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Tag].self, from: data) {
            tags = list
        }
    }

    /// 新建（同名的改颜色）。系统颜色标签的名字不能用。
    /// 只改拾掇里的记录；已打标签的文件要同步颜色请用 TagSync.recolor。
    func add(_ name: String, color: Int) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !FinderTag.colorTags.contains(where: { $0.name == name }) else { return }
        if let index = tags.firstIndex(where: { $0.name == name }) {
            tags[index].color = color
        } else {
            tags.append(Tag(name: name, color: color))
        }
        save()
    }

    func remove(_ name: String) {
        tags.removeAll { $0.name == name }
        save()
        // 正在看这个标签的页面：回到首页，不停在一个已经不存在的标签上
        if let store = LibraryStore.shared, store.selection == .tag(name) { store.selection = .home }
    }

    /// 改名（位置不变）。新名字已经有了就合并成一个。
    func rename(_ old: String, to new: String) {
        guard old != new, let index = tags.firstIndex(where: { $0.name == old }) else { return }
        if tags.contains(where: { $0.name == new }) {
            tags.remove(at: index)
        } else {
            tags[index].name = new
        }
        save()
    }

    func contains(_ name: String) -> Bool { tags.contains { $0.name == name } }

    func color(of name: String) -> Int { tags.first { $0.name == name }?.color ?? 0 }

    private func save() {
        if let data = try? JSONEncoder().encode(tags) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 弹窗：输入名字、选颜色。取消返回 nil。
    static func prompt() -> (name: String, color: Int)? {
        prompt(title: String(localized: "新建标签"), name: "", color: 4)
    }

    /// 通用弹窗：标题、初始名字和颜色。showsName 为 false 时只选颜色。
    static func prompt(title: String, name initial: String, color initialColor: Int, showsName: Bool = true) -> (name: String, color: Int)? {
        if case .tag(let name, let color) = promptChoice(title: title, name: initial, color: initialColor, showsName: showsName,
                                                        offersImport: false) {
            return (name, color)
        }
        return nil
    }

    enum PromptChoice {
        case tag(name: String, color: Int)
        case importFinder
        case cancel
    }

    /// 侧边栏的「新建标签…」：多一个「导入访达标签…」按钮。
    static func promptNewOrImport() -> PromptChoice {
        promptChoice(title: String(localized: "新建标签"), name: "", color: 4, showsName: true, offersImport: true)
    }

    private static func promptChoice(title: String, name initial: String, color initialColor: Int, showsName: Bool,
                                     offersImport: Bool) -> PromptChoice {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "访达只支持这几种标签颜色，选好后在访达里也能看到。")
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        if offersImport { alert.addButton(withTitle: String(localized: "导入访达标签…")) }

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        field.placeholderString = String(localized: "标签名字")
        field.stringValue = initial
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for index in FinderTag.colorOrder + [0] {
            popup.addItem(withTitle: FinderTag.colorName(index))
            popup.lastItem?.tag = index
            popup.lastItem?.image = TagDot.image(FinderTag.color(index))
        }
        popup.selectItem(withTag: initialColor)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: showsName ? 56 : 26))
        if showsName { box.addSubview(field) }
        box.addSubview(popup)
        alert.accessoryView = box
        alert.window.initialFirstResponder = showsName ? (field as NSView) : (popup as NSView)

        let response = alert.runModal()
        if offersImport, response == .alertThirdButtonReturn { return .importFinder }
        guard response == .alertFirstButtonReturn else { return .cancel }
        let name = showsName ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : initial
        guard !name.isEmpty else { return .cancel }
        return .tag(name: name, color: popup.selectedTag())
    }

    /// 只输入名字的弹窗（重命名）。取消或没改返回 nil。
    static func promptName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != initial else { return nil }
        return name
    }
}

/// 自定义标签改名 / 改颜色 / 删除时，同步到已经打了这个标签的文件（用聚焦找文件，先确认数量）。
@MainActor
enum TagSync {
    /// 找出打了这个标签的文件。
    private static func files(_ name: String) async -> [FileItem] {
        await Queries.tagged(name)
    }

    /// 确认：要改 count 个文件。没有文件时不问。
    private static func confirm(_ title: String, count: Int, action: String) -> Bool {
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "聚焦找到 \(count) 个文件打了这个标签，会一起改。还没被聚焦索引的文件不会被改到。")
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func report(_ result: FinderTag.WriteResult, store: LibraryStore) {
        guard !result.failed.isEmpty else { return }
        let names = result.failed.prefix(5).map(\.lastPathComponent).joined(separator: String(localized: "、"))
        store.alertMessage = String(localized: "\(result.failed.count) 个项目的标签读不出来或写不进去，没有改动：\(names)")
    }

    static func rename(_ old: String, store: LibraryStore) async {
        guard let new = CustomTagStore.promptName(title: String(localized: "重命名标签"), initial: old) else { return }
        guard !FinderTag.colorTags.contains(where: { $0.name == new }) else {
            store.alertMessage = String(localized: "“\(new)”是访达的颜色标签，不能用作自定义标签的名字")
            return
        }
        let custom = CustomTagStore.shared
        let color = custom.contains(new) ? custom.color(of: new) : custom.color(of: old)
        let list = await files(old)
        guard confirm(String(localized: "把“\(old)”改名为“\(new)”？"), count: list.count, action: String(localized: "改名")) else { return }
        let result = FinderTag.update(list.map(\.url)) { FinderTagEntries.renaming(old, to: new, color: color, in: $0) }
        custom.rename(old, to: new)
        if custom.color(of: new) != color { custom.add(new, color: color) }
        report(result, store: store)
        store.showToast(String(localized: "已改名，同步了 \(result.changed) 个文件"))
        if store.selection == .tag(old) {
            let failed = Set(result.failed.map(\.path))
            store.switchTag(to: new, items: list.filter { !failed.contains($0.path) })
        }
    }

    static func recolor(_ name: String, to color: Int, store: LibraryStore) async {
        let list = await files(name)
        guard confirm(String(localized: "把“\(name)”改成\(FinderTag.colorName(color))？"), count: list.count, action: String(localized: "改颜色")) else { return }
        CustomTagStore.shared.add(name, color: color)
        let result = FinderTag.update(list.map(\.url)) { FinderTagEntries.recoloring(name, to: color, in: $0) }
        report(result, store: store)
        store.showToast(String(localized: "已改颜色，同步了 \(result.changed) 个文件"))
    }

    static func recolor(_ name: String, store: LibraryStore) async {
        let current = CustomTagStore.shared.color(of: name)
        guard let picked = CustomTagStore.prompt(title: String(localized: "改“\(name)”的颜色"), name: name, color: current, showsName: false),
              picked.color != current else { return }
        await recolor(name, to: picked.color, store: store)
    }

    static func delete(_ name: String, store: LibraryStore) async {
        let list = await files(name)
        guard confirm(String(localized: "删除标签“\(name)”？"), count: list.count, action: String(localized: "删除")) else { return }
        let result = FinderTag.update(list.map(\.url)) { FinderTagEntries.removing(name, from: $0) }
        CustomTagStore.shared.remove(name)
        report(result, store: store)
        store.showToast(String(localized: "已删除标签，从 \(result.changed) 个文件上去掉"))
    }

    /// 导入访达标签：用聚焦找出打了标签的文件，从扩展属性读出不重复的「名字 + 颜色」，加进拾掇（已有的、系统颜色标签跳过）。
    /// 只读文件，不改任何文件上的标签。
    static func importFinderTags(store: LibraryStore) async {
        store.showToast(String(localized: "正在查找文件上的访达标签…"))
        let urls = await Queries.anyTagged().map(\.url)
        let perFile = await Task.detached(priority: .userInitiated) { () -> [[String]] in
            urls.compactMap { url in
                if case .success(let entries?) = FinderTag.readEntries(url) { return entries }
                return nil
            }
        }.value
        let custom = CustomTagStore.shared
        let found = FinderTagEntries.distinctTags(perFile)
        let candidates = FinderTagEntries.importable(found, existing: Set(custom.tags.map(\.name)),
                                                     reserved: Set(FinderTag.colorTags.map(\.name)))
        guard !candidates.isEmpty else {
            store.showToast(String(localized: "没有找到新的访达标签"))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "导入 \(candidates.count) 个访达标签？")
        let names = candidates.prefix(30).map(\.name).joined(separator: String(localized: "、"))
        alert.informativeText = candidates.count > 30
            ? String(localized: "\(names) 等。只加到拾掇的标签列表里，不会改动任何文件。")
            : String(localized: "\(names)。只加到拾掇的标签列表里，不会改动任何文件。")
        alert.addButton(withTitle: String(localized: "导入"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tag in candidates where !custom.contains(tag.name) {
            custom.add(tag.name, color: tag.color)
        }
        store.showToast(String(localized: "已导入 \(candidates.count) 个访达标签"))
    }

    /// 新建标签时名字已经有了、颜色不一样：当作改颜色，连文件一起改。
    static func addOrRecolor(_ name: String, color: Int, store: LibraryStore) async {
        let custom = CustomTagStore.shared
        if custom.contains(name), custom.color(of: name) != color {
            await recolor(name, to: color, store: store)
        } else {
            custom.add(name, color: color)
        }
    }
}

/// 右键菜单里的「标签」子菜单。
struct TagMenu: View {
    let store: LibraryStore
    let items: [FileItem]

    var body: some View {
        // 读文件标签的活放在子视图里：只有菜单真的展开时才做。
        Menu("标签") { TagMenuContent(store: store, items: items) }
    }
}

/// 只读、不订阅（不用 @EnvironmentObject / 观察包装）：右键菜单是 NSHostingMenu 快照（StableContextMenu.swift），
/// 那棵视图树里没有 LibraryStore 环境对象（取不到会直接崩），订阅了的话菜单开着时店里一有变化就会重写菜单（macOS 27 崩溃）。
private struct TagMenuContent: View {
    let store: LibraryStore
    let items: [FileItem]

    var body: some View {
        let perItem = items.map { FinderTag.tags(of: $0.url) }
        let known = FinderTag.allTags
        let knownNames = Set(known.map(\.name))
        // 不在拾掇列表里、但已经打在文件上的标签（访达里建的、或者从侧边栏移除了的），也能在这里去掉。
        let extra = Set(perItem.flatMap { $0 }).subtracting(knownNames)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FinderTag(name: $0, color: FinderTag.color(0), colorIndex: 0, isCustom: true) }
        ForEach(known + extra) { tag in
            let coverage = FinderTagEntries.coverage(of: tag.name, in: perItem)
            Button {
                toggle(tag, coverage: coverage)
            } label: {
                Label {
                    switch coverage {
                    case .all: Text(verbatim: "✓ \(tag.name)")
                    case .some: Text(verbatim: "– \(tag.name)")
                    case .none: Text(tag.name)
                    }
                } icon: {
                    Image(nsImage: TagDot.image(tag.color))
                }
            }
        }
        Divider()
        Button("新建标签…") {
            guard let new = CustomTagStore.prompt() else { return }
            let urls = items.map(\.url)
            Task {
                await TagSync.addOrRecolor(new.name, color: new.color, store: store)
                let result = FinderTag.set(new.name, on: true, for: urls, color: CustomTagStore.shared.color(of: new.name))
                finish(result, name: new.name, added: true)
            }
        }
    }

    /// 全部都有：从全部去掉；部分有或都没有：给全部补上（和访达一样）。
    private func toggle(_ tag: FinderTag, coverage: FinderTagEntries.Coverage) {
        let remove = coverage == .all
        // 已经在文件上的标签保留它原来的颜色；新加的用它在访达 / 拾掇里的颜色
        let color = tag.isCustom ? CustomTagStore.shared.color(of: tag.name) : tag.colorIndex
        let result = FinderTag.set(tag.name, on: !remove, for: items.map(\.url), color: color)
        finish(result, name: tag.name, added: !remove)
    }

    private func finish(_ result: FinderTag.WriteResult, name: String, added: Bool) {
        if added, result.changed > 0 { store.usedTags.insert(name) }
        if added {
            store.showToast(String(localized: "已给 \(result.changed) 个项目加上“\(name)”标签"))
        } else {
            store.showToast(String(localized: "已从 \(result.changed) 个项目去掉“\(name)”标签"))
            // 标签页里去掉了这个标签：直接从列表里拿掉，不重新查（聚焦还没更新，重新查结果不准，还会清掉选中）
            let failed = Set(result.failed.map(\.path))
            store.tagRemoved(name, from: Set(items.map(\.path)).subtracting(failed))
        }
        if !result.failed.isEmpty {
            let names = result.failed.prefix(5).map(\.lastPathComponent).joined(separator: String(localized: "、"))
            store.alertMessage = String(localized: "\(result.failed.count) 个项目的标签读不出来或写不进去，没有改动：\(names)")
        }
    }
}

/// 菜单里只能放 NSImage，画一个彩色圆点。
enum TagDot {
    static func image(_ color: Color) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// 侧边栏的彩色小方块图标：渐变底色 + 白色符号。
struct BadgeIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .shadow(color: (colors.last ?? .black).opacity(0.35), radius: 1.5, y: 1)
            )
    }
}

/// 网格 / 列表里名字后面的标签小圆点（最多 3 个，叠在一起，和访达一样）。在后台读，短时间缓存。
struct TagDotsView: View {
    let path: String
    @State private var colors: [Int] = []
    @State private var version = 0

    var body: some View {
        Group {
            if !colors.isEmpty {
                HStack(spacing: -3) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, index in
                        Circle()
                            .fill(FinderTag.color(index))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    }
                }
                .fixedSize()
            }
        }
        .task(id: "\(path)#\(version)") {
            if let cached = TagColorCache.cached(path) {
                colors = cached
                return
            }
            let path = self.path
            let result = await Task.detached(priority: .utility) { TagColorCache.read(path) }.value
            TagColorCache.store(path, result)
            colors = result
        }
        .onReceive(NotificationCenter.default.publisher(for: FinderTag.didChange)) { note in
            guard let paths = note.userInfo?["paths"] as? Set<String>, paths.contains(path) else { return }
            TagColorCache.invalidate(path)
            version += 1
        }
    }
}

/// 标签颜色缓存：30 秒内同一个文件不重读（滚动网格时不用一直读扩展属性）。
enum TagColorCache {
    private static let lock = NSLock()
    private static var entries: [String: (colors: [Int], at: Date)] = [:]

    static func cached(_ path: String) -> [Int]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], Date().timeIntervalSince(entry.at) < 30 else { return nil }
        return entry.colors
    }

    static func store(_ path: String, _ colors: [Int]) {
        lock.lock(); defer { lock.unlock() }
        if entries.count > 20000 { entries.removeAll() }
        entries[path] = (colors, Date())
    }

    static func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = nil
    }

    /// 文件上有颜色的标签（访达颜色编号，去重，按文件上的顺序）。
    static func read(_ path: String) -> [Int] {
        let url = URL(fileURLWithPath: path)
        var result: [Int] = []
        switch FinderTag.readEntries(url) {
        case .success(let entries?):
            for entry in entries {
                let color = FinderTagEntries.color(of: entry)
                if color > 0, !result.contains(color) { result.append(color) }
            }
        case .success(nil):
            // 老式的访达颜色标记。
            let names = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let labels = NSWorkspace.shared.fileLabels
            for name in names {
                if let index = labels.firstIndex(of: name), index > 0, !result.contains(index) { result.append(index) }
            }
        case .failure:
            break
        }
        return result
    }
}

/// 右键菜单里那一排 7 个颜色圆点（和访达一样）：点一下给选中的加上 / 去掉这个颜色标签。
struct TagPaletteRow: View {
    let store: LibraryStore
    let items: [FileItem]

    /// 选得太多时不逐个读标签（不打勾，点了就是全部加上）。
    static let coverageLimit = 200

    var body: some View {
        let perItem = items.count <= Self.coverageLimit ? items.map { FinderTag.tags(of: $0.url) } : []
        ControlGroup {
            ForEach(FinderTag.colorTags) { tag in
                let coverage = perItem.isEmpty ? FinderTagEntries.Coverage.none : FinderTagEntries.coverage(of: tag.name, in: perItem)
                Button {
                    toggle(tag, remove: coverage == .all)
                } label: {
                    Image(nsImage: TagDot.paletteImage(tag.color, checked: coverage == .all, partial: coverage == .some))
                }
                .help(tag.name)
            }
        }
        .controlGroupStyle(.palette)
    }

    private func toggle(_ tag: FinderTag, remove: Bool) {
        let urls = items.map(\.url)
        let result = FinderTag.set(tag.name, on: !remove, for: urls, color: tag.colorIndex)
        if !remove, result.changed > 0 { store.usedTags.insert(tag.name) }
        if remove {
            store.showToast(String(localized: "已从 \(result.changed) 个项目去掉“\(tag.name)”标签"))
            store.tagRemoved(tag.name, from: Set(items.map(\.path)).subtracting(Set(result.failed.map(\.path))))
        } else {
            store.showToast(String(localized: "已给 \(result.changed) 个项目加上“\(tag.name)”标签"))
        }
        if !result.failed.isEmpty {
            let names = result.failed.prefix(5).map(\.lastPathComponent).joined(separator: String(localized: "、"))
            store.alertMessage = String(localized: "\(result.failed.count) 个项目的标签读不出来或写不进去，没有改动：\(names)")
        }
    }
}

extension TagDot {
    /// 调色板里的圆点：全部都有时中间打勾，部分有时中间一条横线。
    static func paletteImage(_ color: Color, checked: Bool, partial: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if checked {
                path.move(to: NSPoint(x: 4.8, y: 8.2))
                path.line(to: NSPoint(x: 7.2, y: 5.6))
                path.line(to: NSPoint(x: 11.4, y: 10.6))
                path.stroke()
            } else if partial {
                path.move(to: NSPoint(x: 5, y: 8))
                path.line(to: NSPoint(x: 11, y: 8))
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
