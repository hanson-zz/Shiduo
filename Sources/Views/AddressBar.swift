import AppKit
import SwiftUI

// MARK: - 能接住 ↑↓ / Tab / ↩ / Esc 的单行输入框

/// 地址栏和命令面板共用的输入框。SwiftUI 的 TextField 在 macOS 14 上拿不到 Tab / ↑↓（被系统先吃掉），
/// 所以用 NSTextField，在 doCommandBy 里把这几个键交给调用者。
struct KeyCommandTextField: NSViewRepresentable {
    enum Command { case up, down, tab, enter, escape }

    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    /// 出现时就拿到键盘焦点，光标放在最后。
    var focusOnAppear = true
    /// 返回 true 表示已经处理（不再交给系统）。
    var onCommand: (Command) -> Bool
    /// 失去焦点（点到别处）。
    var onFocusLost: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear { Self.focus(field, attempts: 6) }
        return field
    }

    /// 输入框刚放进窗口时 window 可能还是 nil：等一下再试几次。
    private static func focus(_ field: NSTextField, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 6 ? 0 : 0.05)) {
            guard let window = field.window else {
                if attempts > 1 { focus(field, attempts: attempts - 1) }
                return
            }
            window.makeFirstResponder(field)
            moveCursorToEnd(field)
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            Self.moveCursorToEnd(field)
        }
        if field.font != font { field.font = font }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func moveCursorToEnd(_ field: NSTextField) {
        guard let editor = field.currentEditor() else { return }
        let length = (field.stringValue as NSString).length
        editor.selectedRange = NSRange(location: length, length: 0)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyCommandTextField

        init(_ parent: KeyCommandTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onCommand(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onCommand(.tab)
            case #selector(NSResponder.insertNewline(_:)): return parent.onCommand(.enter)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.escape)
            default: return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusLost?()
        }
    }
}

// MARK: - 地址栏状态

/// 可输入地址栏（⌘L / ⇧⌘G / 点路径栏）：输入路径、补全子文件夹、回车前往。
/// 主窗口共用一个 store，所以这里也只有一份；记下是在哪个窗口里打开的，只在那个窗口里显示。
@MainActor
final class AddressBarModel: ObservableObject {
    static let shared = AddressBarModel()

    @Published private(set) var isEditing = false
    @Published var text = "" {
        didSet {
            guard text != oldValue, isEditing, !settingText else { return }
            userMoved = false
            highlighted = 0
            error = nil
            scheduleSuggestions()
        }
    }
    /// 补全下拉里的子文件夹名字。
    @Published private(set) var suggestions: [String] = []
    @Published var highlighted = 0
    @Published private(set) var error: String?
    /// 每次出错加一（输入框左右抖一下）。
    @Published private(set) var shakeTick = 0
    private(set) var windowID: ObjectIdentifier?

    /// 用 ↑↓ 选过：回车去选中的那个，而不是输入的文字。
    private var userMoved = false
    private var settingText = false
    /// 开始输入时的当前文件夹（相对路径从这里算）。
    private var base: String?
    private var listingCache: [String: [String]] = [:]
    private var suggestTask: Task<Void, Never>?
    private var cancelWork: DispatchWorkItem?

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func isEditing(in window: NSWindow?) -> Bool {
        isEditing && (windowID == nil || window.map(ObjectIdentifier.init) == windowID)
    }

    /// 进入输入：框里是当前文件夹（~/文稿/工作/），光标在最后，下拉列出它的子文件夹。
    func begin(in window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow
        cancelWork?.cancel()
        let store = LibraryStore.shared
        base = store?.activeQuery == nil ? store?.currentFolder : nil
        windowID = window.map(ObjectIdentifier.init)
        listingCache = [:]
        error = nil
        userMoved = false
        highlighted = 0
        settingText = true
        text = base.map { AddressBarLogic.displayPath($0, home: home) } ?? "~/"
        settingText = false
        isEditing = true
        scheduleSuggestions(immediately: true)
    }

    func cancel() {
        cancelWork?.cancel()
        suggestTask?.cancel()
        isEditing = false
        suggestions = []
        error = nil
    }

    /// 点到别处：稍等一下再收起（点补全下拉里的一行时输入框会先失去焦点）。
    func focusLost() {
        guard isEditing else { return }
        cancelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }
        cancelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func handle(_ command: KeyCommandTextField.Command) -> Bool {
        switch command {
        case .up: moveHighlight(-1)
        case .down: moveHighlight(1)
        case .tab: complete()
        case .enter: commit()
        case .escape: cancel()
        }
        return true
    }

    private func moveHighlight(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), suggestions.count - 1)
        userMoved = true
    }

    /// Tab：补全成选中的子文件夹，后面带 /，接着列它里面的。
    private func complete() {
        guard suggestions.indices.contains(highlighted) else {
            NSSound.beep()
            return
        }
        text = AddressBarLogic.completion(for: text, picking: suggestions[highlighted])
    }

    /// 回车：用 ↑↓ 选过就去选中的；否则去输入的路径（文件：打开所在文件夹并选中）；
    /// 输入的不存在但下拉里有候选，就去高亮的那个；都没有就抖一下、提示找不到。
    private func commit() {
        if userMoved, suggestions.indices.contains(highlighted) {
            pick(suggestions[highlighted])
            return
        }
        guard let path = AddressBarLogic.resolve(text, current: base, home: home) else {
            cancel()
            return
        }
        let fallback = suggestions.indices.contains(highlighted) && !AddressBarLogic.split(text).partial.isEmpty
            ? suggestions[highlighted] : nil
        Task {
            let kind = await Task.detached(priority: .userInitiated) { Self.kind(of: path) }.value
            guard self.isEditing else { return }
            switch kind {
            case .folder:
                self.finish()
                LibraryStore.shared?.openFolder(URL(fileURLWithPath: path, isDirectory: true))
            case .file:
                self.finish()
                LibraryStore.shared?.revealInFolder(URL(fileURLWithPath: path))
            case .missing:
                if let fallback {
                    self.pick(fallback)
                } else {
                    self.fail(String(localized: "找不到「\((path as NSString).lastPathComponent)」，检查一下路径"))
                }
            }
        }
    }

    /// 点补全下拉里的一行，或回车选中的那行：直接进那个文件夹。
    func pick(_ name: String) {
        guard isEditing else { return }
        let folder = AddressBarLogic.listingFolder(for: text, current: base, home: home)
        let path = (folder as NSString).appendingPathComponent(name)
        finish()
        LibraryStore.shared?.openFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func finish() {
        cancelWork?.cancel()
        suggestTask?.cancel()
        isEditing = false
        suggestions = []
        error = nil
    }

    private func fail(_ message: String) {
        error = message
        shakeTick += 1
        NSSound.beep()
    }

    // MARK: 补全

    private func scheduleSuggestions(immediately: Bool = false) {
        suggestTask?.cancel()
        let input = text
        let folder = AddressBarLogic.listingFolder(for: input, current: base, home: home)
        let partial = AddressBarLogic.split(input).partial
        let cached = listingCache[folder]
        suggestTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return }
            // 读文件夹、排序都不在主线程（几万个子项的文件夹也不卡输入）。
            let (names, ranked) = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                let names = cached ?? Self.subfolderNames(folder)
                return (names, AddressBarLogic.rank(names, partial: partial))
            }.value
            guard let self, !Task.isCancelled, self.isEditing, self.text == input else { return }
            self.listingCache[folder] = names
            self.suggestions = ranked
            if self.highlighted >= ranked.count { self.highlighted = 0 }
        }
    }

    private enum Kind { case folder, file, missing }

    nonisolated private static func kind(of path: String) -> Kind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: path) { return .folder }
        return .file
    }

    /// 文件夹里能进去的子文件夹（.app 这类文件包不算；指向文件夹的替身 / 链接算）。
    nonisolated static func subfolderNames(_ folder: String) -> [String] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        return urls.compactMap { child -> String? in
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true {
                var isDir: ObjCBool = false
                let target = child.resolvingSymlinksInPath().path
                guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else { return nil }
                return child.lastPathComponent
            }
            guard values.isDirectory == true, values.isPackage != true else { return nil }
            return child.lastPathComponent
        }
    }
}

// MARK: - 地址栏界面

/// 输入状态的地址栏：玻璃输入框（右边「↩ 前往 ⇥ 补全」）+ 下面的补全下拉 + 出错提示。
struct AddressBarEditor: View {
    @ObservedObject var model: AddressBarModel = .shared
    /// 下拉宽度跟着输入框，最多这么宽。
    var maxDropdownWidth: CGFloat = 420

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            KeyCommandTextField(text: $model.text,
                                placeholder: String(localized: "输入路径，比如 ~/文稿/工作"),
                                font: .systemFont(ofSize: 13),
                                onCommand: { model.handle($0) },
                                onFocusLost: { model.focusLost() })
                .frame(height: 20)
            HStack(spacing: 10) {
                Text("↩ 前往")
                Text("⇥ 补全")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
        .overlay(shape.strokeBorder(model.error == nil ? Color.accentColor.opacity(0.8) : Color.red.opacity(0.8), lineWidth: 1.5))
        .modifier(ShakeEffect(travel: 6, shakes: CGFloat(model.shakeTick)))
        .animation(.linear(duration: 0.35), value: model.shakeTick)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .modifier(HoverGlassBackground(shape: RoundedRectangle(cornerRadius: 8, style: .continuous)))
                } else if !model.suggestions.isEmpty {
                    AddressSuggestionList(model: model)
                        .frame(maxWidth: maxDropdownWidth, alignment: .leading)
                }
            }
            .offset(y: 34)
        }
        .zIndex(10)
    }
}

/// 补全下拉：玻璃浮层，选中的一行蓝底，点一下进去。
private struct AddressSuggestionList: View {
    @ObservedObject var model: AddressBarModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, name in
                        let selected = index == model.highlighted
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(selected ? Color.white : Color.accentColor)
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                        // 按下就算（输入框失去焦点后下拉会收起，等松手就来不及了）。
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.pick(name) })
                        .onHover { if $0 { model.highlighted = index } }
                        .id(index)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: min(CGFloat(model.suggestions.count) * 27 + 12, 300))
            .onChange(of: model.highlighted) { proxy.scrollTo(model.highlighted) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 240)
        .modifier(HoverGlassBackground(shape: shape))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
    }
}

/// 出错时左右抖一下。
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}

/// 不在文件夹页面时（首页、资料库、搜索结果……）按 ⌘L：在内容顶部浮出地址栏。
struct FloatingAddressBar: View {
    @ObservedObject private var model = AddressBarModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AddressBarEditor(model: model, maxDropdownWidth: 520)
            if model.error == nil, model.suggestions.isEmpty {
                Text("⌘L 或点路径栏进入输入；也能粘贴完整路径，文件会在所在文件夹里选中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .offset(y: 4)
            }
        }
        .padding(10)
        .modifier(HoverGlassBackground(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}
