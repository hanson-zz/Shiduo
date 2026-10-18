import Carbon
import Foundation

/// 全局快捷键里不依赖界面的部分（单元测试会编译这个文件）。
enum ShortcutLogic {
    /// macOS 自带、或常用 App 普遍占用的组合（Carbon 修饰键 + 键码）。
    /// RegisterEventHotKey 撞上这些时往往不会报错，只会悄悄抢走别人的快捷键，所以默认值要避开它们。
    struct Combo: Hashable {
        let modifiers: UInt32
        let keyCode: UInt32
    }

    static let knownConflicts: [Combo: String] = [
        Combo(modifiers: UInt32(cmdKey | shiftKey), keyCode: UInt32(kVK_ANSI_3)): String(localized: "截屏"),
        Combo(modifiers: UInt32(cmdKey | shiftKey), keyCode: UInt32(kVK_ANSI_4)): String(localized: "截屏"),
        Combo(modifiers: UInt32(cmdKey | shiftKey), keyCode: UInt32(kVK_ANSI_5)): String(localized: "截屏"),
        Combo(modifiers: UInt32(cmdKey | shiftKey | controlKey), keyCode: UInt32(kVK_ANSI_3)): String(localized: "截屏到剪贴板"),
        Combo(modifiers: UInt32(cmdKey | shiftKey | controlKey), keyCode: UInt32(kVK_ANSI_4)): String(localized: "截屏到剪贴板"),
        Combo(modifiers: UInt32(cmdKey | shiftKey | controlKey), keyCode: UInt32(kVK_ANSI_5)): String(localized: "截屏到剪贴板"),
        Combo(modifiers: UInt32(cmdKey | optionKey), keyCode: UInt32(kVK_ANSI_S)): String(localized: "全部存储（Xcode、VS Code）"),
        Combo(modifiers: UInt32(cmdKey | optionKey), keyCode: UInt32(kVK_Escape)): String(localized: "强制退出"),
        Combo(modifiers: UInt32(cmdKey | controlKey), keyCode: UInt32(kVK_ANSI_Q)): String(localized: "锁定屏幕"),
        Combo(modifiers: UInt32(cmdKey | controlKey), keyCode: UInt32(kVK_ANSI_F)): String(localized: "全屏"),
        Combo(modifiers: UInt32(cmdKey | controlKey), keyCode: UInt32(kVK_Space)): String(localized: "表情与符号"),
        Combo(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_Space)): String(localized: "聚焦"),
        Combo(modifiers: UInt32(cmdKey | optionKey), keyCode: UInt32(kVK_Space)): String(localized: "访达搜索"),
        Combo(modifiers: UInt32(cmdKey | optionKey), keyCode: UInt32(kVK_ANSI_D)): String(localized: "显示 / 隐藏程序坞"),
    ]

    static func conflict(modifiers: UInt32, keyCode: UInt32) -> String? {
        knownConflicts[Combo(modifiers: modifiers, keyCode: keyCode)]
    }

    /// 数字键直达：拷贝文件用 ⌃⌘ 数字；只拷贝路径用 ⌃⌥⌘ 数字。
    /// 以前是 ⌃⇧⌘ 数字，其中 ⌃⇧⌘3/4/5 正是系统的「截屏到剪贴板」。
    static func quickPickModifiers(pathOnly: Bool) -> UInt32 {
        pathOnly ? UInt32(controlKey | optionKey | cmdKey) : UInt32(controlKey | cmdKey)
    }

    /// 数字 1…9、0 对应的键码。
    static let digitKeys: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5),
        UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9), UInt32(kVK_ANSI_0),
    ]
}

/// 悬浮暂存架的全局快捷键（可在设置里换）。只在 Pro 且打开了悬浮暂存架时注册。
/// 以前固定是 ⌥⌘S，会抢走 Xcode / VS Code 的「全部存储」，所以默认改成 ⌃⌥S；想用回 ⌥⌘S 的可以自己选。
enum FloatingShelfHotKey: String, CaseIterable, Identifiable {
    case controlOptionS
    case optionCommandPeriod
    case controlOptionCommandS
    case optionCommandS

    static let enabledKey = "floatingShelfHotKeyEnabled"
    static let choiceKey = "floatingShelfHotKey"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionS: return "⌃⌥ S"
        case .optionCommandPeriod: return "⌥⌘ ."
        case .controlOptionCommandS: return "⌃⌥⌘ S"
        case .optionCommandS: return "⌥⌘ S"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionCommandPeriod: return UInt32(kVK_ANSI_Period)
        default: return UInt32(kVK_ANSI_S)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionS: return UInt32(controlKey | optionKey)
        case .optionCommandPeriod: return UInt32(optionKey | cmdKey)
        case .controlOptionCommandS: return UInt32(controlKey | optionKey | cmdKey)
        case .optionCommandS: return UInt32(optionKey | cmdKey)
        }
    }

    /// 已知会和别的 App 冲突的说明；nil 表示没发现冲突。
    var conflict: String? { ShortcutLogic.conflict(modifiers: modifiers, keyCode: keyCode) }

    static func from(_ raw: String?) -> FloatingShelfHotKey {
        raw.flatMap(FloatingShelfHotKey.init(rawValue:)) ?? .controlOptionS
    }

    static var current: FloatingShelfHotKey {
        from(UserDefaults.standard.string(forKey: choiceKey))
    }

    // 旧接口：按当前选择。
    static var title: String { current.title }
    static var keyCode: UInt32 { current.keyCode }
    static var modifiers: UInt32 { current.modifiers }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
