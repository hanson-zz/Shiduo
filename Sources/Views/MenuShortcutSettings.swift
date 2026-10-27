import AppKit
import SwiftUI

/// 设置 › 菜单与快捷键（拾掇 Pro）：右键菜单编辑（左边列表、右边实时预览）和快捷键编辑。
/// 免费用户能看到编辑器，但改不了，菜单和快捷键保持默认。
struct MenuShortcutSettingsView: View {
    @EnvironmentObject private var license: LicenseManager

    enum Page: String, Hashable { case menu, shortcuts }

    @AppStorage("settings.menus.page") private var page: Page = .menu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $page) {
                    Text("右键菜单").tag(Page.menu)
                    Text("快捷键").tag(Page.shortcuts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                ProBadge()
                Spacer()
                Menu("导入 / 导出") {
                    Button("导出菜单与快捷键…") { MenuShortcutsTransfer.export() }
                    Button("导入…") { MenuShortcutsTransfer.importFile() }
                }
                .fixedSize()
                .disabled(!license.isPro)
            }
            if !license.isPro {
                ProHintRow()
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                Text("免费版右键菜单和快捷键保持默认。解锁 Pro 后在这里改，马上生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                switch page {
                case .menu: ContextMenuEditor()
                case .shortcuts: ShortcutEditor()
                }
            }
            .disabled(!license.isPro)
        }
        .padding(16)
    }
}

// MARK: - 右键菜单编辑

/// 菜单项目对应的快捷键（预览里显示在右边）。
private func shortcutFor(menuItem id: String) -> AppShortcut? {
    switch id {
    case "cut": return .cut
    case "copy": return .copyItems
    case "copyPath": return .copyPath
    case "duplicate": return .duplicate
    case "makeAlias": return .makeAlias
    case "newFolderWithSelection": return .newFolderWithSelection
    case "newFolder": return .newFolder
    case "paste": return .paste
    case "pasteAndMove": return .pasteAndMove
    default: return nil
    }
}

struct ContextMenuEditor: View {
    @ObservedObject private var store = MenuLayoutStore.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @AppStorage("settings.menus.kind") private var kind: MenuKind = .file
    @State private var selection = Set<String>()
    @State private var collapsed = Set<String>()
    /// 新建分组 / 改分组名字的对话框。
    @State private var naming: Naming?
    @State private var nameText = ""

    private enum Naming: Identifiable {
        case create([String])
        case rename(String)
        var id: String {
            switch self {
            case .create(let ids): return "create:" + ids.joined(separator: ",")
            case .rename(let id): return "rename:" + id
            }
        }
    }

    private var layout: MenuLayout { store.layout(kind) }
    private var known: Set<String> { MenuCatalog.known(kind) }

    /// 选中的顶层项目（能收进分组的）。
    private var selectedItems: [String] {
        layout.entries.filter { $0.kind == .item && selection.contains($0.id) }.map(\.id)
    }

    private var groups: [MenuEntry] { layout.entries.filter { $0.kind == .group } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(MenuKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .onChange(of: kind) { selection = [] }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    list
                    HStack(spacing: 8) {
                        Button("收进分组…") {
                            nameText = ""
                            naming = .create(selectedItems)
                        }
                        .disabled(selectedItems.isEmpty)
                        .help("把选中的项目收进一个子菜单（按住 ⌘ 可多选）")
                        Button("添加分隔线") {
                            let after = layout.entries.last(where: { selection.contains($0.id) })?.id
                            store.update(kind) { $0.insertSeparator(after: after) }
                        }
                        Spacer()
                        Button("恢复默认") {
                            store.reset(kind)
                            selection = []
                        }
                        .disabled(MenuCatalog.isDefault(layout, kind: kind))
                    }
                    Text("拖动排序，取消勾选就隐藏。灰色说明是这一项什么时候才出现（比如单个文件才有「计算哈希」）。全部隐藏后，右键菜单里会留一项「自定义菜单…」回到这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        MenuPreview(entries: layout.resolved(known: known))
                            .padding(.bottom, 8)
                    }
                }
                .frame(width: 250)
            }
        }
        .sheet(item: $naming) { request in
            namingSheet(request)
        }
    }

    // MARK: 列表

    private var list: some View {
        List(selection: $selection) {
            ForEach(layout.entries.filter { $0.kind != .item || known.contains($0.id) }) { entry in
                row(entry)
                    .tag(entry.id)
            }
            .onMove { source, destination in
                // 列表里滤掉了不认识的项目：换算回完整清单里的位置再移动。
                let visible = layout.entries.filter { $0.kind != .item || known.contains($0.id) }
                let ids = source.map { visible[$0].id }
                let all = layout.entries
                let from = IndexSet(ids.compactMap { id in all.firstIndex { $0.id == id } })
                let to = destination < visible.count ? (all.firstIndex { $0.id == visible[destination].id } ?? all.count) : all.count
                store.update(kind) { $0.move(fromOffsets: from, toOffset: to) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .frame(minHeight: 300)
    }

    @ViewBuilder
    private func row(_ entry: MenuEntry) -> some View {
        switch entry.kind {
        case .item:
            itemRow(entry.id, inGroup: nil)
                .contextMenu { itemMenu(entry.id) }
        case .separator:
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(height: 1)
                Text("分隔线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.update(kind) { $0.removeSeparator(entry.id) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("删掉这条分隔线")
            }
            .padding(.vertical, 2)
        case .group:
            groupRow(entry)
        }
    }

    private func itemRow(_ id: String, inGroup groupID: String?) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !layout.isHidden(id) },
                set: { visible in store.update(kind) { $0.setHidden(id, !visible) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Text(MenuCatalog.title(id))
                .foregroundStyle(layout.isHidden(id) ? Color.secondary : Color.primary)
            if MenuCatalog.isSubmenu(id) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let note = MenuCatalog.note(id) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let groupID {
                let children = layout.entries.first { $0.id == groupID }?.children ?? []
                let index = children.firstIndex(of: id) ?? 0
                Button {
                    store.update(kind) { $0.moveChildren(inGroup: groupID, fromOffsets: [index], toOffset: index - 1) }
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("上移")
                Button {
                    store.update(kind) { $0.moveChildren(inGroup: groupID, fromOffsets: [index], toOffset: index + 2) }
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index >= children.count - 1)
                    .help("下移")
                Button {
                    store.update(kind) { $0.moveOutOfGroup(id) }
                } label: { Image(systemName: "arrow.up.left.square") }
                    .buttonStyle(.borderless)
                    .help("移出分组")
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func itemMenu(_ id: String) -> some View {
        if !groups.isEmpty {
            Menu("放进分组") {
                ForEach(groups) { group in
                    Button(group.title ?? "") { store.update(kind) { $0.moveIntoGroup(id, groupID: group.id) } }
                }
            }
        }
        Button("收进新分组…") {
            nameText = ""
            naming = .create(selection.contains(id) ? selectedItems : [id])
        }
        Button("在下面加分隔线") { store.update(kind) { $0.insertSeparator(after: id) } }
    }

    private func groupRow(_ entry: MenuEntry) -> some View {
        let open = !collapsed.contains(entry.id)
        let children = (entry.children ?? []).filter(known.contains)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if open { collapsed.insert(entry.id) } else { collapsed.remove(entry.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                Text(entry.title ?? "")
                    .fontWeight(.medium)
                Text("子菜单 · \(children.count) 项")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    nameText = entry.title ?? ""
                    naming = .rename(entry.id)
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("改名字")
                Button {
                    store.update(kind) { $0.ungroup(entry.id) }
                } label: { Image(systemName: "rectangle.expand.vertical") }
                    .buttonStyle(.borderless)
                    .help("解散分组（项目放回原处）")
            }
            if open {
                ForEach(children, id: \.self) { child in
                    itemRow(child, inGroup: entry.id)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 起名字

    private func namingSheet(_ request: Naming) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request {
            case .create(let ids):
                Text("收进分组")
                    .font(.headline)
                Text("这 \(ids.count) 项会收进一个子菜单，放在其中最靠前那一项的位置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .rename:
                Text("分组名字")
                    .font(.headline)
            }
            TextField("比如「更多」「开发」", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { commit(request) }
            HStack {
                Spacer()
                Button("取消") { naming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("好") { commit(request) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func commit(_ request: Naming) {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request {
        case .create(let ids):
            store.update(kind) { $0.group(ids, title: name.isEmpty ? String(localized: "更多") : name) }
            selection = []
        case .rename(let id):
            store.update(kind) { $0.renameGroup(id, to: name) }
        }
        naming = nil
    }
}

/// 右边的菜单预览：长得像系统右键菜单。只拿掉隐藏的项目（「单个文件才有」这类条件不管，全部显示）。
struct MenuPreview: View {
    let entries: [ResolvedMenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                previewRow(String(localized: "自定义菜单…"), trailing: nil)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let id):
                    previewRow(MenuCatalog.title(id), trailing: trailing(id))
                case .separator:
                    Divider().padding(.vertical, 4).padding(.horizontal, 8)
                case .submenu(let title, let items):
                    previewRow(title, trailing: "▸")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { id in
                            previewRow(MenuCatalog.title(id), trailing: trailing(id), dim: true)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func trailing(_ id: String) -> String? {
        if MenuCatalog.isSubmenu(id) { return "▸" }
        return shortcutFor(menuItem: id).map(\.currentDisplay).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func previewRow(_ title: String, trailing: String?, dim: Bool = false) -> some View {
        HStack {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: dim ? 12 : 13))
        .foregroundStyle(dim ? Color.secondary : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2.5)
    }
}

// MARK: - 快捷键编辑

/// 快捷键表的一个分区（和菜单栏的菜单一样分）。
private struct ShortcutSection: Identifiable {
    let title: String
    let items: [AppShortcut]
    var id: String { title }
    init(_ title: String, _ items: [AppShortcut]) {
        self.title = title
        self.items = items
    }
}

private let shortcutSections: [ShortcutSection] = {
    let sections: [ShortcutSection] = [
        ShortcutSection(String(localized: "文件"), [.newFolder, .newFromLastTemplate, .addToFolderWall, .imageTools, .newFolderWithSelection,
                                     .duplicate, .makeAlias, .deleteImmediately]),
        ShortcutSection(String(localized: "编辑"), [.cut, .copyItems, .paste, .pasteAndMove, .copyPath, .search, .copyText, .addToShelf]),
        ShortcutSection(String(localized: "显示"), [.asIcons, .asList, .showInfo, .showPreview, .toggleToolbar, .togglePathBar, .toggleStatusBar,
                                     .viewOptions, .biggerIcons, .smallerIcons, .refresh, .toggleSidebar]),
        ShortcutSection(String(localized: "前往"), [.back, .forward, .enclosingFolder, .openSelection, .home, .homeFolder, .desktop, .documents,
                                     .downloads, .downloadSources, .duplicates, .cleanup, .addressBar, .goToFolder, .commandPalette]),
        ShortcutSection(String(localized: "标签页"), [.newTab, .closeTab, .closeWindow, .nextTab, .previousTab, .nextTabAlt, .previousTabAlt]),
        ShortcutSection(String(localized: "双栏（Pro）"), [.dualHorizontal, .dualVertical, .focusFirstPane, .focusSecondPane, .copyToOtherPane, .moveToOtherPane]),
    ]
    let listed = Set(sections.flatMap(\.items))
    let rest = AppShortcut.allCases.filter { !listed.contains($0) }
    return rest.isEmpty ? sections : sections + [ShortcutSection(String(localized: "其他"), rest)]
}()

/// 正在录哪一个：装着 NSEvent 本地监听，录完 / 取消就拿掉。
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var target: AppShortcut?
    private var monitor: Any?

    func start(_ shortcut: AppShortcut, onKey: @escaping (NSEvent) -> Void) {
        stop()
        target = shortcut
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
    }
}

struct ShortcutEditor: View {
    @ObservedObject private var store = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var search = ""
    /// 刚按下、但不能直接用的组合键。
    @State private var pending: (shortcut: AppShortcut, combo: KeyCombo, conflict: ShortcutConflict)?

    private var sections: [ShortcutSection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return shortcutSections }
        return shortcutSections.compactMap { section in
            let hits = section.items.filter { s in
                s.title.lowercased().contains(q) || (store.combo(for: s)?.display.lowercased().contains(q) ?? false)
                    || s.display.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : ShortcutSection(section.title, hits)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("搜索命令或组合键", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Spacer()
                Button("全部恢复默认") {
                    recorder.stop()
                    pending = nil
                    store.update { $0.resetAll() }
                }
                .disabled(store.settings.isEmpty)
            }
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { shortcut in
                            row(shortcut)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 320)
            Text("点一下快捷键再按新的组合键；按 Esc 取消，按 ⌫ 清空（这个命令就不要快捷键）。组合键至少要带 ⌘ 或 ⌃；和系统、访达或拾掇别的命令撞了会标红，可以一键交换。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { recorder.stop() }
    }

    private func row(_ shortcut: AppShortcut) -> some View {
        let current = store.combo(for: shortcut)
        let isRecording = recorder.target == shortcut
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(shortcut.title)
                    .frame(width: 210, alignment: .leading)
                    .lineLimit(1)
                Button {
                    if isRecording { recorder.stop() } else { startRecording(shortcut) }
                } label: {
                    Text(isRecording ? String(localized: "按下组合键…") : (current?.display ?? String(localized: "未设置")))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(isRecording ? Color.accentColor : (current == nil ? Color.secondary : Color.primary))
                        .frame(width: 120)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(isRecording ? 0.05 : 0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help("点一下，再按新的组合键")
                Text("默认 \(shortcut.display)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 90, alignment: .leading)
                Spacer()
                if store.settings.isCustomized(shortcut) {
                    Button {
                        if pending?.shortcut == shortcut { pending = nil }
                        store.update { $0.reset(shortcut) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复默认")
                }
            }
            if let pending, pending.shortcut == shortcut {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(pending.combo.display)：\(pending.conflict.message)")
                    Spacer()
                    if case .command(let other) = pending.conflict {
                        Button("交换") {
                            store.update { $0.swap(pending.combo, to: shortcut) }
                            self.pending = nil
                        }
                        .help("这个命令用 \(pending.combo.display)，「\(other.title)」改用这个命令现在的组合键")
                    }
                    Button("取消") { self.pending = nil }
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
    }

    private func startRecording(_ shortcut: AppShortcut) {
        pending = nil
        recorder.start(shortcut) { event in
            handle(event, for: shortcut)
        }
    }

    private func handle(_ event: NSEvent, for shortcut: AppShortcut) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // Esc 取消；⌫ 清空（都不带修饰键时）。
        if flags.isEmpty, event.keyCode == 53 {
            recorder.stop()
            return
        }
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            recorder.stop()
            store.update { $0.clear(shortcut) }
            return
        }
        guard let key = KeyCombo.key(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: [])) else {
            NSSound.beep()
            return
        }
        var mods: KeyCombo.Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        let combo = KeyCombo(key: key, modifiers: mods)
        if combo == store.combo(for: shortcut) {
            recorder.stop()
            return
        }
        if let conflict = store.settings.conflict(combo, for: shortcut) {
            if conflict == .needsModifier {
                // 还没按修饰键就松手（比如只按了字母）：提示，继续录。
                pending = (shortcut, combo, conflict)
                NSSound.beep()
                return
            }
            recorder.stop()
            pending = (shortcut, combo, conflict)
            NSSound.beep()
            return
        }
        recorder.stop()
        pending = nil
        store.update { $0.assign(combo, to: shortcut) }
    }
}
