import SwiftUI

// 拾掇 Pro「菜单与快捷键」里快捷键那一半不碰界面的部分：单元测试直接编译这个文件（和 AppShortcuts.swift 一起）。

/// 一个组合键：键 + 修饰键。存进 UserDefaults / 导出 JSON 用它。
struct KeyCombo: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    /// 普通键是小写的那个字符（「c」「[」「1」）；特殊键用名字：up、down、left、right、delete、forwardDelete、
    /// return、tab、space、escape、home、end、pageUp、pageDown。
    var key: String
    var modifiers: Modifiers

    init(key: String, modifiers: Modifiers) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        var mods: Modifiers = []
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.command) { mods.insert(.command) }
        self.init(key: Self.name(of: key), modifiers: mods)
    }

    private static let named: [(String, KeyEquivalent)] = [
        ("up", .upArrow), ("down", .downArrow), ("left", .leftArrow), ("right", .rightArrow),
        ("delete", .delete), ("forwardDelete", .deleteForward), ("return", .return), ("tab", .tab),
        ("space", .space), ("escape", .escape), ("home", .home), ("end", .end),
        ("pageUp", .pageUp), ("pageDown", .pageDown),
    ]

    static func name(of key: KeyEquivalent) -> String {
        if let pair = named.first(where: { $0.1 == key }) { return pair.0 }
        return String(key.character).lowercased()
    }

    var keyEquivalent: KeyEquivalent {
        if let pair = Self.named.first(where: { $0.0 == key }) { return pair.1 }
        return KeyEquivalent(Character(key.isEmpty ? " " : String(key.prefix(1))))
    }

    var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.command) { mods.insert(.command) }
        return mods
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// 「⇧⌘D」这种写法：和 AppShortcut.display 完全一样（修饰键按 ⌃⌥⇧⌘ 的顺序）。
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyDisplay(key)
    }

    /// 查「不能用」的表用的写法：和 display 一样，只是空格键固定写「空格」（英文界面下 display 是 Space）。
    var canonical: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key == "space" ? "空格" : Self.keyDisplay(key))
    }

    static func keyDisplay(_ key: String) -> String {
        switch key {
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "return": return "↩"
        case "delete": return "⌫"
        case "forwardDelete": return "⌦"
        case "space": return String(localized: "空格")
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "home": return "↖"
        case "end": return "↘"
        case "pageUp": return "⇞"
        case "pageDown": return "⇟"
        default: return key.uppercased()
        }
    }

    /// 录快捷键时按下的键（虚拟键码 + 不带修饰键时打出来的字符）换成 key。
    static func key(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 51: return "delete"
        case 117: return "forwardDelete"
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 115: return "home"
        case 119: return "end"
        case 116: return "pageUp"
        case 121: return "pageDown"
        default:
            guard let c = characters?.lowercased(), c.count == 1, let scalar = c.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            return c
        }
    }
}

/// 不能拿来用的组合键：系统级的、访达里另有意思的、拾掇自己写死在别处的（列表按键、收藏、数字键直达）。
/// AppShortcutTests 也用这张表检查默认快捷键。
enum ReservedShortcuts {
    static let list: [String: String] = {
        var map: [String: String] = [
            // 系统
            "⌃⌘D": String(localized: "系统「查询」"),
            "⌃⌘F": String(localized: "系统「全屏」"),
            "⌃⌘Q": String(localized: "系统「锁定屏幕」"),
            "⌥⌘D": String(localized: "系统「显示 / 隐藏程序坞」"),
            "⌃⌘空格": String(localized: "系统「表情与符号」"),
            "⌘空格": String(localized: "系统「聚焦」"),
            "⌥⌘空格": String(localized: "系统「访达搜索」"),
            "⌘Q": String(localized: "退出拾掇"),
            "⌘H": String(localized: "隐藏拾掇"),
            "⌥⌘H": String(localized: "隐藏其他"),
            "⌘M": String(localized: "最小化窗口"),
            "⌘,": String(localized: "打开设置"),
            "⌘⇥": String(localized: "系统「切换 App」"),
            "⇧⌘⇥": String(localized: "系统「切换 App」"),
            "⌘`": String(localized: "切换窗口"),
            "⌥⌘⎋": String(localized: "系统「强制退出」"),
            "⇧⌘3": String(localized: "系统「截屏」"),
            "⇧⌘4": String(localized: "系统「截屏」"),
            "⇧⌘5": String(localized: "系统「截屏」"),
            "⌃⇧⌘3": String(localized: "系统「截屏到剪贴板」"),
            "⌃⇧⌘4": String(localized: "系统「截屏到剪贴板」"),
            "⌃⇧⌘5": String(localized: "系统「截屏到剪贴板」"),
            // 访达里是别的意思
            "⇧⌘K": String(localized: "访达「网络」"),
            "⇧⌘C": String(localized: "访达「电脑」"),
            "⌘R": String(localized: "访达「显示原身」"),
            "⌥⌘I": String(localized: "访达「检查器」"),
            "⌃⌘I": String(localized: "访达「显示摘要信息」"),
            "⇧⌘A": String(localized: "访达「应用程序」"),
            "⇧⌘U": String(localized: "访达「实用工具」"),
            "⇧⌘I": String(localized: "访达「iCloud 云盘」"),
            "⇧⌘F": String(localized: "访达「最近使用」"),
            "⇧⌘R": String(localized: "访达「隔空投送」"),
            "⌘E": String(localized: "访达「推出」"),
            // 拾掇写死在别处的
            "⌘⌫": String(localized: "移到废纸篓"),
            "⌘O": String(localized: "打开"),
            "⌘Y": String(localized: "快速查看"),
            "⌘A": String(localized: "全选"),
            "⌘Z": String(localized: "撤销"),
            "⇧⌘Z": String(localized: "重做"),
            "⌘=": String(localized: "放大图标"),
        ]
        for digit in 0...9 {
            if digit > 0 { map["⌥⌘\(digit)"] = String(localized: "前往第 \(digit) 个收藏") }
            map["⌃⌘\(digit)"] = String(localized: "数字键直达")
            map["⌃⌥⌘\(digit)"] = String(localized: "数字键直达（拷贝路径）")
        }
        return map
    }()

    static func reason(for combo: KeyCombo) -> String? { list[combo.canonical] }
}

/// 改一个快捷键时为什么不行。
enum ShortcutConflict: Equatable {
    /// 和拾掇另一个命令一样。
    case command(AppShortcut)
    /// 系统 / 访达 / 拾掇别处在用。
    case reserved(String)
    /// 没有 ⌘ 也没有 ⌃：在文件列表里打字会被吃掉。
    case needsModifier

    var message: String {
        switch self {
        case .command(let other): return String(localized: "和「\(other.title)」重复")
        case .reserved(let reason): return String(localized: "已被占用：\(reason)")
        case .needsModifier: return String(localized: "至少要带 ⌘ 或 ⌃")
        }
    }
}

/// 用户改过的快捷键（只存改过的）。版本号写在里面；不认识的命令 id（更新的版本存的）原样留着、不生效。
struct ShortcutSettings: Codable, Equatable {
    static let currentVersion = 1
    static let defaultsKey = "customShortcuts"

    var version = ShortcutSettings.currentVersion
    /// 命令 id → 新的组合键。
    var overrides: [String: KeyCombo] = [:]
    /// 清空了（不要快捷键）的命令 id。
    var cleared: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, overrides, cleared }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        let raw = (try? c.decode([String: LossyCombo].self, forKey: .overrides)) ?? [:]
        overrides = raw.compactMapValues(\.combo)
        cleared = (try? c.decode(Set<String>.self, forKey: .cleared)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(cleared.sorted(), forKey: .cleared)
    }

    private struct LossyCombo: Decodable {
        let combo: KeyCombo?
        init(from decoder: Decoder) throws {
            let decoded = try? KeyCombo(from: decoder)
            combo = (decoded?.key.isEmpty ?? true) ? nil : decoded
        }
    }

    var isEmpty: Bool { overrides.isEmpty && cleared.isEmpty }

    // MARK: - 查询

    /// 改过的、没改过的、清空了的，在不考虑冲突时各是什么。
    private func assigned(_ shortcut: AppShortcut) -> KeyCombo? {
        if cleared.contains(shortcut.rawValue) { return nil }
        return overrides[shortcut.rawValue] ?? shortcut.defaultCombo
    }

    /// 现在生效的组合键。别的命令被用户改成了这个命令的默认组合键时（比如新版本给新命令配的默认键，
    /// 正好是用户早先自己用掉的），用户改的那个赢，这个命令先没有快捷键。
    func combo(for shortcut: AppShortcut) -> KeyCombo? {
        guard let combo = assigned(shortcut) else { return nil }
        if overrides[shortcut.rawValue] == nil {
            let takenByOverride = AppShortcut.allCases.contains { other in
                other != shortcut && overrides[other.rawValue] == combo && !cleared.contains(other.rawValue)
            }
            if takenByOverride { return nil }
        }
        return combo
    }

    func isCustomized(_ shortcut: AppShortcut) -> Bool {
        overrides[shortcut.rawValue] != nil || cleared.contains(shortcut.rawValue)
    }

    /// 谁现在在用这个组合键（除了 except）。
    func holder(of combo: KeyCombo, except: AppShortcut? = nil) -> AppShortcut? {
        AppShortcut.allCases.first { $0 != except && self.combo(for: $0) == combo }
    }

    /// 把 combo 给 shortcut 行不行。
    func conflict(_ combo: KeyCombo, for shortcut: AppShortcut) -> ShortcutConflict? {
        if !combo.modifiers.contains(.command) && !combo.modifiers.contains(.control) { return .needsModifier }
        if let reason = ReservedShortcuts.reason(for: combo) { return .reserved(reason) }
        if let other = holder(of: combo, except: shortcut) { return .command(other) }
        return nil
    }

    // MARK: - 修改

    /// 改成 combo。有冲突时不改，返回冲突。和默认一样时等于恢复默认。
    @discardableResult
    mutating func assign(_ combo: KeyCombo, to shortcut: AppShortcut) -> ShortcutConflict? {
        if let conflict = conflict(combo, for: shortcut) { return conflict }
        set(combo, for: shortcut)
        return nil
    }

    /// 和另一个命令交换：shortcut 拿到 combo，原来用 combo 的那个命令拿到 shortcut 现在的组合键（没有就清空）。
    /// 只在冲突是「和拾掇另一个命令重复」时能换；成功返回被换掉的那个命令。
    @discardableResult
    mutating func swap(_ combo: KeyCombo, to shortcut: AppShortcut) -> AppShortcut? {
        guard case .command(let other)? = conflict(combo, for: shortcut) else { return nil }
        let mine = self.combo(for: shortcut)
        set(combo, for: shortcut)
        if let mine { set(mine, for: other) } else { clear(other) }
        return other
    }

    /// 清空（不要快捷键）。
    mutating func clear(_ shortcut: AppShortcut) {
        overrides[shortcut.rawValue] = nil
        if shortcut.defaultCombo != nil { cleared.insert(shortcut.rawValue) }
    }

    mutating func reset(_ shortcut: AppShortcut) {
        overrides[shortcut.rawValue] = nil
        cleared.remove(shortcut.rawValue)
    }

    mutating func resetAll() {
        let unknownOverrides = overrides.filter { AppShortcut(rawValue: $0.key) == nil }
        overrides = unknownOverrides
        cleared = cleared.filter { AppShortcut(rawValue: $0) == nil }
    }

    private mutating func set(_ combo: KeyCombo, for shortcut: AppShortcut) {
        cleared.remove(shortcut.rawValue)
        overrides[shortcut.rawValue] = combo == shortcut.defaultCombo ? nil : combo
    }

    // MARK: - 存取

    static func load(from defaults: UserDefaults) -> ShortcutSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return ShortcutSettings() }
        return decode(data) ?? ShortcutSettings()
    }

    func save(to defaults: UserDefaults) {
        if isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = encoded() {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func encoded(pretty: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// 读出来以后把不合规的去掉（导入别人给的文件、或者老版本存的）：没有 ⌘ / ⌃ 的、被占用的、和前面重复的。
    static func decode(_ data: Data) -> ShortcutSettings? {
        guard let raw = try? JSONDecoder().decode(ShortcutSettings.self, from: data) else { return nil }
        return raw.sanitized()
    }

    func sanitized() -> ShortcutSettings {
        var clean = self
        clean.version = Self.currentVersion
        // 不认识的命令 id 原样留着（更新的版本存的），这里只查认识的。
        for shortcut in AppShortcut.allCases {
            let id = shortcut.rawValue
            guard let combo = clean.overrides[id] else { continue }
            let noModifier = !combo.modifiers.contains(.command) && !combo.modifiers.contains(.control)
            if combo == shortcut.defaultCombo || clean.cleared.contains(id) || noModifier
                || ReservedShortcuts.reason(for: combo) != nil {
                clean.overrides[id] = nil
            }
        }
        // 两个命令改成了同一个组合键：留前面那个。
        var seen = Set<KeyCombo>()
        for shortcut in AppShortcut.allCases {
            guard let combo = clean.overrides[shortcut.rawValue] else { continue }
            if !seen.insert(combo).inserted { clean.overrides[shortcut.rawValue] = nil }
        }
        return clean
    }
}

extension AppShortcut {
    /// 出厂的组合键。
    var defaultCombo: KeyCombo? { KeyCombo(key, modifiers) }
}

/// 菜单和快捷键一起导出 / 导入的文件。
struct MenuShortcutsExport: Codable {
    static let formatName = "shiduo.menus-shortcuts"

    var format = MenuShortcutsExport.formatName
    var version = 1
    var shortcuts: ShortcutSettings
    var fileMenu: MenuLayout?
    var backgroundMenu: MenuLayout?

    init(shortcuts: ShortcutSettings, fileMenu: MenuLayout?, backgroundMenu: MenuLayout?) {
        self.shortcuts = shortcuts
        self.fileMenu = fileMenu
        self.backgroundMenu = backgroundMenu
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    /// 不是拾掇导出的文件返回 nil。菜单和默认菜单合并、快捷键去掉不合规的。
    static func decode(_ data: Data) -> MenuShortcutsExport? {
        guard let raw = try? JSONDecoder().decode(MenuShortcutsExport.self, from: data), raw.format == formatName else { return nil }
        var result = raw
        result.shortcuts = raw.shortcuts.sanitized()
        result.fileMenu = raw.fileMenu.map { $0.merged(withDefault: MenuCatalog.defaultLayout(.file)) }
        result.backgroundMenu = raw.backgroundMenu.map { $0.merged(withDefault: MenuCatalog.defaultLayout(.background)) }
        return result
    }
}
