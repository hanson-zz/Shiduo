import AppKit
import SwiftUI

extension FileItem {
    /// 关掉「显示文件扩展名」时去掉扩展名（文件夹、App 这类包不动）。
    func shownName(extensions: Bool) -> String {
        guard !extensions, !isDirectory else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}

// MARK: 查看显示选项（⌘J）

/// 浮在窗口上的小面板（和访达的「查看显示选项」一样）：改动马上生效，不挡住主窗口的键盘焦点。
@MainActor
final class ViewOptionsPanel: NSObject, NSWindowDelegate {
    static let shared = ViewOptionsPanel()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(store: LibraryStore) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let panel = self.panel ?? make(store: store)
        self.panel = panel
        place(panel)
        panel.orderFront(nil)
    }

    private func make(store: LibraryStore) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.title = String(localized: "显示选项")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingController(rootView: ViewOptionsView().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        return panel
    }

    /// 放在主窗口右上角（没有主窗口就放屏幕中间）。
    private func place(_ panel: NSPanel) {
        guard let main = NSApp.mainWindow ?? NSApp.keyWindow, main !== panel else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = NSPoint(x: main.frame.maxX - size.width - 24, y: main.frame.maxY - size.height - 96)
        panel.setFrameOrigin(origin)
    }
}

struct ViewOptionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 120
    @AppStorage(ViewPrefs.sortKeyKey) private var sortKey: FileSortKey = .date
    @AppStorage(ViewPrefs.sortAscendingKey) private var sortAscending = false
    @AppStorage(ViewPrefs.showExtensionsKey) private var showExtensions = true
    @AppStorage(ViewPrefs.showItemInfoKey) private var showItemInfo = true
    @AppStorage(Queries.showHiddenFilesKey) private var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("显示方式", selection: $viewMode) {
                Label("图标", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("列表", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text("图标大小")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.caption)
                    Slider(value: $thumbnailSize, in: 64...256)
                    Image(systemName: "photo").font(.title3)
                }
                .foregroundStyle(.secondary)
            }
            .disabled(viewMode != .grid)

            Divider()

            Picker("排序方式", selection: Binding(
                get: { sortKey },
                set: { key in
                    sortKey = key
                    sortAscending = key.defaultAscending
                }
            )) {
                ForEach(FileSortKey.allCases) { Text($0.title).tag($0) }
            }
            Picker("顺序", selection: $sortAscending) {
                Text("升序").tag(true)
                Text("降序").tag(false)
            }
            .pickerStyle(.segmented)

            Divider()

            Toggle("显示文件扩展名", isOn: $showExtensions)
            Toggle("在图标下显示大小", isOn: $showItemInfo)
                .disabled(viewMode != .grid)
            Toggle("显示隐藏文件（文件夹页面）", isOn: Binding(
                get: { showHidden },
                set: { on in
                    showHidden = on
                    if store.currentFolder != nil && store.activeQuery == nil { store.reload() }
                }
            ))
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 底部的路径栏和状态栏

/// 文件列表底部的一条：左边是路径栏（⌥⌘P），右边是状态栏（⌘/：「N 项，已选 M 项，可用 X」）。
/// 路径栏在文件夹里显示当前位置（选中了文件再加上这个文件），在搜索结果等其他页面显示选中文件的位置。
/// 点路径里的任意一层都在拾掇里打开那个文件夹；右键可以拷贝路径、在访达中显示。
struct BrowserBottomBar: View {
    @EnvironmentObject private var store: LibraryStore
    let itemCount: Int
    /// 选中的那一个（选了多个时是排在最前的那个）。
    let selected: FileItem?
    let selectedCount: Int
    @AppStorage(ViewPrefs.showPathBarKey) private var showPath = true
    @AppStorage(ViewPrefs.showStatusBarKey) private var showStatus = true
    @State private var freeSpace: Int64?

    /// 路径栏要显示到哪里。
    private var pathTarget: String? {
        if let selected { return selected.path }
        if store.activeQuery == nil, let folder = store.currentFolder { return folder }
        return nil
    }

    /// 算剩余空间用哪个位置：当前文件夹所在的磁盘，其他页面用选中文件所在的磁盘，都没有就用个人文件夹。
    private var volumeProbe: String {
        if store.activeQuery == nil, let folder = store.currentFolder { return folder }
        if let selected { return selected.url.deletingLastPathComponent().path }
        return NSHomeDirectory()
    }

    private var hasPath: Bool { showPath && pathTarget != nil }

    var body: some View {
        if hasPath || showStatus {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    if hasPath, let target = pathTarget {
                        PathBarCrumbs(path: target, isFile: selected.map { !$0.isDirectory } ?? false)
                    }
                    Spacer(minLength: 8)
                    if showStatus {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
            // 换了文件夹 / 磁盘，或文件数变了（删了、拷进来），在后台重新算剩余空间。
            .task(id: showStatus ? "\(volumeProbe)#\(itemCount)" : "") {
                guard showStatus else { return }
                freeSpace = await Self.availableCapacity(at: volumeProbe)
            }
        }
    }

    private var statusText: String {
        let separator = String(localized: "status.separator", defaultValue: "，")
        var parts = [String(localized: "\(itemCount) 项")]
        if selectedCount > 0 { parts.append(String(localized: "已选 \(selectedCount) 项")) }
        if let freeSpace { parts.append(String(localized: "可用 \(freeSpace.byteText)")) }
        return parts.joined(separator: separator)
    }

    /// 这个位置所在磁盘的可用空间（不在主线程上读）。
    static func availableCapacity(at path: String) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
            return values?.volumeAvailableCapacity.map { Int64($0) }
        }.value
    }
}

/// 路径栏里可点的每一层。
private struct PathBarCrumbs: View {
    @EnvironmentObject private var store: LibraryStore
    let path: String
    /// 最后一层是文件（不是文件夹）。
    let isFile: Bool

    var body: some View {
        let list = PathLogic.crumbs(for: path, home: NSHomeDirectory())
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        segment(crumb, index: index, last: index == list.count - 1)
                            .id(crumb)
                    }
                }
            }
            // 路径太长时让最后一层露出来。
            .onAppear { if let last = list.last { proxy.scrollTo(last, anchor: .trailing) } }
            .onChange(of: path) { if let last = list.last { proxy.scrollTo(last, anchor: .trailing) } }
        }
    }

    private func symbol(_ crumb: String, index: Int, last: Bool) -> String {
        if last && isFile { return "doc" }
        if index == 0 {
            if crumb == NSHomeDirectory() { return "house" }
            if crumb.hasPrefix("/Volumes/") { return "externaldrive" }
            return "internaldrive"
        }
        return "folder"
    }

    @ViewBuilder
    private func segment(_ crumb: String, index: Int, last: Bool) -> some View {
        let label = HStack(spacing: 3) {
            Image(systemName: symbol(crumb, index: index, last: last))
                .font(.system(size: 10))
            Text(PathNameCache.shared.name(crumb))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(last ? Color.primary : Color.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())

        let isCurrentFolder = !isFile && last && store.activeQuery == nil && store.currentFolder == crumb
        Group {
            if last && isFile || isCurrentFolder {
                label
            } else {
                Button {
                    store.openFolder(URL(fileURLWithPath: crumb, isDirectory: true))
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .help(crumb)
        .contextMenu {
            Button("拷贝路径") { FileActions.copy(crumb) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: crumb)]) }
        }
    }
}

/// 路径里每一层显示的名字（「Downloads」显示成「下载」）。系统查一次就记下来，不用每次重画都去问文件系统。
@MainActor
final class PathNameCache {
    static let shared = PathNameCache()
    private var names: [String: String] = [:]

    func name(_ path: String) -> String {
        if let name = names[path] { return name }
        let name = FileManager.default.displayName(atPath: path)
        if names.count > 2000 { names.removeAll() }
        names[path] = name
        return name
    }
}
