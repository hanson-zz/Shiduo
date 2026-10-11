import SwiftUI

extension FileCategory {
    var tint: Color {
        switch self {
        case .recents: return .gray
        case .images: return .orange
        case .videos: return .pink
        case .music: return .red
        case .documents: return .blue
        case .archives: return .brown
        case .apps: return .purple
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore

    private var totalBytes: Int64 { store.totals.values.reduce(0) { $0 + $1.bytes } }
    private var totalCount: Int { store.totals.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                    ForEach(FileCategory.dashboard) { category in
                        CategoryCard(category: category, total: store.totals[category])
                            .onTapGesture { store.selection = .category(category) }
                    }
                }
                if !store.dashboardLoaded {
                    ProgressView("正在读取 Spotlight 索引…")
                        .frame(maxWidth: .infinity)
                }
                ForEach(store.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
                if store.dashboardLoaded && store.totals.values.allSatisfy({ $0.count == 0 }) {
                    ContentUnavailableView(
                        "没有读到任何文件",
                        systemImage: "magnifyingglass",
                        description: Text("拾掇依赖 Spotlight 索引。请确认“系统设置 ▸ Spotlight”中没有关闭文件索引。")
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle("首页")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refreshDashboard() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新统计")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("你的 Mac 里有什么")
                .font(.largeTitle.bold())
            if totalCount > 0 {
                Text("已索引 \(totalCount) 个文件，共 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CategoryCard: View {
    let category: FileCategory
    let total: CategoryTotal?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: category.symbol)
                    .font(.title2)
                    .foregroundStyle(category.tint)
                Spacer()
                if total == nil { ProgressView().controlSize(.small) }
            }
            Text(category.title)
                .font(.headline)
            Text(total.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? "…")
                .font(.title3.weight(.semibold))
            Text(total.map { "\($0.count) 个项目" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(category.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(category.tint.opacity(0.2)))
        .contentShape(Rectangle())
    }
}

struct ShelfView: View {
    @EnvironmentObject private var store: LibraryStore
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shelf.title, systemImage: shelf.symbol)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("查看全部") { store.selection = shelf.target }
                    .buttonStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.items) { item in
                        VStack(spacing: 6) {
                            ThumbnailView(url: item.url, size: 96)
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 110)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(store.selectedIDs.contains(item.id) ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                        .onTapGesture { store.selectedIDs = [item.id] }
                        .contextMenu { FileContextMenu(items: [item]) }
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .help(item.path)
                    }
                }
            }
        }
    }
}
