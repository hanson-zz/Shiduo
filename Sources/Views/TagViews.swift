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

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// 给文件加上或去掉一个标签。color > 0 时连颜色一起写进去（自定义标签在访达里也显示这个颜色）。
    @discardableResult
    static func set(_ name: String, on: Bool, for urls: [URL], color: Int = 0) -> Int {
        var changed = 0
        for url in urls {
            var tags = tags(of: url)
            if on, color > 0 {
                if !tags.contains(name), addColored(name, color: color, to: url) { changed += 1 }
                continue
            }
            if on {
                guard !tags.contains(name) else { continue }
                tags.append(name)
            } else {
                guard tags.contains(name) else { continue }
                tags.removeAll { $0 == name }
            }
            do {
                try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
                changed += 1
            } catch {
                continue
            }
        }
        return changed
    }

    private static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// 直接写扩展属性：每个标签是「名字\n颜色编号」，访达和聚焦都认。
    private static func addColored(_ name: String, color: Int, to url: URL) -> Bool {
        let path = url.path
        var entries: [String] = []
        let length = getxattr(path, tagsAttribute, nil, 0, 0, 0)
        if length > 0 {
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, tagsAttribute, $0.baseAddress, length, 0, 0) }
            if read == length,
               let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                entries = list
            } else {
                entries = tags(of: url)
            }
        }
        guard !entries.contains(where: { $0.components(separatedBy: "\n").first == name }) else { return false }
        entries.append("\(name)\n\(color)")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else {
            return false
        }
        return data.withUnsafeBytes { setxattr(path, tagsAttribute, $0.baseAddress, data.count, 0, 0) } == 0
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
    }

    func color(of name: String) -> Int { tags.first { $0.name == name }?.color ?? 0 }

    private func save() {
        if let data = try? JSONEncoder().encode(tags) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 弹窗：输入名字、选颜色。取消返回 nil。
    static func prompt() -> (name: String, color: Int)? {
        let alert = NSAlert()
        alert.messageText = String(localized: "新建标签")
        alert.informativeText = String(localized: "访达只支持这几种标签颜色，选好后在访达里也能看到。")
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))

        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        field.placeholderString = String(localized: "标签名字")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for index in FinderTag.colorOrder + [0] {
            popup.addItem(withTitle: FinderTag.colorName(index))
            popup.lastItem?.tag = index
            popup.lastItem?.image = TagDot.image(FinderTag.color(index))
        }
        popup.selectItem(withTag: 4)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        box.addSubview(field)
        box.addSubview(popup)
        alert.accessoryView = box
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (name, popup.selectedTag())
    }
}

/// 右键菜单里的「标签」子菜单。
struct TagMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var custom = CustomTagStore.shared
    let items: [FileItem]

    var body: some View {
        Menu("标签") {
            let current = Set(items.flatMap { FinderTag.tags(of: $0.url) })
            ForEach(FinderTag.allTags) { tag in
                let has = current.contains(tag.name)
                Button {
                    let n = FinderTag.set(tag.name, on: !has, for: items.map(\.url), color: tag.isCustom ? tag.colorIndex : 0)
                    store.showToast(has ? String(localized: "已去掉“\(tag.name)”标签") : String(localized: "已给 \(n) 个项目加上“\(tag.name)”标签"))
                    if case .tag = store.selection { store.reload() }
                } label: {
                    Label {
                        Text(has ? "✓ \(tag.name)" : tag.name)
                    } icon: {
                        Image(nsImage: TagDot.image(tag.color))
                    }
                }
            }
            Divider()
            Button("新建标签…") {
                guard let new = CustomTagStore.prompt() else { return }
                custom.add(new.name, color: new.color)
                let n = FinderTag.set(new.name, on: true, for: items.map(\.url), color: new.color)
                store.showToast(String(localized: "已给 \(n) 个项目加上“\(new.name)”标签"))
                if case .tag = store.selection { store.reload() }
            }
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
