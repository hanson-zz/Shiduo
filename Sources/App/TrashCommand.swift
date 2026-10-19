import AppKit
import AudioToolbox
import Quartz
import SwiftUI

/// 「文件」菜单里的「移到废纸篓 ⌘⌫」（和访达一样）。
///
/// 以前 ⌘⌫ 只靠网格 / 列表上的 onKeyPress，只有文件列表拿着键盘焦点时才管用（点过侧边栏、搜索框、
/// 开着快速查看、焦点在简介栏时都不灵）。现在改成菜单快捷键：每个能删文件的地方把「当前选中的文件」
/// 登记成一个上下文（跟它所在的窗口绑在一起），菜单只处理最前面那个窗口里最新登记的上下文。
/// 正在编辑文字时（搜索框、重命名框……）⌘⌫ 照样交给输入框，删到行首，不会删文件。
@MainActor
final class TrashCommandCenter: ObservableObject {
    static let shared = TrashCommandCenter()

    struct Context {
        let id: UUID
        weak var window: NSWindow?
        /// 登记时的选中（只用来判断菜单项能不能用，不用每次都去解析成文件）。
        var ids: Set<String>
        var items: () -> [FileItem]
        var perform: ([FileItem]) -> Void
    }

    /// 新登记的在后面。
    private var contexts: [Context] = []
    /// 选中、前台窗口变了时 +1，让菜单重新算能不能用。
    @Published private(set) var tick = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// App 启动时调用一次。
    func install() {
        guard monitor == nil else { return }
        // 菜单快捷键比输入框先拿到按键：正在编辑文字时把 ⌘⌫ / ⌥⌘⌫ / ⌘⌦ 直接交给输入框，不让菜单删文件。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard TrashKeys.isTrashShortcut(event),
                  let text = event.window?.firstResponder as? NSTextView,
                  text.isEditable else { return event }
            text.keyDown(with: event)
            return nil
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TrashCommandCenter.shared.changed() }
            })
        }
    }

    func register(_ id: UUID, window: NSWindow?, ids: Set<String>,
                  items: @escaping () -> [FileItem], perform: @escaping ([FileItem]) -> Void) {
        contexts.removeAll { $0.id == id || $0.window == nil }
        contexts.append(Context(id: id, window: window, ids: ids, items: items, perform: perform))
        changed()
    }

    func unregister(_ id: UUID) {
        contexts.removeAll { $0.id == id || $0.window == nil }
        changed()
    }

    func changed() { tick &+= 1 }

    /// 菜单要处理的窗口：前台窗口；系统快速查看面板在最前面时，处理它背后的主窗口（和访达一样，预览着也能 ⌘⌫）。
    private var targetWindow: NSWindow? {
        guard let key = NSApp.keyWindow else { return nil }
        if key is QLPreviewPanel { return NSApp.mainWindow }
        return key
    }

    private var current: Context? {
        guard let window = targetWindow else { return nil }
        return contexts.last { $0.window === window }
    }

    /// 前台窗口里有选中、可以移到废纸篓的文件（菜单项是否可用）。
    var canTrash: Bool {
        _ = tick
        return !(current?.ids.isEmpty ?? true)
    }

    /// 菜单「移到废纸篓」。
    func trashCurrent() {
        guard let context = current else { return }
        let list = context.items()
        guard !list.isEmpty else { return }
        context.perform(list)
    }

    /// 菜单「立即删除…」：先确认（不能撤销），确认后才真正删除。
    func deleteCurrentImmediately() {
        guard let context = current, let store = LibraryStore.shared else { return }
        let list = context.items()
        guard !list.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = list.count == 1
            ? String(localized: "确定要立即删除“\(list[0].name)”吗？")
            : String(localized: "确定要立即删除这 \(list.count) 个项目吗？")
        alert.informativeText = String(localized: "此操作不能撤销，也不会进废纸篓。只在 iCloud 云端的文件会被跳过。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        let window = context.window
        let run: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            store.deleteImmediately(list)
        }
        if let window, window.attachedSheet == nil, !(window is NSPanel) {
            alert.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(alert.runModal())
        }
    }
}

/// ⌘⌫、⌘⌦（移到废纸篓）和 ⌥⌘⌫（立即删除）。
enum TrashKeys {
    /// ⌫ 和 ⌦ 的虚拟键码。
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117

    static func isTrashShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == deleteKeyCode || event.keyCode == forwardDeleteKeyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags == .command || flags == [.command, .option]
    }
}

/// 「文件」菜单：移到废纸篓 ⌘⌫、立即删除… ⌥⌘⌫。
struct TrashCommands: Commands {
    @ObservedObject var center: TrashCommandCenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("移到废纸篓") { center.trashCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!center.canTrash)
            Button("立即删除…") { center.deleteCurrentImmediately() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!center.canTrash)
        }
    }
}

/// 让一块界面成为 ⌘⌫ 的处理对象：items 是这块界面当前选中的文件，perform 默认就是移到废纸篓。
/// ids 变化时（选中变了）重新登记，菜单项随之可用 / 不可用。
struct TrashContextModifier: ViewModifier {
    let ids: Set<String>
    let items: () -> [FileItem]
    /// nil：移到废纸篓（LibraryStore.moveToTrash）。
    let perform: (([FileItem]) -> Void)?

    @State private var id = UUID()
    @State private var window: NSWindow?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; TrashCommandCenter.shared.unregister(id) }
            .onChange(of: ids) { update() }
            .onChange(of: window) { update() }
    }

    @MainActor
    private func update() {
        guard visible, let window else { return }
        let perform = self.perform ?? { LibraryStore.shared?.moveToTrash($0) }
        TrashCommandCenter.shared.register(id, window: window, ids: ids, items: items, perform: perform)
    }
}

extension View {
    /// 见 TrashContextModifier。
    func trashContext(ids: Set<String>, items: @escaping () -> [FileItem],
                      perform: (([FileItem]) -> Void)? = nil) -> some View {
        modifier(TrashContextModifier(ids: ids, items: items, perform: perform))
    }
}

/// 找到这块界面所在的窗口。
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.found = found
    }
}

final class WindowReaderView: NSView {
    var found: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = self.window
        // 不在视图更新的过程中改 @State。
        DispatchQueue.main.async { [weak self] in self?.found?(window) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 移到废纸篓的声音（和访达一样）。系统设置里关掉了「播放用户界面音效」就不响；声音文件找不到时什么都不做。
enum TrashSound {
    private static let candidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
    ]

    @MainActor private static var soundID: SystemSoundID?
    @MainActor private static var loaded = false

    /// 系统设置 › 声音 ›「播放用户界面音效」。读不到时按打开处理（系统默认就是打开的）。
    static var userInterfaceSoundsEnabled: Bool {
        let value = CFPreferencesCopyValue("com.apple.sound.uiaudio.enabled" as CFString,
                                           "com.apple.systemsound" as CFString,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    @MainActor
    static func play() {
        guard userInterfaceSoundsEnabled else { return }
        if !loaded {
            loaded = true
            if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                var id: SystemSoundID = 0
                if AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == kAudioServicesNoError {
                    soundID = id
                }
            }
        }
        // 系统音效：跟着「提醒音量」，和访达的声音一样大。
        if let soundID { AudioServicesPlaySystemSound(soundID) }
    }
}
