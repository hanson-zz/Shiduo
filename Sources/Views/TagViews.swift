import AppKit
import SwiftUI

/// 访达标签：用系统自己的颜色标签名（跟随系统语言，例如“红色”“Red”）。
struct FinderTag: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

    /// 系统的七个颜色标签，按访达侧边栏的顺序（红橙黄绿蓝紫灰）。
    static var colorTags: [FinderTag] {
        let names = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        // fileLabels 的顺序：无、灰、绿、紫、蓝、黄、红、橙。
        let order = [6, 7, 5, 2, 4, 3, 1]
        return order.compactMap { index in
            guard names.indices.contains(index), colors.indices.contains(index) else { return nil }
            return FinderTag(name: names[index], color: Color(nsColor: colors[index]))
        }
    }

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// 给文件加上或去掉一个标签。
    @discardableResult
    static func set(_ name: String, on: Bool, for urls: [URL]) -> Int {
        var changed = 0
        for url in urls {
            var tags = tags(of: url)
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
}

/// 右键菜单里的「标签」子菜单。
struct TagMenu: View {
    @EnvironmentObject private var store: LibraryStore
    let items: [FileItem]

    var body: some View {
        Menu("标签") {
            let current = Set(items.flatMap { FinderTag.tags(of: $0.url) })
            ForEach(FinderTag.colorTags) { tag in
                let has = current.contains(tag.name)
                Button {
                    let n = FinderTag.set(tag.name, on: !has, for: items.map(\.url))
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
