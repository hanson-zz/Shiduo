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

    private var visible: [FileItem] {
        let needle = ocrFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard showsOCRTools, !needle.isEmpty else { return store.items }
        return store.items.filter { item in
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
            if showsOCRTools {
                ocrBar
                Divider()
            }
            content
        }
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

    private var ocrBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.secondary)
            TextField("按图中文字筛选（先点右边“识别文字”）", text: $ocrFilter)
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
            Spacer()
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
                    FileGridCell(item: item, size: CGFloat(thumbnailSize), selected: store.selectedIDs.contains(item.id))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
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
            FileActions.open(resolve(ids))
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
    }
}
