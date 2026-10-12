import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cleanup: CleanupScanner
    @EnvironmentObject private var duplicates: DuplicateScanner

    private var totalBytes: Int64 { store.totals.values.reduce(0) { $0 + $1.bytes } }
    private var totalCount: Int { store.totals.values.reduce(0) { $0 + $1.count } }

    private var cleanupCards: [CleanupCard] {
        cleanup.cards.filter { !$0.items.isEmpty && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    private var reclaimable: Int64 { cleanup.totalBytes + duplicates.reclaimable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                library
                cleanupSection
                if !store.sourceGroups.isEmpty { sourcesSection }
                ForEach(store.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
                PrivacyBadges()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                if store.dashboardLoaded && store.totals.values.allSatisfy({ $0.count == 0 }) {
                    ContentUnavailableView(
                        "没有读到任何文件",
                        systemImage: "magnifyingglass",
                        description: Text("拾掇依赖 Spotlight 索引。请确认“系统设置 ▸ Spotlight”中没有关闭文件索引。")
                    )
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("首页")
    }

    // MARK: - 问候

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return String(localized: "早上好")
        case 11..<14: return String(localized: "中午好")
        case 14..<18: return String(localized: "下午好")
        default: return String(localized: "晚上好")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                if totalCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CountingNumber(value: Double(totalCount))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                        Text("个文件，共 \(totalBytes.byteText)，每一类都有自己的货架")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在读取 Spotlight 索引…")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await store.refreshDashboard() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .help("重新统计")
        }
    }

    // MARK: - 资料库

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "资料库"), count: FileCategory.dashboard.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(FileCategory.dashboard) { category in
                    LibraryTile(category: category, total: store.totals[category], previews: store.previews[category] ?? [])
                        .onTapGesture { store.selection = .category(category) }
                }
            }
        }
    }

    // MARK: - 清理

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: String(localized: "清理"),
                badge: reclaimable > 0 ? String(localized: "最多可腾出 \(reclaimable.byteText)") : nil,
                action: { store.selection = .cleanup }
            )
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                DuplicatesTile()
                    .onTapGesture { store.selection = .duplicates }
                if cleanup.isRunning && cleanup.cards.isEmpty {
                    placeholderTile(String(localized: "正在找可以清理的文件…"))
                } else if cleanup.hasScanned && cleanupCards.isEmpty {
                    placeholderTile(String(localized: "没有需要清理的，很整齐"))
                }
                ForEach(cleanupCards.prefix(3)) { card in
                    CleanupTile(card: card)
                        .onTapGesture { store.openCleanup(card.kind) }
                }
            }
            Label("不会直接删除，都进废纸篓，随时可以放回原处。", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func placeholderTile(_ text: String) -> some View {
        HStack(spacing: 10) {
            if cleanup.isRunning { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .glassCard()
    }

    // MARK: - 下载来源

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "下载来源"), count: store.sourceGroups.count, action: { store.openDownloads(source: nil) })
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(store.sourceGroups.prefix(8)) { group in
                    SourceTile(group: group)
                        .onTapGesture { store.openDownloads(source: group.source.id) }
                }
            }
        }
    }
}

// MARK: - 卡片

/// 资料库分类卡片：左上角彩色图标，右上角几张最近文件，底部是数量和大小。
struct LibraryTile: View {
    let category: FileCategory
    let total: CategoryTotal?
    let previews: [FileItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TintedIcon(symbol: category.symbol, tint: category.tint, size: 42)
                Spacer()
                if total == nil {
                    ProgressView().controlSize(.small)
                } else {
                    StackedThumbnails(items: previews, total: total?.count ?? 0, size: 30)
                }
            }
            Spacer(minLength: 18)
            Text(category.title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
            HStack(spacing: 6) {
                Text(total.map { String(localized: "\($0.count) 个项目") } ?? String(localized: "统计中…"))
                Text("·")
                Text(total.map { $0.bytes.byteText } ?? "")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .glassCard(tint: category.tint, interactive: true)
    }
}

struct CleanupTile: View {
    let card: CleanupCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TintedIcon(symbol: card.kind.symbol, tint: card.kind.tint, size: 36)
                Spacer()
                StackedThumbnails(items: card.items, total: card.items.count, size: 26)
            }
            Spacer(minLength: 14)
            Text(card.kind.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(card.bytes.byteText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 3) {
                    Text("\(card.items.count.formatted()) 个项目")
                    Image(systemName: "chevron.right")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .glassCard(tint: card.kind.tint, interactive: true)
    }
}

struct DuplicatesTile: View {
    @EnvironmentObject private var scanner: DuplicateScanner
    private let tint = Color(red: 0.95, green: 0.45, blue: 0.45)

    private var extraCopies: Int {
        scanner.groups.reduce(0) { $0 + max($1.items.count - 1, 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TintedIcon(symbol: "doc.on.doc", tint: tint, size: 36)
                Spacer()
                if scanner.isRunning {
                    ProgressView(value: scanner.progress)
                        .frame(width: 70)
                } else {
                    StackedThumbnails(items: scanner.groups.compactMap(\.items.first), total: scanner.groups.count, size: 26)
                }
            }
            Spacer(minLength: 14)
            Text("重复文件")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                if scanner.hasScanned {
                    Text(scanner.reclaimable.byteText)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                } else {
                    Text(scanner.isRunning ? String(localized: "扫描中…") : String(localized: "点按扫描"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                }
                Spacer()
                HStack(spacing: 3) {
                    Text(scanner.hasScanned ? String(localized: "多出 \(extraCopies.formatted()) 份") : "")
                    Image(systemName: "chevron.right")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .glassCard(tint: tint, interactive: true)
    }
}

struct SourceTile: View {
    let group: SourceGroup

    var body: some View {
        HStack(spacing: 12) {
            TintedIcon(symbol: group.source.symbol, tint: group.source.tint.color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.source.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.items.count) 个 · \(group.bytes.byteText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            StackedThumbnails(items: group.items, total: 0, size: 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: group.source.tint.color, radius: 16, interactive: true)
    }
}

struct ShelfView: View {
    @EnvironmentObject private var store: LibraryStore
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: shelf.title, action: { store.selection = shelf.target })
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        VStack(spacing: 8) {
                            ThumbnailView(url: item.url, size: 104)
                                .frame(width: 120, height: 112)
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 116)
                        }
                        .padding(8)
                        .glassCard(
                            tint: store.selectedIDs.contains(item.id) ? .accentColor : .clear,
                            radius: 14, interactive: true
                        )
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                        .onTapGesture { store.selectedIDs = [item.id] }
                        .contextMenu { FileContextMenu(items: [item]) }
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .help(item.path)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
            }
        }
    }
}
