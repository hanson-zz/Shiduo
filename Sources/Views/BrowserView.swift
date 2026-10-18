import QuickLook
import SwiftUI

enum ViewMode: String {
    case grid
    case list
}

/// 一个文件列表页面：分类、智能文件夹、固定文件夹和搜索结果共用。
struct BrowserView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    let title: String
    let showsOCRTools: Bool
    /// 微信 / QQ 文件页。
    var chatApp: ChatApp? = nil

    @State private var ocrFilter = ""
    @State private var chatKind: ChatFileKind = .all
    /// “来源”筛选：只看从某个来源下载的文件。
    @State private var sourceFilter: String?

    private var sourceGroups: [SourceGroup] { SourceGroup.make(from: store.items) }

    private var visible: [FileItem] {
        var list = store.items
        if chatApp != nil, chatKind != .all {
            list = list.filter(chatKind.includes)
        }
        if let sourceFilter {
            list = list.filter { $0.downloadSource?.id == sourceFilter }
        }
        let needle = ocrFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard showsOCRTools, !needle.isEmpty else { return list }
        return list.filter { item in
            item.name.lowercased().contains(needle)
                || (ocr.text(for: item)?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let query = store.activeQuery {
                ChipBar(query: query)
                Divider()
            }
            if let chatApp {
                ChatFilesBar(app: chatApp, kind: $chatKind)
                Divider()
            }
            if store.activeQuery == nil, store.currentFolder != nil {
                FolderPathBar()
                Divider()
            }
            // 设了来源筛选时菜单一直显示，免得列表里没有下载文件时没法清掉筛选。
            if showsOCRTools || !sourceGroups.isEmpty || sourceFilter != nil {
                HStack(spacing: 12) {
                    if showsOCRTools { ocrBar }
                    if !sourceGroups.isEmpty || sourceFilter != nil { sourceMenu }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            content
        }
        .onChange(of: store.selection) { sourceFilter = nil }
        // 进子文件夹、换一个搜索也清掉来源筛选。
        .onChange(of: store.browsePath) { sourceFilter = nil }
        .onChange(of: store.activeQuery) { sourceFilter = nil }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let bytes = visible.reduce(Int64(0)) { $0 + $1.size }
        return String(localized: "\(visible.count) 个项目 · \(bytes.byteText)")
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("正在查找…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty, chatApp != nil {
            ContentUnavailableView {
                Label("没有找到\(chatApp?.name ?? "")文件", systemImage: "tray")
            } description: {
                Text("如果系统询问“拾掇想访问其他 App 的数据”，请点“允许”。\n也可以在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”里打开拾掇，然后点“重新扫描”。")
            } actions: {
                Button("打开完全磁盘访问权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if visible.isEmpty {
            ContentUnavailableView(
                store.activeQuery != nil ? String(localized: "没有找到匹配的文件") : String(localized: "这里还没有文件"),
                systemImage: store.activeQuery != nil ? "magnifyingglass" : "tray",
                description: Text(store.activeQuery != nil ? String(localized: "试试去掉一个筛选条件。") : "")
            )
        } else {
            FileCollectionView(items: visible)
        }
    }

    private var sourceMenu: some View {
        let groups = sourceGroups
        let current = groups.first { $0.source.id == sourceFilter }
        return Menu {
            Button("全部来源") { sourceFilter = nil }
            Divider()
            ForEach(groups.prefix(40)) { group in
                Button("\(group.source.name)（\(group.items.count)）") { sourceFilter = group.source.id }
            }
        } label: {
            Label(current.map { String(localized: "来源：\($0.source.name)") } ?? String(localized: "来源：全部"), systemImage: current?.source.symbol ?? "arrow.down.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(sourceFilter == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.16)))
        .help("按下载来源筛选")
    }

    private var ocrBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.secondary)
            TextField("按图中文字筛选", text: $ocrFilter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if let progress = ocr.batchProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text(ocr.batchStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("停止") { ocr.cancelBatch() }
            } else {
                if !ocr.batchStatus.isEmpty {
                    Text(ocr.batchStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    ocr.recognizeAll(store.items)
                } label: {
                    Label("识别文字", systemImage: "text.viewfinder")
                }
                .help("在本机识别这里所有图片中的文字（最多 500 张），之后就能按文字筛选和搜索")
            }
        }
    }
}

/// 微信 / QQ 文件页顶部：按文件 / 图片 / 视频筛选，重新扫描。
struct ChatFilesBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var chat: ChatFilesStore
    let app: ChatApp
    @Binding var kind: ChatFileKind

    var body: some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $kind) {
                ForEach(ChatFileKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Text("共 \(chat.bytes(app).byteText)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if chat.isScanning {
                ProgressView().controlSize(.small)
                Text("正在扫描…").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await chat.scan()
                    store.reload()
                }
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(chat.isScanning)
            Button {
                store.openCleanup(.chatFiles)
            } label: {
                Label("清理大文件", systemImage: "sparkles")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct FileCollectionView: View {
    @EnvironmentObject private var store: LibraryStore
    let items: [FileItem]

    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 120
    @State private var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.sortDate, order: .reverse)]
    @State private var previewURL: URL?
    /// 图片用自己的预览，能直接划选文字。
    @State private var liveItem: FileItem?
    /// 网格的宽度，用来算 ↑ ↓ 一次跳几个。
    @State private var gridWidth: CGFloat = 800
    /// 点格子后让网格拿到键盘焦点（AppKit 接走了点按，SwiftUI 不会自动给焦点）。
    @FocusState private var gridFocused: Bool
    /// ⇧ 连选的起点：上一次普通点按 / ⌘ 点按 / 方向键选中的那个（和访达一样）。
    @State private var selectionAnchor: FileItem.ID?
    /// 框选：拖出来的矩形（网格坐标），和开始框选前已经选中的。
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<FileItem.ID> = []
    @State private var marqueeFlags: NSEvent.ModifierFlags = []
    /// 网格可见区域的高度：空白处也能开始框选。
    @State private var viewportHeight: CGFloat = 0
    /// 每个格子在网格里的位置（引用类型，更新它不会重画网格）。
    @State private var cellFrames = GridCellFrames()

    private var sorted: [FileItem] { items.sorted(using: sortOrder) }

    var body: some View {
        Group {
            if viewMode == .grid {
                grid
            } else {
                table
            }
        }
        .quickLookPreview($previewURL, in: sorted.map(\.url))
        // 在快速查看窗口里用方向键翻页时，列表 / 网格的选中跟着走。
        .onChange(of: previewURL) {
            guard let url = previewURL, let item = sorted.first(where: { $0.url == url }),
                  store.selectedIDs != [item.id] else { return }
            store.selectedIDs = [item.id]
        }
        // 预览开着时，在列表 / 网格里用方向键换了选中，预览跟着换。
        .onChange(of: store.selectedIDs) { followSelection() }
        .overlay {
            if let liveItem {
                LiveTextPreview(item: liveItem, onClose: { self.liveItem = nil }, onStep: { _ = step($0) },
                                onStepRow: { _ = step($0 * (viewMode == .grid ? gridColumns : 1)) })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: liveItem?.id)
        .toolbar {
            ToolbarItemGroup {
                if viewMode == .grid {
                    Slider(value: $thumbnailSize, in: 64...256) {
                        Text("缩略图大小")
                    }
                    .frame(width: 120)
                    .help("缩略图大小")
                }
                Picker("显示方式", selection: $viewMode) {
                    Label("图标", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("列表", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                Menu {
                    Button("按日期（新的在前）") {
                        sortOrder = [KeyPathComparator(\FileItem.sortDate, order: .reverse)]
                    }
                    Button("按名称") {
                        sortOrder = [KeyPathComparator(\FileItem.name)]
                    }
                    Button("按大小（大的在前）") {
                        sortOrder = [KeyPathComparator(\FileItem.size, order: .reverse)]
                    }
                    Button("按种类") {
                        sortOrder = [KeyPathComparator(\FileItem.kindText), KeyPathComparator(\FileItem.name)]
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    quickLookSelection()
                } label: {
                    Label("快速查看", systemImage: "eye")
                }
                .keyboardShortcut("y", modifiers: .command)
                .help("快速查看（空格或 ⌘Y）")
                Button {
                    store.showInspector.toggle()
                } label: {
                    Label("简介", systemImage: "info.circle")
                }
                .help("显示或隐藏简介")
            }
        }
    }

    // MARK: 网格

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize + 28), spacing: 8)], spacing: 10) {
                ForEach(sorted) { item in
                    FileGridCell(
                        item: item, size: CGFloat(thumbnailSize), selected: store.selectedIDs.contains(item.id),
                        copyText: TextExtractor.canExtract(item) ? { store.copyText(targets(for: item)) } : nil,
                        // 左键点按、双击和拖动交给 AppKit：拖动选中的格子时一次带上所有选中的文件（macOS 14 起都行）。
                        mouseArea: FileCellMouseArea(
                            urls: { targets(for: item).map(\.url) },
                            onClick: { count, flags in
                                gridFocused = true
                                if count >= 2 {
                                    store.open(item, in: sorted)
                                } else {
                                    select(item, flags: flags)
                                }
                            }
                        )
                    )
                        .contextMenu {
                            FileContextMenu(items: targets(for: item), preview: { preview($0) })
                        }
                        .help(item.path)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: GridCellFramesKey.self,
                                                   value: [item.id: proxy.frame(in: .named(Self.gridSpace))])
                        })
                }
            }
            // 量网格本身的宽度（不含边距和滚动条），↑ ↓ 的每行个数才和实际排版一致。
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { gridWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { gridWidth = proxy.size.width }
            })
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
            // 在空白处拖动：框选（格子上拖动仍然是把文件拖出去）。
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
            )
            .overlay(alignment: .topLeading) {
                if let marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(GridCellFramesKey.self) { frames in cellFrames.frames = frames }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { viewportHeight = proxy.size.height }
        })
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            quickLookSelection()
            return .handled
        }
        // ← → 前后一个，↑ ↓ 上下一行；带修饰键的（⌘↑ 上一层等）留给菜单快捷键。
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard press.modifiers.subtracting([.numericPad, .function]).isEmpty else { return .ignored }
            switch press.key {
            case .leftArrow: return step(-1)
            case .rightArrow: return step(1)
            case .upArrow: return step(-gridColumns)
            default: return step(gridColumns)
            }
        }
        .onKeyPress(.escape) {
            guard previewURL != nil || liveItem != nil else { return .ignored }
            previewURL = nil
            liveItem = nil
            return .handled
        }
    }

    private static let gridSpace = "fileGrid"

    /// 在网格空白处拖出矩形选中文件（和访达一样）：⇧ 加选，⌘ 反选；只点一下空白处取消选中。
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if marquee == nil {
                    gridFocused = true
                    marqueeFlags = NSEvent.modifierFlags
                    marqueeBase = marqueeFlags.contains(.shift) || marqueeFlags.contains(.command) ? store.selectedIDs : []
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                marquee = rect
                guard rect.width >= 3 || rect.height >= 3 else { return }
                let hit = Set(cellFrames.frames.filter { $0.value.intersects(rect) }.map(\.key))
                let next = marqueeFlags.contains(.command) ? marqueeBase.symmetricDifference(hit) : marqueeBase.union(hit)
                if next != store.selectedIDs { store.selectedIDs = next }
            }
            .onEnded { value in
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if moved < 3, !marqueeFlags.contains(.shift), !marqueeFlags.contains(.command) {
                    store.selectedIDs = []
                }
                // 下次 ⇧ 连选从框选到的第一个开始。
                if let first = sorted.first(where: { store.selectedIDs.contains($0.id) }) { selectionAnchor = first.id }
                marquee = nil
            }
    }

    /// 网格每行几个（和 LazyVGrid 的 adaptive 列数算法一致：间距 8）。gridWidth 已是网格本身的宽度。
    private var gridColumns: Int {
        let cell = thumbnailSize + 28 + 8
        return max(1, Int((gridWidth + 8) / cell))
    }

    /// 方向键在文件之间移动；预览打开时由 followSelection 跟着翻页。
    private func step(_ offset: Int) -> KeyPress.Result {
        let list = sorted
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { store.selectedIDs.contains($0.id) } ?? (offset > 0 ? -1 : list.count)
        let target = min(max(index + offset, 0), list.count - 1)
        store.selectedIDs = [list[target].id]
        selectionAnchor = list[target].id
        return .handled
    }

    /// 预览开着、选中换了：预览换成新选中的那个。
    private func followSelection() {
        guard previewURL != nil || liveItem != nil,
              let item = sorted.first(where: { store.selectedIDs.contains($0.id) }) else { return }
        if item.url == previewURL || item.id == liveItem?.id { return }
        previewURL = nil
        liveItem = nil
        preview(item)
    }

    // MARK: 列表

    private var table: some View {
        Table(of: FileItem.self, selection: $store.selectedIDs, sortOrder: $sortOrder) {
            TableColumn("名称", value: \FileItem.name) { item in
                HStack(spacing: 6) {
                    ThumbnailView(url: item.url, size: 20)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.path)
            }
            .width(min: 180, ideal: 320)
            TableColumn("修改日期", value: \FileItem.sortDate) { item in
                Text(item.sortDate == .distantPast ? "--" : item.sortDate.shortText)
            }
            .width(min: 110, ideal: 150)
            TableColumn("大小", value: \FileItem.size) { item in
                Text(item.sizeText)
            }
            .width(min: 60, ideal: 80)
            TableColumn("种类", value: \FileItem.kindText) { item in
                Text(item.kindText)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            // 每一行自己提供拖动内容：拖动选中的几行时，选中的文件一起拖出去。
            ForEach(sorted) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            FileContextMenu(items: resolve(ids), preview: { preview($0) })
        } primaryAction: { ids in
            let list = resolve(ids)
            if list.count == 1, let item = list.first {
                store.open(item, in: sorted)
            } else {
                store.openItems(list)
            }
        }
        .onKeyPress(.space) {
            quickLookSelection()
            return .handled
        }
    }

    // MARK: 选择

    private func resolve(_ ids: Set<String>) -> [FileItem] {
        sorted.filter { ids.contains($0.id) }
    }

    private func targets(for item: FileItem) -> [FileItem] {
        store.selectedIDs.contains(item.id) ? resolve(store.selectedIDs) : [item]
    }

    private func select(_ item: FileItem, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let list = sorted
        // 起点优先用上一次点的那个；它不在当前列表或已不在选中里，再退回到排在最前的已选文件。
        let anchorIndex = list.firstIndex { $0.id == selectionAnchor && store.selectedIDs.contains($0.id) }
            ?? list.firstIndex { store.selectedIDs.contains($0.id) }
        if flags.contains(.shift), let anchor = anchorIndex,
           let index = list.firstIndex(where: { $0.id == item.id }) {
            // ⇧ 点按：从起点连选到这里（起点不变，可以反复调整范围）。
            let range = min(anchor, index)...max(anchor, index)
            store.selectedIDs = Set(list[range].map(\.id))
            if selectionAnchor == nil { selectionAnchor = list[anchor].id }
        } else if flags.contains(.command) {
            if store.selectedIDs.contains(item.id) {
                store.selectedIDs.remove(item.id)
            } else {
                store.selectedIDs.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            store.selectedIDs = [item.id]
            selectionAnchor = item.id
        }
    }

    private func quickLookSelection() {
        if previewURL != nil || liveItem != nil {
            previewURL = nil
            liveItem = nil
        } else if let first = sorted.first(where: { store.selectedIDs.contains($0.id) }) {
            preview(first)
        }
    }

    /// 图片用能划选文字的预览，其他文件用系统的快速查看。
    private func preview(_ item: FileItem) {
        if item.isImage && UserDefaults.standard.object(forKey: "liveTextPreview") as? Bool ?? true {
            liveItem = item
        } else {
            previewURL = item.url
        }
    }
}

/// 网格里每个格子的位置（框选用）。
final class GridCellFrames {
    var frames: [FileItem.ID: CGRect] = [:]
}

struct GridCellFramesKey: PreferenceKey {
    static let defaultValue: [FileItem.ID: CGRect] = [:]
    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct FileGridCell: View {
    let item: FileItem
    let size: CGFloat
    let selected: Bool
    /// 图片和 PDF：鼠标移上去显示“拷贝文字”。
    var copyText: (() -> Void)?
    /// 盖在格子上处理点按、双击和拖出的 AppKit 视图（可以一次拖出多个文件）。
    /// 「拷贝文字」按钮放在它上面，仍然点得到。
    var mouseArea: FileCellMouseArea? = nil

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(url: item.url, size: size)
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: size + 16)
            Text(item.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .overlay { mouseArea }
        .overlay(alignment: .top) {
            // 和缩略图一样大、一样位置的透明框，按钮贴在它右下角。
            Color.clear
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if hovering, let copyText {
                        Button(action: copyText) {
                            Label("拷贝文字", systemImage: "text.viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.regularMaterial))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("识别并拷贝图中文字（⇧⌘C）")
                        .transition(.opacity)
                    }
                }
                .padding(.top, 8)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 固定文件夹 / 外接磁盘 / 任意文件夹页面顶部：返回、上一层、可点的路径。子文件夹都在拾掇里打开，不跳到访达。
struct FolderPathBar: View {
    @EnvironmentObject private var store: LibraryStore

    /// 从根目录（或个人文件夹）到当前文件夹的每一层。
    private var crumbs: [(name: String, path: String)] {
        guard let root = store.browseRoot, let current = store.currentFolder else { return [] }
        // 任意文件夹：从个人文件夹（或磁盘根目录）开始，方便往上走
        var start = root
        if case .folder = store.selection {
            let home = NSHomeDirectory()
            start = current.hasPrefix(home + "/") || current == home ? home : "/"
        }
        var list: [(String, String)] = [(FileManager.default.displayName(atPath: start), start)]
        guard current != start else { return list }
        var path = start
        let rest = current.dropFirst(start == "/" ? 1 : start.count + 1)
        for part in rest.split(separator: "/") {
            path = (path as NSString).appendingPathComponent(String(part))
            list.append((FileManager.default.displayName(atPath: path), path))
        }
        return list
    }

    private var rootSymbol: String {
        switch store.selection {
        case .volume: return "externaldrive"
        case .folder: return "house"
        default: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 20)
            }
            .disabled(!store.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("返回（⌘[）")
            Button {
                store.goUp()
            } label: {
                Image(systemName: "arrow.turn.left.up")
                    .frame(width: 22, height: 20)
            }
            .disabled(!store.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("上一层文件夹（⌘↑）")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let list = crumbs
                    ForEach(Array(list.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            store.openFolder(URL(fileURLWithPath: crumb.path, isDirectory: true))
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: rootSymbol)
                                }
                                Text(crumb.name).lineLimit(1)
                            }
                            .font(.callout.weight(index == list.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == list.count - 1 ? Color.primary : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == list.count - 1)
                        .help(crumb.path)
                    }
                }
            }
            Spacer(minLength: 8)
            if let current = store.currentFolder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
