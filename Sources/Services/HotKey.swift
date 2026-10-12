import AppKit
import Carbon
import ServiceManagement

/// 全局快捷键可选项。用 Carbon 的 RegisterEventHotKey，不需要“辅助功能”权限。
enum QuickSearchHotKey: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionSpace
    case shiftOptionSpace
    case optionCommandK

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: return String(localized: "⌥ 空格")
        case .controlOptionSpace: return String(localized: "⌃⌥ 空格")
        case .shiftOptionSpace: return String(localized: "⇧⌥ 空格")
        case .optionCommandK: return "⌥⌘ K"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionCommandK: return UInt32(kVK_ANSI_K)
        default: return UInt32(kVK_Space)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(optionKey | controlKey)
        case .shiftOptionSpace: return UInt32(optionKey | shiftKey)
        case .optionCommandK: return UInt32(optionKey | cmdKey)
        }
    }

    static var current: QuickSearchHotKey {
        QuickSearchHotKey(rawValue: UserDefaults.standard.string(forKey: "quickSearchHotKey") ?? "") ?? .optionSpace
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "quickSearchEnabled") as? Bool ?? true
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var ref: EventHotKeyRef?
    private var installed = false
    var handler: (() -> Void)?

    /// 按设置注册或取消全局快捷键。返回 false 表示被别的 App 占用了。
    @discardableResult
    func apply() -> Bool {
        unregister()
        guard QuickSearchHotKey.isEnabled else { return true }
        installHandlerIfNeeded()
        let key = QuickSearchHotKey.current
        let id = EventHotKeyID(signature: OSType(0x5348_4459), id: 1)  // "SHDY"
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handler?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// 登录时自动打开拾掇（让全局搜索随时可用）。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 返回错误信息，成功时为 nil。
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return String(localized: "没能修改登录项：\(error.localizedDescription)。可以在“系统设置 › 通用 › 登录项”里手动添加拾掇。")
        }
    }
}
