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

    @State private var ocrFilter = ""
    /// “来源”筛选：只看从某个来源下载的文件。
    @State private var sourceFilter: String?

    private var sourceGroups: [SourceGroup] { SourceGroup.make(from: store.items) }

    private var visible: [FileItem] {
        var list = store.items
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
            if showsOCRTools || !sourceGroups.isEmpty {
                HStack(spacing: 12) {
                    if showsOCRTools { ocrBar }
                    if !sourceGroups.isEmpty { sourceMenu }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            content
        }
        .onChange(of: store.selection) { sourceFilter = nil }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let bytes = visible.reduce(Int64(0)) { $0 + $1.size }
        return "\(visible.count) 个项目 · \(bytes.byteText)"
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("正在查找…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView(
                store.activeQuery != nil ? "没有找到匹配的文件" : "这里还没有文件",
                systemImage: store.activeQuery != nil ? "magnifyingglass" : "tray",
                description: Text(store.activeQuery != nil ? "试试去掉一个筛选条件。" : "")
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
            Label(current.map { "来源：\($0.source.name)" } ?? "来源：全部", systemImage: current?.source.symbol ?? "arrow.down.circle")
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

struct FileCollectionView: View {
    @EnvironmentObject private var store: LibraryStore
    let items: [FileItem]

    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 120
    @State private var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.sortDate, order: .reverse)]
    @State private var previewURL: URL?

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
                        copyText: TextExtractor.canExtract(item) ? { store.copyText(targets(for: item)) } : nil
                    )
                        .onTapGesture(count: 2) { store.open(item, in: sorted) }
                        .onTapGesture { select(item) }
                        .contextMenu {
                            FileContextMenu(items: targets(for: item), preview: { previewURL = $0.url })
                        }
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .help(item.path)
                }
            }
            .padding(16)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            quickLookSelection()
            return .handled
        }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.escape) {
            guard previewURL != nil else { return .ignored }
            previewURL = nil
            return .handled
        }
    }

    /// ← → 在文件之间移动；预览打开时跟着翻页。
    private func step(_ offset: Int) -> KeyPress.Result {
        let list = sorted
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { store.selectedIDs.contains($0.id) } ?? (offset > 0 ? -1 : list.count)
        let target = min(max(index + offset, 0), list.count - 1)
        store.selectedIDs = [list[target].id]
        if previewURL != nil { previewURL = list[target].url }
        return .handled
    }

    // MARK: 列表

    private var table: some View {
        Table(sorted, selection: $store.selectedIDs, sortOrder: $sortOrder) {
            TableColumn("名称", value: \FileItem.name) { item in
                HStack(spacing: 6) {
                    ThumbnailView(url: item.url, size: 20)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .onDrag { NSItemProvider(object: item.url as NSURL) }
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
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            FileContextMenu(items: resolve(ids), preview: { previewURL = $0.url })
        } primaryAction: { ids in
            let list = resolve(ids)
            if list.count == 1, let item = list.first {
                store.open(item, in: sorted)
            } else {
                FileActions.open(list)
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

    private func select(_ item: FileItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if store.selectedIDs.contains(item.id) {
                store.selectedIDs.remove(item.id)
            } else {
                store.selectedIDs.insert(item.id)
            }
        } else {
            store.selectedIDs = [item.id]
        }
    }

    private func quickLookSelection() {
        if previewURL != nil {
            previewURL = nil
        } else if let first = sorted.first(where: { store.selectedIDs.contains($0.id) }) {
            previewURL = first.url
        }
    }
}

struct FileGridCell: View {
    let item: FileItem
    let size: CGFloat
    let selected: Bool
    /// 图片和 PDF：鼠标移上去显示“拷贝文字”。
    var copyText: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(url: item.url, size: size)
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
