import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 拾掇 Pro：自定义快捷键。改动马上存、马上作用到菜单（菜单里的 .keyboardShortcut(AppShortcut) 从这里取）。
/// 免费用户（或试用结束）一律用出厂快捷键，改过的设置留着，解锁后回来。
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var settings: ShortcutSettings

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = ShortcutSettings.load(from: defaults)
    }

    /// 现在真正生效的：没解锁 Pro 时是出厂的。
    nonisolated static func effectiveCombo(for shortcut: AppShortcut) -> KeyCombo? {
        MainActor.assumeIsolated {
            guard LicenseManager.shared.isPro else { return shortcut.defaultCombo }
            return shared.settings.combo(for: shortcut)
        }
    }

    func combo(for shortcut: AppShortcut) -> KeyCombo? { settings.combo(for: shortcut) }

    func update(_ change: (inout ShortcutSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        settings.save(to: defaults)
    }

    func replace(with new: ShortcutSettings) {
        settings = new.sanitized()
        settings.save(to: defaults)
    }
}

/// 拾掇 Pro：自定义右键菜单。免费用户菜单保持默认。
@MainActor
final class MenuLayoutStore: ObservableObject {
    static let shared = MenuLayoutStore()

    @Published private(set) var layouts: [MenuKind: MenuLayout] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for kind in MenuKind.allCases {
            layouts[kind] = MenuCatalog.decode(defaults.data(forKey: kind.defaultsKey), kind: kind)
        }
    }

    /// 编辑器里看到的（用户排过的）。
    func layout(_ kind: MenuKind) -> MenuLayout { layouts[kind] ?? MenuCatalog.defaultLayout(kind) }

    /// 右键菜单真正用的：没解锁 Pro 时是默认菜单。
    func effective(_ kind: MenuKind) -> MenuLayout {
        LicenseManager.shared.isPro ? layout(kind) : MenuCatalog.defaultLayout(kind)
    }

    func update(_ kind: MenuKind, _ change: (inout MenuLayout) -> Void) {
        var copy = layout(kind)
        change(&copy)
        set(copy, for: kind)
    }

    func set(_ layout: MenuLayout, for kind: MenuKind) {
        var layout = layout
        layout.normalize()
        layout.version = MenuLayout.currentVersion
        guard layout != self.layout(kind) else { return }
        layouts[kind] = layout
        if MenuCatalog.isDefault(layout, kind: kind) {
            defaults.removeObject(forKey: kind.defaultsKey)
        } else if let data = MenuCatalog.encode(layout) {
            defaults.set(data, forKey: kind.defaultsKey)
        }
    }

    func reset(_ kind: MenuKind) { set(MenuCatalog.defaultLayout(kind), for: kind) }
}

/// 菜单和快捷键一起导出 / 导入 JSON。
@MainActor
enum MenuShortcutsTransfer {
    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "拾掇菜单与快捷键.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let menus = MenuLayoutStore.shared
        let file = MenuShortcutsExport(shortcuts: ShortcutStore.shared.settings,
                                       fileMenu: menus.layout(.file), backgroundMenu: menus.layout(.background))
        do {
            guard let data = file.encoded() else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            alert(String(localized: "导出失败：\(error.localizedDescription)"))
        }
    }

    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let file = MenuShortcutsExport.decode(data) else {
            alert(String(localized: "这不是拾掇导出的菜单与快捷键文件。"))
            return
        }
        ShortcutStore.shared.replace(with: file.shortcuts)
        if let menu = file.fileMenu { MenuLayoutStore.shared.set(menu, for: .file) }
        if let menu = file.backgroundMenu { MenuLayoutStore.shared.set(menu, for: .background) }
    }

    private static func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

extension View {
    /// 用 AppShortcut 里登记的快捷键（Pro 用户改过的就用改过的；清空了就没有快捷键）。
    /// 想让菜单跟着改动马上变，所在的视图 / Commands 要观察 ShortcutStore.shared。
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(ShortcutStore.effectiveCombo(for: shortcut)?.keyboardShortcut)
    }
}

extension AppShortcut {
    /// 现在生效的写法（改过就是改过的；清空了是空字符串）。
    var currentDisplay: String { ShortcutStore.effectiveCombo(for: self)?.display ?? "" }
}

extension AppShortcut {
    /// 「返回（⌘[）」这种悬停提示，用现在生效的快捷键；清空了就只有名字。
    var currentHelp: String {
        let keys = currentDisplay
        return keys.isEmpty ? title : String(localized: "\(title)（\(keys)）")
    }
}
