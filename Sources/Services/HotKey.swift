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

// 悬浮暂存架的快捷键 FloatingShelfHotKey 在 Pro/ShortcutLogic.swift（单元测试也编译那个文件）。

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 每个全局快捷键一个编号，按下时根据编号找到对应的动作。
    enum Slot: UInt32 {
        case quickSearch = 1
        case floatingShelf = 2
    }

    private static let signature = OSType(0x5348_4459)  // "SHDY"

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var actions: [Slot: () -> Void] = [:]
    private var installed = false

    /// 快速搜索的动作（保留原来的接口）。
    var handler: (() -> Void)? {
        get { actions[.quickSearch] }
        set { actions[.quickSearch] = newValue }
    }

    /// 按设置注册或取消快速搜索的全局快捷键。返回 false 表示被别的 App 占用了。
    @discardableResult
    func apply() -> Bool {
        unregister(.quickSearch)
        guard QuickSearchHotKey.isEnabled else { return true }
        let key = QuickSearchHotKey.current
        return register(.quickSearch, keyCode: key.keyCode, modifiers: key.modifiers)
    }

    /// 悬浮暂存架的快捷键（FloatingShelfHotKey.current）：active 为 true 时注册，否则取消。返回 false 表示被别的 App 占用了。
    @discardableResult
    func applyFloatingShelf(active: Bool, action: @escaping () -> Void) -> Bool {
        unregister(.floatingShelf)
        actions[.floatingShelf] = action
        guard active else { return true }
        return register(.floatingShelf, keyCode: FloatingShelfHotKey.keyCode, modifiers: FloatingShelfHotKey.modifiers)
    }

    // MARK: 数字键直达（⌃⌘ 数字 / ⌃⌥⌘ 数字）

    private var extraRefs: [UInt32: EventHotKeyRef] = [:]
    private var extraActions: [UInt32: () -> Void] = [:]

    /// 注册或取消一个数字键组合。返回 false 表示被别的 App 占用了。
    @discardableResult
    func applyQuickPick(slot: Int, shift: Bool, keyCode: UInt32, active: Bool, action: @escaping () -> Void) -> Bool {
        let id = UInt32(100 + slot * 2 + (shift ? 1 : 0))
        if let ref = extraRefs[id] { UnregisterEventHotKey(ref) }
        extraRefs[id] = nil
        extraActions[id] = action
        guard active else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let modifiers = ShortcutLogic.quickPickModifiers(pathOnly: shift)
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        extraRefs[id] = ref
        return true
    }

    func isRegistered(_ slot: Slot) -> Bool { refs[slot] != nil }

    func unregister() { unregister(.quickSearch) }

    func unregister(_ slot: Slot) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
    }

    private func register(_ slot: Slot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[slot] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        guard let slot = Slot(rawValue: id) else {
            extraActions[id]?()
            return
        }
        actions[slot]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id: UInt32 = status == noErr ? hotKeyID.id : 1
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
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
