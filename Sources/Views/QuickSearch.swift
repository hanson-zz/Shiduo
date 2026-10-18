import AppKit
import SwiftUI

/// 在任何 App 里按快捷键弹出的搜索浮窗：搜到后回车打开、⌘回车在访达中显示，或者直接拖走。
@MainActor
final class QuickSearchModel: ObservableObject {
    @Published var text = "" {
        didSet { if text != oldValue { schedule() } }
    }
    @Published var results: [FileItem] = []
    @Published var selected = 0
    @Published var isSearching = false
    @Published var query: SearchQuery?
    /// 每次弹出都 +1，让输入框重新获得焦点。
    @Published var focusRequest = 0

    weak var store: LibraryStore?
    private var task: Task<Void, Never>?

    var recent: [FileItem] {
        guard let store else { return [] }
        var seen = Set<String>()
        return store.shelves.flatMap(\.items)
            .sorted { $0.recentDate > $1.recentDate }
            .filter { seen.insert($0.path).inserted }
            .prefix(12)
            .map { $0 }
    }

    var visible: [FileItem] { text.trimmingCharacters(in: .whitespaces).isEmpty ? recent : results }

    var current: FileItem? {
        let list = visible
        return list.indices.contains(selected) ? list[selected] : nil
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
    }

    private func schedule() {
        task?.cancel()
        selected = 0
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            results = []
            query = nil
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let parsed = QueryParser().parse(raw)
            let q = parsed.isEmpty ? SearchQuery(text: raw) : parsed
            let found = await Queries.search(q)
            guard !Task.isCancelled else { return }
            query = q
            results = Array(found.prefix(60))
            store?.remember(results)
            isSearching = false
        }
    }
}

final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickSearchController: NSObject, NSWindowDelegate {
    static let shared = QuickSearchController()

    let model = QuickSearchModel()
    private var panel: QuickSearchPanel?
    private var monitor: Any?

    func configure(store: LibraryStore) {
        model.store = store
        HotKeyCenter.shared.handler = { [weak self] in self?.toggle() }
        HotKeyCenter.shared.apply()
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.16))
        }
        model.text = ""
        model.focusRequest += 1
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let root = QuickSearchView(
            model: model,
            open: { [weak self] in self?.open($0) },
            reveal: { [weak self] in self?.reveal($0) },
            showAll: { [weak self] in self?.showAllInApp() }
        )
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// ↑ ↓ 选择，回车打开，⌘回车在访达中显示，Esc 关闭。
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch Int(event.keyCode) {
            case 125: self.model.move(1); return nil          // ↓
            case 126: self.model.move(-1); return nil         // ↑
            case 53: self.hide(); return nil                  // Esc
            case 36, 76:                                      // 回车
                guard let item = self.model.current else { return nil }
                if event.modifierFlags.contains(.command) { self.reveal(item) } else { self.open(item) }
                return nil
            default: return event
            }
        }
    }

    private func open(_ item: FileItem) {
        hide()
        // 文件夹在拾掇主窗口里打开，不跳到访达
        if item.isDirectory, let store = model.store {
            MainWindow.show { store.openFolder(item.url) }
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    private func reveal(_ item: FileItem) {
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func showAllInApp() {
        let text = model.text
        hide()
        let store = model.store
        MainWindow.show {
            guard let store, !text.isEmpty else { return }
            store.searchText = text
            store.submitSearch()
        }
    }
}

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchModel
    let open: (FileItem) -> Void
    let reveal: (FileItem) -> Void
    let showAll: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索文件，比如“上周的pdf”“nianbao”", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if let chips = model.query?.chips, chips.count > 1 || model.query?.text.isEmpty == true {
                HStack(spacing: 6) {
                    Text("理解为").font(.caption).foregroundStyle(.secondary)
                    ForEach(chips) { chip in
                        Label(chip.label, systemImage: chip.symbol)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 680, height: 460)
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
    }

    @ViewBuilder
    private var results: some View {
        let list = model.visible
        if list.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.text.isEmpty ? "sparkle.magnifyingglass" : "doc.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(model.text.isEmpty ? String(localized: "输入文件名、拼音首字母，或者一句话") : (model.isSearching ? String(localized: "正在查找…") : String(localized: "没有找到匹配的文件")))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.text.isEmpty {
                            Text("最近")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            QuickSearchRow(item: item, selected: index == model.selected)
                                .id(item.id)
                                .onTapGesture(count: 2) { open(item) }
                                .onTapGesture { model.selected = index }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .contextMenu {
                                    Button("打开") { open(item) }
                                    Button("在访达中显示") { reveal(item) }
                                    Button("拷贝路径") { FileActions.copy(item.path) }
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selected) {
                    if let item = model.current { proxy.scrollTo(item.id, anchor: nil) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↩ 打开").foregroundStyle(.secondary)
            Text("⌘↩ 在访达中显示").foregroundStyle(.secondary)
            Text("可直接拖到其他 App").foregroundStyle(.secondary)
            Spacer()
            if !model.text.isEmpty {
                Button("在拾掇中查看全部结果", action: showAll)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

struct QuickSearchRow: View {
    let item: FileItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.url, size: 32)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folderText)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(item.sizeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var folderText: String {
        let dir = (item.path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + String(dir.dropFirst(home.count)) : dir
    }
}
